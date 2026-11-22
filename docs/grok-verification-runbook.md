# Grok ingestion verification runbook

LCP can prove that a transcript bundle is complete, internally consistent, and
published to Google Drive. It cannot observe whether an external Grok bot has
polled or indexed that bundle. Use this short runbook when the bot connection
or its refresh schedule changes.

## Preconditions

On the worker host, check the worker and catalog timer.

```sh
systemctl --user is-active lcp-worker.service
systemctl --user is-active lcp-drive-classes.timer
```

Before relying on the remote for durable publication, check that its OAuth
client is private. Run the following on the worker to display whether the account configuration is present and check its file permissions.

```sh
python3 - <<'PY'
import configparser
import pathlib
import stat

config_path = pathlib.Path.home() / ".config/rclone/rclone.conf"
config = configparser.RawConfigParser()
config.read(config_path)
remote = config["gdrive"] if "gdrive" in config else {}
print("gdrive_remote_present=" + str("gdrive" in config).lower())
print("private_client_id_present=" + str(bool(remote.get("client_id", "").strip())).lower())
print("private_client_secret_present=" + str(bool(remote.get("client_secret", "").strip())).lower())
print("token_present=" + str(bool(remote.get("token", "").strip())).lower())
try:
    print("config_mode=%04o" % stat.S_IMODE(config_path.stat().st_mode))
except OSError:
    print("config_mode=missing")
PY
```

If you configured your own Google Cloud OAuth client for rclone, both private-client fields should be true. Keep the rclone configuration private and outside the repository.

Select a recording you expect the agent to read and substitute its exact filename for the fictional example.

```sh
"$HOME/.local/share/lcp/venv/bin/lcp-worker" grok-audit \
  --root /data/lectures \
  --filename 'DEMO 101_2026-01-12_0900.m4a' \
  --json
```

Continue only when `failed_count` is `0`, `published` is `true`, and
`state_artifacts_match` is `true`. The report's
`external_ingestion_verified` value remains `false` by design.
Also require `cached_transcript_matches=true` and
`current_quality.publication_allowed=true`. These fields are recomputed from
the current accepted cached transcript and rendered content; historical stored
quality/publication flags do not satisfy a newer gate. A current blocking
quality finding requires repair or review before relying on the bundle.

For completeness across all recordings, omit `--filename` and require both
`failed_count` and the number of `errors` to be zero. The audit enumerates the
accepted recording heads, so an unfinished recording with no bundle appears
as failed rather than disappearing. Each report's `job_ids` contains only its
current accepted job. A prior published revision cannot satisfy the current
head, and an unknown (`null`) publication value is never a pass. Do not infer
that every recording is available from a successful check of one filename.

In the Grok bot, confirm that Google Drive is connected to the `School
Lectures` root and that the bot can read the course subfolder. Ask:

```text
In School Lectures, read course DEMO 101 and the recording
DEMO 101_2026-01-12_0900. What was said at [00:00]? Cite the exact
transcript filename and timestamp. Include the anonymous speaker label if
present, and do not infer which speaker is the professor.
```

Record the response only if it includes the exact transcript filename, a
timestamped quote grounded in the file, and the anonymous label when one is
present. A response that invents a professor identity fails this check.

## Revision check

Run this only with a synthetic recording under `LCP Test` or another isolated
test destination. Replace a transcript while preserving its filename and
verify that the TXT hash changes; then ask the bot for a known phrase at a
known timestamp. The answer must reflect the new content rather than a cached
older response. Never use a synthetic phrase in a real course folder.

## Evidence record

Keep a local record with the following fields, omitting message content that
contains private lecture material unless it is needed for debugging:

```json
{
  "checked_at": "<check time with UTC offset>",
  "bot": "<your agent>",
  "drive_root": "School Lectures",
  "course": "DEMO 101",
  "recording": "DEMO 101_2026-01-12_0900",
  "source_sha256": "<from the TXT metadata>",
  "local_grok_audit": "pass",
  "new_file_ingestion": "pass|fail|unverified",
  "revision_ingestion": "pass|fail|unverified",
  "notes": "<timestamp and citation observations>"
}
```

A successful Drive upload or local `grok-audit` does not by itself establish
external ingestion. Repeat this check after changing the bot's Drive
connection, polling schedule, parser, or source-selection rules.
