"""Wake ingestion on completed writes/renames, and reconcile missed events."""

import logging
import math
import threading
from pathlib import Path
from typing import Any

from .manifest import SUFFIX
from .worker import Worker, WorkerBusy

LOGGER = logging.getLogger(__name__)


def relevant_event(path: str, inbox: Path) -> bool:
    candidate = Path(path)
    return candidate.parent == inbox and (candidate.name.endswith(".m4a") or candidate.name.endswith(SUFFIX))


def watch(worker: Worker, reconcile_seconds: float = 30, stop: threading.Event | None = None) -> None:
    """Linux close-write and moved-to notifications are hints; markers gate work."""
    if not math.isfinite(reconcile_seconds) or reconcile_seconds <= 0:
        raise ValueError("Reconciliation interval must be finite and positive")
    try:
        from watchdog.events import FileSystemEventHandler
        from watchdog.observers import Observer
    except ImportError as error:
        raise RuntimeError("Watch mode requires the 'watch' or 'runtime' installation extra") from error

    wake = threading.Event()
    stop = stop or threading.Event()

    class CompletionEvents(FileSystemEventHandler):
        def on_closed(self, event: Any) -> None:
            if not event.is_directory and relevant_event(event.src_path, worker.inbox):
                wake.set()

        def on_moved(self, event: Any) -> None:
            if not event.is_directory and relevant_event(event.dest_path, worker.inbox):
                wake.set()

    observer = Observer()
    observer.schedule(CompletionEvents(), str(worker.inbox), recursive=False)
    # Keep the inter-process lock scoped to one reconciliation pass.  Holding
    # it for the lifetime of the watcher would prevent an operator from using
    # the reprocess command (or another one-shot audit) while the service is
    # sleeping between passes.  A pass is still fully serialized with every
    # other worker operation, and filesystem events remain queued as hints for
    # the next pass.
    observer.start()
    try:
        while not stop.is_set():
            try:
                with worker.lock():
                    report = worker._reconcile()
            except WorkerBusy:
                # A one-shot/reprocess operation owns the state directory.
                # Keep the watcher alive and let the next bounded reconciliation
                # retry rather than turning a harmless overlap into a service
                # restart.
                LOGGER.info("Skipping reconciliation while another LCP operation owns the state lock")
            else:
                if report.processed or report.quality_blocked or report.failures:
                    LOGGER.info("Reconciled: %s", report)
            # Bounded wait also retries publication failures and lost events.
            wake.wait(reconcile_seconds)
            wake.clear()
    finally:
        observer.stop()
        observer.join()
