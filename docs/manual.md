# ETAF Reader manual

## Library

`etaf-reader-open` shows the shelf. The first time the store is empty the
configured directories are scanned once; later use `i` to rescan. Files are
identified by the true path of the file, so moving a file imports it as a new
book while an unchanged file keeps its annotations and progress.

The shelf shows bounded pages rather than clipping the library after one
screen. Search by title or author with `s` or the Search button; clear the query
to show the whole library. Filter All/Reading/Unread/Finished and sort by recent
reading, title or author. Page buttons and SPC/DEL reach the remaining books.
Imported books show their cached covers; books without a cover use an initials
avatar. Opening a book resumes its stored location.

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

The top toolbar provides Library, Contents, Notes, Search and More. `o` opens
Reading Settings: palette, paged/scrolling mode, comfortable/compact paragraph
spacing and automatic or fixed column width. These choices are stored in the
library database and restored in the next session. An explicit `:theme` when
creating a scripted session overrides the saved initial palette.

Normal pages publish one styled text Host per column, including headings and
annotations. The selected line gains a nearby toolbar without imposing a
limit on the number of annotated segments. Font-size controls and inline ebook
illustrations are not yet provided.

Progress is stored as chapter index, character offset and percent; reading
time accumulates while the reader is open and is written together with the
position two seconds after the last page turn (and on close). `g` jumps to a
percentage of the whole book.

## Annotations

Select text with the mouse: drag from the first character to the last, and the
toolbar appears above or below the line when the drag ends. Keyboard users
press `v` to anchor the selection, move with the arrow keys, confirm with
`RET`, and cancel with `C-c C-k`.

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
can mark it. `S` reopens the results with snippets. `c` opens the table of
contents at the current chapter; `b` bookmarks the current page and `B` opens
the bookmark list. Contents, notes, search results and bookmarks have page
controls. Choose an item to jump to its location; `u` returns to the position
before a navigation jump. The bookmark dialog also offers deletion, and the
notes dialog opens annotation editing or exports Markdown. `Esc` closes a pane;
`C-c C-k` cancels a selection without closing the book.

## Keyboard help

`?`, `C-c h` and **More → Shortcuts** open the same read-only help modal in the
current reader buffer. Labels come from effective bindings, including local
keymap overrides. `/` searches; Escape leaves search editing first, then
closes the modal and restores the reader focus. An outside click also closes
help without activating the background. Wide windows show two columns;
compact windows use one scrolling column, following the reading theme.

For a mounted session, `(etaf-reader-show-pane reader 'help)` opens this same
modal without changing its navigation pane. Repeating the request reuses it;
`(etaf-reader-show-pane reader nil)` closes help and the navigation pane.
Headless sessions have no help surface and signal `etaf-reader-error`.

## Scripting

A session needs no buffer or timer until mounted. Its reading preferences are
restored from the configured database. Use its supported accessors rather than
inspecting the internal session representation:

```elisp
(let ((reader (etaf-reader-create)))
  (etaf-reader-refresh-library reader)          ; scan or rescan
  (etaf-reader-open-book reader (car (etaf-reader-books reader)))
  (etaf-reader-goto-percent reader 40)
  (etaf-reader-set-metrics reader 40 20 1 'medium 'page)
  (etaf-reader-configure reader :theme 'sepia :density 'comfortable)
  (etaf-reader-state reader))
```

Pass `:parser` to `etaf-reader-create` to drive the same reader from another
backend; it is a plist with `:scan` (directory -> `(:books ... :failed N)`)
and `:extract` (path, output directory -> `(:out ...)`) functions.

## Performance verification

From the enclosing workspace, run the maintained keyboard workload with the
shared driver:

```sh
python3 scripts/performance.py run --mode batch \
  --load-path etaf-reader \
  --scenario-file etaf-reader/benchmarks/performance-scenarios.el \
  --scenario reader.page.styled --sets 3 --samples 30 --warmups 5
```

The workload uses the available viewport rows and verifies every visible line
and the annotation's underline. `--diagnose` adds separate provider, CPU and
allocation passes. Keep the baseline `result.json` and compare with
`--baseline`; a faster comparison is not a pass if the absolute budget fails.
Batch results do not certify graphical latency. For isolated validation builds,
`make check PROVIDER_ROOT=/path/to/providers` selects sibling provider snapshots
without rebuilding or editing another working copy. Normal builds discover the
workspace or standalone sibling layout automatically.

## GUI verification

The maintained `scripts/etaf-reader-gui-scenarios.el` uses ETAF's
`emacs-gui-verifier` engine. In a dedicated graphical Emacs with the application
and ETAF `scripts/` directories on `load-path`, bind `etaf-reader-store-file`
to a disposable copy of the real library database, then schedule:

```elisp
(require 'etaf-reader-gui-scenarios)
(run-at-time 0.1 nil #'etaf-reader-gui-run
             "/tmp/reader-gui-evidence" "/path/to/book.epub"
             "The displayed book title" "A matching library query" t)
```

The directory must be new. The scenario uses native keys, focused RET
activation and native minibuffer input; it changes preferences and creates a
bookmark and annotation in the disposable database. Inspect `result.json`
and the captured images separately. It does not certify physical mouse input
or foreground latency. Close the dedicated instance after verification.

## Troubleshooting

| Symptom | Cause and action |
| --- | --- |
| `找不到电子书解析器` | install the `ebook-parse` CLI (see README) or set `etaf-reader-parser-command` |
| a PDF shows no text | scanned PDF; run OCR first, or open another file |
| a book opens with one huge chapter | the source EPUB packs many chapters into one spine document; use search and bookmarks |
| `无法打开书库数据库` | the SQLite file is locked or corrupt; move it aside to start a fresh library |
| shelf does not show a book | unsupported extension, or the file changed and re-import failed; the message line reports the parser error |
