# Library data and exchange implementation

The native data layer stores JSON payloads in SQLite schema version 2. Existing schema-1 libraries migrate without replacing references. Newly introduced fields default when decoding old payloads; incompatible JSON types remain errors.

- References retain document type, original citation key, volume/issue/pages, publisher, ISBN/ISSN, arbitrary fields, rating, soft-deletion date, multiple collection IDs, primary PDF, and additional attachments.
- Collections have stable UUIDs, parent IDs, and explicit sort order. There is no depth limit. Missing parents and cycles are rejected. Removing collections never removes references or disk files.
- Tags have a name, optional hex color, and sort order. Legacy `Reference.collection` names become literal root collections; `/` in an old name is not treated as a hierarchy separator. Clearing membership must also clear this legacy string.
- Batch writes and imports are transactions. Replace-on-duplicate keeps the stable reference ID, date added, read/favorite/rating/deletion state, existing attachments, and existing notes/PDF when the incoming metadata omits them. ID, normalized DOI, and standardized primary PDF path identify duplicates.

## Exchange

`Bibliography.exportBibTeX` accepts `BibTeXExportOptions(fields:citationKeyTemplate:preserveCitationKeys:)`. An optional set of BibTeX field names limits output. Original type/key and additional fields survive import/export. The parser retains nested braces, macros, concatenation, corporate authors, and literal escaping.

`generateCitationKeys` supports `{author}`/`{Auth}` (first surname with original case), `{auth}` (lowercase surname), `{year}`, `{shortyear}` (last two year digits, including an ISO-date input), `{title}` (first three words), `{title-N}` (first N words), and `{id}`. N=0 contributes no title; an oversized N includes all available words. Diacritics are folded and Chinese names are retained. Duplicate keys receive case-insensitive a/b/.../aa suffixes. `reservedKeys` prevents a selected batch from colliding with references outside that batch. `exportRIS` emits standard bibliographic fields and a PaperShelf C1 extension to retain fields for which RIS has no equivalent. Other RIS applications can ignore this extension while reading ordinary fields.

Crossref lookups populate the additional bibliographic fields when provided by Crossref.

## Zotero

`ZoteroImporter.read(url:storageDirectory:linkedAttachmentDirectory:includeAttachments:)` copies the selected SQLite database and existing WAL to a fresh temporary directory. It verifies source file size, modification time, and identity across copying, checks the copied database, and reads it with read-only/query-only SQLite. It never opens the original database for writing or moves attachments. Cancellation is checked before opening the source, while reading SQLite rows, and while building references and attachment entries.

The importer retains regular items, metadata, creators and their roles, collections, memberships, tags, attached notes, a primary PDF, and additional readable attachments. Stable IDs derive from Zotero library IDs and keys. Deleted items are excluded. Standalone notes and unsupported relative linked-attachment paths produce explicit warnings. Zotero `storage:`, `attachments:` under a selected linked root, and absolute linked attachment paths are supported. Relative traversal and symlink escapes are rejected. When a linked root is supplied, absolute linked paths must also remain within it. `includeAttachments: false` skips attachment scanning and preserves metadata/notes/collections. Arbitrary Zotero fields are retained in `extraFields`.

## Backup and restore

A `.papershelfbackup` is a directory with `manifest.json`, a consistent SQLite backup-API snapshot, and optional attachment copies. SHA-256 checks cover the database and each included file. Creation uses a new staging directory and publishes with a directory rename; existing destinations are never overwritten.

Restore validates format, hashes, counts, attachment ownership, paths, and symlinks before changing the current library. It then saves a fresh safety backup, copies restored attachments into a unique directory, clears bookmarks for relocated paths, and replaces database records/collections/tags within one SQLite transaction. Optional `attachmentDirectory` selects the parent for that new directory; by default it uses `backupDirectory`. Existing files in a selected destination and source attachments are not overwritten. Failures leave the current library transaction rolled back and keep recovery data. Original disk attachments are not deleted or overwritten. Missing/unreadable source attachments are listed in manifest warnings; callers must surface these warnings.

Targeted tests cover legacy defaults and schema migration, extended BibTeX/RIS round trips, field selection and key uniqueness, deep collection hierarchy and cycle rejection, transaction rollback, duplicate metadata replacement, attachment restoration and safety backups, hash/path rejection, restore rollback, and a committed Zotero WAL fixture with byte-for-byte source immutability checks.

## Final verification and shortcuts

The focused run (`swift test --scratch-path .build/learning-parity --filter 'LibraryExchangeTests|BibliographyTests|LibraryDatabaseTests|DOIClientTests|MetadataLookupTests'`) passed 45 tests, including 21 exchange/migration/backup tests, and is recorded in `library-exchange-tests.log`. It includes extended citation-token, selected restore-directory, external Zotero root, metadata-only and cancellation tests. Long legal attachment filenames are covered: backup names use fixed UUID components while the manifest retains original full paths.

`LibraryDatabase(url:readOnly:true)` supports Shortcuts queries without creating a library or running migrations. `applyReferenceChanges(upserting:deleting:)` applies undo/redo patches atomically while retaining unrelated references, collections, and tags.

Backups optionally include `preferences.json` through `preferencesURL`. Its hash is checked before restoration. The returned `restoredPreferencesData` retains templates and presentation preferences but removes `localAPI`, so restoring a backup does not grant API access. Current preferences are included in the recovery backup. The caller installs the returned preferences explicitly after successful restoration.

Three native App Intents provide query search, opening a UUID/citation key, and exporting selected references to a Markdown `IntentFile`. Exports use the saved metadata/annotation templates and OCR setting; region images are embedded as data URIs. App Intents extraction was validated with Apple's `appintentsmetadataprocessor`; `script/extract_app_intents.sh BUILD_DIR APP_BUNDLE` verifies all three actions and installs metadata before signing. This compiler/metadata evidence does not by itself establish final Shortcuts UI discovery or a completed interactive shortcut run.

The final backup regression also verifies security-bookmark resolution when a stored attachment path is stale. The final AppEntity exposes title, citation key, and UUID as native Shortcuts properties. `appintents-packaging.log` records successful extraction and bundling after this change.
