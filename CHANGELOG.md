# Changelog

## Unreleased

### Fixed

- The reader no longer touches the store while ETAF renders: the shelf View
  reads cached rows, and store work happens before mounting.
- `SPC`, `DEL`, the page keys, `n`, `q`, `RET` and the wheel are no longer
  shadowed by the renderer's minor-mode map; `RET` confirms a selection or
  activates the focused control, and `H`/`L` move between chapters as the help
  pane documents.
- Line kinds are real symbols (`body`, `heading`, `quote`, `pre`), so headings
  render bold, quotes get their bar, and the page-turn fast path can classify
  a window.
- Final partial pages clear unused rows instead of keeping stale text. Source
  coordinates follow their text across both columns; selection no longer
  mistakes physical buffer rows for chapter lines.
- Reading columns leave space for the footer, and light/sepia text uses the
  matching foreground. Deferred progress saves retain their originating store.

### Performance

- Opening a long book writes all chapters as one batch per table instead of
  one Controller mutation per row: a synthetic 1000-chapter import dropped
  from 7.7 s to 0.064 s, and a 1692-chapter 28 MB EPUB imported end to end in
  5.6 s in a GUI session (extraction included).

- Heading and annotated pages now use retained content updates too: each
  column is one styled text Host, rather than a subtree per line/segment.
  Selection toolbars temporarily restore line anchors. This removes the
  unconditional whole-view fallback for styled pages; latency must still be
  verified with the maintained keyboard workload on the target display.

### Added

- Local ebook reader application: shelf, library scan and import through the
  `ebook-parse` skill, SQLite storage through ETAF DB, paged and scrolling
  reading layout, dark/light/sepia palettes, adjustable reading width.
- Text selection with the mouse or a keyboard selection mode and a floating
  toolbar for highlight, straight underline, wavy underline, thoughts, copy,
  search and delete; annotations anchor on chapter text offsets.
- Table of contents, notes pane, in-book search, bookmarks, percentage jumps,
  per-book reading progress with reading time and Markdown note export.
- Public session API (`etaf-reader-create`, `etaf-reader-open-book`,
  `etaf-reader-state`) that works without a buffer, plus a replaceable parser
  contract for tests and other frontends.
