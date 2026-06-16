;;; org-fractional-cto-agenda.el --- Global client dashboard -*- lexical-binding: t; -*-

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
;; The dashboard spans ALL clients via `org-fractional-cto-agenda-files'.
;; When an active client is set, `org-agenda-tag-filter-preset' is seeded with
;; the client's tag (derived from its #+filetags) so the view opens pre-focused
;; on that client.  The CATEGORY column shows which client each entry belongs to.
;; Use the native agenda filter (`/') to widen, refocus, or clear the filter.

;;; Code:

(require 'org-agenda)
(require 'seq)

(declare-function org-fractional-cto-agenda-files "org-fractional-cto")
(declare-function org-fractional-cto-client-tag "org-fractional-cto")
(defvar org-fractional-cto-active-client)
(defvar org-fractional-cto-agenda-key)
(defvar org-fractional-cto-pipeline-key)
(defvar org-fractional-cto-pipeline-stages)
(defvar org-fractional-cto-stages)

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
           ;; Keep only real risk entries (not the section container), and drop
           ;; closed-out risks (Status: Resolved or Mitigated).
           (org-agenda-skip-function
            '(or (org-agenda-skip-entry-if 'notregexp "\\[RISK\\]")
                 (org-agenda-skip-entry-if 'regexp "^Status: \\(?:Resolved\\|Mitigated\\)")))))
    (tags "+SECURITY"
          ((org-agenda-overriding-header "Open security findings")
           (org-agenda-sorting-strategy '(priority-down deadline-up))
           ;; Keep only [SECURITY] entries, dropping closed-out findings
           ;; (Status: Resolved or Mitigated) -- same rule as risks.
           (org-agenda-skip-function
            '(or (org-agenda-skip-entry-if 'notregexp "\\[SECURITY\\]")
                 (org-agenda-skip-entry-if 'regexp "^Status: \\(?:Resolved\\|Mitigated\\)")))))
    (tags "+TECHDEBT"
          ((org-agenda-overriding-header "Open tech debt")
           ;; Show only the tech-debt entries themselves, not the container.
           (org-agenda-skip-function
            '(org-agenda-skip-entry-if 'notregexp "\\[TECH DEBT\\]"))))
    (tags "+SCOPE"
          ((org-agenda-overriding-header "Scope changes — pending decisions")
           (org-agenda-sorting-strategy '(deadline-up))
           ;; Show only SCOPE CHANGE entries, not the section container.
           (org-agenda-skip-function
            '(org-agenda-skip-entry-if 'notregexp "SCOPE CHANGE:")))))
  "Agenda blocks composing the global Fractional CTO dashboard.
A list of Org agenda series entries (see `org-agenda-custom-commands').  Each
block runs against all client files; when an active client is set the view opens
pre-filtered to that client.  Reorder, drop, or extend as you like."
  :type '(repeat sexp)
  :group 'org-fractional-cto)

(defun org-fractional-cto--active-client-filter ()
  "Return an `org-agenda-tag-filter-preset' focusing the active client, or nil.
With an active client the dashboard opens filtered to it; with none it opens
global.  Widen, refocus, or clear with the native agenda filter (\\[org-agenda-filter])."
  (when org-fractional-cto-active-client
    (list (concat "+" (org-fractional-cto-client-tag
                       org-fractional-cto-active-client)))))

;;;###autoload
(defun org-fractional-cto-agenda-install ()
  "Register (or refresh) the client dashboard custom command.
The command is bound to `org-fractional-cto-agenda-key'.
Idempotent: any existing custom command bound to that key is removed first, so
re-running picks up changes to `org-fractional-cto-dashboard-blocks' instead of
leaving a stale command behind.
The command spans all client files and, when an active client is set, opens
pre-filtered to it via `org-agenda-tag-filter-preset'; clear or change the
focus with the native agenda filter."
  (setq org-agenda-custom-commands
        (seq-remove (lambda (cmd)
                      (equal (car-safe cmd) org-fractional-cto-agenda-key))
                    org-agenda-custom-commands))
  (add-to-list
   'org-agenda-custom-commands
   `(,org-fractional-cto-agenda-key
     "Fractional CTO — client dashboard"
     ,org-fractional-cto-dashboard-blocks
     ((org-agenda-files (org-fractional-cto-agenda-files))
      (org-agenda-tag-filter-preset (org-fractional-cto--active-client-filter))))))

(defun org-fractional-cto--pipeline-skip ()
  "Agenda skip function keeping only level-1 engagement headings.
Returns nil for a top-level heading (keep) or the end of the current subtree
\(skip) for anything deeper, so inherited child entries do not clutter the view.
Skipping to the subtree end -- rather than the next heading -- jumps past the
whole branch in one step instead of re-checking every descendant."
  (when (> (or (org-current-level) 1) 1)
    (org-end-of-subtree t)))

(defun org-fractional-cto--pipeline-header ()
  "Render `org-fractional-cto-pipeline-stages' as a human funnel label.
The match expression (e.g. \"LEAD|QUALIFIED\") becomes \"Prospect pipeline
\(LEAD / QUALIFIED)\", so the header tracks the configured stages instead of
hard-coding them."
  (format "Prospect pipeline (%s)"
          (mapconcat #'identity
                     (split-string org-fractional-cto-pipeline-stages
                                   "[^A-Za-z0-9_]+" t)
                     " / ")))

(defun org-fractional-cto--pipeline-stage-rank (entry)
  "Return the funnel rank of agenda ENTRY by its stage tag.
ENTRY is an agenda line string carrying a `tags' text property.  The rank is the
index of its stage tag within `org-fractional-cto-stages', so earlier stages
sort first; an entry with no known stage sorts last."
  (let* ((tags (get-text-property 0 'tags entry))
         (stage (seq-find (lambda (s) (member s tags))
                          org-fractional-cto-stages)))
    (or (and stage (seq-position org-fractional-cto-stages stage))
        most-positive-fixnum)))

(defun org-fractional-cto--pipeline-cmp (a b)
  "Compare agenda entries A and B by funnel stage order.
Returns -1, +1, or nil so the pipeline groups every LEAD before every QUALIFIED
\(and so on, following `org-fractional-cto-stages'), turning the flat tag match
into a stage-ordered funnel.  Wired in via `org-agenda-cmp-user-defined'."
  (let ((ra (org-fractional-cto--pipeline-stage-rank a))
        (rb (org-fractional-cto--pipeline-stage-rank b)))
    (cond ((< ra rb) -1)
          ((> ra rb) +1))))

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
            ((org-agenda-overriding-header ,(org-fractional-cto--pipeline-header))
             (org-agenda-skip-function 'org-fractional-cto--pipeline-skip)
             ;; Group the funnel by stage (LEAD before QUALIFIED, …), then by
             ;; client within a stage, instead of raw file-scan order.
             (org-agenda-sorting-strategy '(user-defined-up category-up))
             (org-agenda-cmp-user-defined 'org-fractional-cto--pipeline-cmp))))
     ((org-agenda-files (org-fractional-cto-agenda-files))))))

;;;###autoload
(defun org-fractional-cto-pipeline ()
  "Open the cross-client prospect pipeline view."
  (interactive)
  (org-agenda nil org-fractional-cto-pipeline-key))

(provide 'org-fractional-cto-agenda)

;;; org-fractional-cto-agenda.el ends here
