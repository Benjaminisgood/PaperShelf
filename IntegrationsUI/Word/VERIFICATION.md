# Verification — 2026-10-18

- `npm test`: **11 tests passed** with Node 25.9.0. Actual citeproc formatting covers numeric citations, repeated references, reordering, author–year disambiguation, APA 7, IEEE, uploaded CSL persistence, long metadata, HTML italics/superscripts, hanging-indent output, and rejection of unsafe HTML/CSS/URL attributes.
- Tests also exercise real loopback HTTP requests, exact Host/Origin/session-nonce checks, connection-file permissions, server-side bearer auth, redirects, and document-state reconciliation.
- `npm run build`: self-contained Node `dist/server.mjs` built with citeproc and sanitize-html dependencies. The standalone bundle was copied to a fresh temporary directory **without node_modules** and successfully served the HTTPS task pane, searched the real isolated Swift API, and exposed the required citeproc source notice.
- `npx --yes office-addin-manifest@3.0.1 validate manifest.xml`: Microsoft manifest validator reports a valid schema, HTTPS locations, host requirements, and PNG icon.
- Repository smoke: `node --experimental-strip-types IntegrationsUI/Word/tests/live-paper-api.mjs` launches an independent in-memory Swift LocalAPIServer fixture. Word fetches CSL, formats `(Doe, 2024)` with APA, and proxies search through actual HTTPS. Raycast reads the same fixture. The temporary CA is trusted only by that test's Node client; system trust is unchanged. No production library is read or modified.

Evidence under `evidence/lattice-parity/`: `word-tests.log`, `word-build.log`, `word-manifest-validation.log`, `adapters-live-api.log`, `word-raycast-verification.json`.

This verifies code, protocols, formatting, a standalone bundle, and the manifest. The Word add-in has **not been sideloaded or enabled in the installed Word application**, and insertion, saved-document reopening, layout, and collaboration have not been accepted in a real Word host. No system certificate was installed or warning bypassed. See README for explicit certificate and sideload setup.
