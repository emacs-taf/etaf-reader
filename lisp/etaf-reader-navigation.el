;;; etaf-reader-navigation.el --- Library and reading navigation -*- lexical-binding: t; -*-

;;; Commentary:
;; User-facing library queries, bounded navigation lists, reading preferences
;; and return-to-position history. Views consume cached session values only.

;;; Code:
(require 'etaf-reader-model)

(defun etaf-reader--preference-values (session)
  "Return SESSION's serializable reading preferences."
  (let ((metrics (etaf-reader--read session :metrics)))
    (list :theme (symbol-name (etaf-reader--read session :theme))
          :mode (symbol-name (etaf-reader--read session :mode))
          :density (symbol-name (etaf-reader--read session :density))
          :columns (if (plist-get metrics :manual)
                       (or (plist-get metrics :requested-columns)
                           (plist-get metrics :columns)) 0))))

(defun etaf-reader--apply-preferences (session options)
  "Apply validated OPTIONS to SESSION without storage access."
  (etaf-batch
    (dolist (key '(:theme :mode :density))
      (when (plist-member options key)
        (etaf-reader--write session key (plist-get options key))))
    (when (plist-member options :columns)
      (let ((metrics (copy-sequence (etaf-reader--read session :metrics)))
            (columns (plist-get options :columns)))
        (setq metrics (plist-put metrics :manual (not (eq columns 'auto))))
        (unless (eq columns 'auto)
          (setq metrics (plist-put metrics :columns columns))
          (setq metrics (plist-put metrics :requested-columns columns)))
        (etaf-reader--write session :metrics metrics)))
    (etaf-reader-sync-metrics session)
    (etaf-reader-reflow session)))

(defun etaf-reader-configure (session &rest options)
  "Set and persist reading OPTIONS for SESSION.
Accept :theme dark/light/sepia, :mode page/scroll, :density compact/comfortable,
and :columns auto or an integer from 24 through 72. Validate all options before
changing anything. Return the saved preference plist."
  (unless (and (proper-list-p options) (zerop (% (length options) 2)))
    (signal 'etaf-reader-error '("设置必须是成对的选项和值")))
  (cl-loop for (key value) on options by #'cddr
           unless (pcase key
                    (:theme (memq value '(dark light sepia)))
                    (:mode (memq value '(page scroll)))
                    (:density (memq value '(compact comfortable)))
                    (:columns (or (eq value 'auto)
                                  (and (integerp value) (<= 24 value 72)))))
           do (signal 'etaf-reader-error (list "无效阅读设置" key value)))
  (etaf-reader--apply-preferences session options)
  (let ((preferences (etaf-reader--preference-values session))
        (etaf-reader-store-file (plist-get session :store-file)))
    (etaf-reader-store-put-preferences preferences)
    preferences))

(defun etaf-reader--restore-preferences (session)
  "Restore saved preferences before mounting SESSION."
  (when-let* ((saved (etaf-reader-store-preferences)))
    (let (options)
      (dolist (key '(:theme :mode :density))
        (when-let* ((value (plist-get saved key)))
          (setq options (plist-put options key (intern value)))))
      (let ((columns (or (plist-get saved :columns) 0)))
        (setq options (plist-put options :columns (if (> columns 0) columns 'auto))))
      (etaf-reader--apply-preferences session options))))

(defun etaf-reader-filter-library (session query &optional filter sort)
  "Filter SESSION's library by QUERY and optional FILTER and SORT.
FILTER is all, reading, unread or finished. SORT is recent, title or author.
A changed query resets the displayed library page. Return matching books."
  (unless (and (stringp query) (memq filter '(nil all reading unread finished))
               (memq sort '(nil recent title author)))
    (signal 'etaf-reader-error '("无效书库筛选条件")))
  (etaf-batch
    (etaf-reader--write session :shelf-query (string-trim query))
    (when filter (etaf-reader--write session :filter filter))
    (when sort (etaf-reader--write session :shelf-sort sort))
    (etaf-reader--write session :shelf-page 0))
  (etaf-reader-books session))

(defun etaf-reader-library-page (session)
  "Return SESSION's library page as :items, :index, :pages and :total.
The zero-based page index is clamped to the current filtered result."
  (let* ((books (etaf-reader-books session))
         (size (max 1 (/ (- (or (plist-get (etaf-reader--read session :metrics) :rows) 20) 4) 5)))
         (pages (max 1 (ceiling (length books) size)))
         (page (min (1- pages) (max 0 (etaf-reader--read session :shelf-page)))))
    (list :items (seq-subseq books (* page size) (min (length books) (* (1+ page) size)))
          :index page :pages pages :total (length books))))

(defun etaf-reader-page-library (session delta)
  "Move SESSION's library by DELTA pages and return its resulting page."
  (let* ((page (etaf-reader-library-page session))
         (next (max 0 (min (1- (plist-get page :pages))
                           (+ (plist-get page :index) delta)))))
    (etaf-reader--write session :shelf-page next)
    (etaf-reader-library-page session)))

(defun etaf-reader-show-pane (session pane)
  "Show PANE in SESSION, or close it when nil or already open.
PANE is toc, notes, bookmarks, search, settings or help. Data is loaded before
publication; long lists are paged rather than clipped."
  (unless (memq pane '(nil toc notes bookmarks search settings help))
    (signal 'etaf-reader-error '("未知阅读面板")))
  (when (and (memq pane '(toc notes bookmarks search))
             (null (etaf-reader--read session :book)))
    (signal 'etaf-reader-error '("请先打开一本书")))
  (let ((etaf-reader-store-file (plist-get session :store-file)))
   (etaf-batch
    (pcase pane
      ('notes
       (etaf-reader--write session :book-notes
                           (etaf-reader-store-annotations
                            (plist-get (etaf-reader--read session :book) :id))))
      ('bookmarks
       (etaf-reader--write session :bookmarks
                           (etaf-reader-store-bookmarks
                            (plist-get (etaf-reader--read session :book) :id)))))
    (etaf-reader--write session :pane-page
                        (if (eq pane 'toc)
                            (/ (or (plist-get (etaf-reader--read session :chapter) :index) 0)
                               (etaf-reader--pane-page-size session)) 0))
    (etaf-reader--write session :pane
                        (unless (eq pane (etaf-reader--read session :pane)) pane)))))

(defun etaf-reader--remember-position (session)
  "Push SESSION's current reading position onto bounded navigation history."
  (when (etaf-reader--read session :chapter)
    (let* ((line (nth (etaf-reader--read session :line) (etaf-reader-lines session)))
           (location (cons (plist-get (etaf-reader--read session :chapter) :index)
                           (or (plist-get line :start) 0)))
           (history (plist-get session :history)))
      (unless (equal location (car history))
        (plist-put session :history (seq-take (cons location history) 100))))))

(defun etaf-reader-jump (session chapter offset)
  "Open CHAPTER at OFFSET and remember the previous position in SESSION."
  (etaf-reader--remember-position session)
  (etaf-batch
    (etaf-reader-open-chapter session chapter offset)
    (etaf-reader--write session :pane nil)))

(defun etaf-reader-jump-back (session)
  "Return SESSION to its position before the last navigation jump."
  (if-let* ((history (plist-get session :history)))
      (progn
        (plist-put session :history (cdr history))
        (etaf-batch
          (etaf-reader-open-chapter session (caar history) (cdar history))
          (etaf-reader--write session :pane nil)))
    (etaf-reader-message session "没有更早的跳转位置")))

(defun etaf-reader--pane-items (session)
  "Return the current navigation list as catalog List items."
  (pcase (etaf-reader--read session :pane)
    ('toc
     (mapcar (lambda (chapter)
               (list :key (plist-get chapter :idx)
                     :title (or (plist-get chapter :title) "未命名章节")
                     :description (format "第 %d 章" (1+ (plist-get chapter :idx)))))
             (etaf-reader--read session :chapters)))
    ('notes
     (mapcar (lambda (note)
               (list :key (plist-get note :id)
                     :title (truncate-string-to-width (or (plist-get note :quote) "") 44 nil nil "…")
                     :description (if (string-empty-p (or (plist-get note :note) ""))
                                      (format "第 %d 章 · %s" (1+ (plist-get note :chapter))
                                              (pcase (plist-get note :kind)
                                                ("wavy" "波浪线") ("underline" "下划线") (_ "划线")))
                                    (truncate-string-to-width (plist-get note :note) 44 nil nil "…"))))
             (etaf-reader--read session :book-notes)))
    ('bookmarks
     (mapcar (lambda (row)
               (list :key (plist-get row :id)
                     :title (format "第 %d 章" (1+ (plist-get row :chapter)))
                     :description (truncate-string-to-width (or (plist-get row :label) "") 44 nil nil "…")))
             (etaf-reader--read session :bookmarks)))
    ('search
     (cl-loop for match in (plist-get (etaf-reader--read session :search) :matches)
              for index from 0
              collect (list :key index
                            :title (format "第 %d 章 · 结果 %d" (1+ (plist-get match :chapter)) (1+ index))
                            :description (truncate-string-to-width (or (plist-get match :context) "") 44 nil nil "…"))))))

(defun etaf-reader--pane-page-size (session)
  "Return the bounded navigation list size for SESSION's viewport."
  (max 1 (min 4 (/ (max 0 (- (or (plist-get (etaf-reader--read session :metrics) :rows) 20) 8)) 3))))

(defun etaf-reader--step-pane (session delta)
  "Move the current navigation list by DELTA pages."
  (let* ((size (etaf-reader--pane-page-size session))
         (pages (max 1 (ceiling (length (etaf-reader--pane-items session)) size))))
    (etaf-reader--write session :pane-page
                        (max 0 (min (1- pages)
                                    (+ (etaf-reader--read session :pane-page) delta))))))

(defun etaf-reader--choose-pane-item (session key)
  "Activate navigation item KEY in SESSION."
  (pcase (etaf-reader--read session :pane)
    ('toc (etaf-reader-jump session key 0))
    ('notes
     (when-let* ((note (seq-find (lambda (row) (equal (plist-get row :id) key))
                                (etaf-reader--read session :book-notes))))
       (etaf-reader--remember-position session)
       (etaf-reader-goto-annotation session note)
       (etaf-reader-show-annotation-toolbar session key)))
    ('bookmarks
     (when-let* ((row (seq-find (lambda (item) (equal (plist-get item :id) key))
                               (etaf-reader--read session :bookmarks))))
       (etaf-reader-jump session (plist-get row :chapter) (plist-get row :offset))))
    ('search
     (etaf-reader--remember-position session)
     (etaf-batch
       (etaf-reader--write session :pane nil)
       (etaf-reader-goto-match session key)))))

(provide 'etaf-reader-navigation)
;;; etaf-reader-navigation.el ends here
