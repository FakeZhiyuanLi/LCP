# LCP Desktop

[Start here to install LCP, set up a class, and search your first reading.](GETTING-STARTED.md)

LCP keeps university classes, materials, notes, coursework and lecture references
on the student's Mac. The library works offline. A local agent bridge lets the
student share selected sources and review proposed notes. Lecture transcription
uses an optional, separately configured worker.

The app runs on Apple Silicon with macOS 14 or later. It uses the bundle ID
`org.lcp.Desktop` and opens a workspace in the Dock. The original standalone
LCP Recorder is a separate application.

## Build on the Mac

Use an Apple Silicon Mac with the full Xcode app and Python 3. The Xcode project
uses synchronized filesystem groups introduced in Xcode 16. The release was
built with Xcode 27.2. In Mac Terminal, clone the repository into an empty
location and run the commands from its root.

```sh
git clone https://github.com/FakeZhiyuanLi/LCP.git
cd LCP
swift test --package-path desktop
swift test --package-path client
desktop/scripts/build-app.sh --configuration Release
desktop/scripts/verify-release.sh --app 'desktop/build/Release/LCP Desktop.app'
```

The app build uses the shared native `LCPDesktop` Xcode scheme and
isolated DerivedData at `desktop/.build/xcode-packaging-Release`. It includes
`Contents/Helpers/LCPAgentBridge`, signed separately before the app. A
`Contents/Resources/BuildReceipt.json` records source hashes, Git HEAD/dirty state,
build time and toolchain. The script checks that the recorded inputs match the
compiled sources. It writes the staged app to `desktop/build/Release` and retains
any earlier build in that folder as a timestamped copy.

For Xcode, open `desktop/LCPDesktop.xcodeproj`, select the shared **LCPDesktop**
application scheme and **My Mac**, then Build. The same-name Swift package
executable is useful for development; the project scheme builds the native app.
The application links local `LCPContextCore`, `LCPContextServices` and `LCPClient`
products; no downloaded package is required.

Run the native Xcode smoke test from the repository root.

```sh
xcodebuild -jobs 2 -project desktop/LCPDesktop.xcodeproj -scheme LCPDesktop \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath desktop/.build/xcode-native-tests test
```

The hostless smoke test opens and reopens a temporary library. Swift package
tests cover the domain and services. Verify VoiceOver, microphone permissions
and capture on the Mac using the manual checks below.

## Open and set up

Open the staged app from Mac Terminal.

```sh
open 'desktop/build/Release/LCP Desktop.app'
```

In **Class Library**, choose **New Class…**, enter a class name
and save. You can add a term, course code or other details in **Class actions →
Edit Class** at any time. Import a reading or add a study note to start using the
class. Context search and export use the selected class.
An existing class can be archived without removing its sources or citations.

Personal state lives under `~/Library/Application Support/LCP Desktop`, separate
from `~/Lectures/Incoming`, worker state and the read-only feed. Use the app's
backup/export and restore controls before moving a profile or trying an older
binary. Never synchronize the live SwiftData store or copy it while open. Portable
backups validate their manifest, payload bytes and immutable cited revisions
before restore; retain a verified backup when changing app versions.

In **Settings → Library → Back Up Library**, choose a new folder. The default
keeps your class history, original materials and saved transcript citations.
Select **Include linked lecture audio** to take verified local recordings with
you. After restoring, open the lecture to play its audio. Import the synced feed
again to bring back available uncited transcripts.

On a Mac configured for automatic local updates, finish any recording and quit
LCP Desktop when you’re ready. A verified local build replaces the installed
app while it’s closed. Open LCP Desktop from its usual location.

For a disk image update, save open drafts, finish recording and quit LCP Desktop.
Open the disk image, drag **LCP Desktop.app** to the Applications folder containing
your existing copy, and choose **Replace**. Eject the image and open LCP from that
folder. In Finder, ⇧⌘G opens `~/Applications` for a per-user installation.

## UCI university services

Open **Connections** in the sidebar to set up Canvas, Drive, Gmail, or Calendar. **Refresh Status** rereads this library’s saved account settings. **Manage → Check Connection** checks access with the provider and shows when it succeeded during this app session.

To import material, open a class and choose **Materials → University Services**. Browse or search
in the chosen service, select a source, then import it. The copy belongs to
that LCP class. Importing the same remote item again picks up changes as a
new revision. Saved citations can still open the earlier copy offline.

