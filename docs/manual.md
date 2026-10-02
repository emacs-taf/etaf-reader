# ETAF Reader manual

## Library

`etaf-reader-open` shows the shelf. The first time the store is empty the
configured directories are scanned once; later use `i` to rescan. Files are
identified by the true path of the file, so moving a file imports it as a new
book while an unchanged file keeps its annotations and progress.

| Variable | Meaning |
| --- | --- |
| `etaf-reader-library-directories` | directories scanned by the shelf (default `~/ebooks`) |
| `etaf-reader-store-file` | one SQLite file for books, chapters, annotations, states and bookmarks |
| `etaf-reader-cache-directory` | extracted covers and images per book |
| `etaf-reader-parser-command` | command prefix running the `ebook-parse` CLI, or nil to discover it |

Scanning is metadata-first: EPUB and PDF entries store title, author, chapter
or page counts without extracting text. Opening a book imports it (chapter
text and block structure into SQLite) and never reads the file again until it
changes.

## Reading

The reader wraps the current chapter into lines once per (chapter, columns) and
renders only the visible window: page mode shows `rows × spread` lines in one
or two columns, scroll mode shows one column and moves three lines per wheel
step. `[` and `]` adjust the column width, `z` switches mode, `t` cycles the
dark/light/sepia palettes, and a window resize re-wraps and re-paginates
through `window-size-change-functions`.

Progress is stored as chapter index, character offset and percent; reading
time accumulates while the reader is open and is written together with the
position two seconds after the last page turn (and on close). `g` jumps to a
percentage of the whole book.

## Annotations

Select text with the mouse: drag from the first character to the last, and the
toolbar appears above or below the line when the drag ends. Keyboard users
press `v` to anchor the selection, move with `h` `j` `k` `l`, confirm with
`RET`, and cancel with `C-g`.

The toolbar offers six colors and three styles — `highlight`, `underline`,
`wavy` — plus copy, write a thought, search the book, and delete. Clicking an
existing annotation reopens the toolbar for that annotation. Writing a thought
opens `*etaf-reader 想法*`; `C-c C-c` saves it, `C-c C-k` cancels. A thought
without a mark is stored as a `note` annotation.

Annotations are keyed by (chapter index, code point start/end) inside the
chapter's plain-text projection, not by screen position, so they follow the
text through re-wrapping and font changes. `a` lists the whole book's notes;
`E` exports them as Markdown.

## Search, bookmarks, contents

`s` searches the whole book (case-insensitive, wrapping around the current
chapter), `n`/`N` walk the matches, and the match is selected so the toolbar
can mark it. `c` opens the table of contents and `b` bookmarks the current
page; bookmarks are stored in the `bookmarks` table.

## Scripting

A session is a plain plist of reactive refs and needs no buffer:

```elisp
(let ((reader (etaf-reader-create)))
  (etaf-reader-refresh-library reader)          ; scan or rescan
  (etaf-reader-open-book reader (car (etaf-reader-store-books)))
  (etaf-reader-goto-percent reader 40)
  (etaf-reader-set-metrics reader 40 20 1 'medium 'page)
  (etaf-reader-reflow reader)
  (etaf-reader-state reader))
```

Pass `:parser` to `etaf-reader-create` to drive the same reader from another
backend; it is a plist with `:scan` (directory -> `(:books ... :failed N)`)
and `:extract` (path, output directory -> `(:out ...)`) functions.

## Troubleshooting

| Symptom | Cause and action |
| --- | --- |
| `找不到电子书解析器` | install the `ebook-parse` skill or set `etaf-reader-parser-command` |
| a PDF shows no text | scanned PDF; run OCR first, or open another file |
| a book opens with one huge chapter | the source EPUB packs many chapters into one spine document; use search and bookmarks |
| `无法打开书库数据库` | the SQLite file is locked or corrupt; move it aside to start a fresh library |
| shelf does not show a book | unsupported extension, or the file changed and re-import failed; the message line reports the parser error |
