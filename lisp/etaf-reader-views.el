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

(defun etaf-reader--color-key (color)
  "Return COLOR (a string like \"red\") as a palette keyword."
  (intern (format ":%s" color)))

(defun etaf-reader--fill-key (color)
  "Return the soft fill keyword of annotation COLOR."
  (intern (format ":%s-soft" color)))

;;; ---------------------------------------------------------------------------
;;; Line segments
;;; ---------------------------------------------------------------------------

(defun etaf-reader--span-covering (spans position)
  "Return the span in SPANS covering POSITION, or nil."
  (cl-find-if (lambda (span)
                (and (<= (plist-get span :from) position)
                     (< position (plist-get span :to))))
              spans))

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
                 (span (etaf-reader--span-covering spans middle))
                 (annotation (plist-get span :annotation))
                 (kind (and annotation (or (plist-get annotation :kind) "highlight")))
                 (color (and annotation (or (plist-get annotation :color) "yellow")))
                 (style (etaf-reader--segment-style styles from to))
                 (caret (plist-get span :caret))
                 (selection-p (plist-get span :selection))
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
                 (equal (plist-get previous :bold) (plist-get segment :bold))
                 (equal (plist-get previous :italic) (plist-get segment :italic))
                 (equal (plist-get previous :color) (plist-get segment :color))
                 (equal (plist-get previous :annotation) (plist-get segment :annotation)))
            (plist-put previous :text
                       (concat (plist-get previous :text) (plist-get segment :text)))
          (push segment result))))
    (nreverse result)))

