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
- An explicit repaint is tracked by the View, and the published page is
  recorded so the retained text Hosts always match the page they belong to.

### Performance

- Page turns go through ETAF's retained Host boundary when the published page
  and the new page are plain body text: one `etaf-runtime-update-host-contents`
  batch replaces the visible line texts and the status labels (measured 27 ms
  for 90 line slots plus the page and percent labels, against ~400 ms for a
  whole-view publication).  A page that contains a heading, an annotation or a
  selection falls back to one ordinary publication.  Closing the remaining gap
  (every such fallback page) is tracked as follow-up work.

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
