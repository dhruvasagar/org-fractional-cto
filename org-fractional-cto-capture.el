;;; org-fractional-cto-capture.el --- Capture templates -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Dhruva Sagar
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; The `e' capture group.  Every template routes to a section of the active
;; client's operational hub via `org-fractional-cto--capture-to-heading', which
;; also stashes the client slug and tag in the capture plist so templates can
;; interpolate the client tag with %(org-capture-get :ofc-client-tag).

;;; Code:

(require 'org-capture)
(require 'seq)

(declare-function org-fractional-cto--select-client "org-fractional-cto")
(declare-function org-fractional-cto-client-tag "org-fractional-cto")
(declare-function org-fractional-cto-client-org-file "org-fractional-cto")
(declare-function org-fractional-cto-client-standup-file "org-fractional-cto")
(declare-function org-fractional-cto--template "org-fractional-cto")

;;;; Capture-time helpers

(defun org-fractional-cto--capture-to-heading (heading)
  "Visit HEADING in the selected client's org file, ready for capture.
Stores :ofc-client-slug and :ofc-client-tag in the capture plist so templates
can reference them via %(org-capture-get :ofc-client-tag)."
  (let* ((slug (org-fractional-cto--select-client))
         (tag  (org-fractional-cto-client-tag slug))
         (file (org-fractional-cto-client-org-file slug)))
    (org-capture-put :ofc-client-slug slug)
    (org-capture-put :ofc-client-tag  tag)
    (find-file file)
    (widen)
    (goto-char (point-min))
    (unless (re-search-forward
             (concat "^\\*+ " (regexp-quote heading) "\\(?:[ \t]\\|$\\)") nil t)
      (goto-char (point-max))
      (insert (format "\n** %s\n" heading)))
    (end-of-line)))

(defun org-fractional-cto--standup-file ()
  "Return the active client's standup.org path, or the bundled fallback.
Used as the file thunk for the standup capture so Org reads it as a template
and expands its %-escapes.  Returning the file *contents* via a %(sexp) escape
would leave any nested %^{...}, %U, %? in the standup inert (Org does not
re-scan the result of a %(sexp) expansion)."
  (let* ((slug (org-capture-get :ofc-client-slug))
         (file (and slug (org-fractional-cto-client-standup-file slug))))
    (if (and file (file-exists-p file))
        file
      (org-fractional-cto--template "standup.org"))))

;;;; Template helpers

(defun org-fractional-cto--target (heading)
  "Return a capture target function that files under HEADING."
  (lambda () (org-fractional-cto--capture-to-heading heading)))

(defun org-fractional-cto--file (filename)
  "Return a capture template-file thunk resolving to FILENAME."
  (lambda () (org-fractional-cto--template filename)))

;;;; The templates

(defun org-fractional-cto-capture-templates ()
  "Return the list of `org-capture-templates' entries for the `e' group."
  `(("e" "Engagement (select client)")

    ;; -- Action tracking & delegation -------------------------------------
    ("ew" "Action item" entry
     (function ,(org-fractional-cto--target "Actions"))
     "* TODO %^{Action} :%(org-capture-get :ofc-client-tag):\nDEADLINE: %^{Due}t\n%U\n%?"
     :clock-in t :clock-resume t)
    ("eg" "Delegate action (WAITING)" entry
     (function ,(org-fractional-cto--target "Delegations"))
     (file ,(org-fractional-cto--file "delegation.org")))
    ("eb" "Blocker / escalation" entry
     (function ,(org-fractional-cto--target "Blockers"))
     (file ,(org-fractional-cto--file "blocker.org")))
    ("eW" "Weekly review" entry
     (function ,(org-fractional-cto--target "Weekly Reviews"))
     (file ,(org-fractional-cto--file "weekly_review.org"))
     :clock-in t :clock-resume t)
    ("eP" "Person / team member note" entry
     (function ,(org-fractional-cto--target "People"))
     "* %^{Name} — %^{Role / Stream} :%(org-capture-get :ofc-client-tag):PEOPLE:\n%U\n:PROPERTIES:\n:STREAM: %^{Stream}\n:END:\n%?")

    ;; -- Relationship & communication -------------------------------------
    ("em" "Client meeting" entry
     (function ,(org-fractional-cto--target "Meeting Notes"))
     (file ,(org-fractional-cto--file "client_meeting.org"))
     :clock-in t :clock-resume t)
    ("ei" "Internal sync" entry
     (function ,(org-fractional-cto--target "Internal Syncs"))
     (file ,(org-fractional-cto--file "internal_sync.org"))
     :clock-in t :clock-resume t)
    ("es" "Standup" entry
     (function ,(org-fractional-cto--target "Standup Notes"))
     (file org-fractional-cto--standup-file)
     :clock-in t :clock-resume t)
    ("ec" "Commitment" entry
     (function ,(org-fractional-cto--target "Commitments"))
     "* TODO [COMMITMENT] %^{Commitment} :%(org-capture-get :ofc-client-tag):COMMITMENT:\nDEADLINE: %^{Due date}t\nOwner (internal): %^{Owner}\n%U\nContext: %a\n"
     :clock-in t :clock-resume t)
    ("ep" "Stakeholder profile" entry
     (function ,(org-fractional-cto--target "Stakeholder Profiles"))
     (file ,(org-fractional-cto--file "stakeholder.org"))
     :clock-in t :clock-resume t)
    ("eh" "Client health check" entry
     (function ,(org-fractional-cto--target "Health Checks"))
     "* CLIENT HEALTH CHECK %^{Month} %^{Year} :%(org-capture-get :ofc-client-tag):HEALTH:\n%U\n\n** Pulse Questions\n1. What's working well?\n2. What would you change?\n3. What would you love to see in the next 30 days?\n\n** Their Responses\n%?\n\n** Analysis\n- One thing to improve:\n- One thing to double down on:\n\n** Actions\n- [ ]\n")
    ("eM" "Metrics snapshot" entry
     (function ,(org-fractional-cto--target "Health Checks"))
     "* METRICS %^{Date|%<%Y-%m-%d>} :%(org-capture-get :ofc-client-tag):METRICS:\n%U\n\n** Funnel\n| Metric | Value | vs. Last Week | Notes |\n|--------+-------+---------------+-------|\n|        |       |               |       |\n\n** Observations\n%?\n\n** Actions Triggered\n- [ ]\n")
    ("eq" "QBR" entry
     (function ,(org-fractional-cto--target "QBRs"))
     (file ,(org-fractional-cto--file "qbr.org"))
     :clock-in t :clock-resume t)

    ;; -- Risk & delivery --------------------------------------------------
    ("er" "Risk" entry
     (function ,(org-fractional-cto--target "Risks"))
     "* [RISK] %^{Risk} :%(org-capture-get :ofc-client-tag):RISK:\n%U\nLikelihood: %^{Likelihood|High|Medium|Low}\nImpact: %^{Impact|High|Medium|Low}\nOwner: %^{Owner}\nMitigation: %?\n")
    ("ee" "Scope change" entry
     (function ,(org-fractional-cto--target "Scope Changes"))
     "* SCOPE CHANGE: %^{Description} :%(org-capture-get :ofc-client-tag):SCOPE:\n%U\nIdentified by: %^{Who}\nSOW status: %^{Status|Out of scope|In scope|Grey area}\n\n** What Changed\n%?\n\n** Business Impact\n\n** Recommended Action\n%^{Action|Add to SOW|Decline|Defer|Investigate}\n\n** Commercial Impact\nSOW amendment needed? %^{SOW|Yes|No|TBD}\nDEADLINE: %^{Decision needed by}t\n")
    ("ef" "Post-mortem" entry
     (function ,(org-fractional-cto--target "Post-Mortems"))
     "* POST-MORTEM: %^{Incident title} :%(org-capture-get :ofc-client-tag):POSTMORTEM:\n%U\nDate: %^{Incident date}\nSeverity: %^{Severity|Critical|High|Medium|Low}\nAffected: %^{What was affected}\n\n** What Happened\n%?\n\n** Root Cause\n\n** How We Fixed It\n\n** Prevention\n- [ ]\n")
    ("eR" "Retrospective" entry
     (function ,(org-fractional-cto--target "Retrospectives"))
     (file ,(org-fractional-cto--file "retrospective.org"))
     :clock-in t :clock-resume t)

    ;; -- Technical --------------------------------------------------------
    ("ed" "Discovery session" entry
     (function ,(org-fractional-cto--target "Discovery Sessions"))
     (file ,(org-fractional-cto--file "discovery.org"))
     :clock-in t :clock-resume t)
    ("ek" "Tech spike" entry
     (function ,(org-fractional-cto--target "Discovery Sessions"))
     (file ,(org-fractional-cto--file "tech_spike.org"))
     :clock-in t :clock-resume t)
    ("ea" "ADR" entry
     (function ,(org-fractional-cto--target "Architecture Decisions"))
     (file ,(org-fractional-cto--file "adr.org"))
     :clock-in t :clock-resume t)
    ("eD" "Quick decision" entry
     (function ,(org-fractional-cto--target "Architecture Decisions"))
     "* DECISION: %^{Decision} :%(org-capture-get :ofc-client-tag):DECISION:\n%U\nMade by: %^{Who}\nContext: %^{What prompted this}\n\n** Decision\n%?\n\n** Rationale\n\n** Alternatives Rejected\n\n** Revisit if\n")
    ("eA" "Architecture review" entry
     (function ,(org-fractional-cto--target "Architecture Reviews"))
     (file ,(org-fractional-cto--file "arch_review.org"))
     :clock-in t :clock-resume t)
    ("ev" "Vendor eval" entry
     (function ,(org-fractional-cto--target "Vendor Evaluations"))
     (file ,(org-fractional-cto--file "vendor_eval.org"))
     :clock-in t :clock-resume t)
    ("et" "Tech debt item" entry
     (function ,(org-fractional-cto--target "Technical Debt"))
     "* [TECH DEBT] %^{Description} :%(org-capture-get :ofc-client-tag):TECHDEBT:\n%U\nArea: %^{Area|Frontend|Backend|Infrastructure|Integration|Data|Security}\nSeverity: %^{Severity|Critical|High|Medium|Low}\nDiscovered during: %^{Context}\nImpact if unaddressed: %?\n")
    ("ex" "Security finding" entry
     (function ,(org-fractional-cto--target "Security Findings"))
     "* [SECURITY] %^{Finding} :%(org-capture-get :ofc-client-tag):SECURITY:\n%U\nSeverity: %^{Severity|Critical|High|Medium|Low}\nArea: %^{Area|PCI|GDPR|API|Auth|Data|Infrastructure}\nStatus: %^{Status|Open|Mitigated|Accepted}\nAction: %?\nOwner: %^{Owner}\n")

    ;; -- Innovation -------------------------------------------------------
    ("en" "Innovation idea (single)" entry
     (function ,(org-fractional-cto--target "Innovation Pipeline"))
     "* INNOVATION IDEA: %^{Title} :%(org-capture-get :ofc-client-tag):INNOVATION:\n%U\nCategory: %^{Category|AI/ML|Data|Platform|Integration|Other}\n\n** The Opportunity\n%?\n\n** The Technology\n\n** Why Now / Why This Client\n\n** Rough Effort\n\n** Next Step\n")
    ("eI" "Innovation meeting" entry
     (function ,(org-fractional-cto--target "Innovation Pipeline"))
     (file ,(org-fractional-cto--file "innovation_meeting.org"))
     :clock-in t :clock-resume t)))

;;;###autoload
(defun org-fractional-cto-capture-install ()
  "Add (or refresh) the `e' engagement capture group in `org-capture-templates'.
Idempotent: any existing templates whose keys we own are removed first, so
re-running after editing the templates updates them in place rather than
leaving stale duplicates."
  (let* ((templates (org-fractional-cto-capture-templates))
         (keys (mapcar #'car templates)))
    (setq org-capture-templates
          (append
           (seq-remove (lambda (entry) (member (car-safe entry) keys))
                       org-capture-templates)
           templates))))

(provide 'org-fractional-cto-capture)

;;; org-fractional-cto-capture.el ends here
