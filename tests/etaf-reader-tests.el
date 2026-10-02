;;; etaf-reader-tests.el --- Public acceptance scenarios -*- lexical-binding: t; -*-

;; Copyright (C) 2026 ETAF contributors
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; Public API acceptance for etaf-reader.  Every scenario drives the reader
;; through interfaces declared by the root entry Commentary: a headless
;; session, its navigation, selection, annotation, search and progress
;; functions.  A scripted parser supplies the book data, so no network,
;; backend process or frame is required.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'ert)
(require 'etaf-reader)

;;; ---------------------------------------------------------------------------
;;; Scripted backend
;;; ---------------------------------------------------------------------------

(defconst etaf-reader-tests--chapters
  (list
   (list "第一章 起点"
         (concat "他在清晨出发。走过长长的街道，街角的面包店刚刚开门，空气里有麦子的香味。"
                 "\n\n"
                 "走了很久，鞋底磨薄了一层。远处的钟楼指向正午，他在桥边停下，看了看河水。"
                 "\n\n"
                 "下午的风从河面吹来，带着水汽。他想起出门前母亲说的话，于是继续向前走。"))
   (list "第二章 途中"
         (concat "路边有一家书店。木头的招牌掉了漆，门口摆着一摞旧杂志。"
                 "\n\n"
                 "他停下来，翻了一本讲远方的书。书里写到一座常年下雪的山，和一条通往海的路。"
                 "\n\n"
                 "店主没有催他。他把书放回原处，买了一支铅笔，在扉页写下自己的名字。"))
   (list "第三章 终点"
         (concat "黄昏时到达。村口的灯一盏一盏亮起来，像一串安静的句子。"
                 "\n\n"
                 "他终于站在那扇门前面，抬手，又放下。门上贴着一张褪色的纸，写着欢迎回家。"
                 "\n\n"
                 "故事到这里结束。他把一路上的笔记收进背包，准备第二天重新出发。")))
  "The three chapters the scripted parser serves.")

(defun etaf-reader-tests--blocks (text)
  "Return paragraph blocks of TEXT with projection offsets."
  (let ((cursor 0) (blocks nil) (index 0))
    (dolist (paragraph (split-string text "\n\n" t))
      (when (> index 0)
        (setq cursor (1+ cursor)))
      (push (list (cons :type "p") (cons :text paragraph)
                  (cons :start cursor) (cons :end (+ cursor (length paragraph))))
            blocks)
      (setq cursor (+ cursor (length paragraph)))
      (setq index (1+ index)))
    (nreverse blocks)))

(defun etaf-reader-tests--parser (root)
  "Return a scripted parser whose single book lives under ROOT."
  (let ((book-path (expand-file-name "fake-book.epub" root))
        (chapters etaf-reader-tests--chapters))
    (with-temp-file book-path (insert "fake epub"))
    (list
     :scan
     (lambda (directory)
       (ignore directory)
       (list :books (list (list :path book-path :title "测试书" :author "作者"
                                :format "epub" :chapters (length chapters)
                                :chars 1200 :pages 0 :size 10 :mtime 1234.0))
             :failed 0))
     :extract
     (lambda (_source out)
       (make-directory (expand-file-name "chapters" out) t)
       (let ((index 0) (total 0) (entries nil))
         (dolist (chapter chapters)
           (let* ((text (nth 1 chapter))
                  (file (format "chapters/%03d.json" index)))
             (with-temp-file (expand-file-name file out)
               (insert (json-encode
                        (list :index index :title (nth 0 chapter)
                              :chars (length text) :text text
                              :blocks (etaf-reader-tests--blocks text)))))
             (push (list (cons :index index) (cons :title (nth 0 chapter))
                         (cons :chars (length text)) (cons :file file))
                   entries)
             (setq total (+ total (length text)))
             (setq index (1+ index))))
         (with-temp-file (expand-file-name "manifest.json" out)
           (insert (json-encode
                    (list :schema 1 :title "测试书" :author "作者" :format "epub"
                          :path book-path :cover "" :chars total :pages 0
                          :size 10 :mtime 1234.0
                          :chapters (nreverse entries)))))
         (list :out out :title "测试书" :chapters (length chapters)))))))

;;; ---------------------------------------------------------------------------
;;; Helpers
;;; ---------------------------------------------------------------------------

(defmacro etaf-reader-tests--with-environment (&rest body)
  "Run BODY with a disposable library store and cache directory."
  (declare (indent 0) (debug (body)))
  `(let* ((folder (make-temp-file "etaf-reader-tests" t))
          (etaf-reader-store-file (expand-file-name "library.sqlite3" folder))
          (etaf-reader-cache-directory (expand-file-name "cache" folder)))
     (unwind-protect
         (progn ,@body)
       (delete-directory folder t))))

(defun etaf-reader-tests--open (session)
  "Import the scripted book, open it and use a deterministic page geometry."
  (etaf-reader-refresh-library session)
  (etaf-reader-open-book session (car (etaf-reader-books session)))
  (etaf-reader-set-metrics session 40 4 1 'medium 'page)
  session)

(defun etaf-reader-tests--line (session index)
  "Return SESSION's wrapped line at INDEX."
  (nth index (etaf-reader-lines session)))

;;; ---------------------------------------------------------------------------
;;; Session and library
;;; ---------------------------------------------------------------------------

(ert-deftest etaf-reader-tests-headless-session-starts-on-shelf ()
  "A session built without a buffer starts on the shelf and names itself."
  (etaf-reader-tests--with-environment
    (let ((session (etaf-reader-create)))
      (should (equal (plist-get (etaf-reader-state session) :view) 'shelf))
      (should (null (plist-get (etaf-reader-state session) :book)))
      (should (null (etaf-reader-books session))))))

(ert-deftest etaf-reader-tests-scan-imports-into-the-store ()
  "Scanning the library stores the book and opening imports its chapters."
  (etaf-reader-tests--with-environment
    (let* ((folder (make-temp-file "etaf-reader-book" t))
           (session (etaf-reader-create
                     :parser (etaf-reader-tests--parser folder))))
      (unwind-protect
          (progn
            (etaf-reader-refresh-library session)
            (let ((books (etaf-reader-books session)))
              (should (= (length books) 1))
              (should (equal (plist-get (car books) :title) "测试书"))
              (should (= (or (plist-get (car books) :chapters) 0) 3)))
            (etaf-reader-open-book session (car (etaf-reader-books session)))
            (let ((state (etaf-reader-state session)))
              (should (eq (plist-get state :view) 'reader))
              (should (= (plist-get state :chapters) 3))
              (should (etaf-reader-lines session))))
        (delete-directory folder t)))))

;;; ---------------------------------------------------------------------------
;;; Reading
;;; ---------------------------------------------------------------------------

(ert-deftest etaf-reader-tests-pages-turn-and-chapters-advance ()
  "Page turns move the reading line and cross into the next chapter."
  (etaf-reader-tests--with-environment
    (let* ((folder (make-temp-file "etaf-reader-book" t))
           (session (etaf-reader-tests--open
                     (etaf-reader-create
                      :parser (etaf-reader-tests--parser folder)))))
      (unwind-protect
          (progn
            (let ((state (etaf-reader-state session)))
              (should (> (plist-get state :lines) 4))
              (should (= (plist-get state :line) 0)))
            (etaf-reader-next-page session)
            (should (= (plist-get (etaf-reader-state session) :line) 4))
            (etaf-reader-previous-page session)
            (should (= (plist-get (etaf-reader-state session) :line) 0))
            (etaf-reader-open-chapter session 0)
            (etaf-reader-goto-line session (1- (length (etaf-reader-lines session))))
            (etaf-reader-next-page session)
            (should (= (plist-get (etaf-reader-state session) :chapter) 1))
            (should (= (plist-get (etaf-reader-state session) :line) 0))
            (etaf-reader-previous-page session)
            (should (= (plist-get (etaf-reader-state session) :chapter) 0)))
        (delete-directory folder t)))))

(ert-deftest etaf-reader-tests-selection-annotate-and-note ()
  "A selection becomes an annotation that can carry a thought."
  (etaf-reader-tests--with-environment
    (let* ((folder (make-temp-file "etaf-reader-book" t))
           (session (etaf-reader-tests--open
                     (etaf-reader-create
                      :parser (etaf-reader-tests--parser folder)))))
      (unwind-protect
          (progn
            (etaf-reader-begin-selection session 0 0)
            (etaf-reader-extend-selection session 0 4)
            (should (equal (etaf-reader-selection session) '(0 . 4)))
            (should (equal (etaf-reader-selection-text session) "他在清晨"))
            (let ((id (etaf-reader-annotate session "highlight" "yellow")))
              (should id)
              (etaf-reader-annotation-note session id "一句想法")
              (let ((row (car (etaf-reader-annotations session))))
                (should (equal (plist-get row :kind) "highlight"))
                (should (equal (plist-get row :color) "yellow"))
                (should (equal (plist-get row :note) "一句想法"))
                (should (equal (plist-get row :quote) "他在清晨")))
              (etaf-reader-mark-annotation session id "wavy" "blue")
              (should (equal (plist-get (car (etaf-reader-annotations session))
                                        :kind)
                             "wavy"))
              (etaf-reader-annotation-delete session id)
              (should (null (etaf-reader-annotations session))))
            (should (= (plist-get (etaf-reader-state session) :annotations) 0)))
        (delete-directory folder t)))))

(ert-deftest etaf-reader-tests-progress-is-restored ()
  "Saving stores the position and a new session resumes there."
  (etaf-reader-tests--with-environment
    (let* ((folder (make-temp-file "etaf-reader-book" t))
           (parser (etaf-reader-tests--parser folder))
           (session (etaf-reader-tests--open (etaf-reader-create :parser parser))))
      (unwind-protect
          (progn
            (etaf-reader-open-chapter session 1)
            (etaf-reader-goto-line session 3)
            (let ((offset (plist-get (etaf-reader-tests--line session 3) :start))
                  (percent (etaf-reader-percent session)))
              (etaf-reader-save-now session)
              (should (> percent 0))
              (let* ((second (etaf-reader-create :parser parser))
                     (state (progn (etaf-reader-refresh-library second)
                                   (etaf-reader-open-book
                                    second (car (etaf-reader-books second)))
                                   (etaf-reader-state second)))
                     (line (etaf-reader-tests--line
                            second (plist-get state :line))))
                (should (= (plist-get state :chapter) 1))
                (should (<= (or (plist-get line :start) 0) offset))
                (should (<= offset (or (plist-get line :end) 0))))
              (should (> (etaf-reader-percent session) 0))))
        (delete-directory folder t)))))

(ert-deftest etaf-reader-tests-search-finds-and-selects ()
  "Search finds a phrase across chapters and selects the match."
  (etaf-reader-tests--with-environment
    (let* ((folder (make-temp-file "etaf-reader-book" t))
           (session (etaf-reader-tests--open
                     (etaf-reader-create
                      :parser (etaf-reader-tests--parser folder)))))
      (unwind-protect
          (progn
            (let* ((state (etaf-reader-search-book session "书店"))
                   (match (car (plist-get state :matches))))
              (should (= (length (plist-get state :matches)) 1))
              (should (= (plist-get match :chapter) 1))
              (should (= (plist-get (etaf-reader-state session) :chapter) 1))
              (should (equal (etaf-reader-selection session)
                             (cons (plist-get match :start) (plist-get match :end)))))
            (let ((state (etaf-reader-search-book session "不存在的词")))
              (should (null (plist-get state :matches)))))
        (delete-directory folder t)))))

(ert-deftest etaf-reader-tests-reflow-keeps-position ()
  "A column change re-wraps the chapter and keeps the reading offset."
  (etaf-reader-tests--with-environment
    (let* ((folder (make-temp-file "etaf-reader-book" t))
           (session (etaf-reader-tests--open
                     (etaf-reader-create
                      :parser (etaf-reader-tests--parser folder)))))
      (unwind-protect
          (let* ((before (length (etaf-reader-lines session)))
                 (index (1- before))
                 (offset (plist-get (etaf-reader-tests--line session index) :start)))
            (etaf-reader-goto-line session index)
            (etaf-reader-set-metrics session 24 4 1 'narrow 'page)
            (let* ((lines (etaf-reader-lines session))
                   (line (nth (plist-get (etaf-reader-state session) :line) lines)))
              (should (> (length lines) before))
              (should (<= (or (plist-get line :start) 0) offset))
              (should (<= offset (or (plist-get line :end) 0)))))
        (delete-directory folder t)))))

(ert-deftest etaf-reader-tests-export-notes ()
  "Exporting writes the quotations and thoughts as Markdown."
  (etaf-reader-tests--with-environment
    (let* ((folder (make-temp-file "etaf-reader-book" t))
           (session (etaf-reader-tests--open
                     (etaf-reader-create
                      :parser (etaf-reader-tests--parser folder))))
           (file (expand-file-name "notes.md" folder)))
      (unwind-protect
          (progn
            (etaf-reader-begin-selection session 0 0)
            (etaf-reader-extend-selection session 0 4)
            (let ((id (etaf-reader-annotate session "highlight" "yellow")))
              (etaf-reader-annotation-note session id "值得记住"))
            (etaf-reader-export-notes session file)
            (should (file-exists-p file))
            (with-temp-buffer
              (insert-file-contents file)
              (should (string-match-p "测试书" (buffer-string)))
              (should (string-match-p "他在清晨" (buffer-string)))
              (should (string-match-p "值得记住" (buffer-string)))))
        (delete-directory folder t)))))

(ert-deftest etaf-reader-tests-shelf-filters-use-state ()
  "The shelf filters books by their stored reading state."
  (etaf-reader-tests--with-environment
    (let* ((folder (make-temp-file "etaf-reader-book" t))
           (session (etaf-reader-tests--open
                     (etaf-reader-create
                      :parser (etaf-reader-tests--parser folder)))))
      (unwind-protect
          (progn
            (etaf-reader-save-now session)
            (should (= (length (etaf-reader-books
                                (progn (etaf-reader-set-filter session 'unread)
                                       session)))
                       0))
            (etaf-reader-set-filter session 'reading)
            (should (= (length (etaf-reader-books session)) 1))
            (etaf-reader-set-filter session 'all)
            (should (= (length (etaf-reader-books session)) 1)))
        (delete-directory folder t)))))

(provide 'etaf-reader-tests)
;;; etaf-reader-tests.el ends here
