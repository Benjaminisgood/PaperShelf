# Verification — 2026-10-18

- `npm run typecheck`: passed.
- `npm test`: **8 tests passed**. Tests cover authenticated loopback requests and pagination, connection-file/destination validation, UUID deep links, Unicode and long citations, BibTeX/RIS/Markdown escaping, explicit connection checks, fixed read-only browser getter scripts, and the strict native capture payload with unsafe destination/size rejection.
- `npm run build`: built all three commands successfully in the local `dist/` output with `@raycast/api` 2.8.2; no application was launched.
- The shared live integration smoke tested Raycast search, citation and deep-link generation against the real isolated Swift LocalAPIServer fixture. No production library was accessed.

Evidence under `evidence/lattice-parity/`: `raycast-typecheck.log`, `raycast-tests.log`, `raycast-build.log`, `adapters-live-api.log`, `word-raycast-verification.json`.

The Raycast host has **not been installed, launched, or used for acceptance**. Browser AppleScripts were checked with injected fixture responses; they were not executed against a user's browser, and no Automation permission was requested. Capturing a tab requires an explicit command invocation and any macOS permission the user chooses to grant. Native preview still requires confirmation before import.

An initial developer build used the Raycast CLI's default development output; those generated files were moved into the evidence directory. The checked-in build command now writes only `dist/`, and the development output was not activated in Raycast.