(defun etaf-reader--segment-node (session segment theme)
  "Return the text node of SEGMENT for SESSION."
  (let ((props nil)
        (annotation (plist-get segment :annotation)))
    (when-let* ((fill (plist-get segment :fill)))
      (setq props (plist-put props :background-color
                             (etaf-reader-color fill theme))))
    (when-let* ((color (plist-get segment :color)))
      (setq props (plist-put props :color (etaf-reader-color color theme))))
    (when (plist-get segment :bold)
      (setq props (plist-put props :font-weight 'bold)))
    (when (plist-get segment :italic)
      (setq props (plist-put props :font-style 'italic)))
    (when-let* ((decoration (plist-get segment :decoration)))
      (setq props (plist-put props :text-decoration-line '(underline)))
      (setq props (plist-put props :text-decoration-style
                             (or (plist-get segment :decoration-style) 'solid)))
      (setq props (plist-put props :text-decoration-color
                             (etaf-reader-color decoration theme))))
    (when annotation
      (setq props (plist-put props :help-echo "点击编辑标注"))
      (setq props (plist-put props :on-press
                             (lambda ()
                               (etaf-reader-show-annotation-toolbar
                                session (plist-get annotation :id))))))
    (etaf-node 'text props (list (plist-get segment :text)))))

(defun etaf-reader--view-line (session line theme)
  "Return the View of one wrapped LINE."
  (let* ((segments (etaf-reader--line-segments session line theme))
         (nodes (mapcar (lambda (segment)
                          (etaf-reader--segment-node session segment theme))
                        segments))
         (kind (plist-get line :kind)))
    (etaf-node
     'box
     (list :id (format "reader-line-%d" (or (plist-get line :key) 0))
           :width 'stretch
           :height '(lh 1)
           :overflow 'hidden
           :wrap-mode 'none
           :font-weight (if (eq kind 'heading) 'bold nil)
           :color (when (eq kind 'hr) :dim)
           :pointer 'text
           :on-drag (lambda (gesture)
                      (etaf-reader--drag session gesture)))
     (or nodes (list (etaf-node 'text nil (list "")))))))

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
        (when (and (>= line top) (< (- line top) rows))
          (etaf-view
           (etaf-popover
               :open t
               :anchor (format "reader-line-%d" line)
               :placement (if (< (- line top) (/ rows 2)) 'bottom-start 'top-start)
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
         (mode (etaf-reader--read session :mode))
         (lines (etaf-reader--read session :lines))
         (total (length lines))
         (top (min (etaf-reader--read session :line) (max 0 total)))
         (page-size (* rows spread))
         (visible (seq-subseq lines top (min total (+ top page-size))))
         (slices (etaf-reader--column-slices visible rows spread))
         (chapter (etaf-reader--read session :chapter))
         (book (etaf-reader--read session :book))
         (page (if (= page-size 0) 1 (1+ (/ top page-size))))
         (pages (max 1 (ceiling (/ (float total) page-size)))))
    (etaf-view
     (column :width 'stretch :height 'stretch
             :background-color (etaf-reader-color :bg theme)
             :item-gap '(lh 0)
       ;; Running head
       (flex :width 'stretch :height '(lh 2) :padding '((lh 0) (ch 2))
             :align-items 'center :gap '((lh 0) (ch 2))
         (box :flex-grow 1 :flex-basis 'auto :min-width '(ch 0) :height '(lh 1)
              :overflow 'hidden :font-weight 'bold
           (text (expr (format "%s" (or (plist-get book :title) "")))))
         (box :height '(lh 1) :color (etaf-reader-color :muted theme)
           (text (expr (format "第 %d/%d 章 · %s"
                               (1+ (or (plist-get chapter :index) 0))
                               (length (etaf-reader--read session :chapters))
                               (or (plist-get chapter :title) ""))))))
       ;; Body
       (flex :width 'stretch :height 'stretch :align-items 'stretch
             :gap (list '(lh 0) (list 'ch 2))
         (box :flex-grow 1 :flex-basis '(ch 0) :min-width '(ch 0))
         (column :for (slice slices) :key (plist-get (car slice) :key)
                 ;; One cell of slack absorbs sub-cell rounding.
                 :width (list 'ch (+ columns 1)) :flex-shrink 0
                 :item-gap '(lh 0) :padding '((lh 1) (ch 0))
           (box :for (line slice) :key (plist-get line :key)
                :width 'stretch :height '(lh 1) :overflow 'hidden
             (expr (etaf-reader--view-line session line theme))))
         (box :flex-grow 1 :flex-basis '(ch 0) :min-width '(ch 0)))
       ;; Status line
       (flex :width 'stretch :height '(lh 2) :padding '((lh 0) (ch 2))
             :align-items 'center :gap '((lh 0) (ch 2))
             :border-top (list '(px 1) 'solid (etaf-reader-color :line theme))
         (box :height '(lh 1) :color (etaf-reader-color :muted theme)
           (text (expr (if (eq mode 'page)
                           (format "第 %d/%d 页" page pages)
                         (format "第 %d/%d 行" (1+ top) total)))))
         (box :flex-grow 1 :flex-basis 'auto :min-width '(ch 0) :height '(lh 1)
              :overflow 'hidden :text-align 'center
              :color (etaf-reader-color :dim theme)
           (text (expr (or (etaf-reader--read session :message)
                           (if (eq layout 'wide)
                               "空格 翻页 · h/l 选字 · v 选择 · s 搜索 · c 目录 · a 笔记 · ? 帮助"
                             "空格翻页 · v 选择 · s 搜索 · c 目录 · ? 帮助")))))
         (box :height '(lh 1) :color (etaf-reader-color :accent theme)
           (text (expr (etaf-reader-percent-text session)))))))))

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
     (flex :key (plist-get book :id) :width 'stretch :height '(lh 4)
           :align-items 'center :gap '((lh 0) (ch 2))
           :padding '((lh 0) (ch 1))
           :role 'button :pointer 'hand
           :help-echo "打开这本书"
           :on-press (lambda ()
                       (etaf-reader-guard session
                                          (lambda ()
                                            (etaf-reader-open-book session book))))
       (box :width '(ch 6) :height '(lh 3) :text-align 'center
            :bgcolor (etaf-reader-color :cover theme)
            :color (etaf-reader-color :accent theme) :font-weight 'bold
         (text (expr (if (and (plist-get book :title)
                              (not (string-empty-p (plist-get book :title))))
                         (substring (plist-get book :title) 0 1)
                       "书"))))
       (column :flex-grow 1 :flex-basis 'auto :min-width '(ch 0) :item-gap '(lh 0)
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
                           (format "未读 · %.1f%%" percent)))))))))))

(defun etaf-reader--view-shelf (session)
  "Return the shelf View of SESSION."
  (let* ((theme (etaf-reader--read session :theme))
         (books (etaf-reader-books session))
         (filter (etaf-reader--read session :filter)))
    (etaf-view
     (column :width 'stretch :height 'stretch
             :background-color (etaf-reader-color :bg theme)
             :padding '((lh 1) (ch 3)) :item-gap '(lh 0)
       (flex :width 'stretch :height '(lh 2) :align-items 'center
             :gap '((lh 0) (ch 2))
         (box :height '(lh 1) :font-weight 'bold
           (text "本地书库"))
         (box :width '(ch 26)
           (etaf-tabs :items (list (list :key 'all :label "全部")
                                   (list :key 'reading :label "在读")
                                   (list :key 'unread :label "未读"))
                      :active filter
                      :on-change (lambda (key)
                                   (etaf-reader-set-filter session key))))
         (box :flex-grow 1 :flex-basis 'auto :min-width '(ch 0) :height '(lh 1)
              :overflow 'hidden :text-align 'right
              :color (etaf-reader-color :dim theme)
           (text (expr (format "%d 本 · i 扫描书库 · s 搜索 · ? 帮助"
                               (length books))))))
       (column :width 'stretch :height 'stretch :item-gap '(lh 0)
         (etaf-empty :if (null books)
                     :title "书架是空的"
                     :description "把电子书放进 ~/ebooks，按 i 扫描导入")
         (expr (mapcar (lambda (book)
                         (etaf-reader--book-row session book theme))
                       books)))
       (flex :width 'stretch :height '(lh 1) :align-items 'center
         (box :height '(lh 1) :color (etaf-reader-color :dim theme)
           (text (expr (or (etaf-reader--read session :message) "")))))))))

;;; ---------------------------------------------------------------------------
;;; Panes (contents / notes / help)
;;; ---------------------------------------------------------------------------

(defun etaf-reader--view-pane (session)
  "Return the open pane as a dialog, or nil."
  (let* ((pane (etaf-reader--read session :pane))
         (theme (etaf-reader--read session :theme)))
    (when pane
      (let* ((close (lambda () (etaf-reader--write session :pane nil))))
        (pcase pane
          ('toc
           (let* ((chapters (etaf-reader--read session :chapters))
                  (current (or (plist-get (etaf-reader--read session :chapter) :index) 0)))
             (etaf-view
              (etaf-dialog :open t :title "目录" :width '(ch 56) :height '(lh 20)
                           :on-close close
                (column :width 'stretch :item-gap '(lh 0)
                  (flex :for (chapter chapters) :key (plist-get chapter :idx)
                        :width 'stretch :height '(lh 1) :overflow 'hidden
                        :role 'button :pointer 'hand :padding '((lh 0) (ch 1))
                        :bgcolor (and (= (or (plist-get chapter :idx) -1) current)
                                      (etaf-reader-color :accent-soft theme))
                        :on-press (lambda ()
                                    (etaf-reader-guard
                                     session
                                     (lambda ()
                                       (etaf-reader-open-chapter
                                        session (or (plist-get chapter :idx) 0) 0)
                                       (etaf-reader--write session :pane nil))))
                    (text (expr (format "%d. %s" (1+ (or (plist-get chapter :idx) 0))
                                        (or (plist-get chapter :title) ""))))))))))
          ('notes
           (let ((rows (etaf-reader--read session :book-notes)))
             (etaf-view
              (etaf-dialog :open t :title "笔记与划线" :width '(ch 60) :height '(lh 22)
                           :on-close close
                (column :width 'stretch :item-gap '(lh 0)
                  (etaf-empty :if (null rows) :title "还没有标注"
                              :description "选中文字后按 a 或点击工具条标注")
                  (column :for (row rows) :key (plist-get row :id)
                          :width 'stretch :item-gap '(lh 0) :padding '((lh 0) (ch 1))
                          :role 'button :pointer 'hand
                          :on-press (lambda ()
                                      (etaf-reader-goto-annotation session row))
                    (box :height '(lh 1) :overflow 'hidden :color (etaf-reader-color :muted theme)
                      (text (expr (format "第 %d 章 · %s"
                                          (1+ (or (plist-get row :chapter) 0))
                                          (or (plist-get row :kind) "")))))
                    (box :height '(lh 2) :overflow 'hidden
                      (text (expr (or (plist-get row :quote) ""))))
                    (box :if (not (string-empty-p (or (plist-get row :note) "")))
                         :height '(lh 2) :overflow 'hidden
                         :color (etaf-reader-color :accent theme)
                      (text (expr (concat "想法：" (plist-get row :note)))))))))))
          ('help
           (etaf-view
            (etaf-dialog :open t :title "快捷键" :width '(ch 52) :on-close close
              (column :width 'stretch :item-gap '(lh 0)
                (text "空格 / PgDn  下一页")
                (text "退格 / PgUp  上一页")
                (text "j / k        下一行 / 上一行")
                (text "H / L        上一章 / 下一章")
                (text "v            键盘选择（hjkl 移动，回车标注）")
                (text "鼠标拖选     划出选区，工具条浮出")
                (text "s / n / N    搜索 / 下一个 / 上一个")
                (text "c / a        目录 / 笔记")
                (text "b            书签（当前页）")
                (text "g            跳到百分比")
                (text "z            切换翻页 / 滚动")
                (text "[ / ]        栏宽")
                (text "t            切换主题")
                (text "f            返回书架")
                (text "E            导出笔记")
                (text "q            关闭阅读器"))))))
        ))))

;;; ---------------------------------------------------------------------------
;;; Whole application
;;; ---------------------------------------------------------------------------

(defun etaf-reader-view (session)
  "Return the View of SESSION."
  (let ((view (etaf-reader--read session :view)))
    (etaf-node
     'fragment
     (list :width 'stretch :height 'stretch)
     (delq nil
           (if (eq view 'reader)
               (list (etaf-reader--view-reader session)
                     (etaf-reader--view-toolbar session)
                     (etaf-reader--view-pane session))
             (list (etaf-reader--view-shelf session)
                   (etaf-reader--view-pane session)))))))

(provide 'etaf-reader-views)
;;; etaf-reader-views.el ends here
