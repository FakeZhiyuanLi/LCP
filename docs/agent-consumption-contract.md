# Agent consumption contract

This is the downstream contract for Grok, Hermes, OpenClaw, or another agent
that reads the Drive-published lecture bundle. LCP publishes one bundle per
recording under:

```text
School Lectures/<COURSE>/<COURSE>_<YYYY-MM-DD_HHmm>.{md,txt,srt}
```

## Selecting source material

1. Discover the course folder and the recording stem. Preserve the exact
   course spelling, including spaces.
2. Read the Markdown file as the primary human-readable transcript.
3. Use the TXT file for its metadata header, source SHA-256, and timestamped
   cue text. Use SRT when subtitle timing or cue boundaries need checking.
4. Treat the three files as one bundle. Do not concatenate all three, which
   would duplicate the lecture.

The bundle is usable only when all three files exist and their timestamped cue
text and starts agree. The Markdown file is the primary agent-facing artifact,
so the audit compares Markdown against TXT as well as TXT against SRT; it also
reports orphaned files when a course folder contains only one or two suffixes.
A local `grok-audit` check validates this before an operator asks an external
agent to index the recording.

The audit enumerates every accepted recording in `state/heads.json`, including
recordings that are still processing or have no transcript bundle. It also
checks orphan vault files. A pass requires a valid current accepted head,
the exact matching durable job identity, the current source SHA-256, all three
matching artifact hashes, and completed verified Drive publication. A missing
index, state, bundle, or publication is a failure. Historical published jobs
and an older good bundle under the same canonical filenames cannot satisfy a
new processing or unpublished head. Selecting a historical job ID is rejected.

A complete local bundle that is still quality-blocked or awaiting upload is
reported as failed, because an external agent cannot read that current
revision from Drive yet. An artifact-only directory can be inspected for
format errors, but it cannot establish current publication without the accepted
head and its durable state.

The audit also loads the actual current cached transcript, recomputes quality
and relevance with the installed gates, and compares its freshly rendered
MD/TXT/SRT hashes with the local bundle. Stored `quality` and `published`
flags can predate a gate change and cannot establish safety by themselves.
Missing or invalid cached transcripts, current blocking findings (including
sustained text repetition), or stale rendered content fail the audit even if
an older worker marked that state published. Reports expose only quality
codes and metadata, never cached transcript text or private exception details.

## Answering and citations

- Ground claims in the transcript. If the requested detail is absent, say so.
- Cite the exact course, transcript filename, and `[MM:SS]` timestamp for each
  material claim.
- Keep the recording date from the filename and TXT header; do not substitute
  the Drive upload date.
- When a question spans multiple recordings, identify each source separately.

## Speaker labels

ElevenLabs labels are anonymous and scoped to one recording (`speaker_0`,
`speaker_1`, and so on). `Professor-Speaker: unknown` is intentional. Preserve
labels as turn markers, but never infer that `speaker_0` is the professor from
duration, word count, or speaking order. Assign a role only when the user
provides an explicit calibration mapping.

After that calibration, `Professor-Speaker` contains the mapped anonymous ID
(for example, `speaker_1`) and each matching cue is labeled
`[speaker_1 (Professor)]`. The mapping must be supplied by the user and must
refer to an ID present in that recording. Otherwise it stays `unknown`.

The worker accepts a JSON calibration file with recording filenames or stems
as keys, for example:

```json
{"DEMO 101_2026-01-12_0900": "speaker_0"}
```

Run the worker with `--professor-speakers /path/to/professor-speakers.json`.
This is an explicit operator assertion; the worker rejects a mapping whose
speaker ID does not occur in the transcript and never selects a professor from
speaking time, order, or word count.

The bundle also carries `Speaker-Roles: unassigned; explicit user calibration
required`. Until a user supplies that mapping, describe speakers only by their
anonymous IDs. The `Background-Noise` field and transcript markers such as
`[background noise]`, `[inaudible]`, `[music]`, `[machine whirring]`, and
`[crosstalk]` identify spans that should not support lecture claims or
citations. A lack of markers does not prove that the audio is noise-free.

## Relevance and accidental recordings

Read the TXT `Relevance` field (also shown in Markdown) before indexing a
bundle. Only `likely_lecture` is eligible for automatic Grok ingestion.
`needs_review` means the worker found a possible late-ended recording or
low-density tail. Background-noise markers remain explicitly annotated and
are excluded from lecture claims without blocking an otherwise relevant
lecture. `likely_accidental` means there
was almost no speech for a lecture-length recording. Both statuses remain in
the local vault for operator review, but the worker blocks their Drive
publication by default. Do not ingest them or use them in answers until an
operator explicitly reviews and overrides the flag. `Grok-Use` repeats this
decision in plain language.

## Revisions and stale results

The same filename can receive a corrected transcript. Compare the source and
artifact SHA-256 values and reread the current Drive contents before answering;
filename, file ID, and modification time alone are insufficient. If a prior
answer used an older hash, state that the answer needs to be refreshed.

## Minimal verification prompt

```text
In School Lectures, read course DEMO 101 and the recording
DEMO 101_2026-01-12_0900. What was said at [00:00]? Cite the exact
transcript filename and timestamp. Check `Relevance` first; answer only when
it is `likely_lecture`. Include the anonymous speaker label if it is present,
exclude spans marked as background noise, and do not infer which speaker is
the professor.
```

For a revision check, ask for the exact phrase at a known timestamp after the
operator has replaced the file, and confirm that the answer reflects the
current content rather than a cached earlier version.
