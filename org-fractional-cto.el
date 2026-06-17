;;; org-fractional-cto.el --- Opinionated org-mode workflow for fractional-CTO engagements -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Dhruva Sagar

;; Author: Dhruva Sagar <dhruva.sagar@gmail.com>
;; Maintainer: Dhruva Sagar <dhruva.sagar@gmail.com>
;; Version: 0.1.0
;; Package-Requires: ((emacs "27.1") (org "9.4"))
;; Keywords: outlines, convenience, org, consulting
;; URL: https://github.com/dhruvasagar/org-fractional-cto
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; org-fractional-cto turns Org mode into an operating system for running
;; technical client engagements as a fractional CTO or engagement director.
;;
;; It bundles three things into one opinionated workflow:
;;
;;   1. Onboarding   -- `org-fractional-cto-new-client' scaffolds a complete
;;                      per-client workspace (operational hub, capture templates,
;;                      context).
;;   2. Capture      -- a single `e' capture prefix (`C-c c e ...') routes every
;;                      kind of note -- discovery, ADRs, risks, commitments,
;;                      delegated tasks, blockers, retrospectives, QBRs, and
;;                      more -- directly into the active client's file.
;;   3. Dashboard    -- a per-client agenda view (`C-c a E') surfacing delegated
;;                      work, blockers, open actions, commitments, and risks.
;;
;; The system is multi-client: set an "active client" once per session with
;; `org-fractional-cto-set-active-client' and every capture and the dashboard
;; follow it -- no per-client key prefixes, no copied configuration.
;;
;; Quick start:
;;
;;   (require 'org-fractional-cto)
;;   (setq org-fractional-cto-clients-directory "~/org/clients")
;;   (org-fractional-cto-setup)
;;
;; Then:  M-x org-fractional-cto-new-client
;;        M-x org-fractional-cto-set-active-client
;;        C-c c e w   (capture an action)   /   C-c a E   (open the dashboard)
;;
;; See README.org for the full manual, the tag/keyword legend, and how to wire
;; in external AI session skills (mattpocock/skills, gstack).

;;; Code:

(require 'org)
(require 'org-capture)
(require 'org-agenda)
(require 'seq)
(require 'subr-x)

;;;; Customization

(defgroup org-fractional-cto nil
  "Opinionated Org-mode workflow for running fractional-CTO engagements."
  :group 'org
  :prefix "org-fractional-cto-")

(defcustom org-fractional-cto-clients-directory
  (expand-file-name "clients" (or (bound-and-true-p org-directory) "~/org"))
  "Directory holding one sub-directory per client engagement.
Each client lives in DIRECTORY/<slug>/ and owns <slug>.org, CONTEXT.md, and a
templates/ subdirectory of per-client capture templates."
  :type 'directory
  :group 'org-fractional-cto)

(defcustom org-fractional-cto-people-directory
  (expand-file-name "people" (or (bound-and-true-p org-directory) "~/org"))
  "Directory holding one Org node per person (global, cross-client).
Each person is a file-level `org-id' node (an `:ID:' property drawer plus a
`#+title').  Point this inside your `org-roam-directory' to have roam index
the nodes; the package itself never requires org-roam."
  :type 'directory
  :group 'org-fractional-cto)

(defcustom org-fractional-cto-template-directory
  (expand-file-name
   "templates"
   (file-name-directory (or load-file-name buffer-file-name default-directory)))
  "Directory holding the capture templates.
Defaults to the templates bundled with the package.  Point it at your own
directory to override individual templates -- only the files you provide are
used; the rest still resolve against the bundled set if you keep both on the
path."
  :type 'directory
  :group 'org-fractional-cto)

(defcustom org-fractional-cto-author user-full-name
  "Name inserted as #+AUTHOR in scaffolded engagement files."
  :type 'string
  :group 'org-fractional-cto)

(defcustom org-fractional-cto-agenda-key "E"
  "Dispatcher key, under `C-c a', for the active-client dashboard.
Defaults to \"E\" (i.e. `C-c a E') because the agenda dispatcher already
binds lowercase \"e\" to `org-store-agenda-views' (Export agenda views)."
  :type 'string
  :group 'org-fractional-cto)

(defcustom org-fractional-cto-keymap-prefix nil
  "Optional prefix key sequence for `org-fractional-cto-command-map'.
Defaults to nil: the management commands (new client, set/clear active
client, dashboard, switch client) are reached via `M-x' and no global key
is claimed.  Common prefixes like `C-c f' are already taken (e.g. Magit's
file dispatch), so opt in explicitly if you want one, or bind the map
yourself."
  :type '(choice (key-sequence :tag "Prefix") (const :tag "None" nil))
  :group 'org-fractional-cto)

(defcustom org-fractional-cto-agenda-keymap-prefix nil
  "Optional prefix key for `org-fractional-cto-agenda-command-map' in agendas.
Bound in `org-agenda-mode-map' by `org-fractional-cto-setup' for non-Evil users.
Default nil: reach the at-point actions via \\[execute-extended-command], or --
under Evil -- the comma (`,') localleader (`, g' delegate, `, b' block).  Plain
`,' is `org-agenda-priority' in vanilla agendas, so it is not overridden."
  :type '(choice (key-sequence :tag "Prefix") (const :tag "None" nil))
  :group 'org-fractional-cto)

(defcustom org-fractional-cto-stages
  '("LEAD" "QUALIFIED" "ACTIVE" "LOST" "DORMANT")
  "Ordered engagement stages, carried as a tag on the engagement heading.
Exactly one is present at a time; `org-fractional-cto-set-stage' switches it."
  :type '(repeat string)
  :group 'org-fractional-cto)

(defcustom org-fractional-cto-default-stage "ACTIVE"
  "Stage tag applied to engagements created by `org-fractional-cto-new-client'."
  :type 'string
  :group 'org-fractional-cto)

(defcustom org-fractional-cto-lead-stage "LEAD"
  "Stage tag applied to prospects created by `org-fractional-cto-new-prospect'."
  :type 'string
  :group 'org-fractional-cto)

(defcustom org-fractional-cto-pipeline-stages "LEAD|QUALIFIED"
  "Org tag-match expression selecting prospects for the pipeline view."
  :type 'string
  :group 'org-fractional-cto)

(defcustom org-fractional-cto-pipeline-key "P"
  "Dispatcher key, under `C-c a', for the cross-client pipeline view."
  :type 'string
  :group 'org-fractional-cto)

(defcustom org-fractional-cto-set-tag-inheritance t
  "When non-nil, `org-fractional-cto-setup' enables agenda tag inheritance.
Filetag-based client focus on the dashboard relies on inherited tags being
visible to the agenda filter.  Set to nil to manage tag inheritance yourself."
  :type 'boolean
  :group 'org-fractional-cto)

(defcustom org-fractional-cto-todo-keywords
  '((sequence "TODO" "NEXT" "INPROGRESS" "WAITING" "|" "DONE" "CANCELLED"))
  "TODO keyword sequences the workflow relies on.
Merged into the global `org-todo-keywords' by `org-fractional-cto-setup' so
that keywords such as INPROGRESS are recognised everywhere -- in agenda matches,
the dashboard's \"Open actions\" block, and any Org buffer -- not only inside
client hubs whose \"#+TODO:\" line happens to declare them.  This keeps the
workflow self-contained: it does not depend on your personal Org configuration.

A sequence is added only when it introduces a keyword Org does not already know,
so re-running setup is idempotent and your own keyword definitions win.  Set to
nil to manage TODO keywords entirely yourself."
  :type 'sexp
  :group 'org-fractional-cto)

(defcustom org-fractional-cto-todo-keyword-faces
  '(("INPROGRESS" . (:foreground "deep sky blue" :weight bold)))
  "Faces for workflow-specific TODO keywords.
Merged into `org-todo-keyword-faces' by `org-fractional-cto-setup'.  Only
keywords without an existing face are added, so any face you have already
defined is left untouched.  Set to nil to skip face installation."
  :type 'sexp
  :group 'org-fractional-cto)

;;;; Core state and path helpers

(defvar org-fractional-cto-active-client nil
  "Slug of the active client for this session.
When set, captures and the dashboard target this client without prompting.
Set with `org-fractional-cto-set-active-client'.")

(defun org-fractional-cto--clients-dir ()
  "Return the configured clients directory, expanded."
  (expand-file-name org-fractional-cto-clients-directory))

(defun org-fractional-cto--people-dir ()
  "Return the configured people directory, expanded."
  (expand-file-name org-fractional-cto-people-directory))

(defun org-fractional-cto-clients ()
  "Return the list of client slugs discovered on disk.
Hidden entries (names beginning with a dot, e.g. \".git\" or \".DS_Store\") are
skipped, matching `org-fractional-cto-agenda-files'."
  (let ((dir (org-fractional-cto--clients-dir)))
    (when (file-directory-p dir)
      (seq-filter
       (lambda (entry)
         (file-directory-p (expand-file-name entry dir)))
       (directory-files dir nil "\\`[^.]")))))

(defun org-fractional-cto-client-org-file (slug)
  "Return the operational hub org file for client SLUG."
  (expand-file-name (format "%s/%s.org" slug slug)
                    (org-fractional-cto--clients-dir)))

(defun org-fractional-cto-client-template-file (slug name)
  "Return the per-client override template file NAME for client SLUG.
NAME is a bundled template filename such as \"risk.org\"; the override lives
under the client's `templates/' subdirectory."
  (expand-file-name (format "%s/templates/%s" slug name)
                    (org-fractional-cto--clients-dir)))

(defun org-fractional-cto-client-context-file (slug)
  "Return the CONTEXT.md file for client SLUG."
  (expand-file-name (format "%s/CONTEXT.md" slug)
                    (org-fractional-cto--clients-dir)))

(defun org-fractional-cto-client-name (slug)
  "Return the display name for client SLUG.
Read from the hub file's \"#+title:\" keyword; fall back to SLUG when the file
is missing or carries no title."
  (let ((file (org-fractional-cto-client-org-file slug)))
    (or (and (file-readable-p file)
             (with-temp-buffer
               (insert-file-contents file)
               (goto-char (point-min))
               (let ((case-fold-search t))
                 (when (re-search-forward "^#\\+title:[ \t]*\\(.+\\)$" nil t)
                   (string-trim (match-string 1))))))
        slug)))

(defun org-fractional-cto-client-tag (slug)
  "Derive a valid Org tag from SLUG.
For example \"acme-corp\" becomes \"ACME_CORP\" (Org tags may not contain
hyphens)."
  (upcase (replace-regexp-in-string "[^A-Za-z0-9]" "_" slug)))

(defun org-fractional-cto--template (filename)
  "Return the full path to capture template FILENAME."
  (expand-file-name filename org-fractional-cto-template-directory))

(defun org-fractional-cto-agenda-files ()
  "Return every client directory, for inclusion in `org-agenda-files'.
Adding the directories (not individual files) means new client files are
picked up automatically."
  (let ((dir (org-fractional-cto--clients-dir)))
    (when (file-directory-p dir)
      (seq-filter #'file-directory-p
                  (directory-files dir t "^[^.]")))))

;;;; Active client commands

;;;###autoload
(defun org-fractional-cto-set-active-client (slug)
  "Set SLUG as the active client for this session and return it."
  (interactive
   (list (completing-read "Set active client: "
                          (org-fractional-cto-clients) nil t)))
  (setq org-fractional-cto-active-client slug)
  (message "Active client: %s  (clear with %s)"
           slug "M-x org-fractional-cto-clear-active-client")
  slug)

;;;###autoload
(defun org-fractional-cto-clear-active-client ()
  "Clear the active client.  Captures and the dashboard will prompt again."
  (interactive)
  (setq org-fractional-cto-active-client nil)
  (message "Active client cleared."))

(defun org-fractional-cto--select-client ()
  "Return the active client slug, or prompt for one (without setting it)."
  (or org-fractional-cto-active-client
      (completing-read "Client: " (org-fractional-cto-clients) nil t)))

;;;; Sub-modules

(require 'org-fractional-cto-capture)
(require 'org-fractional-cto-agenda)
(require 'org-fractional-cto-scaffold)
(require 'org-fractional-cto-stage)
(require 'org-fractional-cto-actions)
(require 'org-fractional-cto-doc)
(require 'org-fractional-cto-people)

;;;; Top-level commands and keymap

;;;###autoload
(defun org-fractional-cto-dashboard ()
  "Open the dashboard for the active client (prompting if none is set)."
  (interactive)
  (org-agenda nil org-fractional-cto-agenda-key))

;;;###autoload
(defun org-fractional-cto-switch-client (slug)
  "Set SLUG active and open its dashboard.  Good for context switching."
  (interactive
   (list (completing-read "Switch to client: "
                          (org-fractional-cto-clients) nil t)))
  (org-fractional-cto-set-active-client slug)
  (org-fractional-cto-dashboard))

(declare-function evil-define-key* "evil-core")
(declare-function org-fractional-cto-delegate-at-point "org-fractional-cto-actions")
(declare-function org-fractional-cto-block-at-point "org-fractional-cto-actions")
(declare-function org-fractional-cto--register-people-with-org-id "org-fractional-cto-people")
(defvar org-agenda-mode-map)

(defvar org-fractional-cto-command-map
  (let ((map (make-sparse-keymap)))
    (define-key map "n" #'org-fractional-cto-new-client)
    (define-key map "s" #'org-fractional-cto-set-active-client)
    (define-key map "k" #'org-fractional-cto-clear-active-client)
    (define-key map "d" #'org-fractional-cto-dashboard)
    (define-key map "w" #'org-fractional-cto-switch-client)
    (define-key map "p" #'org-fractional-cto-new-prospect)
    (define-key map "S" #'org-fractional-cto-set-stage)
    (define-key map "g" #'org-fractional-cto-delegate-at-point)
    (define-key map "b" #'org-fractional-cto-block-at-point)
    (define-key map "h" #'org-fractional-cto-docs)
    map)
  "Keymap for `org-fractional-cto' commands.
Bound under `org-fractional-cto-keymap-prefix' by `org-fractional-cto-setup'.")

(defvar org-fractional-cto-agenda-command-map
  (let ((map (make-sparse-keymap)))
    (define-key map "g" #'org-fractional-cto-delegate-at-point)
    (define-key map "b" #'org-fractional-cto-block-at-point)
    map)
  "Keymap of org-fractional-cto at-point actions for use inside agendas.")

(defun org-fractional-cto-agenda-install-keys ()
  "Bind the at-point actions in `org-agenda-mode-map'.
Non-Evil: under `org-fractional-cto-agenda-keymap-prefix' if set.  Evil: under
the comma localleader (`, g' / `, b') in the agenda's motion state, across all
agenda buffers.  The commands no-op gracefully on non-hub entries."
  (require 'org-agenda)
  (when org-fractional-cto-agenda-keymap-prefix
    (define-key org-agenda-mode-map
                (kbd org-fractional-cto-agenda-keymap-prefix)
                org-fractional-cto-agenda-command-map))
  (with-eval-after-load 'evil
    (evil-define-key* 'motion org-agenda-mode-map
                      (kbd ", g") #'org-fractional-cto-delegate-at-point
                      (kbd ", b") #'org-fractional-cto-block-at-point)))

(defun org-fractional-cto--keyword-names (sequence)
  "Return the bare keyword names in a `org-todo-keywords' SEQUENCE.
Strips the type symbol (`sequence'/`type'), the \"|\" separator, and any
fast-access or logging cookie -- so \"WAITING(w@/!)\" yields \"WAITING\"."
  (seq-remove
   (lambda (kw) (equal kw "|"))
   (mapcar (lambda (kw) (car (split-string kw "(")))
           (cdr sequence))))

(defun org-fractional-cto--known-todo-keywords ()
  "Return every TODO keyword currently known to `org-todo-keywords'."
  (apply #'append
         (mapcar #'org-fractional-cto--keyword-names org-todo-keywords)))

(defun org-fractional-cto--install-todo-keywords ()
  "Register the workflow's TODO keywords and faces globally, non-destructively.
Each sequence in `org-fractional-cto-todo-keywords' is appended to
`org-todo-keywords' only when it introduces a keyword Org does not already
recognise, so existing definitions are never duplicated or overridden.  Missing
keyword faces from `org-fractional-cto-todo-keyword-faces' are likewise merged
into `org-todo-keyword-faces'.  Idempotent."
  (let ((known (org-fractional-cto--known-todo-keywords)))
    (dolist (sequence org-fractional-cto-todo-keywords)
      (unless (seq-every-p (lambda (kw) (member kw known))
                           (org-fractional-cto--keyword-names sequence))
        (add-to-list 'org-todo-keywords sequence t)
        (setq known (append known (org-fractional-cto--keyword-names sequence))))))
  (dolist (face org-fractional-cto-todo-keyword-faces)
    (unless (assoc (car face) org-todo-keyword-faces)
      (add-to-list 'org-todo-keyword-faces face))))

(defun org-fractional-cto--install-tag-inheritance ()
  "Enable agenda tag inheritance when `org-fractional-cto-set-tag-inheritance'.
Makes the inherited client filetag filterable in the dashboard."
  (when org-fractional-cto-set-tag-inheritance
    (setq org-agenda-use-tag-inheritance t)))

;;;###autoload
(defun org-fractional-cto-setup ()
  "Install captures, the dashboard agenda command, and key bindings.
Call once from your init file, after Org is available."
  (interactive)
  (org-fractional-cto--install-todo-keywords)
  (org-fractional-cto--install-tag-inheritance)
  (org-fractional-cto-capture-install)
  (org-fractional-cto-agenda-install)
  (org-fractional-cto-pipeline-install)
  (dolist (dir (org-fractional-cto-agenda-files))
    (add-to-list 'org-agenda-files dir t))
  (org-fractional-cto--register-people-with-org-id)
  (org-fractional-cto-agenda-install-keys)
  (when org-fractional-cto-keymap-prefix
    (global-set-key (kbd org-fractional-cto-keymap-prefix)
                    org-fractional-cto-command-map)))

(provide 'org-fractional-cto)

;;; org-fractional-cto.el ends here
