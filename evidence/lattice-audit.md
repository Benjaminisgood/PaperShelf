# Lattice public repository audit

Inspected commit `001dcbbc97ff40536adc0dcee8125239c071544b` (2026-05-22). This is a review of public documentation, not an execution or reverse-engineering of the application. No Lattice artwork or application code is included in PaperShelf.

## Source and permission boundaries

- The tracked tree contains README/changelog/site/static assets, with no Swift source, Xcode project, or Swift package. Native Swift and macOS 14+ are publisher statements ([README lines 15–20](https://github.com/stringer07/Lattice_release/blob/001dcbbc97ff40536adc0dcee8125239c071544b/README.md#L15-L20)).
- The changelog explicitly documents an AppKit rewrite of Settings ([lines 119–123](https://github.com/stringer07/Lattice_release/blob/001dcbbc97ff40536adc0dcee8125239c071544b/CHANGELOG.md#L119-L123)); it does not establish the main UI framework, persistence engine, or PDF implementation.
- No LICENSE or COPYING file was present; GitHub's repository API reported `license: null`. The site says [“© 2026 Lattice. All rights reserved.”](https://github.com/stringer07/Lattice_release/blob/001dcbbc97ff40536adc0dcee8125239c071544b/docs/privacy.html#L131). Public availability does not establish permission to reuse its code, artwork, or branding. Publicly described behaviors can inform an independently implemented reference manager.

## Product behavior documented by its author

| Capability | Pinned evidence |
| --- | --- |
| Three-column library, table, metadata/annotation inspector; search and keyboard actions | [README 114–143](https://github.com/stringer07/Lattice_release/blob/001dcbbc97ff40536adc0dcee8125239c071544b/README.md#L114-L143) |
| Collections, tags, Unfiled/Missing DOI/Missing Attachment filters | [README 145–172](https://github.com/stringer07/Lattice_release/blob/001dcbbc97ff40536adc0dcee8125239c071544b/README.md#L145-L172) |
| Link original PDFs, open externally, reveal in Finder, replace attachment | [README 99–104](https://github.com/stringer07/Lattice_release/blob/001dcbbc97ff40536adc0dcee8125239c071544b/README.md#L99-L104) |
| Optional on-disk organization by copying or moving PDFs | [README 248–263](https://github.com/stringer07/Lattice_release/blob/001dcbbc97ff40536adc0dcee8125239c071544b/README.md#L248-L263) |
| PDF, BibTeX and DOI import, explicit duplicate handling | [README 174–199](https://github.com/stringer07/Lattice_release/blob/001dcbbc97ff40536adc0dcee8125239c071544b/README.md#L174-L199) |
| RIS, Zotero migration, manual entry, backup and restore added in v2.1.6 | [CHANGELOG 7–15](https://github.com/stringer07/Lattice_release/blob/001dcbbc97ff40536adc0dcee8125239c071544b/CHANGELOG.md#L7-L15) |
| Highlight, underline, strikethrough, text, free text, square and circle annotation extraction; region images | [README 277–309](https://github.com/stringer07/Lattice_release/blob/001dcbbc97ff40536adc0dcee8125239c071544b/README.md#L277-L309) |
| Metadata/annotation templates; Markdown/TextBundle/BibTeX export; Shortcuts | [README 339–441](https://github.com/stringer07/Lattice_release/blob/001dcbbc97ff40536adc0dcee8125239c071544b/README.md#L339-L441) |
| Local storage and direct third-party metadata requests, no vendor library backend | [Privacy policy 68–74](https://github.com/stringer07/Lattice_release/blob/001dcbbc97ff40536adc0dcee8125239c071544b/docs/privacy.html#L68-L74) |
| Deliberately no full built-in PDF reader | [README 228–245](https://github.com/stringer07/Lattice_release/blob/001dcbbc97ff40536adc0dcee8125239c071544b/README.md#L228-L245) |

## Recommended implementation sequence

1. Local persistence and three-column library; linked PDF import, editable metadata, collections/tags/search, external open and Finder reveal.
2. BibTeX import/export, DOI lookup, explicit duplicate handling, Markdown export. Network or metadata failures must preserve editable records and user changes.
3. Quick Look and PDF annotation extraction, with text/page verification; later add region images and TextBundle.
4. RIS, backup/restore, Zotero migration, advanced templates, Shortcuts, optional on-disk organization and extension APIs.

This sequence is a recommendation, not a statement that PaperShelf implements all listed capabilities. Consult PaperShelf's implementation report for delivered features and tested limitations. Lattice's advertised footprint targets are not independently verified performance measurements.
