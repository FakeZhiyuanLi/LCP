# Desktop contracts

## Ownership and boundaries

LCPContextCore owns academic domain, repository, SwiftData persistence, immutable
payload storage and portable backup. LCPContextServices owns import/extraction,
scoped retrieval, bundles, reviewed proposals, and snapshot import, in distinct
files. LCPAgentBridge exposes the same services as local stdio MCP with explicit
grants. LCPDesktop supplies SwiftUI; LCPClient supplies only local capture facade.
Stable bundle ID org.lcp.Desktop. Default root Application Support/LCP Desktop.
The agent bridge uses local stdio. University Services makes student-initiated
HTTPS reads to UCI Canvas, the UCI Registrar and the selected Google service.
New classes save a local Drive folder request. The desktop resolves it under
the configured lecture root or under School Lectures in My Drive. Drive read
access can link an existing folder. Creating a missing folder requires the
additional `drive.file` grant. The class retains the Drive folder ID independently
of its capture destination.
Google authorization opens the system browser and uses a short-lived loopback
callback with PKCE. Desktop service credentials live in the Mac Keychain.
The recorder and lecture worker retain their separate transport contracts.

## Identity and recovery decisions

UUIDs identify academic terms/classes/materials; term-specific enrollments never
use course names as keys. Store immutable revisions and their exact payload SHA256.
An opaque server job ID is separate from filename/size/audio digest and transcript
payload digest. Never recompute Python job IDs in Swift. Retain all cited revisions;
backup validates the complete manifest and payloads before replacing state.
Date-only values and timezone-bearing instants are distinct types.
Codex CLI can connect via stdio MCP.
The desktop can copy a credential-free `mcpServers` JSON snippet for each scoped
grant. The bridge records bounded MCP `clientInfo` only after a successful scoped
read or resource request, then refreshes that metadata on a later connection.
Grok Bot offers manual file attachment. Source-grounded consumption and the
OpenAI Dots and Claude Duet routes still require verification.

BYOK agent provider profiles and API keys live in per-library Mac Keychain
entries, outside `ContextState`, portable backups, context snapshots, and MCP
configuration exports. The OpenAI-compatible Responses check sends a bounded
test prompt without class context. A future subscription transport can reuse the
provider abstraction without moving personal keys into academic state.
The class planner builds a fresh bounded snapshot through `RetrievalService`,
quotes source text as untrusted study data, and sends it only after the student
chooses an enabled provider and enters a planning request. A generated answer
stays in the planner until review. Saving it creates an attributed `agent_plan`
activity with source-level citations and an input-context manifest. The planner
does not write university services or official class records.

## Agent presentation

`AgentDisplayTool` defines the name, schema and validator for each display tool.
The stdio MCP bridge and OpenAI-compatible Responses client share that registry.
A display call formats its supplied values locally. Writing external agent output
to a class uses the existing scoped proposal and acceptance flow.

`AgentVisual` serializes a validated figure inside a fenced `lcp-visual` Markdown
block with integer `version` 1, a `tool` name, a `title`, and up to 16 `items`.
Bar charts require a shared `unit` and a finite, non-negative `value` per label.
Timelines retain the supplied order and require a `label` and `detail` per step.
Chats, activity revisions, and backups keep that Markdown alongside the prose.
The native renderer validates stored figures on read. It presents unknown block
versions as selectable code. Web links and validated LCP citation links open
on a student's click.

To add a display feature, extend the registry with its schema and validator,
extend the native visual view, and test the same inputs through both the bridge
and the Responses client. Preserve decoding of existing versioned figures.
The provider can issue up to four terminal display calls per answer.
Functions that need a result returned to the model require a separate
continuation and authorization design.


## Capture

Local class capture uses the academic enrollment UUID and stores audio in the
library’s Recordings directory. Capture into the synced inbox requires an exact
catalog-backed destination and 24-hour freshness, validated at start. A process-safe lock is held through finalization. Incompatible installed
or running recorder versions block desktop capture. Build a compatible recorder,
keep original inactive for cold rollback; never interrupt a live recording.

## Feed v1

Exporter writes immutable payloads then an atomic index.json complete generation.
Importer validates bounds, schema, paths, payload digests and complete generation
before one commit. Preserve previous generation and authored mappings on failure.
No raw jobs/credentials/absolute rack paths/audio are exported. Blocked/unaccepted
jobs export status only. Content requires strict accepted-head identity and quality.

## Storage and recovery

