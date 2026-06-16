# Per-client capture template overrides — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make every capture template overridable per-client by resolving from a `<clients-dir>/<slug>/templates/` directory before the bundled set, populated at onboarding.

**Architecture:** One generic template resolver replaces the standup-only special case. The 13 inline-string templates are externalized to bundled `templates/*.org` files (verbatim), so all 30 templates are file-based and overridable. Onboarding copies the bundled set into each new client's `templates/`. Two-layer resolution: per-client `templates/<name>` → bundled. No legacy fallback, no existing-client migration.

**Tech Stack:** Emacs Lisp, `org-capture`, ERT. Spec: `docs/superpowers/specs/2026-06-16-per-client-template-overrides-design.md`.

---

## File Structure

- `org-fractional-cto.el` — add `org-fractional-cto-client-template-file`; remove `org-fractional-cto-client-standup-file` (last task). `--template` unchanged.
- `org-fractional-cto-capture.el` — add `--resolve-template-file`; repoint `--file` through it; delete `--standup-template`; convert all 14 inline/standup entries to `(--file …)`; fix `declare-function`s.
- `org-fractional-cto-scaffold.el` — add `--copy-templates`, call it from `--scaffold`; delete `--write-standup`; fix `declare-function`.
- `templates/` — add 13 new files: `research.org`, `action.org`, `person.org`, `commitment.org`, `health_check.org`, `metrics.org`, `risk.org`, `scope_change.org`, `post_mortem.org`, `quick_decision.org`, `tech_debt.org`, `security.org`, `innovation_idea.org`.
- `test/org-fractional-cto-capture-test.el` — rewrite standup tests onto the resolver; add resolver, onboarding-copy, and 13-file regression-snapshot tests; extend `every-file-template-exists`.
- `test/org-fractional-cto-prospect-test.el` — fix the two tests that read template bodies as strings; drop the now-dead inline-tag test.
- `README.org`, `doc/guide.org`, `doc/reference.org`, `doc/playbook.org`, `org-fractional-cto.texi` — document overrides.

**Invariant:** every task ends green (`make test`). Each task commits.

---

## Task 1: Add `client-template-file` helper

**Files:**
- Modify: `org-fractional-cto.el` (after `org-fractional-cto-client-org-file`, ~line 195)
- Test: `test/org-fractional-cto-prospect-test.el`

- [ ] **Step 1: Write the failing test**

Add to `test/org-fractional-cto-prospect-test.el` (end of file, before `(provide …)`):

```elisp
(ert-deftest ofc-client-template-file-path ()
  "client-template-file points into the client's templates/ subdir."
  (let ((org-fractional-cto-clients-directory "/tmp/ofc-x"))
    (should (equal (org-fractional-cto-client-template-file "acme" "risk.org")
                   "/tmp/ofc-x/acme/templates/risk.org"))))
```

- [ ] **Step 2: Run test to verify it fails**

Run: `make test 2>&1 | grep -E "client-template-file-path|void-function"`
Expected: FAIL — `void-function org-fractional-cto-client-template-file`.

- [ ] **Step 3: Write minimal implementation**

In `org-fractional-cto.el`, immediately after the `org-fractional-cto-client-org-file` defun (~line 195), add:

```elisp
(defun org-fractional-cto-client-template-file (slug name)
  "Return the path to per-client override template NAME for client SLUG.
NAME is a bundled template filename such as \"risk.org\"; the override lives
under DIRECTORY/<slug>/templates/."
  (expand-file-name (format "%s/templates/%s" slug name)
                    (org-fractional-cto--clients-dir)))
```

- [ ] **Step 4: Run test to verify it passes**

Run: `make test 2>&1 | grep -E "client-template-file-path|Ran .* tests"`
Expected: the test passes; total unchanged-otherwise.

- [ ] **Step 5: Commit**

```bash
git add org-fractional-cto.el test/org-fractional-cto-prospect-test.el
git commit -m "feat: add client-template-file helper for per-client overrides"
```

---

## Task 2: Add the generic resolver and route `--file` through it

**Files:**
- Modify: `org-fractional-cto-capture.el` (`--file`, ~line 95; declare-functions ~line 20-25)
- Test: `test/org-fractional-cto-capture-test.el`

- [ ] **Step 1: Write the failing test**