- **UCI Canvas.** Open **Account → Settings → Approved Integrations** in
  UCI Canvas. If the university enables personal access tokens for your account,
  create one for your own LCP installation, then enter it under **Connections → UCI Canvas → Set Up**.
  Load your courses and choose the Canvas course corresponding to the open LCP
  class. Browse the course's available materials, including assignments,
  files, pages, modules (including safe HTTPS external links), quizzes, discussion topics, announcements and calendar events,
  then import your selection. Canvas controls which courses, files, pages,
  discussions and calendar data your account can read. A
  deployment for other students needs a developer key approved by the Canvas
  administrator. [Canvas token documentation](https://canvas.eee.uci.edu/doc/api/file.oauth.html)
- **Automatic Canvas refresh.** Open **Settings → Canvas**, choose a refresh
  interval, and connect UCI Canvas. Then open each class's **Materials →
  University Services → UCI Canvas**, load your active courses, select the
  matching Canvas course. The **Automatically import new Canvas updates** switch
  is on by default, and selecting a course with it on subscribes the class.
  LCP refreshes bounded snapshots of assignments, quizzes,
  announcements, and course calendar events for explicitly subscribed classes
  only. Classes without a saved Canvas subscription are skipped, so a similar
  course code or title cannot attach coursework to the wrong class.
- **Google Drive, Gmail and Calendar.** This preview uses your own Google Cloud
  project with the Drive API, Gmail API and Calendar API enabled. Configure the Google Auth
  Platform audience to allow your account, adding yourself as a test user if
  the app is in testing. Create a **Desktop app** OAuth client, download its
  JSON, then choose **Choose Google Client JSON** in LCP. Choose **Sign In with Google**
  for the service you want and sign in through the browser. Each connection
  requests its own read permission. Drive also offers permission to create class folders. A managed UCI account may require
  Workspace administrator approval. [Google desktop OAuth guide](https://developers.google.com/identity/protocols/oauth2/native-app) · [Google API Library](https://console.cloud.google.com/apis/library)
- **Class folders in Drive.** New classes automatically look for a matching folder directly under **School Lectures**, using the course code or, if omitted, the class name. LCP reuses a match and creates a missing folder when Drive allows it. An offline class saves immediately and folder setup can resume later. Open **Materials** for the folder link or setup status. Older classes can opt in with **Set Up Google Drive Folder**. If Drive was connected for reading, choose **Connections → Google Drive → Manage… → Enable Folder Creation…** to authorize creation. To send recordings for server processing, choose the synced destination separately in **Capture**.
- **Drive materials.** Search for a file by name or text. LCP downloads the
  selected file or exports supported Google Workspace documents, slides and
  sheets as PDFs. **Gmail materials.** Use a Gmail search such as
  `subject:"ICS 46" newer_than:30d`, then select a message to keep its readable
  body as a course source. **Load Attachments** lists bounded file attachments
  from that message, including small inline MIME files, so you can import a
  selected PDF or other supported original with the Gmail thread as provenance.
  **Calendar materials.** Search the primary Google Calendar by event text, then
  import a selected event as dated class context with its title, times, location,
  description and stable Google Calendar link.
- **Gradescope.** Open the course or assignment in Gradescope, directly or
  through Canvas. Save its link in LCP. To keep your work offline, download
  the submission PDF from Gradescope and select it in LCP with the appropriate
  source link. [Gradescope student help](https://www.gradescope.com/help#help-center-section-student-workflow)
- **Piazza and UCI Zoom.** Open a class page in Piazza or a UCI Zoom meeting
  link, then save the HTTPS address from **Materials → University Services**.
  LCP strips transient query and fragment values such as meeting passwords and
  retains the stable class or meeting path with the selected class.
- **UCI Registrar.** Choose the term, department and course number to preview
  the Registrar's current Schedule of Classes report. Save the report as a
  searchable class material. This public lookup works without an account.
  [UCI Schedule of Classes](https://www.reg.uci.edu/perl/WebSoc)

Source imports run when you choose them. LCP also retries pending class-folder
requests while running. Imported copies work offline and follow the library's
usual backup and agent-sharing settings.
Disconnecting a service removes its saved credential from this library's Mac
Keychain configuration. You can also revoke access in Canvas or your Google
account. [Google account connections](https://myaccount.google.com/connections)

### Review Canvas coursework and keep its sources together

Import a Canvas assignment or quiz in **University Services**. LCP saves its
description as a material, then offers a separate coursework review showing the
class, source revision and deadline. **Add Coursework** (or **Apply Reviewed
Facts** for an existing item) is the only action that changes coursework. Cancel
keeps the imported material and leaves coursework untouched. You can reopen the
review from the material's **Actions → Review Coursework** menu.

Canvas deadlines keep their exact instant and display in the academic term's
timezone. An absent deadline stays unknown. A new source import never silently
changes a saved deadline: reimport, inspect the review, then accept it. Progress,
related materials and a chosen Gradescope submission link survive that update.
If the source, coursework or term changed while the review was open, reopen it
before saving. Automatic Canvas refresh imports newer source snapshots and
places new or changed official facts in the same review queue. It never
overwrites Coursework progress, submission links, related materials or reviewed
deadlines without an explicit acceptance.

In **Coursework → Edit → Related class materials**, select the saved Drive
reading, Gmail clarification or attachment, Gradescope feedback PDF, UCI schedule,
or local file that belongs to the assignment. Only materials from this class are
offered. Each link opens its exact saved revision offline, even after a newer
copy is imported. These source links and their payloads survive library backup
and restore. All of these local review, edit and read actions work without
credentials or an internet connection and do not invoke lecture transcription.

## Agent connections

The bundled helper uses local stdio MCP and explicit persistent grants. It has no
network listener. MCP clients can discover one metadata resource per granted
class through `resources/list` and `resources/read`, then use the scoped tools
for source passages and immutable citations. The application supplies
connection/setup details and grants for selected classes; revoking a grant blocks future requests. Use **MCP JSON** on a grant to copy a credential-free `mcpServers` configuration for a compatible client. Keep the helper's `--root` and `--grant` arguments specific to the selected profile and connection. After a client sends `initialize` with bounded `clientInfo` and completes an authorized context read, LCP records its label, version and verification time in the local connection record.
Do not add credentials to bundles, backups, source documents or setup commands.

The desktop records a verified connection after a successful scoped bridge
read. For a chat client with file attachments, including Grok Bot, select
**Export Class Context**, review the exported `context.md`, and attach it to a
chat. Ask the agent to cite a passage using its original LCP link, then open
that link on the Mac. This export is a snapshot of the sources you selected.

Agent-proposed notes and study logs require review. Acceptance preserves agent
identity, immutable citations and history. An agent cannot silently edit original
materials, official deadlines, grades, recording destinations or capture state.

## Lecture feed and capture

Every academic class can record locally, including name-only classes. In **Capture**, choose the class and its **On this Mac** destination. Finalized audio is stored in the library’s `Recordings` folder and appears under that class’s **Lectures** tab. Select a catalog destination and save its mapping to send future recordings through the server processing workflow.

For a self-hosted transcript feed, sync the server export directory as **Send
Only** and `~/Library/Application Support/LCP Desktop/Feed` on the Mac as
**Receive Only**. Give the feed its own Syncthing folder, such as
`lcp-desktop-feed`. The importer validates the complete generation and payload
hashes before replacing the local snapshot. A partial or corrupt transfer
leaves the last valid snapshot available. The app tracks processing, transcript
quality and Drive publication separately. Review the class assignment for
older lectures.

Source citations resolve exact immutable material or transcript revisions. A newer
transcript cannot silently change an old note's citation. Transcript reading works
without local audio. Playback requires a deliberately selected local file whose
size and SHA-256 match the recording identity; no remote audio URL is invented.

If you also use the standalone recorder, the two apps share a capture lock
through finalization. Finish active recordings before replacing a recorder.
[Recorder migration](../docs/capture-migration.md)

## Package a Mac release

From the repository root, create the arm64 preview disk image for download.

```sh
desktop/scripts/build-app.sh --configuration Release
desktop/scripts/package-release.sh --public-preview
```

The public-preview command prints the output directory. The preview uses an
ad-hoc signature and lacks Apple notarization. Gatekeeper may block first
launch on another Mac. [Apple’s guide to opening apps you trust](https://support.apple.com/en-us/102445)

For optional local updates on the developer’s Mac, enable the updater once
from the checkout, specifying the installed app’s path.

```sh
python3 desktop/scripts/local_updates.py enable --app '/Applications/LCP Desktop.app'
```

For this workflow, use `desktop/scripts/package-release.sh --dmg` to queue a
verified local build. Quit LCP Desktop when you're ready, then reopen it after the new build is
installed. Run `python3 desktop/scripts/local_updates.py status` to check the
update or `python3 desktop/scripts/local_updates.py disable` to opt out.

The versioned DMG contains the app and its local MCP helper. The release
directory also contains the review ZIP, build receipt, release manifest and
`SHA256SUMS`. Run `shasum -a 256 -c SHA256SUMS` in that directory to verify
the artifacts. Use a fresh output directory for each run.

The personal build uses ad-hoc signing. For distribution to other Macs through
Gatekeeper, use a **Developer ID Application** signing identity with its private
key in the build Mac's Keychain and configure a Keychain profile with
`xcrun notarytool store-credentials`. The following opt-in command submits the
app and disk image to Apple's notary service and staples the resulting tickets.

```sh
desktop/scripts/package-release.sh --dmg \
  --app 'desktop/build/Release/LCP Desktop.app' \
  --output-directory desktop/build/releases/notarized \
  --sign-identity 'Developer ID Application: Your Name (TEAMID)' \
  --notary-profile 'lcp-notary'
```

## Recovery and release checks

If startup reports a storage error, preserve the profile, select or restore a
verified backup into a fresh profile, and retain the original for diagnosis.
Keep payloads that may be pinned by a saved citation. A missing source
must appear as unavailable rather than opening a different revision. Restore
before switching back to an older app; there is no destructive downgrade path.

For a release, run these manual checks in a test library on an Apple Silicon Mac.

1. Create fictional classes and materials offline; quit/reopen, search and open
   exact citations; export and restore into a clean profile.
2. Complete one compatible external-agent query and open its returned citation;
   revoke the grant and confirm further requests fail.
3. Review a proposed study log, accept one and reject another; retry acceptance
   without duplicating the entry; confirm stale edits require review.
4. Exercise stale/partial/corrupt feed behavior and revision-pinned citations.
5. After safe recorder migration, manually verify microphone permission, both
   lease-aware launch orders, stop/finalization, login relaunch and cold rollback
   using synthetic audio and isolated test destinations.
6. Check keyboard navigation, focus, readable labels and VoiceOver in the native window.
