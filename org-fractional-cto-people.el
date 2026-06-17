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

(defun org-fractional-cto--unique-slug (slug)
  "Return SLUG, numerically suffixed if a node file already exists."
  (let ((candidate slug) (n 1))
    (while (file-exists-p (org-fractional-cto-person-file candidate))
      (setq n (1+ n)
            candidate (format "%s_%d" slug n)))
    candidate))

(defun org-fractional-cto--person-scaffold (name id)
  "Return new-node text for NAME with ID, from the bundled person.org scaffold."
  (let ((tpl (with-temp-buffer
               (insert-file-contents (org-fractional-cto--template "person.org"))
               (buffer-string))))
    (replace-regexp-in-string
     "%NAME%" name
     (replace-regexp-in-string "%ID%" id tpl t t) t t)))

(defun org-fractional-cto-create-person (name)
  "Create (or reuse) the person node for NAME and return its `org-id'.
A node whose `#+title' equals NAME is reused.  Otherwise a new file is written
under the people directory, given a fresh ID, and registered with `org-id'."
  (let ((existing (seq-find (lambda (cell) (string= (car cell) name))
                            (org-fractional-cto-people))))
    (if existing
        (org-fractional-cto--person-id (cdr existing))
      (let* ((slug (org-fractional-cto--unique-slug
                    (org-fractional-cto-people-slug name)))
             (file (org-fractional-cto-person-file slug))
             (id   (org-id-new)))
        (make-directory (org-fractional-cto--people-dir) t)
        (with-temp-file file
          (insert (org-fractional-cto--person-scaffold name id)))
        (org-id-add-location id file)
        id))))

(defun org-fractional-cto--register-people-with-org-id ()
  "Make every person node resolvable by `org-id' in a fresh session.
Adds the node files to `org-id-extra-files' when that variable holds a list."
  (when (listp org-id-extra-files)
    (dolist (file (org-fractional-cto--person-files))
      (add-to-list 'org-id-extra-files file))))

;;;###autoload
(defun org-fractional-cto-insert-person ()
  "Insert an `[[id:...][Name]]' link to a person, creating the node if new.
Completes over existing person nodes by name.  Entering a name with no match
offers to create the node and then links it.  Bind it yourself if you like;
org-roam users may instead use `org-roam-node-insert'."
  (interactive)
  (let* ((people (org-fractional-cto-people))
         (name (completing-read "Person: " (mapcar #'car people) nil nil))
         (cell (assoc name people))
         (id (if cell
                 (org-fractional-cto--person-id (cdr cell))
               (when (y-or-n-p (format "Create new person \"%s\"? " name))
                 (org-fractional-cto-create-person name)))))
    (when id
      (insert (format "[[id:%s][%s]]" id name)))))

(provide 'org-fractional-cto-people)

;;; org-fractional-cto-people.el ends here
