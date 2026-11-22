# LCP website

The public landing page lives at [lcp.betanine.dev](https://lcp.betanine.dev/). It uses plain HTML, CSS, JavaScript, local fonts, and screenshots from the desktop app’s fictional demo library.

Serve this directory as the site root, excluding this README. The host’s `/download` route redirects to the versioned Apple Silicon DMG under `/downloads/`. Take the DMG from the corresponding GitHub release and verify it against the published SHA256SUMS before serving it. Update the version, release links, and download target together. The screenshots and fonts can be served directly without a build step.

Keep deployment manifests and checksum receipts outside the public release directory. If a manifest is copied into a release temporarily for remote verification, remove it before switching `current`. The public site should contain only the files required to render the page and serve its documented download route.