Add to `test/org-fractional-cto-capture-test.el` before `(provide …)`. These
use `stakeholder.org` (an existing bundled file) so the fallback path resolves
to a real file in this task; the new `risk.org` etc. only exist after Task 4:

```elisp
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `make test 2>&1 | grep -E "resolve-template|void-function"`
Expected: FAIL — `void-function org-fractional-cto--resolve-template-file`.

- [ ] **Step 3: Write minimal implementation**

In `org-fractional-cto-capture.el`, add a `declare-function` near the others
(~line 23):

```elisp
(declare-function org-fractional-cto-client-template-file "org-fractional-cto")
```

Then add the resolver in the `;;;; Template helpers` section (before `--file`,
~line 89) and repoint `--file`:

```elisp
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
```

- [ ] **Step 4: Run test to verify it passes**

Run: `make test 2>&1 | grep -E "resolve-template|unexpected"`
Expected: both new tests pass; `0 unexpected`.

- [ ] **Step 5: Commit**

```bash
git add org-fractional-cto-capture.el test/org-fractional-cto-capture-test.el
git commit -m "feat: generic per-client template resolver behind --file"
```

---

## Task 3: De-specialize standup onto the resolver

**Files:**
- Modify: `org-fractional-cto-capture.el` (delete `--standup-template` ~line 73-87; `es` entry ~line 149-152)
- Modify: `test/org-fractional-cto-capture-test.el` (replace the three `--standup-template` tests ~line 40-79)

- [ ] **Step 1: Rewrite the standup tests onto the resolver**

In `test/org-fractional-cto-capture-test.el`, replace the three tests
`ofc-standup-template-uses-per-client-file`,
`ofc-standup-template-falls-back-to-bundle`, and
`ofc-standup-template-resolves-slug-before-target` with:

```elisp
(ert-deftest ofc-standup-uses-per-client-override ()
  "The es standup template returns the client's templates/standup.org."
  (ofc-capture-test-with-client
    (let ((override (org-fractional-cto-client-template-file "acme" "standup.org")))
      (make-directory (file-name-directory override) t)
      (with-temp-file override (insert "* STANDUP CLIENT-SPECIFIC MARKER\n"))
      (let ((result (funcall (org-fractional-cto--file "standup.org"))))
        (should (string-match-p "CLIENT-SPECIFIC MARKER" result))))))

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
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `make test 2>&1 | grep -E "standup|void-function|unexpected"`
Expected: FAIL — the new `ofc-standup-entry-is-a-plain-file-template` fails
because `es` still uses `(function org-fractional-cto--standup-template)`.

- [ ] **Step 3: Delete `--standup-template` and convert the `es` entry**

In `org-fractional-cto-capture.el`, delete the entire `--standup-template`
defun (the `(defun org-fractional-cto--standup-template () … )` block, ~lines
73-87). Then change the `es` entry from:

```elisp
    ("es" "Standup" entry
     (function ,(org-fractional-cto--target "Standup Notes"))
     (function org-fractional-cto--standup-template)
     :clock-in t :clock-resume t)
```

to:

```elisp
    ("es" "Standup" entry
     (function ,(org-fractional-cto--target "Standup Notes"))
     (function ,(org-fractional-cto--file "standup.org"))
     :clock-in t :clock-resume t)
```

Also delete the now-stale `client-standup-file` `declare-function` line near
the top (`(declare-function org-fractional-cto-client-standup-file …)`, ~line
23) — the capture file no longer calls it.

- [ ] **Step 4: Run tests to verify they pass**

Run: `make test 2>&1 | grep -E "standup|unexpected|Ran "`
Expected: all standup tests pass; `0 unexpected`.

- [ ] **Step 5: Commit**

```bash
git add org-fractional-cto-capture.el test/org-fractional-cto-capture-test.el
git commit -m "refactor: standup uses the generic file resolver, no special-casing"
```

---

## Task 4: Externalize the 13 inline templates to files

This task creates 13 bundled files with content equal to the current inline
strings, converts the entries to `(--file …)`, adds a regression-snapshot
test, and fixes the two prospect tests that read bodies as strings.

**Files:**
- Create: 13 files under `templates/` (listed below)
- Modify: `org-fractional-cto-capture.el` (13 entries: `eo ew eP ec eh eM er ee ef eD et ex en`)
- Modify: `test/org-fractional-cto-capture-test.el` (add snapshot test; extend file-exists test)
- Modify: `test/org-fractional-cto-prospect-test.el` (fix 2 tests; remove 1 dead test)

