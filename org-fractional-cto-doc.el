;;; org-fractional-cto-doc.el --- In-Emacs access to the manuals -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Dhruva Sagar
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Read the bundled documentation without leaving Emacs.  Two layers:
;;
;;   * The long-form Org sources -- `org-fractional-cto-guide',
;;     `org-fractional-cto-playbook', `org-fractional-cto-reference' -- open the
;;     bundled doc/*.org files read-only, so they always reflect the latest
;;     source.
;;   * The combined Texinfo manual -- `org-fractional-cto-info' (or plain
;;     `C-h i') -- which straight.el/MELPA compile from those same sources at
;;     build time and register on `Info-directory-list'.
;;
;; `org-fractional-cto-docs' is a single dispatcher over all of the above,
;; bound to `h' in `org-fractional-cto-command-map'.

;;; Code:

(require 'info)

(defvar org-fractional-cto-doc--load-dir
  (file-name-directory (or load-file-name buffer-file-name default-directory))
  "Directory this file was loaded from; used to locate the bundled docs.")

(defcustom org-fractional-cto-doc-directory
  (expand-file-name "doc" org-fractional-cto-doc--load-dir)
  "Directory holding the bundled documentation sources.
Defaults to the doc/ directory shipped with the package.  Resolves correctly
only when the package build includes doc/ (see the `:files' recipe directive)."
  :type 'directory
  :group 'org-fractional-cto)

(defun org-fractional-cto--doc-file (filename)
  "Return the absolute path to bundled documentation FILENAME."
  (expand-file-name filename org-fractional-cto-doc-directory))

(defun org-fractional-cto--view-doc (filename)
  "Open bundled documentation FILENAME read-only in its own buffer."
  (let ((path (org-fractional-cto--doc-file filename)))
    (unless (file-readable-p path)
      (user-error
       "Documentation file not found: %s -- was the package built with doc/?"
       path))
    (find-file-read-only path)))

;;;###autoload
(defun org-fractional-cto-guide ()
  "Open the org-fractional-cto user guide (a step-by-step walkthrough)."
  (interactive)
  (org-fractional-cto--view-doc "guide.org"))

;;;###autoload
(defun org-fractional-cto-playbook ()
  "Open the fractional-CTO engagement playbook (the methodology)."
  (interactive)
  (org-fractional-cto--view-doc "playbook.org"))

;;;###autoload
(defun org-fractional-cto-reference ()
  "Open the engagement reference guide (the per-capture/tag lookup)."
  (interactive)
  (org-fractional-cto--view-doc "reference.org"))

;;;###autoload
(defun org-fractional-cto-info ()
  "Open the combined org-fractional-cto Info manual (`C-h i' equivalent)."
  (interactive)
  (info "org-fractional-cto"))

;;;###autoload
(defun org-fractional-cto-docs (choice)
  "Open a piece of org-fractional-cto documentation.
CHOICE selects the guide, playbook, reference, or the combined Info manual."
  (interactive
   (list (completing-read
          "org-fractional-cto docs: "
          '("guide" "playbook" "reference" "info (combined manual)")
          nil t)))
  (pcase choice
    ("guide" (org-fractional-cto-guide))
    ("playbook" (org-fractional-cto-playbook))
    ("reference" (org-fractional-cto-reference))
    (_ (org-fractional-cto-info))))

(provide 'org-fractional-cto-doc)

;;; org-fractional-cto-doc.el ends here
