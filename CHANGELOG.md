# Changelog

## Unreleased

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
