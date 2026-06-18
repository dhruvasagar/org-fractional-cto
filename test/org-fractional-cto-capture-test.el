;;; org-fractional-cto-capture-test.el --- Tests for capture templates -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Dhruva Sagar
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; ERT tests for the `e' capture group: the generic per-client template
;; resolver, the client-slug memoisation, and the standup capture (now just a
;; plain file template).  Run with: make test
;;
;; Resolution: a per-client <slug>/templates/<name> override wins over the
;; bundled template.  Org resolves a (function ...) template via
;; `org-capture-get-template' BEFORE it runs the target function, so the
;; resolver selects the client itself via `org-fractional-cto--capture-client-slug'
;; rather than reading a slug the target has not stashed yet.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'org-capture)
(require 'org-fractional-cto)
(require 'org-fractional-cto-capture)

(defmacro ofc-capture-test-with-client (&rest body)
  "Run BODY with a throwaway clients dir holding a scaffolded acme client.
Binds a clean capture plist and clears any active client / session state."
  (declare (indent 0) (debug t))
  `(let* ((org-fractional-cto-clients-directory (make-temp-file "ofc-capture" t))
          (org-fractional-cto-active-client "acme")
          (org-capture-plist nil)
          (dir (expand-file-name "acme" org-fractional-cto-clients-directory)))
     (unwind-protect
         (progn
           (make-directory dir t)
           ,@body)
       (delete-directory org-fractional-cto-clients-directory t))))

(ert-deftest ofc-standup-uses-per-client-override ()
  "The es standup template returns the client's templates/standup.org.
Calls the --file thunk with an empty capture plist, mirroring Org's order
\(template resolved before the target stores the slug), so this also guards
that the thunk resolves lazily at call time rather than at definition time."
  (ofc-capture-test-with-client
    (should (null (org-capture-get :ofc-client-slug)))
    (let ((override (org-fractional-cto-client-template-file "acme" "standup.org")))
      (make-directory (file-name-directory override) t)
      (with-temp-file override (insert "* STANDUP CLIENT-SPECIFIC MARKER\n"))
      (let ((result (funcall (org-fractional-cto--file "standup.org"))))
        (should (string-match-p "CLIENT-SPECIFIC MARKER" result))
        (should (equal (org-capture-get :ofc-client-slug) "acme"))))))

(ert-deftest ofc-standup-falls-back-to-bundle ()
  "With no override, the es standup template uses the bundled standup.org."
  (ofc-capture-test-with-client
    (let ((result (funcall (org-fractional-cto--file "standup.org")))
          (bundled (org-fractional-cto--file-contents
                    (org-fractional-cto--template "standup.org"))))
      (should (string= result bundled)))))

