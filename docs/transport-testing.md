# Verify synced lecture transport

Use the Mac transport probe when setting up or changing a self-hosted lecture worker. The probe synthesizes a short phrase, writes a mono AAC file and its ready marker to an isolated Syncthing share, checks that the other device acknowledged both files over Tailscale, and verifies their size and SHA-256 over SSH.

## Prepare the test share

- Configure a dedicated Syncthing folder named `lecture-test-inbox`, **Send Only** on the Mac and **Receive Only** at `/data/lectures-test/inbox` on the worker. Keep this directory separate from class recordings.
- Set up the Tailscale CLI, Syncthing and `ffprobe` on the Mac and Python 3 on the worker. The configured Syncthing device name must match its Tailscale hostname. Make sure SSH already recognizes the host key and supports a noninteractive login as the account with read access to the test files.
- By default, a transport check only writes the synthetic file pair and reads its status. If a transcription worker is watching the test directory, it may process the fixture through its configured backend regardless of whether the probe waits for a transcript.

## Run the check on the Mac

From the repository root, substitute your worker's Syncthing name and SSH host alias. The local report will include host and folder metadata. Keep it in a private directory.

```sh
mkdir -p -m 700 "$HOME/Library/Logs/LCP"
python3 scripts/test_transport.py --peer WORKER_DEVICE_NAME \
  --ssh-target WORKER_SSH_ALIAS --environment test \
  --report "$HOME/Library/Logs/LCP/transport-test.json"
```

A successful transport check reports both the peer's acknowledgement and verification of the actual file and marker on disk. Exit 2 means the peer acknowledged the pair but the SSH verification could not complete. Correct the SSH connection and run a new test for a complete result.

For a readback of a synthetic transcript, first configure a test worker for `/data/lectures-test`, then add `--wait-for-transcript`. To also check publication, select a separate Drive test folder in that worker, and pass `--wait-for-publication --drive-root-folder-id TEST_FOLDER_ID` to the probe. The probe checks published job state and the remote MD/TXT/SRT bytes. Verifying an external agent's access requires a query in that agent. [Worker setup](../server/README.md) · [Drive setup](drive-setup.md) · [Agent verification](grok-verification-runbook.md)
