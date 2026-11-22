# Working on LCP

LCP Desktop is a local-first class library for macOS 14 and later on Apple Silicon. Keep the native app, capture library, and optional self-hosted transcription service independently usable.

## Components

- `desktop/` contains the SwiftUI workspace, SwiftData library, scoped local MCP helper, university integrations, Xcode project, and release scripts. Read the desktop-specific instructions and storage contracts when changing these components. [Desktop instructions](desktop/AGENTS.md) · [Storage and interface contracts](docs/desktop-contracts.md)
- `client/` contains the capture facade and a standalone menu bar recorder. Capture uses AVFoundation and writes a finalized AAC audio file and a versioned ready marker with the filename, size, and SHA-256 digest. Keep network access and provider credentials outside the capture library.
- `server/` contains the optional Linux worker, a separate desktop feed exporter, and example units. The worker verifies copied input against the ready marker, preserves synced inputs, and archives verified audio before scratch cleanup. Use synthetic input and a fresh worker root for development. [Server setup](server/README.md)

## Data and integration contracts

Every academic class can record locally. Recording to a synced inbox requires a fresh validated destination and an explicit class mapping. Preserve the shared capture lease until finalization and never replace an app during a recording.

Keep material and transcript revisions immutable and retain exact revisions used by citations. Validate a full backup or feed generation before replacing state. Backups and exports must exclude service credentials. Store desktop credentials in the Mac Keychain.

Agent access uses scoped local stdio grants. Verify authorization on every request, including citation resolution. Agent proposals require user review, version preconditions, and idempotent acceptance. Report Drive publication and confirmed consumption by a downstream agent as separate facts.

Use a temporary library and fictional sources for tests. Never check in real coursework, lecture media, account settings, private reports, or deployment state. Keep example configuration usable with the reader’s own directories and service credentials. Changes to the checkout do not authorize modifying a running worker, installed app, or production data.

## Verification

On Apple Silicon macOS, run `swift test --package-path client`, `swift test --package-path desktop`, and `desktop/scripts/build-app.sh` for native changes. For worker changes, run the synthetic suites in an isolated Linux directory. Preserve resource limits, pause state and retry accounting when maintaining an existing deployment.
