# Google Drive for LCP

For the Mac app, open **Connections → Google Drive → Set Up**. The app uses a Google Cloud Desktop OAuth client. Enable the Drive API, choose the client JSON, and sign in with the account that owns or can access your course material. If you previously granted read access, **Manage → Enable Folder Creation…** allows LCP to create missing folders for new classes. [Desktop quick start](../desktop/GETTING-STARTED.md) · [Google's desktop client guide](https://developers.google.com/identity/protocols/oauth2/native-app)

The optional worker uses a separate rclone connection to publish transcripts and maintain the synced recorder catalog.

## Configure the worker account

1. Install rclone on the worker and run `rclone config` as the user who will run LCP. Add a Google Drive remote named `gdrive`. Authorize the Google account that holds your lecture files. For publication, give the remote access to create and update files in that destination. [rclone's Google Drive instructions](https://rclone.org/drive/)
2. Open your intended **School Lectures** folder in Drive. Copy the folder ID from its URL. Use immediate child folders for courses.
3. Put the root ID in a private shell variable, then list only the child folders. Confirm the returned names match your intended destination. Keep the rclone configuration on the worker.

```sh
read -r LCP_DRIVE_ROOT_FOLDER_ID
rclone lsd gdrive: --drive-root-folder-id "$LCP_DRIVE_ROOT_FOLDER_ID"
```

## Publish the class catalog

From an environment containing the worker package, run the catalog command. The example follows the worker's default directory layout. Create a writable classes directory or select an output path your worker account owns.

```sh
lcp-drive-classes --output /data/lectures/classes/classes.json \
  --remote gdrive --drive-root-folder-id "$LCP_DRIVE_ROOT_FOLDER_ID"
```

Share the output directory with Syncthing as **Send Only** on the worker and **Receive Only** at `~/Lectures/Classes` on the Mac. The recorder uses this catalog to select the exact Drive folder for synced recordings. Refresh it regularly. The supplied timer runs every five minutes. The reserved child `LCP Test` is excluded from the normal class list. The generated catalog contains account-specific folder IDs and belongs outside Git.

## Publish transcripts

On a worker configured for local CPU inference, an example publishing command is:

```sh
lcp-worker watch --root /data/lectures --transcriber local \
  --model small.en --device cpu --compute-type int8 \
  --publish --remote gdrive --drive-root-folder-id "$LCP_DRIVE_ROOT_FOLDER_ID"
```

The worker writes the MD, TXT and SRT bundle under the matching course subfolder. Choose a separate root and destination for a synthetic publication test. To use an explicit mapping instead, copy the [example course mapping](../server/config/course-folders.example.json) to a private file, supply your course keys and child-folder IDs, and use `--drive-folders /path/to/course-folders.json`.

The systemd catalog service and publication drop-in read `~/.config/lcp/drive.env`. Create it with mode 0600, add `LCP_DRIVE_ROOT_FOLDER_ID` and optionally `LCP_RCLONE` with the rclone executable path. An example file follows.

```text
LCP_DRIVE_ROOT_FOLDER_ID=your_selected_folder_id
LCP_RCLONE=/usr/local/bin/rclone
```

Install the catalog service and timer to publish the class list automatically. To enable transcript publication for the hosted example worker, also install `server/systemd/lcp-worker.service.d/publication.conf` as a user-service drop-in. Review its transcription backend and arguments before restarting the worker. [Worker setup](../server/README.md)
