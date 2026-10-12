;;; etaf-reader-views.el --- ETAF Views of etaf-reader -*- lexical-binding: t; -*-

;; Copyright (C) 2026 ETAF contributors
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; Pure renderers: every function takes plain data read from the session's
;; refs and returns a View tree, so a ref write repaints the mounted reader.
;; Reading lines are laid out by the model; this layer splits a line into
;; styled segments (annotation fill, underline, wavy, selection, caret) and
;; paints them with the session's palette.
;;
;; The selection toolbar is an `etaf-popover' anchored to the line node the
;; selection starts on, which is the WeChat Reading interaction adapted to a
;; keyboard text application: drag or `v' selects, the toolbar floats above or
;; below the line.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'etaf)
(require 'etaf-ui)
(require 'etaf-reader-theme)
(require 'etaf-reader-model)
(require 'etaf-reader-navigation)

(declare-function etaf-reader-search-command "etaf-reader-app")
(declare-function etaf-reader--direction "etaf-reader-app" (direction))

(defun etaf-reader--color-key (color)
  "Return COLOR (a string like \"red\") as a palette keyword."
  (intern (format ":%s" color)))

(defun etaf-reader--fill-key (color)
  "Return the soft fill keyword of annotation COLOR."
  (intern (format ":%s-soft" color)))

;;; ---------------------------------------------------------------------------
;;; Line segments
;;; ---------------------------------------------------------------------------

(defun etaf-reader--segment-style (styles from to)
  "Return the run styles covering STYLES interval FROM..TO."
  (let ((result ""))
    (dolist (style styles)
      (when (and (< (or (nth 0 style) 0) to) (> (or (nth 1 style) 0) from))
        (setq result (concat result " " (or (nth 2 style) "")))))
    (string-trim result)))

(defun etaf-reader--line-segments (session line _theme)
  "Return the render segments of LINE in SESSION."
  (let* ((text (or (plist-get line :text) ""))
         (length (length text))
         (start (or (plist-get line :start) 0))
         (end (or (plist-get line :end) 0))
         (shift (- length (max 0 (- end start))))
         (selection (etaf-reader-selection session))
         (cursor (etaf-reader--read session :cursor))
         (annotations (etaf-reader--read session :annotations))
         (styles (plist-get line :styles))
         (boundaries (list 0 length))
         (spans nil))
    (cl-labels ((add (from to &rest props)
                  (when (< from to)
                    (push from boundaries)
                    (push to boundaries)
                    (push (append (list :from from :to to) props) spans))))
      (dolist (style styles)
        (push (max 0 (min length (nth 0 style))) boundaries)
        (push (max 0 (min length (nth 1 style))) boundaries))
      (dolist (annotation annotations)
        (let* ((a-start (max start (or (plist-get annotation :start) 0)))
               (a-end (min end (or (plist-get annotation :end) 0))))
          (when (< a-start a-end)
            (add (+ shift (- a-start start)) (+ shift (- a-end start))
                 :annotation annotation))))
      (when selection
        (let* ((s-start (max start (car selection)))
               (s-end (min end (cdr selection))))
          (when (< s-start s-end)
            (add (+ shift (- s-start start)) (+ shift (- s-end start))
                 :selection t))))
      (when (and cursor (equal (plist-get cursor :line) (plist-get line :key)))
        (let ((position (max 0 (min (1- (max 1 length))
                                    (or (plist-get cursor :char) 0)))))
          (add position (min length (1+ position)) :caret t)))
      (let* ((sorted (sort (delete-dups (copy-sequence boundaries)) #'<))
             (segments nil)
             (items sorted))
        (while (cdr items)
          (let* ((from (car items))
                 (to (cadr items))
                 (middle (/ (+ from to) 2.0))
                 (covering (cl-remove-if-not
                            (lambda (span)
                              (and (<= (plist-get span :from) middle)
                                   (< middle (plist-get span :to)))) spans))
                 (annotation (seq-some (lambda (span) (plist-get span :annotation))
                                       covering))
                 (kind (and annotation (or (plist-get annotation :kind) "highlight")))
                 (color (and annotation (or (plist-get annotation :color) "yellow")))
                 (style (etaf-reader--segment-style styles from to))
                 (caret (seq-some (lambda (span) (plist-get span :caret)) covering))
                 (selection-p (seq-some (lambda (span) (plist-get span :selection))
                                        covering))
                 (fill (cond (caret :accent)
                             (selection-p :sel)
                             ((equal kind "highlight")
                              (etaf-reader--fill-key color))))
                 (decoration (cond ((equal kind "underline") (etaf-reader--color-key color))
                                   ((equal kind "wavy") (etaf-reader--color-key color))
                                   ((equal kind "note") :accent)))
                 (decoration-style (cond ((equal kind "wavy") 'wavy)
                                         ((equal kind "note") 'dotted)))
                 (segment (list :text (substring text from to)
                                :bold (string-match-p "bold" style)
                                :italic (string-match-p "italic" style)
                                :fill fill
                                :decoration decoration
                                :decoration-style decoration-style
                                :color (when (eq (plist-get line :kind) 'quote)
                                         :quote)
                                :annotation annotation)))
            (push segment segments)
            (setq items (cdr items))))
        (etaf-reader--merge-segments (nreverse segments))))))

(defun etaf-reader--merge-segments (segments)
  "Merge adjacent SEGMENTS with identical rendering."
  (let ((result nil))
    (dolist (segment segments)
      (let ((previous (car result)))
        (if (and previous
                 (equal (plist-get previous :fill) (plist-get segment :fill))
                 (equal (plist-get previous :decoration) (plist-get segment :decoration))
                 (equal (plist-get previous :decoration-style)
                        (plist-get segment :decoration-style))
                 (equal (plist-get previous :bold) (plist-get segment :bold))
                 (equal (plist-get previous :italic) (plist-get segment :italic))
                 (equal (plist-get previous :color) (plist-get segment :color))
                 (equal (plist-get previous :annotation) (plist-get segment :annotation)))
            (plist-put previous :text
                       (concat (plist-get previous :text) (plist-get segment :text)))
          (push segment result))))
    (nreverse result)))

(defun etaf-reader--line-content (session line theme)
  "Return LINE's styled text and source coordinates for SESSION.
Caller-owned string properties travel through ETAF's public text boundary;
no buffer writes or separate paint layer are involved.  One nonempty Text
Host per slot also keeps blank and final-page slots addressable."
  (let ((kind (plist-get line :kind)) pieces)
    (dolist (segment (etaf-reader--line-segments session line theme))
      (let ((text (copy-sequence (plist-get segment :text))) face)
        (when (or (eq kind 'heading) (plist-get segment :bold))
          (setq face (plist-put face :weight 'bold)))
        (when (plist-get segment :italic)
          (setq face (plist-put face :slant 'italic)))
        (when-let* ((fill (plist-get segment :fill)))
          (setq face (plist-put face :background (etaf-reader-color fill theme))))
        (when-let* ((color (or (plist-get segment :color)
                              (and (eq kind 'hr) :dim))))
          (setq face (plist-put face :foreground (etaf-reader-color color theme))))
        (when-let* ((decoration (plist-get segment :decoration)))
          (setq face
                (plist-put face :underline
                           (list :color (etaf-reader-color decoration theme)
                                 :style (pcase (plist-get segment :decoration-style)
                                          ('wavy 'wave) ('dotted 'dots) (_ 'line))))))
        (when face (put-text-property 0 (length text) 'face face text))
        (when-let* ((annotation (plist-get segment :annotation)))
          (add-text-properties 0 (length text)
                               (list 'reader-annotation (plist-get annotation :id)
                                     'help-echo "点击查看或编辑标注") text))
        (push text pieces)))
    (let ((text (apply #'concat (nreverse pieces))))
      (when (string-empty-p text) (setq text " "))
      (when (plist-get line :key)
        (put-text-property 0 (length text) 'reader-line (plist-get line :key) text))
      text)))

(defun etaf-reader--view-line (session line theme)
  "Return one fixed, retained line slot for LINE."
  (let* ((slot (or (plist-get line :slot) 0))
         (id (format "reader-text-%d" slot)))
    (etaf-node
     'box
     (list :key slot :id (format "reader-line-%d" slot)
           :width 'stretch :height '(lh 1) :overflow 'hidden :wrap-mode 'none)
     (list (etaf-node 'text (list :ref (intern id) :id id)
                      (list (etaf-reader--line-content session line theme)))))))

;;; ---------------------------------------------------------------------------
;;; Selection toolbar
;;; ---------------------------------------------------------------------------

(defun etaf-reader--toolbar-line (session)
  "Return the toolbar's line index, or nil."
  (let ((toolbar (etaf-reader--read session :toolbar)))
    (and toolbar (plist-get toolbar :line))))

(defun etaf-reader--toolbar-button (label color help on-press)
  "Return one ghost button of the annotation toolbar."
  (etaf-view
   (etaf-button :label label :variant 'ghost :pointer 'hand
                :color color :help-echo help :on-press on-press)))

(defun etaf-reader--view-toolbar (session)
  "Return the selection toolbar popover, or nil."
  (let* ((toolbar (etaf-reader--read session :toolbar))
         (theme (etaf-reader--read session :theme)))
    (when toolbar
      (let* ((line (plist-get toolbar :line))
             (top (etaf-reader--read session :line))
             (metrics (etaf-reader--read session :metrics))
             (rows (max 1 (or (plist-get metrics :rows) 20)))
             (page-size (* rows (or (plist-get metrics :spread) 1)))
             (annotation (plist-get toolbar :annotation))
             (closing (lambda () (etaf-reader--write session :toolbar nil)))
             (mark
              (lambda (kind color)
                (etaf-reader-guard
                 session
                 (lambda ()
                   (if annotation
                       (etaf-reader-mark-annotation session (plist-get annotation :id)
                                                    kind color)
                     (etaf-reader-annotate session kind color))
                   (funcall closing)))))
             (choose-color
              (lambda (color)
                (funcall mark (if annotation
                                  (or (plist-get annotation :kind) "highlight")
                                "highlight")
                         color)))
             (copy
              (lambda ()
                (etaf-reader-guard
                 session
                 (lambda ()
                   (kill-new (if annotation
                                 (or (plist-get annotation :quote) "")
                               (etaf-reader-selection-text session)))
                   (etaf-reader-message session "已复制")
                   (funcall closing)))))
             (search
              (lambda ()
                (etaf-reader-guard
                 session
                 (lambda ()
                   (let ((query (if annotation
                                    (or (plist-get annotation :quote) "")
                                  (etaf-reader-selection-text session))))
                     (when (and query (not (string-empty-p query)))
                       (funcall closing)
                       (etaf-reader-search-book
                        session (substring query 0 (min 40 (length query))))))))))
             (note
              (lambda ()
                (etaf-reader-write-note session
                                        (and annotation (plist-get annotation :id)))))
             (remove
              (lambda ()
                (etaf-reader-guard
                 session
                 (lambda ()
                   (etaf-reader-annotation-delete session (plist-get annotation :id)))))))
        (when (and (>= line top) (< (- line top) page-size))
          (etaf-view
           (etaf-popover
               :open t
               :anchor (format "reader-line-%d" (- line top))
               :placement (if (< (% (- line top) rows) (/ rows 2)) 'bottom-start 'top-start)
               :width '(ch 46)
               :on-close closing
             (column :width 'stretch :item-gap '(lh 0) :padding '((lh 0) (ch 1))
               (flex :width 'stretch :align-items 'center :height '(lh 2)
                 (expr (mapcar
                        (lambda (color)
                          (etaf-reader--toolbar-button
                           "●"
                           (etaf-reader-color (etaf-reader--color-key color) theme)
                           (format "用 %s 色标注" color)
                           (lambda () (funcall choose-color color))))
                        (etaf-reader-annotation-color-keys))))
               (flex :width 'stretch :gap '((lh 0) (ch 1)) :align-items 'center
                     :height '(lh 2)
                 (expr (etaf-reader--toolbar-button
                        "高亮" (etaf-reader-color :ink theme) "高亮显示"
                        (lambda ()
                          (funcall mark "highlight"
                                   (or (and annotation (plist-get annotation :color))
                                       "yellow")))))
                 (expr (etaf-reader--toolbar-button
                        "直线" (etaf-reader-color :ink theme) "直线下划线"
                        (lambda ()
                          (funcall mark "underline"
                                   (or (and annotation (plist-get annotation :color))
                                       "blue")))))
                 (expr (etaf-reader--toolbar-button
                        "波浪" (etaf-reader-color :ink theme) "波浪下划线"
                        (lambda ()
                          (funcall mark "wavy"
                                   (or (and annotation (plist-get annotation :color))
                                       "red"))))))
               (flex :width 'stretch :gap '((lh 0) (ch 1)) :align-items 'center
                     :height '(lh 2)
                 (expr (etaf-reader--toolbar-button
                        "复制" (etaf-reader-color :ink theme) "复制选中文字" copy))
                 (expr (etaf-reader--toolbar-button
                        "写想法" (etaf-reader-color :ink theme) "为这段写想法" note))
                 (expr (etaf-reader--toolbar-button
                        "搜索" (etaf-reader-color :ink theme) "在本书中搜索" search))
                 (expr (etaf-reader--toolbar-button
                        "删除" (etaf-reader-color :red theme) "删除这条标注" remove)))))))))))

;;; ---------------------------------------------------------------------------
;;; Reader
;;; ---------------------------------------------------------------------------

(defun etaf-reader--column-slices (lines rows spread)
  "Divide LINES into SPREAD columns of ROWS lines each (column-major)."
  (cl-loop for column from 0 below (max 1 spread)
           for from = (* column (max 1 rows))
           for to = (min (length lines) (+ from (max 1 rows)))
           when (< from to)
           collect (seq-subseq lines from to)))

(defun etaf-reader--view-reader (session)
  "Return the reading View of SESSION."
  (let* ((theme (etaf-reader--read session :theme))
         (metrics (etaf-reader--read session :metrics))
         (layout (plist-get metrics :layout))
         (spread (or (plist-get metrics :spread) 1))
         (rows (max 1 (or (plist-get metrics :rows) 20)))
         (columns (max 16 (or (plist-get metrics :columns) 40)))
         (lines (etaf-reader--read session :lines))
         (total (length lines))
         (top (min (etaf-reader--read session :line) (max 0 total)))
         (page-size (* rows spread))
         ;; Slots give every rendered line a stable identity across page
         ;; turns, so Ebox reuses the nodes and only patches their text.
         (remaining (nthcdr top lines))
         (visible (cl-loop for slot below page-size
                           for line = (pop remaining)
                           collect (plist-put (copy-sequence line) :slot slot)))
         (slices (etaf-reader--column-slices visible rows spread))
         (chapter (etaf-reader--read session :chapter))
         (book (etaf-reader--read session :book))
         )
    (etaf-view
     (flex :flex-direction 'column :width 'stretch :height 'stretch
           :background-color (etaf-reader-color :panel theme)
           :color (etaf-reader-color :ink theme) :gap '((lh 0) (ch 0))
       ;; Running head
       (flex :width 'stretch :height '(lh 3) :flex-shrink 0
             :padding '((lh 0) (ch 2)) :background-color (etaf-reader-color :panel theme)
             :align-items 'center :gap '((lh 0) (ch 1))
         (etaf-button :label "书库" :variant 'ghost
                      :on-press (lambda () (etaf-reader-show-shelf session)))
         (column :flex-grow 1 :flex-basis '(ch 0) :min-width '(ch 0)
                 :item-gap '(lh 0)
           (box :height '(lh 1) :overflow 'hidden :font-weight 'bold
             (text (expr (or (plist-get book :title) ""))))
           (box :height '(lh 1) :overflow 'hidden :color (etaf-reader-color :muted theme)
             (text (expr (format "%s · 第 %d/%d 章"
                                 (or (plist-get chapter :title) "")
                                 (1+ (or (plist-get chapter :index) 0))
                                 (length (etaf-reader--read session :chapters)))))))
         (etaf-button :label "目录" :variant 'ghost
                      :on-press (lambda () (etaf-reader-show-pane session 'toc)))
         (etaf-button :if (not (eq layout 'narrow)) :label "笔记" :variant 'ghost
                      :on-press (lambda () (etaf-reader-show-pane session 'notes)))
         (etaf-button :if (eq layout 'wide) :label "搜索" :variant 'ghost
                      :on-press
                      (lambda ()
                        (let ((query (etaf-call-with-input (lambda () (read-string "搜索全书：")))))
                          (unless (string-empty-p (string-trim query))
                            (etaf-reader--remember-position session)
                            (etaf-reader-search-book session (string-trim query))
                            (etaf-reader-show-pane session 'search)))))
         (etaf-menu :label "更多"
                    :items '((:key settings :label "阅读设置")
                             (:key notes :label "笔记与划线")
                             (:key bookmarks :label "书签列表")
                             (:key add-bookmark :label "收藏这一页")
                             (:key search :label "搜索结果")
                             (:key back :label "返回跳转前")
                             (:key help :label "快捷键"))
                    :on-select (lambda (key)
                                 (pcase key
                                   ('add-bookmark (etaf-reader-add-bookmark session))
                                   ('back (etaf-reader-jump-back session))
                                   (_ (etaf-reader-show-pane session key))))))
       ;; Body
       (flex :ref 'reader-body :id "reader-body"
             :width 'stretch :flex-grow 1 :flex-basis '(lh 0)
             :min-height '(lh 0) :align-items 'stretch
             :on-direction #'etaf-reader--direction
             :pointer 'text :on-drag (plist-get session :drag-handler)
             :gap (list '(lh 0) (list 'ch 2))
         (box :flex-grow 1 :flex-basis '(ch 0) :min-width '(ch 0))
         (column :for (slice slices) :key (plist-get (car slice) :slot)
                 ;; One cell of slack absorbs sub-cell rounding.
                 :width (list 'ch (+ columns 5)) :flex-shrink 0
                 :background-color (etaf-reader-color :bg theme)
                 :item-gap '(lh 0) :padding '((lh 1) (ch 2))
           (expr
            (if (etaf-reader--read session :toolbar)
                ;; Line anchors exist only while the nearby toolbar needs one.
                (mapcar (lambda (line)
                          (etaf-reader--view-line session line theme)) slice)
              (let ((id (format "reader-column-%d"
                                (/ (plist-get (car slice) :slot) rows))))
                (etaf-node
                 'box (list :width 'stretch :height (list 'lh rows)
                            :overflow 'hidden :wrap-mode 'none)
                 (list (etaf-node
                        'text (list :ref (intern id) :id id)
                        (list (mapconcat
                               (lambda (line)
                                 (etaf-reader--line-content session line theme))
                               slice "\n")))))))))
         (box :flex-grow 1 :flex-basis '(ch 0) :min-width '(ch 0)))
       ;; Status line
       (flex :width 'stretch :height '(lh 2) :flex-shrink 0
             :padding '((lh 0) (ch 2))
             :align-items 'center :gap '((lh 0) (ch 2))
             :border-top (list '(px 1) 'solid (etaf-reader-color :line theme))
         (box :height '(lh 1) :flex-shrink 0 :color (etaf-reader-color :muted theme)
           (text :ref 'reader-page :id "reader-page"
                 (expr (concat (etaf-reader--page-label session) " · "
                               (etaf-reader-percent-text session)))))
         (box :flex-grow 1 :flex-basis '(ch 0) :min-width '(ch 0) :height '(lh 1)
              :overflow 'hidden :text-align 'center
              :color (etaf-reader-color :dim theme)
           (text (expr (or (etaf-reader--read session :message)
                           (if (eq layout 'wide)
                               "空格 翻页 · v 选择 · s 搜索 · c 目录 · a 笔记 · o 设置"
                             "空格 翻页 · o 设置"))))))))))

;;; ---------------------------------------------------------------------------
;;; Shelf
;;; ---------------------------------------------------------------------------

(defun etaf-reader--book-percent (session book)
  "Return BOOK's progress percent from SESSION's cached states."
  (or (plist-get (etaf-reader-book-state session (plist-get book :id)) :percent)
      0))

(defun etaf-reader--book-row (session book theme)
  "Return the shelf row View of BOOK."
  (let ((percent (etaf-reader--book-percent session book)))
    (etaf-view
     (etaf-button :key (plist-get book :id) :width 'stretch
                  :variant 'ghost :padding '((lh 0) (ch 1))
                  :label (or (plist-get book :title) "打开书籍")
                  :help-echo "打开这本书并继续上次阅读"
                  :on-press (lambda ()
                              (etaf-reader-guard session
                                                 (lambda ()
                                                   (etaf-reader-open-book session book))))
      (flex :width 'stretch :height '(lh 5)
            :align-items 'center :gap '((lh 0) (ch 2))
       (box :width '(ch 8) :height '(lh 4) :text-align 'center
            :bgcolor (etaf-reader-color :cover theme)
            :color (etaf-reader-color :accent theme)
         (expr
          (if (string-empty-p (or (plist-get book :cover) ""))
              (etaf-view (etaf-avatar :name (or (plist-get book :title) "书") :variant 'neutral))
            (etaf-node 'image
                       (list :src (expand-file-name
                                   (plist-get book :cover)
                                   (etaf-reader--cache-book-directory (plist-get book :id)))
                             :columns 8 :rows 4) nil))))
       (column :flex-grow 1 :flex-basis '(ch 0) :min-width '(ch 0) :item-gap '(lh 0)
         (box :height '(lh 1) :overflow 'hidden :font-weight 'bold
           (text (expr (or (plist-get book :title) "未命名"))))
         (box :height '(lh 1) :overflow 'hidden
              :color (etaf-reader-color :muted theme)
           (text (expr (string-join
                        (delq nil
                              (list (or (plist-get book :author) "")
                                    (upcase (or (plist-get book :format) ""))
                                    (and (> (or (plist-get book :pages) 0) 0)
                                         (format "%d 页" (plist-get book :pages)))
                                    (and (> (or (plist-get book :chapters) 0) 0)
                                         (format "%d 章" (plist-get book :chapters)))))
                        " · "))))
         (box :height '(lh 1) :overflow 'hidden
              :color (etaf-reader-color :dim theme)
           (text (expr (let ((state (etaf-reader-book-state session (plist-get book :id))))
                         (if (and state (> (or (plist-get state :last_read) 0) 0))
                             (format "已读 %.1f%% · %s"
                                     percent
                                     (format-time-string
                                      "%m-%d %H:%M"
                                      (seconds-to-time (plist-get state :last_read))))
                           (format "未读 · %.1f%%" percent))))))))))))

(defun etaf-reader--view-shelf (session)
  "Return the paged, searchable shelf of SESSION."
  (let* ((theme (etaf-reader--read session :theme))
         (page (etaf-reader-library-page session))
         (books (plist-get page :items))
         (filter (etaf-reader--read session :filter))
         (query (etaf-reader--read session :shelf-query)))
    (etaf-view
     (flex :flex-direction 'column :width 'stretch :height 'stretch
           :background-color (etaf-reader-color :bg theme)
           :color (etaf-reader-color :ink theme)
           :padding '((lh 1) (ch 3)) :gap '((lh 0) (ch 0))
       (flex :width 'stretch :height '(lh 3) :flex-shrink 0
             :align-items 'center :gap '((lh 0) (ch 1))
         (text :font-weight 'bold "本地书库")
         (box :flex-grow 1 :flex-basis '(ch 0) :min-width '(ch 0))
         (etaf-button :label "搜索" :variant 'ghost
                      :on-press
                      (lambda ()
                        (etaf-reader-filter-library
                         session (etaf-call-with-input
                                  (lambda () (read-string "书名或作者：" query))))))
         (etaf-menu :label "排序"
                    :items '((:key recent :label "最近阅读")
                             (:key title :label "书名") (:key author :label "作者"))
                    :on-select (lambda (key)
                                 (etaf-reader-filter-library session query nil key)))
         (etaf-button :label "扫描" :variant 'ghost
                      :on-press (lambda () (etaf-reader-refresh-library session)))
         (etaf-button :label "设置" :variant 'ghost
                      :on-press (lambda () (etaf-reader-show-pane session 'settings))))
       (box :height '(lh 2) :flex-shrink 0
         (etaf-tabs :items '((:key all :label "全部") (:key reading :label "在读")
                             (:key unread :label "未读") (:key finished :label "已读"))
                    :active filter
                    :on-change (lambda (key)
                                 (etaf-reader-filter-library session query key))))
       (column :width 'stretch :flex-grow 1 :flex-basis '(lh 0)
               :min-height '(lh 0) :overflow 'hidden :item-gap '(lh 0)
         (etaf-empty :if (null books)
                     :title (if (string-empty-p query) "书架是空的" "没有找到这本书")
                     :description "把电子书放进 ~/ebooks 后扫描，或换个书名、作者试试")
         (expr (mapcar (lambda (book) (etaf-reader--book-row session book theme)) books)))
       (flex :width 'stretch :height '(lh 3) :flex-shrink 0
             :align-items 'center :gap '((lh 0) (ch 1))
         (etaf-button :label "上一页" :variant 'ghost
                      :disabled (= (plist-get page :index) 0)
                      :on-press (lambda () (etaf-reader-page-library session -1)))
         (text (expr (format "%d / %d · %d 本"
                             (1+ (plist-get page :index)) (plist-get page :pages)
                             (plist-get page :total))))
         (etaf-button :label "下一页" :variant 'ghost
                      :disabled (= (1+ (plist-get page :index)) (plist-get page :pages))
                      :on-press (lambda () (etaf-reader-page-library session 1)))
         (etaf-button :if (not (string-empty-p query)) :label "清除搜索" :variant 'ghost
                      :on-press (lambda () (etaf-reader-filter-library session ""))))))))

;;; ---------------------------------------------------------------------------
;;; Panes (contents / notes / help)
;;; ---------------------------------------------------------------------------

(defun etaf-reader--view-settings (session)
  "Return catalog controls for SESSION's persisted reading preferences."
  (etaf-view
   (column :width 'stretch :item-gap '(lh 1)
     (etaf-select :label "外观" :presentation 'chips
                  :value (etaf-reader--read session :theme)
                  :options '((dark . "夜间") (light . "明亮") (sepia . "纸色"))
                  :on-change (lambda (value) (etaf-reader-configure session :theme value)))
     (etaf-select :label "阅读" :presentation 'chips
                  :value (etaf-reader--read session :mode)
                  :options '((page . "翻页") (scroll . "滚动"))
                  :on-change (lambda (value) (etaf-reader-configure session :mode value)))
     (etaf-select :label "段落" :presentation 'chips
                  :value (etaf-reader--read session :density)
                  :options '((comfortable . "舒适") (compact . "紧凑"))
                  :on-change (lambda (value) (etaf-reader-configure session :density value)))
     (etaf-menu :label "阅读栏宽"
                :items '((:key auto :label "自适应窗口") (:key 32 :label "窄栏")
                         (:key 40 :label "标准") (:key 48 :label "宽栏"))
                :on-select (lambda (value) (etaf-reader-configure session :columns value)))
     (text "设置会自动保存；调整窗口后继续原来的阅读位置。"))))

(defun etaf-reader--view-pane (session)
  "Return a bounded, navigable dialog for SESSION's current pane."
  (let* ((pane (etaf-reader--read session :pane))
         (metrics (etaf-reader--read session :metrics))
         (width (if (eq (plist-get metrics :layout) 'narrow)
                    (max 28 (+ 2 (plist-get metrics :columns))) 60))
         (close (lambda () (etaf-reader--write session :pane nil))))
    (when pane
      (pcase pane
        ('settings
         (etaf-view
          (etaf-dialog :open t :title "阅读设置" :width (list 'ch width)
                       :close-label "关闭" :compact t :on-close close
            (expr (etaf-reader--view-settings session)))))
        ('help
         (etaf-view
          (etaf-dialog :open t :title "快捷键" :width (list 'ch width)
                       :close-label "关闭" :on-close close
            (column :width 'stretch :item-gap '(lh 0)
              (text "空格 / 退格     下一页 / 上一页")
              (text "方向键 / H L    逐行 / 换章")
              (text "v + 方向键 + 回车 选择并标注（C-c C-k 取消）")
              (text "s / n N / S     搜索 / 跳转 / 结果列表")
              (text "c / a / B       目录 / 笔记 / 书签")
              (text "b / u           加书签 / 返回跳转前")
              (text "o / t / z       设置 / 主题 / 阅读模式")
              (text "[ ] / g         栏宽 / 跳到百分比")
              (text "f / i / E / C-c h 书库 / 扫描 / 导出笔记 / 帮助")
              (text "Esc / q         关闭面板 / 退出阅读器")))))
        (_
         (let* ((items (etaf-reader--pane-items session))
                (size (etaf-reader--pane-page-size session))
                (pages (max 1 (ceiling (length items) size)))
                (page (min (1- pages) (etaf-reader--read session :pane-page)))
                (visible (seq-subseq items (* page size)
                                    (min (length items) (* (1+ page) size)))))
           (etaf-view
            (etaf-dialog :open t :width (list 'ch width)
                         :height (list 'lh (+ 8 (* size 3)
                                             (if (memq pane '(notes bookmarks)) 3 0)))
                         :close-label "关闭" :compact t :on-close close
                         :title (pcase pane ('toc "目录") ('notes "笔记与划线")
                                       ('bookmarks "书签") (_ "搜索结果"))
              (column :width 'stretch :item-gap '(lh 1)
                (etaf-empty :if (null items) :title "这里还没有内容"
                            :description "阅读时可以添加书签、划线，或搜索全书。")
                (etaf-list :items visible
                           :on-select (lambda (key)
                                        (etaf-reader--choose-pane-item session key)))
                (etaf-button :if (eq pane 'notes) :label "导出 Markdown" :variant 'ghost
                             :on-press
                             (lambda ()
                               (let ((file (etaf-call-with-input
                                            (lambda ()
                                              (read-file-name "导出笔记到：" nil nil nil "阅读笔记.md")))))
                                 (etaf-reader-export-notes session file))))
                (etaf-menu :if (eq pane 'bookmarks) :label "删除书签"
                           :items (cl-loop for row in (etaf-reader--read session :bookmarks)
                                           for index from 1
                                           collect (list :key (plist-get row :id)
                                                         :label (format "%d. %s" index
                                                                        (truncate-string-to-width
                                                                         (or (plist-get row :label) "") 36 nil nil "…"))))
                           :on-select
                           (lambda (id)
                             (etaf-reader-store-delete-bookmark id)
                             (etaf-reader--write session :bookmarks
                                                 (etaf-reader-store-bookmarks
                                                  (plist-get (etaf-reader--read session :book) :id)))))
                (flex :width 'stretch :gap '((lh 0) (ch 1)) :align-items 'center
                  (etaf-button :label "上一页" :variant 'ghost :disabled (= page 0)
                               :on-press (lambda () (etaf-reader--step-pane session -1)))
                  (text (expr (format "%d / %d · %d 项" (1+ page) pages (length items))))
                  (etaf-button :label "下一页" :variant 'ghost :disabled (= (1+ page) pages)
                               :on-press (lambda () (etaf-reader--step-pane session 1)))))))))))))

;;; ---------------------------------------------------------------------------
;;; Whole application
;;; ---------------------------------------------------------------------------

(defun etaf-reader-view (session)
  "Return the View of SESSION."
  ;; Track the repaint trigger: commands that cannot use the retained fast
  ;; path bump it to force an ordinary publication.
  (etaf-reader--read session :revision)
  (let ((view (etaf-reader--read session :view)))
    (etaf-node
     'box
     (list :width 'stretch :height 'stretch :overflow 'hidden
           :background-color (etaf-reader-color :bg (etaf-reader--read session :theme)))
     (delq nil
           (if (eq view 'reader)
               (list (etaf-reader--view-reader session)
                     (etaf-reader--view-toolbar session)
                     (etaf-reader--view-pane session))
             (list (etaf-reader--view-shelf session)
                   (etaf-reader--view-pane session)))))))

(provide 'etaf-reader-views)
;;; etaf-reader-views.el ends here
