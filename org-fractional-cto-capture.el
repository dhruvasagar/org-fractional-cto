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
(declare-function org-fractional-cto-client-standup-file "org-fractional-cto")
(declare-function org-fractional-cto--template "org-fractional-cto")
(declare-function org-fractional-cto-client-name "org-fractional-cto")

;;;; Capture-time helpers

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
    (find-file file)
    (widen)
    (goto-char (point-min))
    (unless (re-search-forward
             (concat "^\\*+ " (regexp-quote heading) "\\(?:[ \t]\\|$\\)") nil t)
      (goto-char (point-max))
      (insert (format "\n** %s\n" heading)))
    (end-of-line)))

(defun org-fractional-cto--file-contents (path)
  "Return the contents of PATH as a string, for use as a capture template.
A capture entry's template must be a literal string, a (file \"literal-path\")
form, or a (function FN) form -- there is no (file FN) form.  We therefore read
the file ourselves and hand Org the text via a (function ...) template, which
Org re-scans so the standup's %^{...}, %U and %? escapes expand normally."
  (with-temp-buffer
    (insert-file-contents path)
    (buffer-string)))

(defun org-fractional-cto--standup-template ()
  "Return the active client's standup.org contents, or the bundled fallback.
Used as a (function ...) capture template so Org re-scans and expands the
%-escapes in the returned text -- unlike a %(sexp) escape, whose result Org
would insert verbatim, leaving any nested %^{...}, %U or %? inert.

This runs before the target function (see `org-capture-get-template'), so it
selects the client itself via `org-fractional-cto--capture-client-slug' rather
than reading a slug the target has not stored yet."
  (let* ((slug (org-fractional-cto--capture-client-slug))
         (file (and slug (org-fractional-cto-client-standup-file slug))))
    (org-fractional-cto--file-contents
     (if (and file (file-exists-p file))
         file
       (org-fractional-cto--template "standup.org")))))

;;;; Template helpers

(defun org-fractional-cto--target (heading)
  "Return a capture target function that files under HEADING."
  (lambda () (org-fractional-cto--capture-to-heading heading)))

(defun org-fractional-cto--file (filename)
  "Return a capture-template thunk yielding the contents of bundled FILENAME.
Use it in the (function ...) template position; the contents are read at
capture time so Org expands the file's %-escapes."
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
     "* RESEARCH: %^{Topic} :RESEARCH:\n%U\nArea: %^{Area|Company|Market|Competitor|Tech stack|People|Funding|Other}\nSource: %^{Source / link}\n\n** Finding\n%?\n\n** Implication\n\n** Follow-up\n- [ ]\n")
    ("eF" "Fit / qualification" entry
     (function ,(org-fractional-cto--target "Qualification"))
     (function ,(org-fractional-cto--file "qualification.org"))
     :clock-in t :clock-resume t)

    ;; -- Action tracking & delegation -------------------------------------
    ("ew" "Action item" entry
     (function ,(org-fractional-cto--target "Actions"))
     "* TODO %^{Action}\nDEADLINE: %^{Due}t\n%U\n%?"
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
    ("eP" "Person / team member note" entry
     (function ,(org-fractional-cto--target "People"))
     "* %^{Name} — %^{Role / Stream} :PEOPLE:\n%U\n:PROPERTIES:\n:STREAM: %^{Stream}\n:END:\n%?")

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
     (function org-fractional-cto--standup-template)
     :clock-in t :clock-resume t)
    ("ec" "Commitment" entry
     (function ,(org-fractional-cto--target "Commitments"))
     "* TODO [COMMITMENT] %^{Commitment} :COMMITMENT:\nDEADLINE: %^{Due date}t\nOwner (internal): %^{Owner}\n%U\nContext: %a\n"
     :clock-in t :clock-resume t)
    ("ep" "Stakeholder profile" entry
     (function ,(org-fractional-cto--target "Stakeholder Profiles"))
     (function ,(org-fractional-cto--file "stakeholder.org"))
     :clock-in t :clock-resume t)
    ("eh" "Client health check" entry
     (function ,(org-fractional-cto--target "Health Checks"))
     "* CLIENT HEALTH CHECK %^{Month} %^{Year} :HEALTH:\n%U\n\n** Pulse Questions\n1. What's working well?\n2. What would you change?\n3. What would you love to see in the next 30 days?\n\n** Their Responses\n%?\n\n** Analysis\n- One thing to improve:\n- One thing to double down on:\n\n** Actions\n- [ ]\n")
    ("eM" "Metrics snapshot" entry
     (function ,(org-fractional-cto--target "Health Checks"))
     "* METRICS %^{Date|%<%Y-%m-%d>} :METRICS:\n%U\n\n** Funnel\n| Metric | Value | vs. Last Week | Notes |\n|--------+-------+---------------+-------|\n|        |       |               |       |\n\n** Observations\n%?\n\n** Actions Triggered\n- [ ]\n")
    ("eq" "QBR" entry
     (function ,(org-fractional-cto--target "QBRs"))
     (function ,(org-fractional-cto--file "qbr.org"))
     :clock-in t :clock-resume t)

    ;; -- Risk & delivery --------------------------------------------------
    ("er" "Risk" entry
     (function ,(org-fractional-cto--target "Risks"))
     "* [RISK] %^{Risk} :RISK:\n%U\nStatus: %^{Status|Open|Mitigated|Resolved|Accepted}\nLikelihood: %^{Likelihood|High|Medium|Low}\nImpact: %^{Impact|High|Medium|Low}\nOwner: %^{Owner}\nMitigation: %?\n")
    ("ee" "Scope change" entry
     (function ,(org-fractional-cto--target "Scope Changes"))
     "* SCOPE CHANGE: %^{Description} :SCOPE:\n%U\nIdentified by: %^{Who}\nSOW status: %^{Status|Out of scope|In scope|Grey area}\n\n** What Changed\n%?\n\n** Business Impact\n\n** Recommended Action\n%^{Action|Add to SOW|Decline|Defer|Investigate}\n\n** Commercial Impact\nSOW amendment needed? %^{SOW|Yes|No|TBD}\nDEADLINE: %^{Decision needed by}t\n")
    ("ef" "Post-mortem" entry
     (function ,(org-fractional-cto--target "Post-Mortems"))
     "* POST-MORTEM: %^{Incident title} :POSTMORTEM:\n%U\nDate: %^{Incident date}\nSeverity: %^{Severity|Critical|High|Medium|Low}\nAffected: %^{What was affected}\n\n** What Happened\n%?\n\n** Root Cause\n\n** How We Fixed It\n\n** Prevention\n- [ ]\n")
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
     "* DECISION: %^{Decision} :DECISION:\n%U\nMade by: %^{Who}\nContext: %^{What prompted this}\n\n** Decision\n%?\n\n** Rationale\n\n** Alternatives Rejected\n\n** Revisit if\n")
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
     "* [TECH DEBT] %^{Description} :TECHDEBT:\n%U\nArea: %^{Area|Frontend|Backend|Infrastructure|Integration|Data|Security}\nSeverity: %^{Severity|Critical|High|Medium|Low}\nDiscovered during: %^{Context}\nImpact if unaddressed: %?\n")
    ("ex" "Security finding" entry
     (function ,(org-fractional-cto--target "Security Findings"))
     "* [SECURITY] %^{Finding} :SECURITY:\n%U\nStatus: %^{Status|Open|Mitigated|Resolved|Accepted}\nSeverity: %^{Severity|Critical|High|Medium|Low}\nArea: %^{Area|PCI|GDPR|API|Auth|Data|Infrastructure}\nAction: %?\nOwner: %^{Owner}\n")

    ;; -- Innovation -------------------------------------------------------
    ("en" "Innovation idea (single)" entry
     (function ,(org-fractional-cto--target "Innovation Pipeline"))
     "* INNOVATION IDEA: %^{Title} :INNOVATION:\n%U\nCategory: %^{Category|AI/ML|Data|Platform|Integration|Other}\n\n** The Opportunity\n%?\n\n** The Technology\n\n** Why Now / Why This Client\n\n** Rough Effort\n\n** Next Step\n")
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
  (let* ((templates (org-fractional-cto-capture-templates))
         (keys (mapcar #'car templates)))
    (setq org-capture-templates
          (append
           (seq-remove (lambda (entry) (member (car-safe entry) keys))
                       org-capture-templates)
           templates))))

(provide 'org-fractional-cto-capture)

;;; org-fractional-cto-capture.el ends here