The native model is a VersionedSchema v1 SwiftData transaction envelope containing
Codable domain records. Relationships and immutable revision histories are
validated in one transaction under a process-safe flock. Additions to this
schema use optional fields where earlier backups may lack a value.
Future schema markers fail explicitly rather than attempting a destructive
migration. Before restore, the repository validates a separate fresh store and
keeps a pre-restore backup; damaged input remains untouched.

Portable backups include original materials, activity history and the exact
transcript revisions retained by citations and bookmarks. Unpinned transcript
cache stays in the source library. After restoring, the student can import the
feed again to recover available uncited transcripts. Restored agent access
requires a new grant.

A transcript repair can change both the words and the cue boundaries. An
entry keeps its original citation until the student reviews a passage from
the repaired transcript and saves a correction. The entry's earlier revision
retains its own citation. A reviewed agent's input manifest records the
sources it actually received at the time.

The **Include linked lecture audio** option in the backup dialog copies each
linked recording after checking its byte count and SHA-256. Restore verifies
the included files and links each recording to its copy in the recovered
library. Audio is optional on every export. For a lecture with local audio,
the reader can play a verified recording while its transcript is unavailable.

Missing/corrupt managed files are shown as unavailable so the academic library
can still open. Exact-hash relinking can repair a missing/corrupt original;
complete backups and newly saved citations require verified bytes and locators.
A structurally unreadable/future store is preserved; the UI can validate a backup
into a new profile without overwriting that store.

## Agent interoperability

The Codex CLI interoperability check uses fictional class materials and transcripts.
It lists granted classes, searches both source types, retrieves passages, and
resolves returned citations against their original digests and locators.
Clients that accept file attachments can read a reviewed export of `context.md`.
The recipient’s answer and citation return require verification in that client.

## Scope and provenance additions within schema v1

Local grant, export and human search controls support explicit material selection
and inclusive source time bounds. Time means a material's import instant, an
activity's event instant, or a lecture's known capture instant; unknown lecture
instants are omitted whenever a bound is set. Stored grant restrictions also
apply to direct citations, lists and agent-created snapshots. An empty explicit
material list never broadens into all context. Proposal capabilities can be
revoked while retaining read access.

Class session/location details, grant bounds, and agent input manifests are
optional additions so prior schema-v1 records and backups still decode. A nil
input manifest means unknown actual inputs; an empty array records an explicit
review that no LCP inputs were supplied. Input citations and answer citations
are distinct, validated, pinned dependencies. Immutable activity revisions retain
their own attribution and input manifest; restoring an older backup validates
its existing snapshot without backfilling historical metadata.

## Reviewed lecture association corrections

A recording can move between academic classes or become unassigned without
changing its audio identity, recording destination or publication facts. The
repository appends an immutable association revision using only citations saved
before the change. Current browsing and search follow the current class. A former
class may resolve only an exact retained historical citation, including its
original identity, revision, digest and locator; it does not gain access to other
cues or future revisions. Grant restrictions and revocation still apply.

Scoped historical context bundles include only the retained passage. They omit
the full transcript payload, which could expose other cues, and explicitly report
passages omitted by the size budget. Repository backups retain the complete pinned
payload under the user's recovery authority. History participates in retention
and restore validation. The optional history field preserves older schema-v1
records exactly; ordinary edits cannot erase or fabricate a history ledger.

## Reviewed university coursework sources

Canvas assignment/quiz details retain an optional `courseworkContext` on the
immutable material revision. It contains the refreshed title, kind and exact
deadline instant, independently of the list row and the Mac's current timezone.
Missing deadlines stay nil; malformed dates fail the import. The original text
also retains the Canvas deadline string for source inspection.

A local `CourseworkService` prepares a read-only review of that revision. Explicit
acceptance upserts only the coursework linked to that material in that enrollment,
checks the current material revision, coursework snapshot and term timezone under
the repository transaction lock, and is idempotent on retry. Reimporting a source
does not change coursework. Acceptance preserves personal progress, related
sources and the user's submission link. The local agent bridge has no new
coursework-write or deadline-write capability.

`CourseworkItem.sourceCitation` and `relatedCitations` are optional schema-v1
additions. Related material citations support the existing Canvas, Drive, Gmail,
Gradescope, UCI and local import paths. Core validation enforces same-class
material evidence, bounded selections and exact revision/digest/locator validity.
Their payload references participate in ordinary pinning, validation and portable
backup/restore; source updates do not remap an existing selection. Old records
decode with these fields absent. This adds source provenance to coursework,
without representing manual progress or local deadline edits as Canvas writes.

The shared university importer also recognizes `google-calendar` documents from
the existing Calendar client. Permanent Calendar URLs permit only the `eid` query
key; credential-bearing query values remain rejected.
