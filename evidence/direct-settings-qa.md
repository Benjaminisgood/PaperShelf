# Direct model and graph settings verification

Verified 2026-10-20 in the native PaperShelf app.

- Model settings accept API address, model name and API Key directly. Saving keeps the masked value and displays its saved state; reveal/hide is available.
- The save-and-test action and model catalog action persist current inputs before invoking the provider. A loopback mock service verified the submitted fixture credential and model, returning a successful JSON probe and two catalog models.
- In the isolated QA bundle and library, custom database address/user/password, independent graph API Key and embedding API Key were saved through the actual UI. After quitting and reopening, all four masked credentials reloaded with saved status. No production credentials were replaced by fixtures.
- Graph form snapshots preserve advanced options and restore custom connections when switching modes. Standalone graph and credential harnesses cover defaults, synchronization, distinct small models, managed-service matching, saved credential precedence, inherited fallback, routing, and command scoping.
- 19 backend integration tests passed. Swift app build and bundle signing/launch were verified through `script/build_and_run.sh --verify`.
- Graph credentials were tested for storage and routing; this check did not connect to a new external graph database or embedding service.

Local diagnostic logs are in `.build/settings-form-qa/`. The loopback fixture server and QA app were stopped after verification.

A final production check found legacy keychain reads could stall after rebuilding the app. New saves therefore use an atomic local `provider-credentials.json` file, without keychain writes or authorization prompts. Readable legacy values migrate without overwriting newer saves; explicit clears remain cleared. A temporary-file harness covered persistence, 40 concurrent merges, migration, clears, and malformed-file protection. The actual QA UI was then used to save a fixture API key locally, quit, reopen, and verify it reloaded as Saved. Inaccessible legacy values require one-time re-entry.
