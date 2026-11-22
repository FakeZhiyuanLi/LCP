# Isolated manual capture acceptance

These two native test hosts exercise the production `CaptureCoordinator` on the
Apple Silicon Mac. They use the ordinary shared capture lease, a generated local
catalog and explicit synthetic folder identities. Audio stays under
`~/Library/Application Support/LCP Capture/Acceptance/<runID>/Incoming`, outside
both production and test Syncthing folders. No transcription or Drive request is
made. Do not add this folder to Syncthing.

This is a hardware/manual checkpoint, not an automated test result. Building and
opening a host does not request microphone access. Only an explicit **Start**
press does so. Record short fictional sentences and retain the files privately.
Never use these hosts to record a real class.

Build on the Mac, from the native LCP checkout:

```sh
# Mac Terminal
run_id="capture-$(date -u +%Y%m%dT%H%M%SZ)"
./client/scripts/build-capture-acceptance.sh --run-id "$run_id"
```

The build prints two exact `open` commands and a private fixture path. It does not
install, launch, stop or replace either production app. Use a new run ID on each
build; existing recordings, fixtures and builds are preserved. The generated
catalog keeps the normal 24-hour freshness gate. After it expires, build a new run
rather than bypassing freshness. Both apps use signed lease protocol metadata and
defer ordinary Quit until asynchronous audio and marker finalization complete.

Use the two printed commands to open A and B for this run.

To check Stop and Finalize, record ten seconds in A while checking that B
cannot start, then Stop A and wait for its finalized filename/digest. Reverse
the roles: record in B, verify A cannot start, then Stop B. Both must return to
idle without an error. Run the verifier below; it must show two passing finalized
recordings, `aac16kMono: true`, matching ready markers, and exclusion for A and B.
The longer checklist below covers additional release acceptance separately.

Before testing, leave any real recording running until it fully saves. The normal
recorder may remain idle, but do not start it during this checkpoint. Older
incompatible recorder installations correctly block both hosts; do not remove a
guard or launch the cold rollback copy to get around that result.

1. In A choose attempt 1, press **Start**, and allow the normal microphone prompt.
   Speak a fictional sentence for 10 seconds. The state must become recording,
   and duration must advance. While it is recording, press **Start** in B using
   B's attempt 1. B must display capture-in-use and create no finalized audio.
2. Stop A. Its state must go through finalizing and return to idle with a filename,
   byte count and digest. During finalizing, a nearly simultaneous Start in B
   must remain excluded until A closes its encoder and writes the marker. A short
   real finalization can finish before a click; do not claim this race was covered
   unless it was actually observed. Repeat with longer disposable speech if
   needed. Both apps retain event timestamps and state transitions.
3. Start B and repeat the exclusion check in A, then stop B. Test nearly
   simultaneous Starts in both hosts with new attempt numbers; exactly one may
   record. Never let an error cause a second marker or overwrite the first file.
4. Reuse A's completed attempt within the same minute. The existing filename
   must be rejected and its bytes preserved. Choose the next numbered attempt
   to continue. The selected destination cannot change while capture is active;
   session UUID, class ID, start instant and timezone stay in metadata receipts.
5. With a new attempt, press ordinary **Quit** while recording. The host must
   remain alive through finalization, write the normal v1 marker, then exit.
   Reopen the same test host and verify its completed file. Use QuickTime or the
   normal player deliberately to confirm the fictional sentence is audible all
   the way to the end. The verifier does not listen to speech.
6. Optional cancellation/denial check: cancel or deny the ordinary microphone
   prompt. No marked audio may appear. After restoring permission through normal
   System Settings, retry a fresh attempt and confirm the shared lease is usable.
   Do not reset TCC, sign around a privacy failure or change production settings.
7. Optional crash check uses only one of these disposable test hosts during a
   synthetic recording. Force Quit that exact host through macOS Activity Monitor
   after verifying its bundle/run identity. The next test host may acquire the
   shared lease. The crash-left audio must remain unmarked. Never force-quit the
   production recorder or manufacture a marker for unfinished audio.

After both normal recording orders, run the read-only evidence verifier:

```sh
# Mac Terminal — metadata only; no playback, marker write or upload
python3 client/scripts/verify-capture-acceptance.py --run-id "$run_id"
```

It checks actual audio SHA-256/size against the normal marker and finalized
receipts, AAC/16 kHz/mono format through `afinfo`, session/class identity,
cross-host exclusion observed during completed capture intervals, and ordinary
quit events. Exit 2 means evidence is missing or incomplete; no recordings before
a manual test is the expected incomplete state. Build/signature checks alone do
not establish real hardware behavior. The report always leaves overall manual
acceptance open because human audibility, exact click races, login relaunch and
cold rollback cannot be established from these metadata receipts.

For a repeatable check of a peer Start during Saving, run the following from
the native LCP checkout on the Apple Silicon Mac.

```sh
# Mac Terminal
python3 client/scripts/check-saving-peer.py
```

Two independent processes use generated AAC, a private capture lock, and the
normal capture coordinator. The first keeps its encoder open after Stop until
the second receives the capture-in-use error. The second then retries and saves
while the first process is still alive. The printed receipt includes the event
order, both process identities, and the sizes and digests of the two finalized
recordings. The physical microphone and interactive menu tests use the A/B
instructions above.

For login relaunch and cold rollback testing, follow the [capture migration guide](../../docs/capture-migration.md). Keep the
original rollback recorder inactive whenever desktop capture can run. Never
delete or replace the shared `capture.lock` inode to recover from a test.