- [ ] **Step 1: Write the regression-snapshot test (failing)**

Add to `test/org-fractional-cto-capture-test.el` before `(provide …)`. The
expected strings are the exact current inline templates; the test asserts each
new file's contents match, ignoring only a trailing newline:

```elisp
(defconst ofc-externalized-template-fixtures
  '(("research.org" . "* RESEARCH: %^{Topic} :RESEARCH:\n%U\nArea: %^{Area|Company|Market|Competitor|Tech stack|People|Funding|Other}\nSource: %^{Source / link}\n\n** Finding\n%?\n\n** Implication\n\n** Follow-up\n- [ ]\n")
    ("action.org" . "* TODO %^{Action}\nDEADLINE: %^{Due}t\n%U\n%?")
    ("person.org" . "* %^{Name} — %^{Role / Stream} :PEOPLE:\n%U\n:PROPERTIES:\n:STREAM: %^{Stream}\n:END:\n%?")
    ("commitment.org" . "* TODO [COMMITMENT] %^{Commitment} :COMMITMENT:\nDEADLINE: %^{Due date}t\nOwner (internal): %^{Owner}\n%U\nContext: %a\n")
    ("health_check.org" . "* CLIENT HEALTH CHECK %^{Month} %^{Year} :HEALTH:\n%U\n\n** Pulse Questions\n1. What's working well?\n2. What would you change?\n3. What would you love to see in the next 30 days?\n\n** Their Responses\n%?\n\n** Analysis\n- One thing to improve:\n- One thing to double down on:\n\n** Actions\n- [ ]\n")
    ("metrics.org" . "* METRICS %^{Date|%<%Y-%m-%d>} :METRICS:\n%U\n\n** Funnel\n| Metric | Value | vs. Last Week | Notes |\n|--------+-------+---------------+-------|\n|        |       |               |       |\n\n** Observations\n%?\n\n** Actions Triggered\n- [ ]\n")
    ("risk.org" . "* [RISK] %^{Risk} :RISK:\n%U\nStatus: %^{Status|Open|Mitigated|Resolved|Accepted}\nLikelihood: %^{Likelihood|High|Medium|Low}\nImpact: %^{Impact|High|Medium|Low}\nOwner: %^{Owner}\nMitigation: %?\n")
    ("scope_change.org" . "* SCOPE CHANGE: %^{Description} :SCOPE:\n%U\nIdentified by: %^{Who}\nSOW status: %^{Status|Out of scope|In scope|Grey area}\n\n** What Changed\n%?\n\n** Business Impact\n\n** Recommended Action\n%^{Action|Add to SOW|Decline|Defer|Investigate}\n\n** Commercial Impact\nSOW amendment needed? %^{SOW|Yes|No|TBD}\nDEADLINE: %^{Decision needed by}t\n")
    ("post_mortem.org" . "* POST-MORTEM: %^{Incident title} :POSTMORTEM:\n%U\nDate: %^{Incident date}\nSeverity: %^{Severity|Critical|High|Medium|Low}\nAffected: %^{What was affected}\n\n** What Happened\n%?\n\n** Root Cause\n\n** How We Fixed It\n\n** Prevention\n- [ ]\n")
    ("quick_decision.org" . "* DECISION: %^{Decision} :DECISION:\n%U\nMade by: %^{Who}\nContext: %^{What prompted this}\n\n** Decision\n%?\n\n** Rationale\n\n** Alternatives Rejected\n\n** Revisit if\n")
    ("tech_debt.org" . "* [TECH DEBT] %^{Description} :TECHDEBT:\n%U\nArea: %^{Area|Frontend|Backend|Infrastructure|Integration|Data|Security}\nSeverity: %^{Severity|Critical|High|Medium|Low}\nDiscovered during: %^{Context}\nImpact if unaddressed: %?\n")
    ("security.org" . "* [SECURITY] %^{Finding} :SECURITY:\n%U\nStatus: %^{Status|Open|Mitigated|Resolved|Accepted}\nSeverity: %^{Severity|Critical|High|Medium|Low}\nArea: %^{Area|PCI|GDPR|API|Auth|Data|Infrastructure}\nAction: %?\nOwner: %^{Owner}\n")
    ("innovation_idea.org" . "* INNOVATION IDEA: %^{Title} :INNOVATION:\n%U\nCategory: %^{Category|AI/ML|Data|Platform|Integration|Other}\n\n** The Opportunity\n%?\n\n** The Technology\n\n** Why Now / Why This Client\n\n** Rough Effort\n\n** Next Step\n"))
  "Each externalized template's bundled file must equal its old inline string.")

(ert-deftest ofc-externalized-templates-match-inline-source ()
  "Every externalized file reproduces its previous inline template verbatim
\(ignoring a single trailing newline)."
  (dolist (pair ofc-externalized-template-fixtures)
    (let* ((name (car pair))
           (expected (cdr pair))
           (path (org-fractional-cto--template name)))
      (should (file-exists-p path))
      (should (string= (string-trim-right expected)
                       (string-trim-right
                        (org-fractional-cto--file-contents path)))))))
```

