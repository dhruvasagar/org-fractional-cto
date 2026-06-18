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
  "Register every person node with `org-id' so `[[id:...]]' links resolve.
Reads each node file's `:ID:' and records its location directly via
`org-id-add-location', independent of `org-id-extra-files' (whose default value
is a symbol, not a list).  Person files are never added to `org-agenda-files'."
  (require 'org-id)
  (dolist (file (org-fractional-cto--person-files))
    (let ((id (org-fractional-cto--person-id file)))
      (when id
        (org-id-add-location id file)))))

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

(defun org-fractional-cto--person-goto-notes (file)
  "Visit person FILE and move point onto its `Notes / History' heading.
Appends the heading if the node lacks one."
  (find-file file)
  (widen)
  (goto-char (point-min))
  (if (re-search-forward "^\\*+ Notes / History[ \t]*$" nil t)
      (beginning-of-line)
    (goto-char (point-max))
    (unless (bolp) (insert "\n"))
    (insert "* Notes / History\n")
    (forward-line -1)))

(defun org-fractional-cto--capture-to-person ()
  "Capture target for `eP': pick or create a person; file under Notes / History."
  (let* ((people (org-fractional-cto-people))
         (name (completing-read "Person: " (mapcar #'car people) nil nil))
         (cell (assoc name people))
         (file (if cell
                   (cdr cell)
                 (progn (org-fractional-cto-create-person name)
                        (cdr (assoc name (org-fractional-cto-people)))))))
    (org-fractional-cto--person-goto-notes file)))

(defun org-fractional-cto-person-tag (slug)
  "Return the Org heading tag for person SLUG (e.g. \"jane_doe\" -> \"@jane_doe\").
SLUG is a person node's filename base; it is already `[a-z0-9_]', valid in an
Org tag."
  (concat "@" slug))

(defun org-fractional-cto-person-record (name)
  "Ensure a person node exists for NAME and return a descriptor plist.
The plist has :id, :name, :slug, :tag (see `org-fractional-cto-person-tag'),
and :link (an `[[id:ID][NAME]]' string).  Reuses an existing node whose title
equals NAME, otherwise creates one."
  (let* ((id   (org-fractional-cto-create-person name))
         (file (cdr (assoc name (org-fractional-cto-people))))
         (slug (and file (file-name-base file))))
    (list :id id :name name :slug slug
          :tag (and slug (org-fractional-cto-person-tag slug))
          :link (format "[[id:%s][%s]]" id name))))

(defun org-fractional-cto--read-person-name (prompt)
  "Completing-read a person by display name for PROMPT.
Existing person titles are offered; free text is allowed so a new name flows
through to node creation.  Returns the chosen/typed string (possibly empty)."
  (completing-read (format "%s: " prompt)
                   (mapcar #'car (org-fractional-cto-people)) nil nil))

(defun org-fractional-cto--capture-person (prompt &optional tag)
  "Capture `%()' helper: pick a person for PROMPT and return an `[[id:]]' link.
With TAG non-nil, also stash the person record under `:ofc-person' in the
capture plist so `org-fractional-cto--apply-person-tag' tags the heading on
finalize.  Returns an empty string when no name is entered."
  (let ((name (org-fractional-cto--read-person-name prompt)))
    (if (or (null name) (string-empty-p (string-trim name)))
        ""
      (let ((rec (org-fractional-cto-person-record name)))
        (when tag (org-capture-put :ofc-person rec))
        (plist-get rec :link)))))

(defun org-fractional-cto--capture-people (prompt)
  "Capture `%()' helper: pick people for PROMPT until empty input.
Returns a comma-separated string of `[[id:]]' links (empty string if none)."
  (let ((links nil)
        (name (org-fractional-cto--read-person-name prompt)))
    (while (and name (not (string-empty-p (string-trim name))))
      (push (plist-get (org-fractional-cto-person-record name) :link) links)
      (setq name (org-fractional-cto--read-person-name
                  (format "%s (another; empty to finish)" prompt))))
    (mapconcat #'identity (nreverse links) ", ")))

(defun org-fractional-cto--apply-person-tag ()
  "Tag the captured heading with the `:ofc-person' record's tag, if any.
Registered on `org-capture-before-finalize-hook'; a no-op for captures that did
not select a taggable person."
  (let ((rec (org-capture-get :ofc-person)))
    (when rec
      (save-excursion
        (goto-char (point-min))
        (unless (org-at-heading-p) (outline-next-heading))
        (when (org-at-heading-p)
          (org-toggle-tag (plist-get rec :tag) 'on))))))

(provide 'org-fractional-cto-people)

;;; org-fractional-cto-people.el ends here
