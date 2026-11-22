# LCP Desktop implementation

Read the [repository instructions](../AGENTS.md) and [desktop contracts](../docs/desktop-contracts.md).

LCP Desktop targets macOS 14+ with SwiftUI and uses the stable bundle ID
`org.lcp.Desktop`. The default library lives in `~/Library/Application Support/LCP Desktop`.
Keep capture code in the client package and server processing outside the desktop.
Coordinate edits to shared files with their current owner.

Use fictional data and temporary libraries for automated tests. Exercise microphone
capture only in a deliberate manual check. Bound imports and commit each
transaction atomically. Preserve the exact cited revisions in backups. Keep
private context, credentials, real transcripts and recordings out of version
control and public artifacts.