- [ ] **Step 2: Run test to verify it fails**

Run: `make test 2>&1 | grep -E "externalized-templates-match|unexpected"`
Expected: FAIL — files do not exist yet.

- [ ] **Step 3: Create the 13 template files**

Create each file under `templates/` with content equal to the matching
fixture string (newlines real, single trailing newline). Exact contents:

`templates/research.org`:
```
* RESEARCH: %^{Topic} :RESEARCH:
%U
Area: %^{Area|Company|Market|Competitor|Tech stack|People|Funding|Other}
Source: %^{Source / link}

** Finding
%?

** Implication

** Follow-up
- [ ]
```

`templates/action.org`:
```
* TODO %^{Action}
DEADLINE: %^{Due}t
%U
%?
```

`templates/person.org`:
```
* %^{Name} — %^{Role / Stream} :PEOPLE:
%U
:PROPERTIES:
:STREAM: %^{Stream}
:END:
%?
```

`templates/commitment.org`:
```
* TODO [COMMITMENT] %^{Commitment} :COMMITMENT:
DEADLINE: %^{Due date}t
Owner (internal): %^{Owner}
%U
Context: %a
```

`templates/health_check.org`:
```
* CLIENT HEALTH CHECK %^{Month} %^{Year} :HEALTH:
%U

** Pulse Questions
1. What's working well?
2. What would you change?
3. What would you love to see in the next 30 days?

** Their Responses
%?

** Analysis
- One thing to improve:
- One thing to double down on:

** Actions
- [ ]
```

`templates/metrics.org`:
```
* METRICS %^{Date|%<%Y-%m-%d>} :METRICS:
%U

** Funnel
| Metric | Value | vs. Last Week | Notes |
|--------+-------+---------------+-------|
|        |       |               |       |

** Observations
%?

** Actions Triggered
- [ ]
```

`templates/risk.org`:
```
* [RISK] %^{Risk} :RISK:
%U
Status: %^{Status|Open|Mitigated|Resolved|Accepted}
Likelihood: %^{Likelihood|High|Medium|Low}
Impact: %^{Impact|High|Medium|Low}
Owner: %^{Owner}
Mitigation: %?
```

`templates/scope_change.org`:
```
* SCOPE CHANGE: %^{Description} :SCOPE:
%U
Identified by: %^{Who}
SOW status: %^{Status|Out of scope|In scope|Grey area}

** What Changed
%?

** Business Impact

** Recommended Action
%^{Action|Add to SOW|Decline|Defer|Investigate}

** Commercial Impact
SOW amendment needed? %^{SOW|Yes|No|TBD}
DEADLINE: %^{Decision needed by}t
```

`templates/post_mortem.org`:
```
* POST-MORTEM: %^{Incident title} :POSTMORTEM:
%U
Date: %^{Incident date}
Severity: %^{Severity|Critical|High|Medium|Low}
Affected: %^{What was affected}

** What Happened
%?

** Root Cause

** How We Fixed It

** Prevention
- [ ]
```

`templates/quick_decision.org`:
```
* DECISION: %^{Decision} :DECISION:
%U
Made by: %^{Who}
Context: %^{What prompted this}

** Decision
%?

** Rationale

** Alternatives Rejected

** Revisit if
```

`templates/tech_debt.org`:
```
* [TECH DEBT] %^{Description} :TECHDEBT:
%U
Area: %^{Area|Frontend|Backend|Infrastructure|Integration|Data|Security}
Severity: %^{Severity|Critical|High|Medium|Low}
Discovered during: %^{Context}
Impact if unaddressed: %?
```