(ert-deftest ofc-standup-entry-is-a-plain-file-template ()
  "The es entry resolves like any other file template (no special function)."
  (let* ((templates (org-fractional-cto-capture-templates))
         (entry (seq-find (lambda (tpl) (equal (car-safe tpl) "es")) templates))
         (template-form (nth 4 entry)))
    ;; (function <thunk>) where the thunk is the --file closure, not the old
    ;; named org-fractional-cto--standup-template symbol.
    (should (eq (car template-form) 'function))
    (should (functionp (cadr template-form)))
    (should-not (eq (cadr template-form) 'org-fractional-cto--standup-template))))

(ert-deftest ofc-capture-client-slug-memoises ()
  "The slug helper selects once and reuses the stored value thereafter."
  (ofc-capture-test-with-client
    (should (equal (org-fractional-cto--capture-client-slug) "acme"))
    ;; Change the active client; the memoised plist value must win so the
    ;; template and target agree within a single capture.
    (let ((org-fractional-cto-active-client "other"))
      (should (equal (org-fractional-cto--capture-client-slug) "acme")))))

(ert-deftest ofc-capture-client-slug-prompts-when-no-active-client ()
  "With no active client, the slug helper prompts via `completing-read'.
The selection is also memoised so it happens only once per capture."
  (ofc-capture-test-with-client
    (let ((org-fractional-cto-active-client nil)
          (prompts 0))
      (cl-letf (((symbol-function 'completing-read)
                 (lambda (&rest _) (cl-incf prompts) "acme")))
        ;; First resolution prompts...
        (should (equal (org-fractional-cto--capture-client-slug) "acme"))
        (should (= prompts 1))
        ;; ...and the second reuses the memoised value (no extra prompt),
        ;; so template + target across one capture prompt the user once.
        (should (equal (org-fractional-cto--capture-client-slug) "acme"))
        (should (= prompts 1))))))

;;;; Audit: file/string templates that embed the client name

(ert-deftest ofc-every-file-template-exists ()
  "Every (function ... --file FN) capture template points at a real file.
Guards against a template entry referencing a bundled file that was renamed
or removed."
  (dolist (filename '("adr.org" "arch_review.org" "blocker.org"
                      "client_meeting.org" "delegation.org" "discovery.org"
                      "innovation_meeting.org" "internal_sync.org"
                      "presales_call.org" "qbr.org" "qualification.org"
                      "retrospective.org" "stakeholder.org" "standup.org"
                      "tech_spike.org" "vendor_eval.org" "weekly_review.org"
                      "research.org" "action.org" "person.org" "commitment.org"
                      "health_check.org" "metrics.org" "risk.org"
                      "scope_change.org" "post_mortem.org" "quick_decision.org"
                      "tech_debt.org" "security.org" "innovation_idea.org"))
    (should (file-exists-p (org-fractional-cto--template filename)))))

(ert-deftest ofc-client-name-fills-after-target-runs ()
  "%(org-capture-get :ofc-client-name) resolves to the client display name.
Unlike the standup's file-selection decision (made when the template function
runs, before the target), a %(...) escape is evaluated by
`org-capture-fill-template' AFTER the target has stored :ofc-client-name --
so the meeting/ADR/etc. templates that print the client name are safe.  This
pins that ordering down with a prompt-free template."
  (ofc-capture-test-with-client
    ;; Give the hub a #+title so the display name differs from the slug.
    (with-temp-file (org-fractional-cto-client-org-file "acme")
      (insert "#+title: Acme Corp\n#+filetags: :ACME:\n\n* Acme Corp Engagement\n** Meeting Notes\n"))
    (let ((tmpl "* MEETING %(org-capture-get :ofc-client-name)\n"))
      ;; Template is resolved first (here it is a literal string); then the
      ;; target runs and stores the client name...
      (funcall (org-fractional-cto--target "Meeting Notes"))
      (should (equal (org-capture-get :ofc-client-name) "Acme Corp"))
      ;; ...and only now does the %(...) escape get evaluated.
      (let ((filled (org-capture-fill-template tmpl)))
        (should (string-match-p "MEETING Acme Corp" filled))))))

(ert-deftest ofc-resolve-template-prefers-client-override ()
  "The resolver returns the client's templates/<name> when it exists."
  (ofc-capture-test-with-client
    (let ((override (org-fractional-cto-client-template-file "acme" "stakeholder.org")))
      (make-directory (file-name-directory override) t)
      (with-temp-file override (insert "* OVERRIDDEN STAKEHOLDER\n"))
      (should (equal (org-fractional-cto--resolve-template-file "stakeholder.org")
                     override)))))

(ert-deftest ofc-resolve-template-falls-back-to-bundled ()
  "With no client override, the resolver returns the bundled path."
  (ofc-capture-test-with-client
    (should (equal (org-fractional-cto--resolve-template-file "stakeholder.org")
                   (org-fractional-cto--template "stakeholder.org")))))

(defconst ofc-externalized-template-fixtures
  '(("research.org" . "* RESEARCH: %^{Topic} :RESEARCH:\n%U\nArea: %^{Area|Company|Market|Competitor|Tech stack|People|Funding|Other}\nSource: %^{Source / link}\n\n** Finding\n%?\n\n** Implication\n\n** Follow-up\n- [ ]\n")
    ("action.org" . "* TODO %^{Action}\nDEADLINE: %^{Due}t\n%U\n%?\n")
    ("person.org" . ":PROPERTIES:\n:ID:       %ID%\n:END:\n#+title: %NAME%\n#+filetags: :PERSON:\n\n- Role / title:\n- Organisation:\n- Side: Our team | Client | Vendor | External\n- Contact (email · phone):\n- Socials (LinkedIn · X · GitHub · website):\n- Photo:\n\n* About\n\n* Notes / History\n")
    ("commitment.org" . "* TODO [COMMITMENT] %^{Commitment} :COMMITMENT:\nDEADLINE: %^{Due date}t\nOwner (internal): %(org-fractional-cto--capture-person \"Owner\" t)\n%U\nContext: %a\n")
    ("health_check.org" . "* CLIENT HEALTH CHECK %^{Month} %^{Year} :HEALTH:\n%U\n\n** Pulse Questions\n1. What's working well?\n2. What would you change?\n3. What would you love to see in the next 30 days?\n\n** Their Responses\n%?\n\n** Analysis\n- One thing to improve:\n- One thing to double down on:\n\n** Actions\n- [ ]\n")
    ("metrics.org" . "* METRICS %^{Date|%<%Y-%m-%d>} :METRICS:\n%U\n\n** Funnel\n| Metric | Value | vs. Last Week | Notes |\n|--------+-------+---------------+-------|\n|        |       |               |       |\n\n** Observations\n%?\n\n** Actions Triggered\n- [ ]\n")
    ("risk.org" . "* [RISK] %^{Risk} :RISK:\n%U\nStatus: %^{Status|Open|Mitigated|Resolved|Accepted}\nLikelihood: %^{Likelihood|High|Medium|Low}\nImpact: %^{Impact|High|Medium|Low}\nOwner: %(org-fractional-cto--capture-person \"Owner\" t)\nMitigation: %?\n")
    ("scope_change.org" . "* SCOPE CHANGE: %^{Description} :SCOPE:\n%U\nIdentified by: %(org-fractional-cto--capture-person \"Identified by\")\nSOW status: %^{Status|Out of scope|In scope|Grey area}\n\n** What Changed\n%?\n\n** Business Impact\n\n** Recommended Action\n%^{Action|Add to SOW|Decline|Defer|Investigate}\n\n** Commercial Impact\nSOW amendment needed? %^{SOW|Yes|No|TBD}\nDEADLINE: %^{Decision needed by}t\n")
    ("post_mortem.org" . "* POST-MORTEM: %^{Incident title} :POSTMORTEM:\n%U\nDate: %^{Incident date}\nSeverity: %^{Severity|Critical|High|Medium|Low}\nAffected: %^{What was affected}\n\n** What Happened\n%?\n\n** Root Cause\n\n** How We Fixed It\n\n** Prevention\n- [ ]\n")
    ("quick_decision.org" . "* DECISION: %^{Decision} :DECISION:\n%U\nMade by: %(org-fractional-cto--capture-person \"Made by\")\nContext: %^{What prompted this}\n\n** Decision\n%?\n\n** Rationale\n\n** Alternatives Rejected\n\n** Revisit if\n")
    ("tech_debt.org" . "* [TECH DEBT] %^{Description} :TECHDEBT:\n%U\nArea: %^{Area|Frontend|Backend|Infrastructure|Integration|Data|Security}\nSeverity: %^{Severity|Critical|High|Medium|Low}\nDiscovered during: %^{Context}\nImpact if unaddressed: %?\n")
    ("security.org" . "* [SECURITY] %^{Finding} :SECURITY:\n%U\nStatus: %^{Status|Open|Mitigated|Resolved|Accepted}\nSeverity: %^{Severity|Critical|High|Medium|Low}\nArea: %^{Area|PCI|GDPR|API|Auth|Data|Infrastructure}\nAction: %?\nOwner: %(org-fractional-cto--capture-person \"Owner\" t)\n")
    ("innovation_idea.org" . "* INNOVATION IDEA: %^{Title} :INNOVATION:\n%U\nCategory: %^{Category|AI/ML|Data|Platform|Integration|Other}\n\n** The Opportunity\n%?\n\n** The Technology\n\n** Why Now / Why This Client\n\n** Rough Effort\n\n** Next Step\n"))
  "Each externalized template's bundled file must equal its old inline string.")

(ert-deftest ofc-externalized-templates-match-inline-source ()
  "Every externalized file reproduces its previous inline template verbatim.
The bundled file must equal the old inline string plus exactly one trailing
newline (the two templates whose inline form lacked one have it appended in
the fixtures, so every bundled template ends in exactly one newline)."
  (dolist (pair ofc-externalized-template-fixtures)
    (let* ((name (car pair))
           (expected (cdr pair))
           (path (org-fractional-cto--template name)))
      (should (file-exists-p path))
      (should (string= expected (org-fractional-cto--file-contents path))))))

(ert-deftest ofc-clock-in-templates-cursor-in-top-entry ()
  "Clock-in capture templates place %? in the top entry, before any sub-heading,
so Org clocks the entry's main heading rather than a sub-heading."
  ;; The 15 templates whose capture entry carries `:clock-in t'.  When a new
  ;; clock-in template is added, extend this list so its %? placement is guarded.
  (dolist (name '("presales_call.org" "qualification.org" "weekly_review.org"
                  "client_meeting.org" "internal_sync.org" "standup.org"
                  "stakeholder.org" "qbr.org" "retrospective.org"
                  "discovery.org" "tech_spike.org" "adr.org"
                  "arch_review.org" "vendor_eval.org" "innovation_meeting.org"))
    (let* ((body (org-fractional-cto--file-contents
                  (org-fractional-cto--template name)))
           (cursor (string-match "%\\?" body))
           (subheading (string-match "^\\*\\*+ " body)))
      (should cursor)
      (should subheading)
      (should (< cursor subheading)))))

(ert-deftest ofc-resolve-template-falls-back-with-no-active-client ()
  "With no active client and no override on disk, the resolver returns the
bundled template (after a single client selection prompt)."
  (ofc-capture-test-with-client
    (let ((org-fractional-cto-active-client nil))
      (cl-letf (((symbol-function 'completing-read) (lambda (&rest _) "acme")))
        (should (equal (org-fractional-cto--resolve-template-file "stakeholder.org")
                       (org-fractional-cto--template "stakeholder.org")))))))

(ert-deftest ofc-person-capture-targets-person-and-bundled-note ()
  "eP routes to the person target and a bundled (client-free) note template."
  (let* ((templates (org-fractional-cto-capture-templates))
         (entry (seq-find (lambda (tpl) (equal (car-safe tpl) "eP")) templates))
         (target (nth 3 entry))
         (template-form (nth 4 entry)))
    (should (eq (car target) 'function))
    (should (eq (cadr target) 'org-fractional-cto--capture-to-person))
    (should (eq (car template-form) 'function))
    (should (functionp (cadr template-form)))))

(ert-deftest ofc-stakeholder-template-has-person-link-line ()
  "The bundled stakeholder template prompts for a link to the global person."
  (let ((text (org-fractional-cto--file-contents
               (org-fractional-cto--template "stakeholder.org"))))
    (should (string-match-p "^Person (global node):" text))))

(ert-deftest ofc-owner-templates-use-tagging-person-helper ()
  "Each single-owner template invokes the person helper with the tag flag."
  (dolist (name '("delegation.org" "blocker.org" "commitment.org"
                  "risk.org" "security.org"))
    (let ((text (org-fractional-cto--file-contents
                 (org-fractional-cto--template name))))
      (should (string-match-p
               "%(org-fractional-cto--capture-person \"[^\"]+\" t)" text)))))

(ert-deftest ofc-attendee-templates-use-people-helper ()
  "Attendee fields invoke the multi-person link helper."
  (dolist (name '("client_meeting.org" "discovery.org" "qbr.org"
                  "retrospective.org" "innovation_meeting.org" "presales_call.org"))
    (let ((text (org-fractional-cto--file-contents
                 (org-fractional-cto--template name))))
      (should (string-match-p "%(org-fractional-cto--capture-people " text)))))

(ert-deftest ofc-authorship-templates-use-untagged-person-helper ()
  "Authorship fields invoke the single-person helper WITHOUT the tag flag."
  (dolist (name '("arch_review.org" "vendor_eval.org"
                  "quick_decision.org" "scope_change.org"))
    (let ((text (org-fractional-cto--file-contents
                 (org-fractional-cto--template name))))
      ;; present, and not the tagging form (no trailing ` t)`)
      (should (string-match-p "%(org-fractional-cto--capture-person \"[^\"]+\")" text))
      (should-not (string-match-p
                   "%(org-fractional-cto--capture-person \"[^\"]+\" t)" text)))))

(provide 'org-fractional-cto-capture-test)

;;; org-fractional-cto-capture-test.el ends here
