# Testing the macOS recorder

Use macOS 14+ with Xcode or the Xcode Command Line Tools installed. Run these commands from the repository root.

## Automated checks

```sh
swift test --package-path client
swift build --package-path client -Xswiftc -strict-concurrency=complete
```

The automated tests check configuration, native AAC encoding/readback, storage, recorder behavior, class-catalog validation, and completion manifests without requesting microphone access. The strict-concurrency build catches unsafe actor teardown before a future Swift 6 toolchain turns it into an error. Recorder lifecycle tests use a fake recording device; native delegate delivery and real capture need the manual check below. Manifest tests verify byte counts, known SHA-256 digests across multiple read chunks, publication after flushing, failure handling, and synchronous termination.

## Standalone recorder

Build and launch the standalone menu bar recorder from Mac Terminal.

```sh
./client/scripts/run-recorder.sh
```

To build the signed app bundle without launching it, use
`./client/scripts/run-recorder.sh --build-only`. The app is written to
`client/.build/manual/LCPRecorder.app` and runs as a menu bar-only app (`LSUIElement`
is enabled, so it has no Dock icon). On first launch, choose a class and click
**Start recording**, then allow microphone access when macOS asks. The **Class**
menu is populated
from the server-published Google Drive catalog at
`~/Lectures/Classes/classes.json`; the client never contacts Google Drive.
The catalog is normally delivered by a separate Syncthing folder
(`lecture-classes`, Mac receive-only). Class names are displayed exactly as
the Drive folder names, including spaces. The catalog must be a fresh version
1 snapshot (generated within 24 hours) before **Start recording** is enabled.
Use **Refresh** after a catalog sync; the app also refreshes it periodically.
The picker intentionally starts with no class selected; choose the class
explicitly before pressing **Start recording**. If a refresh removes the
previous selection, the app clears it instead of silently choosing another
class.
The production bundle identifier is `dev.lcp.Recorder`; the separate test
harness below uses `dev.lcp.RecorderTest`.

Open **LCP → Recorder → Microphone** and choose **System Default** or a named
input. Open **Diagnostics → Start mic check** and speak into that input. The
screen should show the input name, moving average and peak levels, and a warning
if the peak nears clipping. No class is needed and no file is saved. Close the
menu to end the check. Reopen it to confirm the check is off. Quit and reopen
the app to confirm the selected input is remembered. If an external input is
disconnected, reconnect it or explicitly choose another input before recording.
During a real recording, open **Diagnostics** to see levels without starting a
separate check. Changing inputs is available between recordings.

To install the recorder for your user account, finish any active recording,
save open drafts and quit both LCP Desktop and LCP Recorder. Then run the installer.

```sh
./client/scripts/install-recorder.sh
```

This builds, verifies, and installs the app at `~/Applications/LCP Recorder.app`.
Add that app to **System Settings → General → Login Items** if it should start
automatically after login. `--build-only` installs it without opening it.

While recording, the menu bar icon changes from `mic.fill` to
`record.circle.fill` and shows a live `MM:SS` counter. You may close the menu
while recording; the capture continues in the background. Stop the recording
from the menu when class ends. After the encoder flushes and closes the
AAC file, the app writes both files to `~/Lectures/Incoming`:

* `<COURSE>_<YYYY-MM-DD_HHmm>.m4a`
* `<COURSE>_<YYYY-MM-DD_HHmm>.m4a.ready.json`

The sidecar contains the finalized file size and SHA-256. Syncthing transports
these local files to your separately configured lecture worker.
The app also stops and finalizes an active recording during normal app termination.
Force quit, `kill -9`, or power loss cannot run that cleanup path.

## Isolated manual microphone test harness

The test host is a small menu bar app built from the production recording
engine. It intentionally exposes a free-form course field so engine validation
and failure paths can be tested without changing the Drive catalog. It writes
to the dedicated test staging folder `~/Lectures/TestIncoming`. Configure that
folder as a separate Syncthing Send Only folder with ID `lecture-test-inbox`,
paired with the test worker’s `/data/lectures-test/inbox` Receive Only folder. Test files
there are processed by the optional test worker and remain in its isolated
vault by default. If you explicitly enable the test publication drop-in, they
are published below the separate `School Lectures/LCP Test` Drive folder. They
never enter the production
`~/Lectures/Incoming` / `lecture-inbox` path. Use distinctive `LCPTEST` course
codes. The production app's picker is manifest-only and does not expose this
free-form field.

