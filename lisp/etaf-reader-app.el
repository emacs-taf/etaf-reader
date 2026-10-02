;;; etaf-reader-app.el --- Application shell of etaf-reader -*- lexical-binding: t; -*-

;; Copyright (C) 2026 ETAF contributors
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; The application layer binds one reader session to the Views, owns the
;; buffer, the keymap and the window metrics.  The `etaf-reader-app'
;; Component is the only place that renders the session; every command writes
;; a reactive source, so a page turn, an annotation or a theme change repaints
;; without a remount.
;;
;; Keys are buffer-local commands, not components: reading is a keyboard
;; activity, and a window resize re-runs the layout through
;; `window-size-change-functions' together with the framework's own refit.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'etaf)
(require 'etaf-ui)
(require 'etaf-reader-theme)
(require 'etaf-reader-model)
(require 'etaf-reader-views)

(defvar-local etaf-reader--session nil
  "Reader session shown by the current buffer's runtime.")

(defvar etaf-reader--size-hook-installed nil
  "Whether the global window-size hook was installed.")

;;; ---------------------------------------------------------------------------
;;; Small helpers
;;; ---------------------------------------------------------------------------

(defun etaf-reader--current ()
  "Return the current buffer's reader session."
  (or etaf-reader--session
      (user-error "Not an ETAF reader buffer")))

(defun etaf-reader--call (function)
  "Run FUNCTION for the current session with error reporting."
  (etaf-reader-guard (etaf-reader--current) function))

(defun etaf-reader--cursor-move (session delta-line delta-char)
  "Move the selection caret by DELTA-LINE lines and DELTA-CHAR characters."
  (let* ((cursor (etaf-reader--read session :cursor))
         (lines (etaf-reader--read session :lines))
         (count (length lines))
         (line (or (plist-get cursor :line) (etaf-reader--read session :line)))
         (char (or (plist-get cursor :char) 0))
         (new-line (max 0 (min (1- (max 1 count)) (+ line delta-line))))
         (entry (nth new-line lines))
         (text (or (plist-get entry :text) ""))
         (new-char (if (/= new-line line)
                       (if (> delta-line 0) 0 (length text))
                     (max 0 (min (length text) (+ char delta-char))))))
    (if cursor
        (etaf-reader-extend-selection session new-line new-char)
      (etaf-reader-begin-selection session new-line new-char))
    ;; Keep the caret inside the visible page.
    (let* ((top (etaf-reader--read session :line))
           (page (max 1 (etaf-reader--page-size session))))
      (cond ((< new-line top) (etaf-reader-goto-line session new-line))
            ((>= new-line (+ top page))
             (etaf-reader-goto-line session (max 0 (- new-line (1- page)))))))))

;;; ---------------------------------------------------------------------------
;;; Component and view
;;; ---------------------------------------------------------------------------

(etaf-define-component etaf-reader-app (&key session)
  "Render the reader for SESSION and own its lifecycle."
  :bindings ((reader (or session
                         (signal 'etaf-reader-error
                                 '("etaf-reader-app needs the :session from `etaf-reader-create'"))))
             (theme (etaf-reader--ref reader :theme))
             (tokens (etaf-computed
                      (lambda ()
                        (etaf-reader-theme-defaults (etaf-value theme)))
                      :name 'etaf-reader-theme-tokens)))
  :setup
  (etaf-theme-provide tokens)
  :render
  (etaf-reader-view reader))

(defun etaf-reader-view-for-session (session)
  "Return the mountable View of SESSION."
  (etaf-view (etaf-reader-app :session session)))

;;; ---------------------------------------------------------------------------
;;; Window metrics
;;; ---------------------------------------------------------------------------

(defun etaf-reader--window-size-changed (frame)
  "Reflow every reader shown on FRAME after a window resize."
  (dolist (window (window-list frame))
    (let ((buffer (window-buffer window)))
      (when (buffer-live-p buffer)
        (when-let* ((session (buffer-local-value 'etaf-reader--session buffer)))
          (ignore-errors
            (etaf-reader-sync-metrics session
                                      (window-body-width window)
                                      (window-body-height window))))))))

(defun etaf-reader--install-size-hook ()
  "Install the reader's global window-size hook once."
  (unless etaf-reader--size-hook-installed
    (add-hook 'window-size-change-functions #'etaf-reader--window-size-changed)
    (setq etaf-reader--size-hook-installed t)))

;;; ---------------------------------------------------------------------------
;;; Keymap
;;; ---------------------------------------------------------------------------

(defvar etaf-reader-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "SPC") #'etaf-reader-next-page-command)
    (define-key map (kbd "<next>") #'etaf-reader-next-page-command)
    (define-key map (kbd "DEL") #'etaf-reader-previous-page-command)
    (define-key map (kbd "<prior>") #'etaf-reader-previous-page-command)
    (define-key map (kbd "j") #'etaf-reader-forward-line-command)
    (define-key map (kbd "k") #'etaf-reader-backward-line-command)
    (define-key map (kbd "h") #'etaf-reader-backward-char-command)
    (define-key map (kbd "l") #'etaf-reader-forward-char-command)
    ;; Upper case always moves between chapters, selection or not.
    (define-key map (kbd "H") #'etaf-reader-chapter-backward-command)
    (define-key map (kbd "L") #'etaf-reader-chapter-forward-command)
    (define-key map (kbd "<left>") #'etaf-reader-previous-page-command)
    (define-key map (kbd "<right>") #'etaf-reader-next-page-command)
    (define-key map (kbd "<down>") #'etaf-reader-forward-line-command)
    (define-key map (kbd "<up>") #'etaf-reader-backward-line-command)
    (define-key map (kbd "v") #'etaf-reader-toggle-selection-command)
    (define-key map (kbd "RET") #'etaf-reader-confirm-selection-command)
    (define-key map (kbd "C-g") #'etaf-reader-cancel-selection-command)
    (define-key map (kbd "s") #'etaf-reader-search-command)
    (define-key map (kbd "n") #'etaf-reader-search-next-command)
    (define-key map (kbd "N") #'etaf-reader-search-previous-command)
    (define-key map (kbd "c") #'etaf-reader-toc-command)
    (define-key map (kbd "a") #'etaf-reader-notes-command)
    (define-key map (kbd "b") #'etaf-reader-bookmark-command)
    (define-key map (kbd "g") #'etaf-reader-goto-percent-command)
    (define-key map (kbd "z") #'etaf-reader-toggle-mode-command)
    (define-key map (kbd "[") #'etaf-reader-narrower-command)
    (define-key map (kbd "]") #'etaf-reader-wider-command)
    (define-key map (kbd "t") #'etaf-reader-toggle-theme-command)
    (define-key map (kbd "f") #'etaf-reader-shelf-command)
    (define-key map (kbd "i") #'etaf-reader-scan-command)
    (define-key map (kbd "E") #'etaf-reader-export-command)
    (define-key map (kbd "?") #'etaf-reader-help-command)
    (define-key map (kbd "q") #'etaf-reader-close)
    (define-key map (kbd "<wheel-down>") #'etaf-reader-wheel-down-command)
    (define-key map (kbd "<wheel-up>") #'etaf-reader-wheel-up-command)
    (define-key map (kbd "<mouse-5>") #'etaf-reader-wheel-down-command)
    (define-key map (kbd "<mouse-4>") #'etaf-reader-wheel-up-command)
    map)
  "Keymap of a buffer opened by `etaf-reader-open'.")

;;; ---------------------------------------------------------------------------
;;; Renderer-owned keys
;;; ---------------------------------------------------------------------------

(defvar etaf-reader--command-maps
  (list (cons 'etaf-reader--session
              (let ((map (make-sparse-keymap)))
                ;; The renderer's minor-mode map owns these keys and wins over
                ;; a major-mode map; an `emulation-mode-map-alists' entry wins
                ;; over every minor mode, so the reader replaces them here.
                (define-key map (kbd "SPC") #'etaf-reader-next-page-command)
                (define-key map (kbd "S-SPC") #'etaf-reader-previous-page-command)
                (define-key map (kbd "C-v") #'etaf-reader-next-page-command)
                (define-key map (kbd "M-v") #'etaf-reader-previous-page-command)
                (define-key map (kbd "DEL") #'etaf-reader-previous-page-command)
                (define-key map (kbd "n") #'etaf-reader-search-next-command)
                (define-key map (kbd "q") #'etaf-reader-close)
                (define-key map (kbd "RET") #'etaf-reader-return-command)
                (define-key map [wheel-up] #'etaf-reader-wheel-up-command)
                (define-key map [wheel-down] #'etaf-reader-wheel-down-command)
                (define-key map [mouse-4] #'etaf-reader-wheel-up-command)
                (define-key map [mouse-5] #'etaf-reader-wheel-down-command)
                map)))
  "Reader bindings that must beat the renderer's own minor-mode map.
The alist's key is `etaf-reader--session', the buffer-local variable every
reader buffer owns, so the entry is active exactly there.  TAB focus cycling
and activation of focused controls stay the renderer's (RET dispatches
between them).")

(defun etaf-reader-return-command ()
  "Confirm the current selection, or activate the focused control."
  (interactive)
  (etaf-reader--call
   (lambda ()
     (let ((session (etaf-reader--current)))
       (if (and (etaf-reader-selection session)
                (null (etaf-focused-host-ref)))
           (etaf-reader-show-toolbar session)
         (etaf-activate))))))

;;; ---------------------------------------------------------------------------
;;; Commands
;;; ---------------------------------------------------------------------------

(defun etaf-reader-next-page-command ()
  "Turn to the next page (page mode) or scroll (scroll mode)."
  (interactive)
  (etaf-reader--call
   (lambda ()
     (let ((session (etaf-reader--current)))
       (if (eq (etaf-reader--read session :mode) 'scroll)
           (etaf-reader-scroll-lines session 3)
         (etaf-reader-clear-selection session)
         (etaf-reader-next-page session))))))

(defun etaf-reader-previous-page-command ()
  "Turn to the previous page (page mode) or scroll back (scroll mode)."
  (interactive)
  (etaf-reader--call
   (lambda ()
     (let ((session (etaf-reader--current)))
       (if (eq (etaf-reader--read session :mode) 'scroll)
           (etaf-reader-scroll-lines session -3)
         (etaf-reader-clear-selection session)
         (etaf-reader-previous-page session))))))

(defun etaf-reader-forward-line-command ()
  "Move down one line, or extend the keyboard selection."
  (interactive)
  (etaf-reader--call
   (lambda ()
     (let ((session (etaf-reader--current)))
       (if (etaf-reader--read session :cursor)
           (etaf-reader--cursor-move session 1 0)
         (etaf-reader-scroll-lines session 1))))))

(defun etaf-reader-backward-line-command ()
  "Move up one line, or extend the keyboard selection."
  (interactive)
  (etaf-reader--call
   (lambda ()
     (let ((session (etaf-reader--current)))
       (if (etaf-reader--read session :cursor)
           (etaf-reader--cursor-move session -1 0)
         (etaf-reader-scroll-lines session -1))))))

(defun etaf-reader-forward-char-command ()
  "Move right one character, or go to the next chapter."
  (interactive)
  (etaf-reader--call
   (lambda ()
     (let ((session (etaf-reader--current)))
       (if (etaf-reader--read session :cursor)
           (etaf-reader--cursor-move session 0 1)
         (etaf-reader-next-chapter session))))))

(defun etaf-reader-backward-char-command ()
  "Move left one character, or go to the previous chapter."
  (interactive)
  (etaf-reader--call
   (lambda ()
     (let ((session (etaf-reader--current)))
       (if (etaf-reader--read session :cursor)
           (etaf-reader--cursor-move session 0 -1)
         (etaf-reader-previous-chapter session))))))

(defun etaf-reader-chapter-forward-command ()
  "Open the next chapter."
  (interactive)
  (etaf-reader--call
   (lambda () (etaf-reader-next-chapter (etaf-reader--current)))))

(defun etaf-reader-chapter-backward-command ()
  "Open the previous chapter."
  (interactive)
  (etaf-reader--call
   (lambda () (etaf-reader-previous-chapter (etaf-reader--current)))))

(defun etaf-reader-toggle-selection-command ()
  "Start or clear the keyboard selection."
  (interactive)
  (etaf-reader--call
   (lambda ()
     (let ((session (etaf-reader--current)))
       (if (etaf-reader--read session :cursor)
           (etaf-reader-clear-selection session)
         (etaf-reader-begin-selection session
                                      (etaf-reader--read session :line) 0)
         (etaf-reader-message session "hjkl 移动选择，回车打开工具条，C-g 取消"))))))

(defun etaf-reader-confirm-selection-command ()
  "Open the annotation toolbar for the current selection."
  (interactive)
  (etaf-reader--call
   (lambda ()
     (let ((session (etaf-reader--current)))
       (if (etaf-reader-selection session)
           (etaf-reader-show-toolbar session)
         (etaf-reader-message session "还没有选中文字"))))))

(defun etaf-reader-cancel-selection-command ()
  "Clear the selection, cursor and toolbar."
  (interactive)
  (etaf-reader--call
   (lambda ()
     (etaf-reader-clear-selection (etaf-reader--current)))))

(defun etaf-reader-search-command ()
  "Search the current book."
  (interactive)
  (etaf-reader--call
   (lambda ()
     (let* ((session (etaf-reader--current))
            (query (read-string "搜索全书：")))
       (unless (string-empty-p (string-trim query))
         (etaf-reader-search-book session (string-trim query)))))))

(defun etaf-reader-search-next-command ()
  "Jump to the next search match."
  (interactive)
  (etaf-reader--call (lambda () (etaf-reader-search-next (etaf-reader--current)))))

(defun etaf-reader-search-previous-command ()
  "Jump to the previous search match."
  (interactive)
  (etaf-reader--call
   (lambda () (etaf-reader-search-next (etaf-reader--current) t))))

(defun etaf-reader-toc-command ()
  "Toggle the table of contents pane."
  (interactive)
  (etaf-reader--call
   (lambda ()
     (let ((session (etaf-reader--current)))
       (etaf-reader--write session :pane
                           (if (eq (etaf-reader--read session :pane) 'toc) nil 'toc))))))

(defun etaf-reader-notes-command ()
  "Toggle the notes pane."
  (interactive)
  (etaf-reader--call
   (lambda ()
     (let ((session (etaf-reader--current)))
       (etaf-reader--write session :book-notes
                           (etaf-reader-store-annotations
                            (plist-get (etaf-reader--read session :book) :id)))
       (etaf-reader--write session :pane
                           (if (eq (etaf-reader--read session :pane) 'notes) nil 'notes))))))

(defun etaf-reader-bookmark-command ()
  "Bookmark the top line of the current page."
  (interactive)
  (etaf-reader--call (lambda () (etaf-reader-add-bookmark (etaf-reader--current)))))

(defun etaf-reader-goto-percent-command ()
  "Jump to a percent of the book."
  (interactive)
  (etaf-reader--call
   (lambda ()
     (let* ((session (etaf-reader--current))
            (input (read-string "跳到百分比（0-100）：")))
       (when (string-match-p "\\`[0-9.]+\\'" input)
         (etaf-reader-goto-percent session (string-to-number input)))))))

(defun etaf-reader-toggle-mode-command ()
  "Toggle page turning and scrolling."
  (interactive)
  (etaf-reader--call
   (lambda ()
     (let* ((session (etaf-reader--current))
            (mode (if (eq (etaf-reader--read session :mode) 'page) 'scroll 'page)))
       (etaf-reader--write session :mode mode)
       (etaf-reader-sync-metrics session)
       (etaf-reader-message session (if (eq mode 'page) "翻页模式" "滚动模式"))))))

(defun etaf-reader--adjust-columns (session delta)
  "Adjust SESSION's reading width by DELTA characters."
  (let* ((row (or (etaf-reader--read session :metrics) '()))
         (columns (max 24 (min 72 (+ (or (plist-get row :columns) 40) delta)))))
    (plist-put row :columns columns)
    (plist-put row :manual t)
    (etaf-reader--write session :metrics row)
    (etaf-reader-reflow session)
    (etaf-reader-message session (format "栏宽 %d 字符" columns))))

(defun etaf-reader-wider-command ()
  "Widen the reading column."
  (interactive)
  (etaf-reader--call
   (lambda () (etaf-reader--adjust-columns (etaf-reader--current) 4))))

(defun etaf-reader-narrower-command ()
  "Narrow the reading column."
  (interactive)
  (etaf-reader--call
   (lambda () (etaf-reader--adjust-columns (etaf-reader--current) -4))))

(defun etaf-reader-toggle-theme-command ()
  "Switch to the next palette."
  (interactive)
  (etaf-reader--call
   (lambda ()
     (let* ((session (etaf-reader--current))
            (themes '(dark light sepia))
            (current (etaf-reader--read session :theme))
            (tail (cdr (memq current themes))))
       (etaf-reader--write session :theme (or (car tail) (car themes)))
       (etaf-reader-message session
                            (format "主题：%s" (etaf-reader--read session :theme)))))))

(defun etaf-reader-shelf-command ()
  "Return to the shelf."
  (interactive)
  (etaf-reader--call (lambda () (etaf-reader-show-shelf (etaf-reader--current)))))

(defun etaf-reader-scan-command ()
  "Rescan the library directories."
  (interactive)
  (etaf-reader--call
   (lambda ()
     (etaf-reader-message (etaf-reader--current) "正在扫描书库…")
     (etaf-reader-refresh-library (etaf-reader--current)))))

(defun etaf-reader-export-command ()
  "Export the current book's annotations as Markdown."
  (interactive)
  (etaf-reader--call
   (lambda ()
     (let* ((session (etaf-reader--current))
            (book (etaf-reader--read session :book))
            (default (expand-file-name
                      (concat (or (plist-get book :title) "notes") ".md")
                      "~/"))
            (file (read-file-name "导出到：" default)))
       (etaf-reader-export-notes session file)))))

(defun etaf-reader-help-command ()
  "Show the key help pane."
  (interactive)
  (etaf-reader--call
   (lambda ()
     (let ((session (etaf-reader--current)))
       (etaf-reader--write session :pane
                           (if (eq (etaf-reader--read session :pane) 'help) nil 'help))))))

(defun etaf-reader--wheel (delta)
  "Scroll by DELTA lines (or turn pages)."
  (etaf-reader--call
   (lambda ()
     (let ((session (etaf-reader--current)))
       (if (eq (etaf-reader--read session :mode) 'page)
           (if (> delta 0)
               (etaf-reader-next-page session)
             (etaf-reader-previous-page session))
         (etaf-reader-scroll-lines session delta))))))

(defun etaf-reader-wheel-down-command ()
  "Scroll the reader downwards."
  (interactive)
  (etaf-reader--wheel 3))

(defun etaf-reader-wheel-up-command ()
  "Scroll the reader upwards."
  (interactive)
  (etaf-reader--wheel -3))

;;; ---------------------------------------------------------------------------
;;; Entry points
;;; ---------------------------------------------------------------------------

(defun etaf-reader--display (session)
  "Mount SESSION in its buffer and return that buffer."
  (let* ((buffer (get-buffer-create "*ETAF Reader*"))
         (window (get-buffer-window buffer t)))
    (plist-put session :buffer buffer)
    (with-current-buffer buffer
      (setq-local etaf-reader--session session)
      (setq-local truncate-lines t)
      (setq-local mode-line-format nil)
      (setq-local emulation-mode-map-alists
                  (cons 'etaf-reader--command-maps
                        (remq 'etaf-reader--command-maps
                              emulation-mode-map-alists)))
      (setq-local buffer-display-table
                  (let ((table (copy-sequence (or standard-display-table
                                                  (make-display-table)))))
                    (set-display-table-slot table 'truncation ?\s)
                    table))
      (face-remap-set-base 'default
                           (list :background
                                 (etaf-reader-color :bg (etaf-reader--read session :theme))))
      (use-local-map etaf-reader-mode-map))
    ;; A native text application owns the window it was opened from: a
    ;; `display-buffer' rule must not split the frame into a second pane.
    (let ((display-buffer-overriding-action '((display-buffer-same-window))))
      (pop-to-buffer buffer))
    (setq window (get-buffer-window buffer t))
    ;; Store reads happen before mounting: creating Data Controllers inside
    ;; ETAF's publication is a render side effect and is rejected.
    (etaf-reader--write session :books (etaf-reader-store-books))
    (etaf-reader-refresh-states session)
    (etaf-reader-sync-metrics session)
    (etaf-mount buffer (etaf-reader-view-for-session session)
                (list :viewport-width
                      (if (window-live-p window) (window-body-width window t) 800)
                      :viewport-height
                      (if (window-live-p window) (window-body-height window) 30)))
    (etaf-runtime-flush (etaf-runtime-for-buffer buffer))
    (etaf-reader--install-size-hook)
    buffer))

(defun etaf-reader--open-path (session path)
  "Open the book file at PATH in SESSION."
  (let* ((path (expand-file-name path))
         (id (etaf-reader--book-id path))
         (existing (etaf-reader-store-book id))
         (row (or existing
                  (list :id id :path path
                        :title (file-name-base path)
                        :author "" :format (upcase (file-name-extension path))
                        :cover "" :chapters 0 :chars 0 :pages 0
                        :size 0 :mtime 0 :added (floor (float-time))
                        :opened 0))))
    (etaf-reader-open-book session row)))

;;;###autoload
(defun etaf-reader-open (&optional file)
  "Open the local ebook reader and return its buffer.
FILE, when a path, is imported and opened right away; when a session from
`etaf-reader-create', that session is mounted as it is, which lets scripts
and tests display the exact state they built."
  (interactive)
  (let* ((provided (and (listp file) (plist-get file :view)))
         (session (if provided file (etaf-reader-create)))
         (buffer (etaf-reader--display session)))
    (cond
     (provided nil)
     ((and (stringp file) (file-readable-p file))
      (etaf-reader--call-in session
                            (lambda () (etaf-reader--open-path session file))))
     ((and (null (etaf-reader--read session :books))
           (seq-some #'file-directory-p etaf-reader-library-directories))
      (etaf-reader--call-in session
                            (lambda () (etaf-reader-refresh-library session)))))
    buffer))

;;;###autoload
(defun etaf-reader-open-file (file)
  "Open FILE (an ebook) in a new reader."
  (interactive "fEbook file: ")
  (etaf-reader-open file))

(defun etaf-reader--call-in (session function)
  "Run FUNCTION for SESSION reporting errors in the status line."
  (condition-case error
      (funcall function)
    (etaf-reader-error
     (etaf-reader-message session (error-message-string error)))
    (error
     (etaf-reader-message session (format "出错：%s" error)))))

;;;###autoload
(defun etaf-reader-close ()
  "Save the reading position and close the reader."
  (interactive)
  (let* ((session (etaf-reader--current))
         (buffer (current-buffer)))
    (etaf-reader-save-quiet session)
    (when-let* ((runtime (etaf-runtime-for-buffer buffer)))
      (etaf-unmount runtime))
    (plist-put session :buffer nil)
    (kill-buffer buffer)))

(provide 'etaf-reader-app)
;;; etaf-reader-app.el ends here
