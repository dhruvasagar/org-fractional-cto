;;; org-fractional-cto-people.el --- Global person nodes -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Dhruva Sagar
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; People are first-class, linkable Org nodes: one file per person under
;; `org-fractional-cto-people-directory', each a file-level `org-id' node
;; (`:ID:' drawer + `#+title').  References elsewhere are plain `[[id:...]]'
;; links resolved by built-in `org-id'.  This module owns the directory/path
;; helpers, pure node creation, `org-id' registration, the insert-or-create
;; helper, and the `eP' capture target.  No org-roam dependency: roam, if the
;; people directory is inside the user's roam graph, consumes these files
;; unchanged.

;;; Code:

(require 'org-id)
(require 'seq)
(require 'subr-x)

(declare-function org-fractional-cto--people-dir "org-fractional-cto")
(declare-function org-fractional-cto--template "org-fractional-cto")
(defvar org-fractional-cto-people-directory)

(defun org-fractional-cto-people-slug (name)
  "Derive a filesystem slug from person NAME.
Lowercases, maps non-alphanumerics to single underscores, and trims."
  (let ((base (replace-regexp-in-string
               "_+" "_"
               (replace-regexp-in-string
                "[^a-z0-9]" "_" (downcase (string-trim name))))))
    (replace-regexp-in-string "\\`_+\\|_+\\'" "" base)))

(defun org-fractional-cto-person-file (slug)
  "Return the node file path for person SLUG."
  (expand-file-name (format "%s.org" slug) (org-fractional-cto--people-dir)))

(defun org-fractional-cto--person-files ()
  "Return the list of person node files on disk (absolute paths)."
  (let ((dir (org-fractional-cto--people-dir)))
    (when (file-directory-p dir)
      (directory-files dir t "\\.org\\'"))))

(defun org-fractional-cto--person-title (file)
  "Return the `#+title' of person node FILE, or nil."
  (when (file-readable-p file)
    (with-temp-buffer
      (insert-file-contents file)
      (goto-char (point-min))
      (let ((case-fold-search t))
        (when (re-search-forward "^#\\+title:[ \t]*\\(.+\\)$" nil t)
          (string-trim (match-string 1)))))))

(defun org-fractional-cto--person-id (file)
  "Return the top-level `:ID:' of person node FILE, or nil."
  (when (file-readable-p file)
    (with-temp-buffer
      (insert-file-contents file)
      (goto-char (point-min))
      (when (re-search-forward "^[ \t]*:ID:[ \t]*\\(\\S-+\\)" nil t)
        (string-trim (match-string 1))))))

(defun org-fractional-cto-people ()
  "Return an alist of (TITLE . FILE) for all titled person nodes."
  (delq nil
        (mapcar (lambda (f)
                  (let ((title (org-fractional-cto--person-title f)))
                    (and title (cons title f))))
                (org-fractional-cto--person-files))))

(provide 'org-fractional-cto-people)

;;; org-fractional-cto-people.el ends here
