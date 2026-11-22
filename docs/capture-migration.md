# Capture compatibility and idle migration

The desktop and revised menu-bar recorder share `CaptureCoordinator` and lease
protocol 1 (`org.lcp.capture.v1`). Neither build changes recording format, naming,
catalog eligibility, transport, worker state, or paid processing. Both acquire
`~/Library/Application Support/LCP Capture/capture.lock` before recording and
hold its open file descriptor until the encoder closes and ready-marker work
finishes. Do not remove this lock file: the inode is the exclusion boundary.
Owner text is diagnostic only; the OS releases the lock after a crash.
The compatible recorder's optional microphone check holds the same lease until
its local capture session stops; it cannot bypass desktop recording exclusion.
Desktop callers pass the saved Drive-folder ID as `expectedDriveFolderID` with
the exact course code. Both catalog validations check that precondition, so a
deleted/recreated same-name folder requires explicit remapping. The legacy
picker may omit it because the user selects directly from the current catalog.

The original installed recorder does not implement this protocol. A shared lock
cannot constrain an old binary that ignores it. Capture preflight checks the known
`~/Applications/LCP Recorder.app` and `/Applications/LCP Recorder.app` installs,
their signed compatibility metadata, and running `dev.lcp.Recorder` / `LCPRecorder`
processes. Unknown, renamed, or third-party old copies are unsupported and must
remain inactive. Dynamic code validity is checked before reading a running
process's signed metadata, so replacing its app on disk does not certify an old
running instance as upgraded. An unreadable signature/version fails closed.

## Build and automated validation — Mac Terminal

From the native LCP checkout on macOS arm64:

```sh
swift test --package-path client
swift build --package-path client -Xswiftc -strict-concurrency=complete
./client/scripts/run-recorder.sh --build-only
```

The last command creates `client/.build/manual/LCPRecorder.app`, verifies its
Info.plist and ad-hoc signature, and never opens or installs it. Its metadata
contains `LCPCaptureProtocolVersion=1` and
`LCPCaptureLeaseIdentifier=org.lcp.capture.v1`. Tests inject fake microphone
dependencies, private temporary catalog/staging/lease roots and process checks.
They do not use real lectures, production ready markers, or provider APIs.

`install-recorder.sh --build-only` **installs** without opening. Do not confuse
it with the build-only command above. Installation refuses to proceed while a
known recorder or desktop process remains running.

## Reviewed idle rollout — Mac only, after recording finishes

1. Keep the original app running until any lecture fully finalizes. Observe
   saving complete in its UI; verify the resulting audio/marker through the
   normal recording workflow. Do not manufacture a ready marker for older
   incomplete audio as part of migration.
2. Close both desktop and original recorder using their normal Quit commands.
   Retire the original recorder's automatic Login Item before continuing. Do
   not force-quit a recording or change microphone privacy/signing settings to
   bypass an error.
3. Preserve an inactive copy of the original app outside the two active install
   paths for cold rollback. Review the compatible desktop/recorder build and
   its test results. With every capture host closed, install the compatible
   recorder using `./client/scripts/install-recorder.sh --build-only`.
4. Verify the installed signature and both compatibility keys, then launch the
   compatible recorder/desktop. Choose one supported host to reopen at login;
   do not retain an auto-launch path to the original binary. Refresh the local
   class catalog. Synced recording destinations require a fresh catalog. Offline classes can record to their local library.
5. Perform the isolated acceptance checkpoint below before relying on desktop
   capture. No automated test here establishes real microphone, native GUI,
   login relaunch, or external transport acceptance.

## Isolated acceptance checkpoint

Use a dedicated synthetic staging directory and catalog, never production
Incoming. Build a test host around the public coordinator with those paths while
keeping the **same shared lease path** for the two hosts under test. Do not use
the older direct-engine free-form manual harness to claim lease acceptance.

Start desktop capture, then attempt capture in the compatible recorder: the
second host must report that capture is in use. Repeat in reverse order and with
nearly simultaneous clicks. Stop the owner and attempt another start while it
shows Saving: exclusion must persist until the encoder closes and its v1 marker
is written. Verify AAC 16 kHz mono at 32 kbps, marker byte count/SHA256, frozen
destination, session UUID, academic association, start instant and timezone.
Reopen the desktop and verify its persisted finalized association.

While idle, refresh a stale/removed destination and verify start stays blocked;
cancel/deny a permission prompt and verify a subsequent authorized attempt can
acquire the lease. Test process-crash recovery only with disposable synthetic
recordings: the next owner may acquire the lease, but unfinished audio must stay
unmarked. Verify ordinary Quit waits for asynchronous closure, and check login
relaunch manually. Agent/network actions must not start capture.

## Cold rollback

Quit the desktop and compatible recorder completely, with all recordings fully
finalized. Disable their automatic launch entries before restoring the inactive
original binary and its chosen login entry. Preserve all academic data and
recordings. The restored original is unsupported for coexistence; desktop capture
must block again until a compatible installation is restored. Do not remove the
shared lock file or reset worker/accounting state to complete rollback.
