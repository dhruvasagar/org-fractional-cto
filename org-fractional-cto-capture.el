;;; org-fractional-cto-capture.el --- Capture templates -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Dhruva Sagar
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; The `e' capture group.  Every template routes to a section of the active
;; client's operational hub via `org-fractional-cto--capture-to-heading', which
;; stashes the client slug, tag, and display name in the capture plist.
;; Templates auto-fill the client name via %(org-capture-get :ofc-client-name).
;; The client tag is no longer repeated in captured items; it is inherited
;; from the hub's #+filetags line instead.

;;; Code:

(require 'org-capture)
(require 'seq)

(declare-function org-fractional-cto--select-client "org-fractional-cto")
(declare-function org-fractional-cto-client-tag "org-fractional-cto")
(declare-function org-fractional-cto-client-org-file "org-fractional-cto")
(declare-function org-fractional-cto--template "org-fractional-cto")
(declare-function org-fractional-cto-client-name "org-fractional-cto")
(declare-function org-fractional-cto-client-template-file "org-fractional-cto")
(declare-function org-fractional-cto--capture-to-person "org-fractional-cto-people")
(declare-function org-fractional-cto--apply-person-tag "org-fractional-cto-people")

;;;; Capture-time helpers

(defun org-fractional-cto--goto-section (file heading)
  "Visit FILE and leave point at the end of HEADING's line.
Searches for the first `^\\*+ HEADING' line; if none exists, appends a new
`** HEADING' at end of file.  Shared by capture targeting and AI filing."
  (find-file file)
  (widen)
  (goto-char (point-min))
  (unless (re-search-forward
           (concat "^\\*+ " (regexp-quote heading) "\\(?:[ \t]\\|$\\)") nil t)
    (goto-char (point-max))
    (insert (format "\n** %s\n" heading))
    (forward-line -1))
  (end-of-line))

(defun org-fractional-cto--capture-client-slug ()
  "Return the client slug for the current capture, selecting at most once.
Memoised into the capture plist under :ofc-client-slug.  Org resolves a
\(function ...) template (e.g. the standup) via `org-capture-get-template'
BEFORE it runs the target function, so the template cannot rely on the target
having stashed the slug yet.  Routing both through this helper means whichever
runs first performs the selection, stores it, and the other reuses it -- the
user is prompted once and both agree on the same client."
  (or (org-capture-get :ofc-client-slug)
      (let ((slug (org-fractional-cto--select-client)))
        (org-capture-put :ofc-client-slug slug)
        slug)))

(defun org-fractional-cto--capture-to-heading (heading)
  "Visit HEADING in the selected client's org file, ready for capture.
Stores :ofc-client-slug, :ofc-client-tag, and :ofc-client-name in the capture
plist.  Templates should reference the client name via
%(org-capture-get :ofc-client-name); :ofc-client-tag is retained for
backward compatibility but templates must NOT embed it in headlines
(the tag lives in the hub's #+filetags instead)."
  (let* ((slug (org-fractional-cto--capture-client-slug))
         (tag  (org-fractional-cto-client-tag slug))
         (file (org-fractional-cto-client-org-file slug)))
    (org-capture-put :ofc-client-tag  tag)
    (org-capture-put :ofc-client-name (org-fractional-cto-client-name slug))
    (org-fractional-cto--goto-section file heading)))

(defun org-fractional-cto--file-contents (path)
  "Return the contents of PATH as a string, for use as a capture template.
A capture entry's template must be a literal string, a (file \"literal-path\")
form, or a (function FN) form -- there is no (file FN) form.  We therefore read
the file ourselves and hand Org the text via a (function ...) template, which
Org re-scans so the standup's %^{...}, %U and %? escapes expand normally."
  (with-temp-buffer
    (insert-file-contents path)
    (buffer-string)))

;;;; Template helpers

(defun org-fractional-cto--target (heading)
  "Return a capture target function that files under HEADING."
  (lambda () (org-fractional-cto--capture-to-heading heading)))

(defun org-fractional-cto--resolve-template-file (name)
  "Return a filesystem path for template NAME.
Prefer the active client's override at <clients-dir>/<slug>/templates/NAME;
otherwise fall back to the bundled template.  The slug is obtained (and
memoised) via `org-fractional-cto--capture-client-slug', so this works whether
it runs at template-resolution time or later."
  (let* ((slug (org-fractional-cto--capture-client-slug))
         (override (and slug (org-fractional-cto-client-template-file slug name))))
    (if (and override (file-exists-p override))
        override
      (org-fractional-cto--template name))))

(defun org-fractional-cto--file (filename)
  "Return a capture-template thunk yielding the contents of template FILENAME.
Resolves FILENAME through `org-fractional-cto--resolve-template-file' so a
per-client override under <slug>/templates/ wins over the bundled copy.  Used
in the (function ...) template position; contents are read at capture time so
Org expands the file's %-escapes."
  (lambda () (org-fractional-cto--file-contents
              (org-fractional-cto--resolve-template-file filename))))

(defun org-fractional-cto--bundled-file (filename)
  "Return a capture-template thunk yielding bundled FILENAME's contents.
Unlike `org-fractional-cto--file' this performs NO client selection or
per-client override resolution; use it for templates (e.g. person notes) that
are not scoped to a client."
  (lambda () (org-fractional-cto--file-contents
              (org-fractional-cto--template filename))))

;;;; The templates

(defun org-fractional-cto-capture-templates ()
  "Return the list of `org-capture-templates' entries for the `e' group."
  `(("e" "Engagement (select client)")

    ;; -- Pre-sales / pipeline ---------------------------------------------
    ("el" "Pre-sales call / lead intake" entry
     (function ,(org-fractional-cto--target "Pre-Sales Notes"))
     (function ,(org-fractional-cto--file "presales_call.org"))
     :clock-in t :clock-resume t)
    ("eo" "Research note" entry
     (function ,(org-fractional-cto--target "Research"))
     (function ,(org-fractional-cto--file "research.org")))
    ("eF" "Fit / qualification" entry
     (function ,(org-fractional-cto--target "Qualification"))
     (function ,(org-fractional-cto--file "qualification.org"))
     :clock-in t :clock-resume t)

    ;; -- Action tracking & delegation -------------------------------------
    ("ew" "Action item" entry
     (function ,(org-fractional-cto--target "Actions"))
     (function ,(org-fractional-cto--file "action.org"))
     :clock-in t :clock-resume t)
    ("eg" "Delegate action (WAITING)" entry
     (function ,(org-fractional-cto--target "Delegations"))
     (function ,(org-fractional-cto--file "delegation.org")))
    ("eb" "Blocker / escalation" entry
     (function ,(org-fractional-cto--target "Blockers"))
     (function ,(org-fractional-cto--file "blocker.org")))
    ("eW" "Weekly review" entry
     (function ,(org-fractional-cto--target "Weekly Reviews"))
     (function ,(org-fractional-cto--file "weekly_review.org"))
     :clock-in t :clock-resume t)
    ("eP" "Person note (global)" entry
     (function org-fractional-cto--capture-to-person)
     (function ,(org-fractional-cto--bundled-file "person_note.org")))

    ;; -- Relationship & communication -------------------------------------
    ("em" "Client meeting" entry
     (function ,(org-fractional-cto--target "Meeting Notes"))
     (function ,(org-fractional-cto--file "client_meeting.org"))
     :clock-in t :clock-resume t)
    ("ei" "Internal sync" entry
     (function ,(org-fractional-cto--target "Internal Syncs"))
     (function ,(org-fractional-cto--file "internal_sync.org"))
     :clock-in t :clock-resume t)
    ("es" "Standup" entry
     (function ,(org-fractional-cto--target "Standup Notes"))
     (function ,(org-fractional-cto--file "standup.org"))
     :clock-in t :clock-resume t)
    ("ec" "Commitment" entry
     (function ,(org-fractional-cto--target "Commitments"))
     (function ,(org-fractional-cto--file "commitment.org"))
     :clock-in t :clock-resume t)
    ("ep" "Stakeholder profile" entry
     (function ,(org-fractional-cto--target "Stakeholder Profiles"))
     (function ,(org-fractional-cto--file "stakeholder.org"))
     :clock-in t :clock-resume t)
    ("eh" "Client health check" entry
     (function ,(org-fractional-cto--target "Health Checks"))
     (function ,(org-fractional-cto--file "health_check.org")))
    ("eM" "Metrics snapshot" entry
     (function ,(org-fractional-cto--target "Health Checks"))
     (function ,(org-fractional-cto--file "metrics.org")))
    ("eq" "QBR" entry
     (function ,(org-fractional-cto--target "QBRs"))
     (function ,(org-fractional-cto--file "qbr.org"))
     :clock-in t :clock-resume t)

    ;; -- Risk & delivery --------------------------------------------------
    ("er" "Risk" entry
     (function ,(org-fractional-cto--target "Risks"))
     (function ,(org-fractional-cto--file "risk.org")))
    ("ee" "Scope change" entry
     (function ,(org-fractional-cto--target "Scope Changes"))
     (function ,(org-fractional-cto--file "scope_change.org")))
    ("ef" "Post-mortem" entry
     (function ,(org-fractional-cto--target "Post-Mortems"))
     (function ,(org-fractional-cto--file "post_mortem.org")))
    ("eR" "Retrospective" entry
     (function ,(org-fractional-cto--target "Retrospectives"))
     (function ,(org-fractional-cto--file "retrospective.org"))
     :clock-in t :clock-resume t)

    ;; -- Technical --------------------------------------------------------
    ("ed" "Discovery session" entry
     (function ,(org-fractional-cto--target "Discovery Sessions"))
     (function ,(org-fractional-cto--file "discovery.org"))
     :clock-in t :clock-resume t)
    ("ek" "Tech spike" entry
     (function ,(org-fractional-cto--target "Discovery Sessions"))
     (function ,(org-fractional-cto--file "tech_spike.org"))
     :clock-in t :clock-resume t)
    ("ea" "ADR" entry
     (function ,(org-fractional-cto--target "Architecture Decisions"))
     (function ,(org-fractional-cto--file "adr.org"))
     :clock-in t :clock-resume t)
    ("eD" "Quick decision" entry
     (function ,(org-fractional-cto--target "Architecture Decisions"))
     (function ,(org-fractional-cto--file "quick_decision.org")))
    ("eA" "Architecture review" entry
     (function ,(org-fractional-cto--target "Architecture Reviews"))
     (function ,(org-fractional-cto--file "arch_review.org"))
     :clock-in t :clock-resume t)
    ("ev" "Vendor eval" entry
     (function ,(org-fractional-cto--target "Vendor Evaluations"))
     (function ,(org-fractional-cto--file "vendor_eval.org"))
     :clock-in t :clock-resume t)
    ("et" "Tech debt item" entry
     (function ,(org-fractional-cto--target "Technical Debt"))
     (function ,(org-fractional-cto--file "tech_debt.org")))
    ("ex" "Security finding" entry
     (function ,(org-fractional-cto--target "Security Findings"))
     (function ,(org-fractional-cto--file "security.org")))

    ;; -- Innovation -------------------------------------------------------
    ("en" "Innovation idea (single)" entry
     (function ,(org-fractional-cto--target "Innovation Pipeline"))
     (function ,(org-fractional-cto--file "innovation_idea.org")))
    ("eI" "Innovation meeting" entry
     (function ,(org-fractional-cto--target "Innovation Pipeline"))
     (function ,(org-fractional-cto--file "innovation_meeting.org"))
     :clock-in t :clock-resume t)))

;;;###autoload
(defun org-fractional-cto-capture-install ()
  "Add (or refresh) the `e' engagement capture group in `org-capture-templates'.
Idempotent: any existing templates whose keys we own are removed first, so
re-running after editing the templates updates them in place rather than
leaving stale duplicates."
  (add-hook 'org-capture-before-finalize-hook
            #'org-fractional-cto--apply-person-tag)
  (let* ((templates (org-fractional-cto-capture-templates))
         (keys (mapcar #'car templates)))
    (setq org-capture-templates
          (append
           (seq-remove (lambda (entry) (member (car-safe entry) keys))
                       org-capture-templates)
           templates))))

(provide 'org-fractional-cto-capture)

;;; org-fractional-cto-capture.el ends here
