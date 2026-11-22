# LCP Desktop

LCP keeps a university class’s readings, lecture recordings, coursework, and notes together on your Mac. Search a passage and cite the exact revision you read, or share selected material with an agent. You can create a class, record a lecture, and search imported readings offline.

## Install on a Mac

The desktop preview runs on **Apple Silicon with macOS 14 or later**. Download the disk image from GitHub Releases, open it, and drag **LCP Desktop** into **Applications**. This preview uses an ad-hoc signature. macOS may require you to approve the first launch in **System Settings → Privacy & Security**. The release page includes a SHA-256 checksum. [Download LCP Desktop](https://lcp.betanine.dev/) · [GitHub releases](https://github.com/FakeZhiyuanLi/LCP/releases) · [Apple’s guide to opening apps you trust](https://support.apple.com/en-us/102445)

In **Class Library**, choose **New Class…** and enter a name. Open the class and choose **Materials → Add Material → Import Files…** to add your first reading. In **Capture**, select the class and choose **Start Recording**. Choose **Stop and Finalize** to save the audio under **Lectures**. [Quick start](desktop/GETTING-STARTED.md)

## Connect your class materials

- **UCI Canvas** imports course materials through the Canvas API and can refresh them on a schedule. Open a class's University Services view, select its Canvas course, and enable automatic sync for that class. Only explicitly subscribed classes receive future Canvas updates. Review imported assignments and deadline changes before adding them to your coursework.
- **Google Drive, Gmail, and Calendar** use Google OAuth credentials you configure in **Connections**. Drive can link a new class to a matching folder under **School Lectures**, or create one when you grant folder creation. Choose individual files, messages, or events to import.
- **Gradescope, Piazza, Zoom, and the UCI Registrar** support saved links, downloaded Gradescope PDFs, or public course schedules, depending on the service.
- **Agents** can read selected classes or materials through the bundled local MCP helper. The Codex CLI connection has been tested with fictional sources. For a chat client that accepts files, export the class context and attach the reviewed Markdown. [Connection and agent setup](desktop/README.md)

## Build from source

On an Apple Silicon Mac with Xcode installed, run these commands from the repository root.

```sh
swift test --package-path client --jobs 2
swift test --package-path desktop --jobs 2
desktop/scripts/build-app.sh --configuration Release
open 'desktop/build/Release/LCP Desktop.app'
```

The app includes its local agent helper and uses Swift packages in this checkout. For a disk image or Developer ID packaging, see the [release instructions](desktop/README.md#package-a-mac-release).

## Optional lecture processing

Local recordings work with the desktop app alone. For transcription and Drive publication, the repository includes a separate Python worker for a self-hosted Linux system. Choose a transcription backend and configure a synced destination before sending audio. Using a hosted provider can incur charges. The desktop can import eligible transcripts from a one-way feed. [Worker setup](server/README.md) · [Desktop feed exporter](server/desktop_exporter/README.md) · [Capture migration](docs/capture-migration.md)

## License

LCP is distributed under the [MIT License](LICENSE).
