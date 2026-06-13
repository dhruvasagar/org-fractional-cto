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
;;                      per-client workspace (operational hub, standup, context).
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
Each client lives in DIRECTORY/<slug>/ and owns <slug>.org, standup.org,
and CONTEXT.md."
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

;;;; Core state and path helpers

(defvar org-fractional-cto-active-client nil
  "Slug of the active client for this session.
When set, captures and the dashboard target this client without prompting.
Set with `org-fractional-cto-set-active-client'.")

(defun org-fractional-cto--clients-dir ()
  "Return the configured clients directory, expanded."
  (expand-file-name org-fractional-cto-clients-directory))

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

(defun org-fractional-cto-client-standup-file (slug)
  "Return the standup template file for client SLUG."
  (expand-file-name (format "%s/standup.org" slug)
                    (org-fractional-cto--clients-dir)))

(defun org-fractional-cto-client-context-file (slug)
  "Return the CONTEXT.md file for client SLUG."
  (expand-file-name (format "%s/CONTEXT.md" slug)
                    (org-fractional-cto--clients-dir)))

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

(defvar org-fractional-cto-command-map
  (let ((map (make-sparse-keymap)))
    (define-key map "n" #'org-fractional-cto-new-client)
    (define-key map "s" #'org-fractional-cto-set-active-client)
    (define-key map "k" #'org-fractional-cto-clear-active-client)
    (define-key map "d" #'org-fractional-cto-dashboard)
    (define-key map "w" #'org-fractional-cto-switch-client)
    map)
  "Keymap for `org-fractional-cto' commands.
Bound under `org-fractional-cto-keymap-prefix' by `org-fractional-cto-setup'.")

;;;###autoload
(defun org-fractional-cto-setup ()
  "Install captures, the dashboard agenda command, and key bindings.
Call once from your init file, after Org is available."
  (interactive)
  (org-fractional-cto-capture-install)
  (org-fractional-cto-agenda-install)
  (dolist (dir (org-fractional-cto-agenda-files))
    (add-to-list 'org-agenda-files dir t))
  (when org-fractional-cto-keymap-prefix
    (global-set-key (kbd org-fractional-cto-keymap-prefix)
                    org-fractional-cto-command-map)))

(provide 'org-fractional-cto)

;;; org-fractional-cto.el ends here
