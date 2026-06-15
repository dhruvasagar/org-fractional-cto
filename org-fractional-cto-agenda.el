;;; org-fractional-cto-agenda.el --- Per-client dashboard -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Dhruva Sagar
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; The client dashboard is a first-class Org agenda custom command registered
;; under `org-fractional-cto-agenda-key' (default "E", reached with `C-c a E').
;;
;; Being a real agenda command -- rather than a bespoke function calling
;; `org-agenda' -- means it inherits everything the dispatcher provides:
;; appears in the `C-c a' menu, exportable, filterable with `/', refreshable
;; with `r', sticky-agenda aware, and so on.
;;
;; It stays per-client by computing `org-agenda-files' at run time from the
;; active client (prompting if none is set): the block general-settings form
;; `(org-agenda-files (org-fractional-cto--dashboard-files))' is evaluated each
;; time the command runs.

;;; Code:

(require 'org-agenda)
(require 'seq)

(declare-function org-fractional-cto--select-client "org-fractional-cto")
(declare-function org-fractional-cto-client-org-file "org-fractional-cto")
(declare-function org-fractional-cto-agenda-files "org-fractional-cto")
(defvar org-fractional-cto-agenda-key)
(defvar org-fractional-cto-pipeline-key)
(defvar org-fractional-cto-pipeline-stages)

(defcustom org-fractional-cto-dashboard-blocks
  '((agenda ""
            ((org-agenda-span 7)
             (org-agenda-overriding-header "Next 7 days")))
    (todo "WAITING"
          ((org-agenda-overriding-header "Delegated — awaiting response")
           (org-agenda-sorting-strategy '(deadline-up priority-down))))
    (tags-todo "BLOCKER"
               ((org-agenda-overriding-header "Blockers & escalations")
                (org-agenda-sorting-strategy '(priority-down deadline-up))))
    (tags-todo "-BLOCKER-COMMITMENT/!TODO|NEXT|INPROGRESS"
               ((org-agenda-overriding-header "Open actions")
                (org-agenda-sorting-strategy '(priority-down deadline-up))))
    (tags-todo "COMMITMENT"
               ((org-agenda-overriding-header "Commitments")
                (org-agenda-sorting-strategy '(deadline-up))))
    (tags "+RISK"
          ((org-agenda-overriding-header "Active risks")
           ;; Show only the risk entries themselves, not the section container.
           (org-agenda-skip-function '(org-agenda-skip-entry-if 'notregexp "\\[RISK\\]")))))
  "Agenda blocks composing the per-client dashboard.
A list of Org agenda series entries (see `org-agenda-custom-commands').  Each
block runs against the active client's file only; reorder, drop, or extend as
you like."
  :type '(repeat sexp)
  :group 'org-fractional-cto)

(defun org-fractional-cto--dashboard-files ()
  "Return the active client's org file as a one-element list.
Prompts for a client when none is active.  Evaluated each time the dashboard
command runs, which is what keeps the view per-client."
  (list (org-fractional-cto-client-org-file
         (org-fractional-cto--select-client))))

;;;###autoload
(defun org-fractional-cto-agenda-install ()
  "Register (or refresh) the client dashboard custom command.
The command is bound to `org-fractional-cto-agenda-key'.
Idempotent: any existing custom command bound to that key is removed first, so
re-running picks up changes to `org-fractional-cto-dashboard-blocks' instead of
leaving a stale command behind."
  (setq org-agenda-custom-commands
        (seq-remove (lambda (cmd)
                      (equal (car-safe cmd) org-fractional-cto-agenda-key))
                    org-agenda-custom-commands))
  (add-to-list
   'org-agenda-custom-commands
   `(,org-fractional-cto-agenda-key
     "Fractional CTO — client dashboard"
     ,org-fractional-cto-dashboard-blocks
     ((org-agenda-files (org-fractional-cto--dashboard-files))))))

(defun org-fractional-cto--pipeline-skip ()
  "Agenda skip function keeping only level-1 engagement headings.
Returns nil for a top-level heading (keep) or the position of the next heading
\(skip) for anything deeper, so inherited child entries do not clutter the view."
  (when (> (or (org-current-level) 1) 1)
    (or (outline-next-heading) (point-max))))

;;;###autoload
(defun org-fractional-cto-pipeline-install ()
  "Register (or refresh) the cross-client prospect pipeline custom command.
Bound to `org-fractional-cto-pipeline-key'.  Idempotent."
  (setq org-agenda-custom-commands
        (seq-remove (lambda (cmd)
                      (equal (car-safe cmd) org-fractional-cto-pipeline-key))
                    org-agenda-custom-commands))
  (add-to-list
   'org-agenda-custom-commands
   `(,org-fractional-cto-pipeline-key
     "Fractional CTO — prospect pipeline"
     ((tags ,org-fractional-cto-pipeline-stages
            ((org-agenda-overriding-header "Prospect pipeline (LEAD / QUALIFIED)")
             (org-agenda-skip-function 'org-fractional-cto--pipeline-skip))))
     ((org-agenda-files (org-fractional-cto-agenda-files))))))

;;;###autoload
(defun org-fractional-cto-pipeline ()
  "Open the cross-client prospect pipeline view."
  (interactive)
  (org-agenda nil org-fractional-cto-pipeline-key))

(provide 'org-fractional-cto-agenda)

;;; org-fractional-cto-agenda.el ends here
