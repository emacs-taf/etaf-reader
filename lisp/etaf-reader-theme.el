;;; etaf-reader-theme.el --- Palettes for etaf-reader -*- lexical-binding: t; -*-

;; Copyright (C) 2026 ETAF contributors
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; Three fixed palettes with one paper-like page and six annotation colors.
;; `etaf-reader-color' is the lookup used by the Views; the application
;; projects the same palette onto the ETAF UI token contract so shared
;; etaf-ui Components (buttons, tabs, progress bars) follow the reader.

;;; Code:

(require 'etaf)
(require 'etaf-ui)

(define-error 'etaf-reader-error "ETAF reader error")

(defgroup etaf-reader nil
  "Local ebook reader built with ETAF and Ebox."
  :group 'applications)

(defcustom etaf-reader-theme 'dark
  "Appearance of a new reader session: `dark', `light' or `sepia'."
  :type '(choice (const :tag "Dark" dark) (const :tag "Light" light)
                 (const :tag "Sepia" sepia))
  :group 'etaf-reader)

;;: One entry per palette.  The six annotation colors come in a strong ink
;;: (underline styles and toolbar dots) and a soft tint (highlight fill).
(defconst etaf-reader--palettes
  '((dark :bg "#0F1216" :panel "#151A21" :panel2 "#1B212B" :line "#242C38"
          :ink "#E8ECF2" :muted "#9AA5B4" :dim "#66707F"
          :accent "#5B8DEF" :accent-soft "#1A2436" :cover "#232B37"
          :sel "#2C3A52" :quote "#8EA8D8" :gold "#E4B15E"
          :red "#F0656F" :red-soft "#3A2026"
          :orange "#E8944A" :orange-soft "#3A2A1A"
          :yellow "#D9B13B" :yellow-soft "#37301A"
          :green "#54B87A" :green-soft "#1D3326"
          :blue "#5B8DEF" :blue-soft "#1E2C44"
          :purple "#A279D8" :purple-soft "#2B2340")
    (light :bg "#FFFFFF" :panel "#F7F8FA" :panel2 "#EDF0F4" :line "#E1E6EC"
           :ink "#1C2330" :muted "#5A6371" :dim "#8A93A0"
           :accent "#2F6FED" :accent-soft "#E8EFFD" :cover "#E1E6EC"
           :sel "#CFE0FB" :quote "#4A6FC0" :gold "#B07A16"
           :red "#D93A44" :red-soft "#FCE4E5"
           :orange "#C46A16" :orange-soft "#FBEBD9"
           :yellow "#A8861B" :yellow-soft "#FAF0CD"
           :green "#2E7D5B" :green-soft "#DFF3E8"
           :blue "#2F6FED" :blue-soft "#E3EDFD"
           :purple "#7A4FC0" :purple-soft "#EEE6FA")
    (sepia :bg "#F4EBD9" :panel "#EFE4CD" :panel2 "#E7D8BC" :line "#D9C5A2"
           :ink "#3B3225" :muted "#6D5E47" :dim "#95846A"
           :accent "#8A6A2F" :accent-soft "#EDE0C4" :cover "#DCC9A6"
           :sel "#E4D3B2" :quote "#7A6440" :gold "#8A6A2F"
           :red "#B0453A" :red-soft "#F0DCD4"
           :orange "#A2641F" :orange-soft "#EFE0C8"
           :yellow "#8F7517" :yellow-soft "#EEE4C0"
           :green "#4C7A54" :green-soft "#DFE8D4"
           :blue "#3F6293" :blue-soft "#DFE4EE"
           :purple "#6E5590" :purple-soft "#E7DFF0"))
  "Palette of every supported appearance, keyed by mode.")

(defconst etaf-reader--annotation-colors
  '(red orange yellow green blue purple)
  "Annotation color keys offered by the toolbar, in display order.")

(defun etaf-reader-color (key &optional mode)
  "Return the palette color named KEY.
MODE defaults to `etaf-reader-theme'; an unknown mode falls back to `dark'.
An unknown KEY signals `etaf-reader-error' instead of painting a fallback."
  (let* ((mode (if (assq (or mode etaf-reader-theme) etaf-reader--palettes)
                   (or mode etaf-reader-theme)
                 'dark))
         (palette (cdr (assq mode etaf-reader--palettes)))
         (color (plist-get palette key)))
    (unless (and (keywordp key) color)
      (signal 'etaf-reader-error (list (format "Unknown color: %S" key))))
    color))

(defun etaf-reader-annotation-color-keys ()
  "Return the annotation color keys in toolbar order."
  (copy-sequence etaf-reader--annotation-colors))

(defun etaf-reader-theme-defaults (&optional mode)
  "Return the ETAF UI token plist for MODE.
The application passes the result to `etaf-theme-provide' so shared etaf-ui
Components follow the reader's palette."
  (let ((dark (eq (or mode etaf-reader-theme) 'dark))
        (panel2 (etaf-reader-color :panel2 mode))
        (danger (etaf-reader-color :red mode)))
    ;; Disabled fills sit on the second panel tone, one step above the
    ;; catalog's default of the first.
    (cons :ui-disabled-bg
          (cons panel2
                (etaf-ui-theme-tokens
                 (list :bg (etaf-reader-color :bg mode)
                       :fg (etaf-reader-color :ink mode)
                       :panel (etaf-reader-color :panel mode)
                       :track panel2
                       :border (etaf-reader-color :line mode)
                       :muted (etaf-reader-color :muted mode)
                       :dim (etaf-reader-color :dim mode)
                       :accent (etaf-reader-color :accent mode)
                       :accent-fg "#FFFFFF"
                       :accent-soft (etaf-reader-color :accent-soft mode)
                       :success (if dark "#4FBF8B" "#2E7D5B")
                       :danger danger
                       :danger-bg (etaf-reader-color :red-soft mode)
                       :danger-border danger
                       :warning (etaf-reader-color :gold mode)
                       :warning-bg (etaf-reader-color :yellow-soft mode)))))))

(provide 'etaf-reader-theme)
;;; etaf-reader-theme.el ends here
