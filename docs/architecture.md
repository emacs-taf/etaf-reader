# ETAF Reader architecture

## Responsibilities

`etaf-reader` is an application: it owns the library, the reading session and
the annotations, and it renders through ETAF and Ebox. Parsing is delegated to
the `ebook-parse` skill behind a two-function contract, and storage is
delegated to ETAF DB; neither is re-implemented here.

| Module | Owns |
| --- | --- |
| `etaf-reader-theme` | palettes and the ETAF UI token projection |
| `etaf-reader-store` | the SQLite schema, Data Controllers and row operations |
| `etaf-reader-library` | parser discovery/call, scan, import, cover and image cache |
| `etaf-reader-model` | session refs, wrapping, pagination, selection, annotations, search, progress |
| `etaf-reader-views` | pure renderers read from the session refs |
| `etaf-reader-app` | buffer, keymap, window metrics, commands, mount/unmount |

The root entry re-exports the supported subset; everything unlisted is
internal.

## Data flow

1. `etaf-reader-refresh-library` asks the parser to scan the configured
   directories and upserts one `books` row per file, keeping annotations and
   reading state of unchanged files.
2. Opening a book imports it when its chapter rows are missing: the parser
   writes a manifest and one JSON file per chapter into a per-book cache
   directory (images included), and the store receives one `chapters` row
   (metadata) and one `contents` row (text + blocks JSON) per chapter.
3. The model loads one chapter at a time, wraps its block text into lines for
   the current column count, and publishes refs: chapter, lines, annotations,
   selection, position. Views read those refs during render, so a command
   repaints without a remount.
4. Page turns and selection changes only write refs; position and reading time
   are written to the `states` table on a trailing timer and on close.

## Invariants

- **One projection.** `chapter.text` is `"\n".join(block.text)`; block and run
  offsets inside a chapter are code point offsets into that projection.
  Annotations store `(chapter, start, end)` in the same space, which is why
  they survive re-wrapping, font changes and resizes.
- **One writer per fact.** Reading position lives in `states`, annotations in
  `annotations`, book metadata in `books`; views never derive one from another
  except for display.
- **Rendering is a function of refs.** Views never call the store; the model
  refreshes cached annotation and state lists when a write happens.
- **Import is replace-on-success.** An extraction writes to `cache/<id>.new`
  and only replaces the previous directory after the manifest was read, so a
  failed import never leaves a half-updated book.

## Performance

The reading path does no I/O: the current chapter's text, lines, annotations
and states are in memory. Wrapping is cached per (chapter, column count) and
only re-run when the column count changes or a chapter is opened. The shelf
reads cached states from one hash table instead of one query per row. The
windowed render keeps the node count constant regardless of chapter size.

Two publication paths exist, and the difference is measured:

- A plain-body page turn replaces the visible line texts and the status labels
  through `etaf-runtime-update-host-contents`, one retained Ebox publication.
  Measured at 27 ms for 90 line slots plus the page and percent labels on a
  GPU frame, with no garbage collection in the sample.
- Anything the retained path cannot patch -- a page with a heading, an
  annotation or an active selection -- falls back to an ordinary ETAF
  publication.  That currently costs ~400 ms per turn on the same frame, which
  is the framework's whole-view publication cost, not a reader defect.  The
  fast path is skipped deliberately rather than applied partially, because a
  retained content update replaces only text strings.

The `:line` position is a plain session field so the fast path can move the
window without triggering a reactive publication; `:revision` is the explicit
repaint trigger, and `:published-line` records which page the retained Hosts
belong to.  Keep those three in sync when changing the reading Views.

## Dependencies

`etaf-reader` requires `etaf`, `etaf-ui`, `etaf-db`, `ebox` and `ecss` at
runtime, and the `ebook-parse` skill (with poppler for PDF) for imports.
Applications embed the reader through `etaf-reader-view-for-session`; the
Component provides its palette to the subtree, so shared ETAF UI controls
follow the reading theme.
