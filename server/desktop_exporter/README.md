# LCP desktop feed exporter v1

This independent Python 3.10+ standard-library package exports deliberately
accepted transcript content to a private, separate desktop feed. It does not
import the worker, adapters, provider clients, dashboard or durable worker APIs.
No dependency installation, STT, Drive calls, repair, reservation, source write,
audio read or worker execution is needed. The operations dashboard is unchanged.

## Synthetic verification

Run from this directory on Linux or Apple Silicon macOS with Python 3.10+:

```sh
python3 -B -m unittest discover -s tests -v
python3 -B tests/generate_fixture.py /absolute/new/synthetic-fixture-feed
```

Every test builds temporary synthetic roots. The fixture contains four invented
recordings: one eligible with exact Unicode cues and a separate sound event,
one blocked, one accepted head with a missing job, and one unaccepted manifest.
Only the eligible recording has transcript content. Fixture `index.json` and
`payloads/*.json` are the exporter's actual UTF-8 output, with matching digests
and byte sizes. Never point tests or fixture generation at production roots.

## Source authority and feed semantics

Only `state/heads.json`, its exact selected `state/jobs/<opaque-job-id>.json`,
and directly contained `inbox/*.m4a.ready.json` metadata are read. Head manifest,
filename key, head identity, current marker and job identity must agree on the
source filename, size and SHA. The full persisted settings identity is compared
between head and job, but never compared to current worker settings; settings
revisions and same-job repairs are therefore supported. IDs are opaque safe
basenames, never rederived from settings. Historical jobs are never scanned.

The v1 root index has exactly `schema_version`, `generation_id`, `exported_at`,
`producer`, `complete`, `recordings`, `retirements`. Recording rows have exactly
`filename`, `size_bytes`, `sha256`, `accepted_job_id`, `status`, `transcript`.
Status has exactly `server_received`, `processing`, `quality`,
`drive_publication`, `external_ingestion`. Transcript references have exactly
`path`, `sha256`, `size_bytes`, `accepted_job_id`. Paths are always
`payloads/<SHA256-of-exact-payload-bytes>.json`.

Only accepted, structurally valid, quality-eligible local-ready or published
jobs with no outstanding error carry transcript content. Such rows always have
`server_received: true` and `quality: "eligible"`. All blocked, pending,
unaccepted, missing or inconsistent facts have `transcript: null`. Unaccepted
markers have `server_received: false`: arrival of a marker alone does not prove
receipt of its audio bytes. An accepted head establishes the worker's original
verified receipt without the exporter opening audio. No network verification of
Drive is attempted. `drive_publication` reports only the accepted job's stored
publication boolean (`published`, `not_published`, or `unknown`).
`external_ingestion` is always `unknown`, including when historical flags say
`grok_ingested: true`. No external bot acknowledgment is available here.

Payloads have exactly `schema_version`, `filename`, `size_bytes`, `sha256`,
`accepted_job_id`, `cues`, `audio_events`, `generated_at`. Cue objects contain
exact `start`, `end`, `text`, `speaker`; event objects contain exact `start`,
`end`, `text`. Endpoints and text are preserved; no sorting, interpolation,
timestamp repair or role inference occurs. Anonymous speaker IDs remain
recording-scoped. Empty zero-duration cues are conservatively rejected.

Quality checks are pinned dependency-free copies of the worker quality
algorithm and its transcript data models. They recompute citation, repetition,
relevance, sparse-speech and open-tail gates. Stored blocking/review flags also
block export. `_quality.py` changes only its relative model import; `_models.py`
contains only transcript/event dataclasses and event validation, excluding
transcription settings and provider/worker protocols. Updating this policy is an
explicit independent exporter release; it never changes production behavior.

The same unchanged transcript reuses its exact prior payload including its
generation timestamp. A same-job content repair produces a new content digest
and leaves the previous immutable payload intact. `generated_at` is the first
successful export of that exact payload revision, not a provider-call time.
`exported_at` is the UTC time of each complete generation.

Retirements contain exactly `filename`, `size_bytes`, `sha256`, `reason`, with
`source_replaced` or `no_longer_present`. Tombstones persist across generations
until that identity returns, so intermittent clients do not miss a single-cycle
removal. No exporter pruning or source deletion occurs. A missing/malformed head
index aborts and preserves the previous index; it never triggers a mass removal.

## Consistency, bounds and failures

Directory descriptors and `O_NOFOLLOW` reject symlinks at every path hop. Reads
reject hardlinks, nonregular files, traversal, duplicate JSON keys, invalid UTF-8,
nonfinite timing, overlapping speech cues, out-of-bound event/cue endpoints and
oversize documents. Validated metadata bytes and file identities, plus inbox
names, are reread after payload durability and immediately before index commit.
A concurrent exporter is rejected with an independent output lock, never the
worker lock. This is a bounded optimistic snapshot; an external writer can still
change state immediately after the final check. The next minute refreshes it.