`templates/security.org`:
```
* [SECURITY] %^{Finding} :SECURITY:
%U
Status: %^{Status|Open|Mitigated|Resolved|Accepted}
Severity: %^{Severity|Critical|High|Medium|Low}
Area: %^{Area|PCI|GDPR|API|Auth|Data|Infrastructure}
Action: %?
Owner: %^{Owner}
```

`templates/innovation_idea.org`:
```
* INNOVATION IDEA: %^{Title} :INNOVATION:
%U
Category: %^{Category|AI/ML|Data|Platform|Integration|Other}

** The Opportunity
%?

** The Technology

** Why Now / Why This Client

** Rough Effort

** Next Step
```

- [ ] **Step 4: Run snapshot test to verify it passes**

Run: `make test 2>&1 | grep -E "externalized-templates-match|unexpected"`
Expected: PASS.

- [ ] **Step 5: Convert the 13 capture entries to file templates**

In `org-fractional-cto-capture.el`, replace each inline body with a `--file`
form. The bodies stay byte-equal because the files match. Replace exactly:

```elisp
    ("eo" "Research note" entry
     (function ,(org-fractional-cto--target "Research"))
     (function ,(org-fractional-cto--file "research.org")))
```
```elisp
    ("ew" "Action item" entry
     (function ,(org-fractional-cto--target "Actions"))
     (function ,(org-fractional-cto--file "action.org"))
     :clock-in t :clock-resume t)
```
```elisp
    ("eP" "Person / team member note" entry
     (function ,(org-fractional-cto--target "People"))
     (function ,(org-fractional-cto--file "person.org")))
```
```elisp
    ("ec" "Commitment" entry
     (function ,(org-fractional-cto--target "Commitments"))
     (function ,(org-fractional-cto--file "commitment.org"))
     :clock-in t :clock-resume t)
```
```elisp
    ("eh" "Client health check" entry
     (function ,(org-fractional-cto--target "Health Checks"))
     (function ,(org-fractional-cto--file "health_check.org")))
```
```elisp
    ("eM" "Metrics snapshot" entry
     (function ,(org-fractional-cto--target "Health Checks"))
     (function ,(org-fractional-cto--file "metrics.org")))
```
```elisp
    ("er" "Risk" entry
     (function ,(org-fractional-cto--target "Risks"))
     (function ,(org-fractional-cto--file "risk.org")))
```
```elisp
    ("ee" "Scope change" entry
     (function ,(org-fractional-cto--target "Scope Changes"))
     (function ,(org-fractional-cto--file "scope_change.org")))
```
```elisp
    ("ef" "Post-mortem" entry
     (function ,(org-fractional-cto--target "Post-Mortems"))
     (function ,(org-fractional-cto--file "post_mortem.org")))
```
```elisp
    ("eD" "Quick decision" entry
     (function ,(org-fractional-cto--target "Architecture Decisions"))
     (function ,(org-fractional-cto--file "quick_decision.org")))
```
```elisp
    ("et" "Tech debt item" entry
     (function ,(org-fractional-cto--target "Technical Debt"))
     (function ,(org-fractional-cto--file "tech_debt.org")))
```
```elisp
    ("ex" "Security finding" entry
     (function ,(org-fractional-cto--target "Security Findings"))
     (function ,(org-fractional-cto--file "security.org")))
```
```elisp
    ("en" "Innovation idea (single)" entry
     (function ,(org-fractional-cto--target "Innovation Pipeline"))
     (function ,(org-fractional-cto--file "innovation_idea.org")))
```

- [ ] **Step 6: Fix the prospect tests that read bodies as strings**

In `test/org-fractional-cto-prospect-test.el`:

Replace `ofc-risk-and-security-templates-have-status-field` with a file-based
version:

```elisp
(ert-deftest ofc-risk-and-security-templates-have-status-field ()
  "Both the risk and security templates offer the same closeable Status field."
  (dolist (name '("risk.org" "security.org"))
    (let ((body (org-fractional-cto--file-contents
                 (org-fractional-cto--template name))))
      (should (string-match-p
               "Status: %\\^{Status|Open|Mitigated|Resolved|Accepted}" body)))))
```

Replace `ofc-templates-keep-type-subtags` with:

```elisp
(ert-deftest ofc-templates-keep-type-subtags ()
  "The risk template file still carries its :RISK: subtag."
  (let ((body (org-fractional-cto--file-contents
               (org-fractional-cto--template "risk.org"))))
    (should (string-match-p ":RISK:" body))))
```

