# Inline inspector and organization controls

Verified on 2026-10-20 using the native QA bundle and a synthetic library under `.build/inspector-qa/library/`. Production papers and PDFs were not used as edit fixtures.

Implemented:

- Metadata fields, title, authors, publication data, custom fields, abstract and notes edit directly in the inspector. Return or leaving a field saves; Escape restores the current field. Existing edit commands open the inspector. The old metadata sheet was removed.
- Collection and tag membership use visible, separate switches with names on the left and switches on the right. Disabling a switch changes only that paper's membership. Parent collection rows distinguish direct membership from membership in a child collection.
- Right-side creation creates and assigns a collection/tag; left-side creation and rename use inline fields with explicit Save/Cancel and Escape. Sidebar context menus also include removing membership from selected papers.
- When an edit removes the paper from the current filter, the inspector stays available with a notice and Show paper action.
- Remote metadata updates preview in the same inspector with Apply/Cancel and three-way conflict checking. Direct notification observers flush focused inputs before Apply/Refresh; native QA caught and fixed deferred SwiftUI notification delivery losing the last edit.

Native UI checks completed:

1. Toggled literal `A,B` tag on/off; sidebar count followed membership. Removed both a parent and its last child membership; Unfiled count increased and definitions remained.
2. Removed the active tag filter's membership: table became empty, inspector retained the paper. Re-enabled the tag and the row returned.
3. Changed year then Escape: original value remained. Changed year then Return: table updated. Changed source and immediately selected another paper: the source saved to the original paper and the second paper stayed unchanged.
4. Created a tag in the inspector; Escape cancelled a separate draft without leaving a tag. Created a collection with the menu shortcut and renamed a tag using the left sidebar. No edit sheet appeared.
5. Quit/reopened the QA app; metadata, tag names and membership states persisted.
6. Used real Crossref responses for public sample DOIs in the synthetic library. Edited a focused preview title and clicked Apply without Return: the final build saved the exact last text. Entered a DOI without Return and clicked Refresh: the identifier was committed and the preview loaded. Cancelled a focused preview edit: original metadata remained.
7. At approximately 980-point window width, hid/showed the left sidebar and inspector; the inspector remained about 390 points wide and toolbar controls stayed visible. Inspected the final Chinese layout with left-aligned names and right-aligned switches.

Automated checks:

- `Tests/AppHarnesses/LibraryOrganizationEditing.swift` passed against the real store and isolated SQLite: exact tag names, latest-record preservation, last-collection legacy clearing, filter behavior, scoped batch changes, inline creation, Undo/Redo, invalid IDs, and reopen persistence.
- Three `ReferenceEditsTests` passed, covering independent changes and same-field conflict protection.
- QA build, packaging, code signature verification, localization validation and `git diff --check` passed.

Logs and temporary fixture executables are under `.build/inspector-qa/` and `.build/organization-qa/`. The native UI checks do not claim exhaustive testing of all attachment/file-dialog or external service workflows.

Production deployment: `./script/build_and_run.sh --verify` completed successfully. The restarted production app showed the original 21 papers, editable metadata fields and the user's existing collection/tag switches. No test entries were added to the production library.
