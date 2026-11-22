# Optional lecture worker

LCP Desktop can record and organize a class entirely on the Mac. To transcribe lectures on your own Linux host, sync finalized audio and its ready marker to the worker. The worker verifies the pair, keeps an independent archive, and writes timestamped Markdown, TXT and SRT files. Google Drive publication and the one-way desktop feed are optional.

## Install on a fresh worker

The package requires Python 3.10 or newer. From the repository root on the worker host, create the environment used by the example service units.

```sh
python3 -m venv "$HOME/.local/share/lcp/venv"
"$HOME/.local/share/lcp/venv/bin/python" -m pip install './server[watch]'
. "$HOME/.local/share/lcp/venv/bin/activate"
lcp-worker --help
```

Use a new, dedicated worker root. The CLI defaults to `/data/lectures`. For a first run you can use a writable directory under your home folder.

```sh
export LCP_WORK_ROOT="$HOME/.local/share/lcp/lectures"
install -d -m 700 "$LCP_WORK_ROOT" "$LCP_WORK_ROOT/inbox"
```

This distribution targets fresh self-hosted roots. An existing installation with newer worker state or provider accounting requires its matching worker and migration procedure.

For offline local processing, install the local backend. The example uses CPU inference. The first use of a named model downloads it, or you can supply a local model directory.

```sh
python -m pip install './server[runtime]'
lcp-worker watch --root "$LCP_WORK_ROOT" --transcriber local \
  --model small.en --device cpu --compute-type int8
```

For Linux x86_64 with Python 3.14, [optional pinned GPU dependencies](constraints-linux-py314.txt) describe one Pascal GPU environment. Check CTranslate2 support on your hardware when selecting CUDA compute types.

For hosted transcription, set `ELEVENLABS_API_KEY` privately on the worker and start it with `--transcriber elevenlabs`. It sends accepted audio to the provider and may incur charges. The hosted backend defaults to Scribe v2 with word timestamps and diarization. A synced inbox shared with this worker is a recording destination for that backend.

## Connect the recorder

1. Configure a Syncthing folder to send `~/Lectures/Incoming` from the Mac to `$LCP_WORK_ROOT/inbox` on the worker. Use **Send Only** on the Mac and **Receive Only** on the worker.
2. To supply synced recording destinations, publish the Google Drive class catalog from the worker and share its directory in the reverse direction to `~/Lectures/Classes` on the Mac. [Drive and catalog setup](../docs/drive-setup.md)
3. In LCP Desktop, select and save the synced destination for a class in **Capture**. The **On this Mac** destination saves recordings in the library.
4. To check the transport, generate a disposable recording in a separate test folder. [Transport check](../docs/transport-testing.md)

After finalization the recorder writes `<course>_<date>_<time>.m4a.ready.json`. The version 1 marker contains `filename`, `size_bytes`, and `sha256` for the closed AAC file. The worker reconciles either arrival order and processes only a matching file and marker. Keep both synced inputs intact. Identical input is idempotent and corrected audio has a new content identity.

## Results and quality

Under the worker root, `archive/` contains verified recordings, `state/` contains job and revision state, and `vault/<course>/` contains transcript bundles. `work/` is processing scratch. Give the worker exclusive access to this root. Transcript cues retain recording-scoped speaker IDs. An explicit calibration map can identify a professor for a particular recording.

Quality and relevance checks can hold a transcript for review. The following read-only audits inspect the local state. For a check of one lecture, add `--filename` with its exact recording basename.

```sh
lcp-worker quality-audit --root "$LCP_WORK_ROOT" --json
lcp-worker grok-audit --root "$LCP_WORK_ROOT" --json
```

The Grok audit checks local evidence for a complete, published bundle. To verify that an external agent can retrieve it, ask that agent for a dated, timestamped citation. [Agent consumption contract](../docs/agent-consumption-contract.md) · [Grok verification](../docs/grok-verification-runbook.md)

The local dashboard shows job status. Keep it on loopback unless you provide authenticated access.

```sh
lcp-dashboard --root "$LCP_WORK_ROOT" --host 127.0.0.1 --port 8186
```

To import accepted transcripts in LCP Desktop, set up the independent feed exporter on a compatible Linux worker. The exporter writes a separate directory for a one-way Syncthing share to the Mac. [Desktop exporter](desktop_exporter/README.md)

## Optional systemd units

The examples in [systemd](systemd) run as the worker user and expect `/data/lectures` (`/data/lectures-test` for isolated tests). Adjust those paths and prepare the directories before enabling the units. The sample worker service selects hosted transcription and local fallback. Install the runtime dependencies for local fallback and put the API key in a mode-0600 `~/.config/lcp/runtime.env`. For a local-only service, use the local command above as the service's `ExecStart`, with the virtual environment binary and an explicit worker root.

Copy only the units you intend to run to `~/.config/systemd/user/`. Start a unit explicitly after `systemctl --user daemon-reload` and inspect it with `systemctl --user status`. Use the optional publication drop-in only after configuring and verifying the correct Drive account and destination. [Drive setup](../docs/drive-setup.md)

## Tests

From the repository root in a Python environment on the worker host, run the offline suite with synthetic fixtures.

```sh
python -m pip install './server[test]'
python -m pytest server/tests
```