Delete `ofc-inline-templates-drop-client-tag` entirely — there are no inline
string bodies left, and `ofc-file-templates-drop-client-tag` already scans
every bundled file (including the 13 new ones) for the client tag.

- [ ] **Step 7: Run the full suite**

Run: `make test 2>&1 | tail -3`
Expected: `0 unexpected`. (`ofc-file-templates-drop-client-tag` now also
covers the new files.)

- [ ] **Step 8: Commit**

```bash
git add templates/ org-fractional-cto-capture.el test/
git commit -m "refactor: externalize 13 inline capture templates to overridable files"
```

---

## Task 5: Onboarding copies the bundled templates; drop `--write-standup`

**Files:**
- Modify: `org-fractional-cto-scaffold.el` (`--scaffold` ~line 127-150; delete `--write-standup` ~line 87-98; declare-function ~line 26)
- Test: `test/org-fractional-cto-prospect-test.el`

- [ ] **Step 1: Write the failing test**

Add to `test/org-fractional-cto-prospect-test.el`:

```elisp
(ert-deftest ofc-onboarding-populates-client-templates ()
  "new-client copies every bundled template into the client's templates/ dir."
  (ofc-prospect-test-with-clients-dir
    (org-fractional-cto-new-client "Acme Corp" "acme")
    (let* ((bundled-dir (file-name-directory
                         (org-fractional-cto--template "x.org")))
           (bundled (directory-files bundled-dir nil "\\.org\\'"))
           (client-dir (org-fractional-cto-client-template-file "acme" "")))
      (should (file-directory-p client-dir))
      ;; standup.org is copied like any other template, no special handling.
      (should (member "standup.org" bundled))
      (dolist (name bundled)
        (should (file-exists-p
                 (org-fractional-cto-client-template-file "acme" name)))))))
```

- [ ] **Step 2: Run test to verify it fails**

Run: `make test 2>&1 | grep -E "onboarding-populates|unexpected"`
Expected: FAIL — `templates/` dir not created by onboarding.

- [ ] **Step 3: Add `--copy-templates`, call it, delete `--write-standup`**

In `org-fractional-cto-scaffold.el`:

(a) Replace the `--write-standup` defun (~lines 87-98) with `--copy-templates`:

```elisp
(defun org-fractional-cto--copy-templates (slug)
  "Copy every bundled template into client SLUG's templates/ directory.
Existing files are left untouched so re-running never clobbers edits.  Standup
is just one of the copied files -- it gets no special handling."
  (let* ((dest (file-name-directory
                (org-fractional-cto-client-template-file slug "x.org")))
         (src  (file-name-directory (org-fractional-cto--template "x.org"))))
    (make-directory dest t)
    (dolist (name (directory-files src nil "\\.org\\'"))
      (let ((target (expand-file-name name dest)))
        (unless (file-exists-p target)
          (copy-file (expand-file-name name src) target))))))
```

(b) In `--scaffold` (~lines 135-147), drop the `standup` binding and the
`--write-standup` call, and add the copy call. The `let*` bindings become:

```elisp
  (let* ((tag     (org-fractional-cto-client-tag slug))
         (dir     (expand-file-name slug (org-fractional-cto--clients-dir)))
         (hub     (org-fractional-cto-client-org-file slug))
         (context (org-fractional-cto-client-context-file slug)))
```

and the body that writes files becomes:

```elisp
    (make-directory dir t)
    (org-fractional-cto--write-hub hub client-name tag stage)
    (org-fractional-cto--copy-templates slug)
    (org-fractional-cto--write-context context client-name slug)
    (dolist (d (org-fractional-cto-agenda-files))
      (add-to-list 'org-agenda-files d t))
    dir))
```

(c) Update the stale `declare-function` near the top (~line 26): replace

```elisp
(declare-function org-fractional-cto-client-standup-file "org-fractional-cto")
```

with

```elisp
(declare-function org-fractional-cto-client-template-file "org-fractional-cto")
(declare-function org-fractional-cto--template "org-fractional-cto")
```

- [ ] **Step 4: Run test to verify it passes**

Run: `make test 2>&1 | grep -E "onboarding-populates|unexpected"`
Expected: PASS; `0 unexpected`.

- [ ] **Step 5: Commit**