Bounds: 2,000 recordings and retained tombstones; 4 MiB heads/index; 64 KiB
markers; 16 MiB jobs/payloads; 20,000 cues and 20,000 events per transcript;
16 KiB per text; 24 hours maximum duration; 2 GiB source-size metadata; 128 MiB
read budget per tree including consistency rereads; 128 MiB per generation;
10,000 directory entries/payload files; 512 MiB retained immutable payloads.
At the retention bound, export fails without deleting anything; an explicit
retention policy is required before extending long-term capacity.

All payload bytes are fsynced and committed without replacement, then verified,
before the fsynced atomic `index.json` replacement. Crash orphans consume the
storage budget and remain private. Syncthing can deliver index and payloads in
either order: the Mac importer must verify every referenced file/hash/byte count
before applying a complete generation and retry on missing payloads. Do not treat
`complete: true` alone as proof all files have reached the Mac yet.

## Independent deployment examples

Keep this package outside the production worker source/venv. `run_export.py`
supports isolated Python (`-I -B`) and adds only its independent package path.
Example units use `~/.local/share/lcp-desktop-exporter/current`, read-only
`/data/lectures`, and a NEW mode-0700
`~/.local/share/lcp-desktop-feed` owned by the user. The unit uses
`%h/.local/share/lcp-desktop-feed` for both output and its explicit
`ReadWritePaths` exception under `ProtectHome=read-only`. This dedicated root is
outside every worker tree and requires no root-owned directory provisioning.
The output root must already exist; the exporter does not create root paths.
Never use an inbox, classes, test or state directory as the output.

The Linux x86_64 service MUST enter the native `lcp-export-sandbox` launcher
before Python executes. Reviewed Landlock ABIs 6–8 enforce a default-deny filesystem
policy: only the dedicated output is writable, while the independent package,
system runtime, heads, jobs, and exact existing ready-marker files are readable.
Audio and worker control contents are inaccessible. Only the inbox directory
can be listed within the source. Ancestor traversal uses `O_PATH` on Linux;
macOS keeps its ordinary directory descriptors. The Python export schema,
selection, quality policy and consistency checks are unchanged.

Landlock alone does not cover chmod/chown, timestamps or extended attributes.
A mandatory seccomp allowlist denies those operations globally, as well as
network socket creation, IPC/fd acquisition, io_uring, process creation/control,
mounting and unknown syscalls. Only Python and its exact ELF loader are
executable. All inherited descriptors >=3 are closed, stdin is replaced by a
read-only null descriptor, and stdout/stderr accept only pipes or the systemd
journal stream. Regular-file/terminal/control-socket stdout or stderr rejects
startup without writing even the rejection into that descriptor. Existing
output symlinks, hardlinks, nonregular files and nonprivate modes reject startup.
New symlinks are denied even within output; normal output hardlinks and atomic
renames remain available for durable payload commits. There is no writable
runtime directory outside output and no privilege or host-policy change.

The native launcher is Linux-only and requires the installed modern Landlock
headers, `close_range`, seccomp and x86_64. Unknown future ABIs reject startup
until reviewed. Python runs with `-I -S -B` to exclude user and system site hooks.
Build on the Linux worker host.

```sh
cc -O2 -Wall -Wextra -Werror -D_FORTIFY_SOURCE=3 -fstack-protector-strong \
  -Wl,-z,relro,-z,now -o lcp-export-sandbox sandbox.c
cc -O2 -Wall -Wextra -Werror -o tests/fail-syscall tests/fail_syscall.c
python3 -B -m unittest discover -s tests -v
```

Seven native test groups exercise more than 50 denial cases, successful output
durability, source hashes/mode/mtime/ctime preservation, inherited writable
descriptors (including standard descriptors), and unavailable Landlock,
restriction, close_range and seccomp primitives. Native tests skip on macOS;
that skip is never a Linux deployment waiver. The original 29 synthetic Python
tests still run on macOS arm64 with Python 3.10+. Do not run the Linux binary
on the Mac or copy a Linux virtual environment there.

The user-systemd mount namespace settings remain defense in depth. User managers can lack mount namespace support. The mandatory Landlock and seccomp launcher enforces the read-only source boundary. A
missing/unsupported primitive rejects startup with exit 126 before Python;
there is no override or unsandboxed retry. These controls constrain the exporter
process and its descendants, not unrelated processes outside its domain or
future kernel vulnerabilities. Paths/stat information and read access times
are not hidden; content/namespace/permission/timestamp mutations are denied.

Verify the boundary through the actual user service and an isolated synthetic
source before real export or timer activation. Precreate Syncthing's `.stfolder`
as mode 0700. Failed gates leave the timer disabled and dedicated folder paused.
The timer runs every minute and never starts/restarts the worker. There is no
feed HTTP endpoint. Share only the feed directory using the dedicated Syncthing
folder `lcp-desktop-feed`, worker Send Only and Mac
Receive Only at `~/Library/Application Support/LCP Desktop/Feed`.

Rollback: stop/disable only `lcp-desktop-export.timer`; stop the independent
export service if active; preserve feed files and durable worker state. Remove
only the dedicated Syncthing folder configuration if explicitly retiring it,
never its data or unrelated folder/device settings.
