# LCP Desktop quick start

LCP Desktop keeps readings, slides, notes, and lecture references together for each class. You can set up your first class and search a reading entirely offline.

## Install LCP on your Mac

You’ll need an Apple Silicon Mac (M-series) running macOS 14 or later. Download the arm64 disk image (`.dmg`) from the project’s releases. Open it, drag **LCP Desktop** into **Applications**, eject the image, then open **LCP Desktop** from Applications. [LCP releases](https://github.com/FakeZhiyuanLi/LCP/releases)

The preview has an ad-hoc signature and has not been notarized by Apple. If Gatekeeper blocks the first launch and you trust this download, follow Apple’s **Open Anyway** instructions in **System Settings → Privacy & Security**. [Apple’s guide to opening apps you trust](https://support.apple.com/en-us/102445)

**Updating LCP.** Save your work, finish any recording, and quit LCP. Drag the newer app into the same Applications folder and choose **Replace**. Your class library lives in your user account.

## Set up your first class

1. **Create the class.** In **Class Library**, choose **New Class…**, enter a **Class Name** such as *Data Structures*, and choose **Save**. Use **Optional details** to add a term or course code now, or add them later under **Class actions → Edit Class**.
2. **Add one reading.** Open the class and choose **Materials → Add Material → Import Files…**. Pick a syllabus or reading with selectable text, such as a PDF or a plain-text file.
3. **Find a passage.** In **Search Sources**, enter a distinctive word from the reading and choose **Search → Open Exact Source**. When you see the matching passage, choose **Retain Citation** to keep that version for later.

**Class folders in Google Drive.** Saving a new class also asks LCP to find or create its folder under **School Lectures**. LCP uses the course code when you enter one, or the class name otherwise. Open **Materials** to see the status or open the folder. You can save classes offline and LCP will retry. For a class you created before this feature, choose **Materials → Set Up Google Drive Folder**.

## Connect other sources when you need them

Open **Connections** in the sidebar to set up a university account. Choose **Manage → Check Connection** to test saved access. To import a source, open its destination class and choose **Materials → University Services**.

- **UCI Canvas.** If your account allows personal tokens, create one in **Account → Settings → Approved Integrations**. In **Connections**, choose **Set Up** beside **UCI Canvas**, enter the token, and choose **Connect to Canvas**. [Canvas token documentation](https://canvas.eee.uci.edu/doc/api/file.oauth.html)
- **Google Drive, Gmail, or Calendar.** This release needs a Google Cloud **Desktop app** OAuth client. Enable the API for your chosen service and add your account as a test user if the client is in testing. In LCP, choose **Choose Google Client JSON…**, then **Sign In with Google** for each service you want to use. [Google desktop client setup](https://developers.google.com/identity/protocols/oauth2/native-app)
- **Enable Drive folder creation.** If you previously connected Drive for reading, open **Connections → Google Drive → Manage… → Enable Folder Creation…** and approve access in Google. Existing matching folders can be linked with read access.
- **Gradescope.** Under **Gradescope & UCI → Gradescope**, save the assignment link or import a submission PDF you downloaded from Gradescope.

**To share with an agent**, open **Class actions → Export Class Context**, choose the materials to share, and review the exported `context.md` before attaching it in your agent’s chat. Try asking “What does the syllabus say about late work? Cite the passage.”

**To record a lecture**, open **Capture**, choose your class, and select **Start Recording**. Allow microphone access when prompted. Every class has an **On this Mac** destination. Choose **Stop and Finalize** to save the audio under that class’s **Lectures** tab. For server transcription, select a synced recording destination and save its mapping before recording.

**To back up your work**, open **Settings → Library → Back Up Library** and choose a new folder.