```bash
git add org-fractional-cto-scaffold.el test/org-fractional-cto-prospect-test.el
git commit -m "feat: onboarding populates per-client templates/; drop --write-standup"
```

---

## Task 6: Remove the obsolete `client-standup-file`

**Files:**
- Modify: `org-fractional-cto.el` (delete `org-fractional-cto-client-standup-file` ~line 197-200)

- [ ] **Step 1: Confirm no references remain**

Run: `grep -rn "client-standup-file" org-fractional-cto*.el test/`
Expected: only the defun in `org-fractional-cto.el` (all callers migrated in
Tasks 3 and 5). If any other reference appears, update it to
`org-fractional-cto-client-template-file SLUG "standup.org"` before deleting.

- [ ] **Step 2: Delete the defun**

In `org-fractional-cto.el`, remove:

```elisp
(defun org-fractional-cto-client-standup-file (slug)
  "Return the standup template file for client SLUG."
  (expand-file-name (format "%s/standup.org" slug)
                    (org-fractional-cto--clients-dir)))
```

- [ ] **Step 3: Run the full suite + byte-compile**

Run: `make test 2>&1 | tail -3`
Expected: `0 unexpected`.

Run: `emacs -Q --batch -L . -f batch-byte-compile org-fractional-cto.el org-fractional-cto-capture.el org-fractional-cto-scaffold.el 2>&1; rm -f *.elc`
Expected: no `reference to free variable` / `not known to be defined` warnings
for the changed symbols.

- [ ] **Step 4: Commit**

```bash
git add org-fractional-cto.el
git commit -m "refactor: remove obsolete client-standup-file helper"
```

---

## Task 7: Documentation

**Files:**
- Modify: `README.org`, `doc/guide.org`, `doc/reference.org`, `doc/playbook.org`
- Regenerate: `org-fractional-cto.texi`

- [ ] **Step 1: Find where templates/onboarding are documented**

Run:
```bash
grep -rn "standup\|template\|onboard\|new-client\|new-prospect" README.org doc/guide.org doc/reference.org doc/playbook.org
```
Read the matching sections to place the new content consistently with existing
prose and tables.

- [ ] **Step 2: Add a "Per-client template overrides" subsection**

In `doc/guide.org` (near onboarding) and `doc/reference.org` (near the capture
reference), add prose covering:
- Each client owns `<slug>/templates/<name>.org`; onboarding copies the full
  bundled set there.
- Capture resolves per-client `templates/<name>` first, else the bundled
  template. No legacy fallback.
- To customize a template for a client, edit its file under
  `<slug>/templates/`.
- Existing clients (pre-feature) keep using bundled templates; to adopt
  overrides, move any edited `<slug>/standup.org` to
  `<slug>/templates/standup.org` and copy other bundled templates in as needed.
- The `templates/` subdir is not scanned by the agenda (Org lists agenda
  directories non-recursively).

In `README.org` and `doc/playbook.org`, add a short pointer to the above with
the resolution order.

- [ ] **Step 3: Regenerate the manual**

Run: `make info`
Expected: exit 0; `org-fractional-cto.texi` rewritten.

- [ ] **Step 4: Run the full suite once more**

Run: `make test 2>&1 | tail -3`
Expected: `0 unexpected`.

- [ ] **Step 5: Commit**

```bash
git add README.org doc/ org-fractional-cto.texi
git commit -m "docs: document per-client template overrides"
```

---

## Self-Review notes (already reconciled into tasks above)

- **Spec coverage:** resolver (Task 2), standup de-specialized (Task 3), all 13
  inline externalized incl. `innovation_idea.org` (Task 4), onboarding copy +
  `--write-standup` removal (Task 5), `client-standup-file` removed (Task 6),
  docs + texi (Task 7). No legacy fallback / no migration (by omission, per
  spec). `upgrade-hub` untouched (per spec).
- **Broken-test coverage:** the three `--standup-template` tests (Task 3), and
  the two string-body prospect tests plus the dead inline-tag test (Task 4) are
  all explicitly rewritten/removed.
- **Type/name consistency:** `org-fractional-cto-client-template-file (slug
  name)`, `org-fractional-cto--resolve-template-file (name)`,
  `org-fractional-cto--copy-templates (slug)` are used consistently across
  tasks.
- **Green-at-every-commit:** Task 2's resolver tests use the existing
  `stakeholder.org` so they pass before any new files exist; the `risk.org`
  bundled file only becomes required in Task 4.