If the test Drive folder has not been created, create `LCP Test` as a child of
`School Lectures` and keep its folder ID in your local test-worker configuration
or shell environment. Do not pass the production `School Lectures` root ID to a
test run. Test and production workers use separate roots and locks.

If a copy of the test app is already running, use **Quit** in its menu before rebuilding it.

```sh
./client/scripts/run-recorder-test.sh
```

To compile and verify the app without opening it:

```sh
./client/scripts/run-recorder-test.sh --build-only
```

1. Find **LCP Test** with the microphone icon in the macOS menu bar. The app should have no Dock icon. Check that `~/Lectures/TestIncoming` exists (the test app creates it if needed).
2. Enter a distinctive test course code such as `LCPTEST1` in the free-form field. (The test harness deliberately bypasses the production Drive-backed class picker.) Click **Start** and allow microphone access when macOS asks. Speak for 10–15 seconds. The icon should become a recording circle and the `MM:SS` duration should advance about once per second, including while the menu is closed.
3. While recording, confirm there is no matching `.m4a.ready.json` file. Click **Stop**. The microphone icon should return and the duration should stop advancing. Find `LCPTEST1_YYYY-MM-DD_HHmm.m4a` and its `.m4a.ready.json` sidecar in `~/Lectures/TestIncoming`; the timestamp should use your Mac's local time. Open the audio in QuickTime Player and confirm your speech plays through to the end.
4. Verify the actual audio format with the command below, replacing the example filename. Expect **1 channel**, **16000 Hz**, AAC (`aac`), and an encoded bitrate around **32000 bits per second**. Short AAC files include container overhead, so total file size does not directly equal the configured bitrate.

   ```sh
   afinfo "$HOME/Lectures/TestIncoming/LCPTEST1_2026-10-17_1430.m4a"
   ```

5. Test collision protection: start and stop a short recording, then start again with the same course code within the same local minute. Expect an existing-file error and the first file to remain unchanged and playable. Use another course code or wait for the next minute to continue.
6. Test input validation: with microphone permission granted, use an empty course code or `../BAD`. **Start** should show an error and stay stopped. Change back to `LCPTEST2` to recover.
7. Test clean termination: record 10 seconds with `LCPTESTQUIT`, then click **Quit** while recording. Play the resulting `.m4a` and run `afinfo` on it. It should be finalized and readable, with a matching `.m4a.ready.json` sidecar. This checks normal app termination; force quit, `kill -9`, and power loss do not deliver the normal termination notification and may leave audio without a completion marker.
8. Optional permission test: quit the app, turn off **LCP Recorder Test** in **System Settings → Privacy & Security → Microphone**, then relaunch the script and try **Start**. Expect an actionable error and no active recording. Restore microphone access and relaunch before continuing. If macOS does not list the app yet, try **Start** once to request access.

After a successful stop, the client streams the finalized audio through SHA-256 and atomically writes `<audio filename>.ready.json` with exactly `version: 1`, `filename`, `size_bytes`, and `sha256`. Compare `size_bytes` with `stat -f %z <audio path>` and `sha256` with `shasum -a 256 <audio path>`. No completion marker is published for a failed start, unsuccessful completion, or encoder error. If marker writing fails, the audio remains available and the app shows an error; the test worker must leave unmarked audio unprocessed. The client performs no network operations.

To verify transport and publication, follow the test-environment runbook using
your Syncthing peer and SSH target. For a publication check, use the dedicated
Drive test folder with the optional test worker. [Transport test instructions](../docs/transport-testing.md)

The app uses the stable development bundle ID `dev.lcp.RecorderTest` and ad-hoc signing. A rebuild can cause macOS to request microphone permission again. The script does not reset privacy permissions.
