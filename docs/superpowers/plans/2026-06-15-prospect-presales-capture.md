# Pre-Sales / Prospect Capture Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let the operator capture and track a prospect from the first pre-sales call through qualification and conversion, reusing the existing client hub and dashboard, with engagement stage carried as a tag.

**Architecture:** A prospect *is* a client from day one (same directory/hub/dashboard). A single stage tag (`LEAD`/`QUALIFIED`/`ACTIVE`/`LOST`/`DORMANT`) on the level-1 engagement heading distinguishes funnel position. Three new canonical hub sections (Pre-Sales Notes, Research, Qualification) and three new captures (`el`/`eo`/`eF`) cover the pre-sales stage; a cross-client pipeline agenda view surfaces the funnel. The deep engagement discovery (`ed`) is untouched.

**Tech Stack:** Emacs Lisp, Org mode (org-capture, org-agenda), ERT for tests, batch `emacs -Q` via `make test`/`make info`.

---

## Reference: design

Spec: `docs/superpowers/specs/2026-06-15-prospect-presales-capture-design.md`. Read it before starting.

## File Structure

| File | Responsibility | Change |
|------|----------------|--------|
| `org-fractional-cto.el` | core config, state, keymap, setup | add stage/pipeline defcustoms; require stage module; keymap `p`/`S`; install pipeline in `setup` |
| `org-fractional-cto-scaffold.el` | onboarding | append 3 sections; stage-aware `--write-hub`; extract `--scaffold` + `--read-name-and-slug`; `new-prospect` |
| `org-fractional-cto-stage.el` | **new** — stage lifecycle | `set-stage`, `upgrade-hub`, engagement-heading helpers |
| `org-fractional-cto-capture.el` | capture templates | add `el`/`eo`/`eF` |
| `org-fractional-cto-agenda.el` | agenda views | pipeline custom command + install + skip fn |
| `templates/presales_call.org` | **new** — `el` body | file template |
| `templates/qualification.org` | **new** — `eF` body | file template |
| `test/org-fractional-cto-prospect-test.el` | **new** — ERT suite | all tests below |
| `Makefile` | test runner | load the new test file |
| `doc/{guide,reference,playbook}.org`, `org-fractional-cto.texi` | docs | document the feature, regenerate manual |

**Conventions to follow (from the existing code):**
- Every section heading and capture is tagged *explicitly* with the client tag; do not rely on inheritance for the client tag. The stage tag is the one exception — it lives only on the engagement heading and inherits.
- File-based capture templates resolve via `org-fractional-cto--file` / `org-fractional-cto--template`.
- Install functions are idempotent (remove-then-add by key).
- Tests drive interactive commands by passing arguments directly; never simulate `org-capture`.

---

## Task 1: Add pre-sales sections + test harness

**Files:**
- Modify: `org-fractional-cto-scaffold.el` (the `org-fractional-cto-sections` defconst)
- Modify: `Makefile` (test target)
- Create: `test/org-fractional-cto-prospect-test.el`

- [ ] **Step 1: Create the test file with fixtures and the first failing tests**

Create `test/org-fractional-cto-prospect-test.el`:

```elisp
;;; org-fractional-cto-prospect-test.el --- Tests for pre-sales / prospect capture -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Dhruva Sagar
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; ERT tests for prospect onboarding, engagement stage tags, hub upgrade,
;; pre-sales captures, and the pipeline view.  Run with: make test

;;; Code:

(require 'ert)
(require 'org-fractional-cto)

(defmacro ofc-prospect-test-with-clients-dir (&rest body)
  "Run BODY with a throwaway clients directory and clean session state."
  (declare (indent 0) (debug t))
  `(let* ((org-fractional-cto-clients-directory (make-temp-file "ofc-clients" t))
          (org-fractional-cto-active-client nil)
          (org-agenda-files (copy-sequence org-agenda-files)))
     (unwind-protect
         (progn ,@body)
       (dolist (buf (buffer-list))
         (when (and (buffer-file-name buf)
                    (string-prefix-p
                     (expand-file-name org-fractional-cto-clients-directory)
                     (expand-file-name (buffer-file-name buf))))
           (with-current-buffer buf (set-buffer-modified-p nil))
           (kill-buffer buf)))
       (delete-directory org-fractional-cto-clients-directory t))))

(ert-deftest ofc-sections-include-presales-sections ()
  (should (equal (cadr (assoc "Pre-Sales Notes" org-fractional-cto-sections))
                 "PRESALES"))
  (should (equal (cadr (assoc "Research" org-fractional-cto-sections))
                 "RESEARCH"))
  (should (equal (cadr (assoc "Qualification" org-fractional-cto-sections))
                 "QUALIFICATION")))

(ert-deftest ofc-new-client-hub-has-presales-sections ()
  (ofc-prospect-test-with-clients-dir
    (org-fractional-cto-new-client "Acme Corp" "acme")
    (find-file (org-fractional-cto-client-org-file "acme"))
    (goto-char (point-min))
    (should (re-search-forward "^\\*\\* Pre-Sales Notes .*:PRESALES:" nil t))
    (should (re-search-forward "^\\*\\* Research .*:RESEARCH:" nil t))
    (should (re-search-forward "^\\*\\* Qualification .*:QUALIFICATION:" nil t))))

(provide 'org-fractional-cto-prospect-test)

;;; org-fractional-cto-prospect-test.el ends here
```

- [ ] **Step 2: Wire the test file into the Makefile**

In `Makefile`, change the `test` target to load both test files:

```make
.PHONY: test
test:
	$(EMACS) -Q --batch -L . \
	  -l test/org-fractional-cto-actions-test.el \
	  -l test/org-fractional-cto-prospect-test.el \
	  -f ert-run-tests-batch-and-exit
```

- [ ] **Step 3: Run the new tests to verify they fail**

Run: `make test 2>&1 | tail -20`
Expected: `ofc-sections-include-presales-sections` and `ofc-new-client-hub-has-presales-sections` FAIL (sections not present).

- [ ] **Step 4: Add the three sections**

In `org-fractional-cto-scaffold.el`, in the `org-fractional-cto-sections` defconst, add three entries immediately after the `("Retrospectives" "RETRO")` line (before the closing `)` of the list):

```elisp
    ("Retrospectives"         "RETRO")
    ("Pre-Sales Notes"        "PRESALES")
    ("Research"               "RESEARCH")
    ("Qualification"          "QUALIFICATION"))
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `make test 2>&1 | tail -20`
Expected: both new tests PASS; all existing tests still PASS.

- [ ] **Step 6: Commit**

```bash
git add org-fractional-cto-scaffold.el Makefile test/org-fractional-cto-prospect-test.el
git commit -m "feat: add pre-sales/research/qualification hub sections"
```

---

## Task 2: Stage constants + stage-aware scaffolding

**Files:**
- Modify: `org-fractional-cto.el` (Customization section)
- Modify: `org-fractional-cto-scaffold.el` (`--write-hub`, extract `--scaffold` and `--read-name-and-slug`, rewrite `new-client`)
- Test: `test/org-fractional-cto-prospect-test.el`

- [ ] **Step 1: Write the failing test**

Append to `test/org-fractional-cto-prospect-test.el` (before the `(provide …)` line):

```elisp
(ert-deftest ofc-new-client-engagement-is-active ()
  (ofc-prospect-test-with-clients-dir
    (org-fractional-cto-new-client "Acme Corp" "acme")
    (find-file (org-fractional-cto-client-org-file "acme"))
    (goto-char (point-min))
    (org-mode)
    (re-search-forward "^\\* Acme Corp Engagement")
    (org-back-to-heading t)
    (should (member "ACTIVE" (org-get-tags nil t)))
    (should (member "ACME" (org-get-tags nil t)))))
```

- [ ] **Step 2: Run to verify it fails**

Run: `make test 2>&1 | grep -A3 ofc-new-client-engagement-is-active`
Expected: FAIL — engagement heading has only `:ACME:`, no `ACTIVE` tag.

- [ ] **Step 3: Add stage/pipeline defcustoms to core**

In `org-fractional-cto.el`, immediately after the `org-fractional-cto-keymap-prefix` defcustom (the last one before the `;;;; Core state and path helpers` comment), add:

```elisp
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
```

- [ ] **Step 4: Make `--write-hub` stage-aware**

In `org-fractional-cto-scaffold.el`, replace the whole `org-fractional-cto--write-hub` defun with:

```elisp
(defun org-fractional-cto--write-hub (file client-name tag stage)
  "Write the operational hub FILE for CLIENT-NAME tagged TAG at STAGE.
STAGE is a string from `org-fractional-cto-stages' placed on the engagement
heading alongside TAG."
  (with-temp-file file
    (insert (format "#+title: %s\n" client-name))
    (insert (format "#+AUTHOR: %s\n" org-fractional-cto-author))
    (insert "#+STARTUP: overview\n")
    (insert "#+TODO: TODO NEXT INPROGRESS WAITING | DONE CANCELLED\n")
    (insert "#+OPTIONS: date:nil\n\n")
    (insert (format "* %s Engagement  :%s:%s:\n" client-name tag stage))
    (insert (format ":PROPERTIES:\n:ID:       %s-OPS\n:CATEGORY: %s\n:END:\n\n"
                    tag client-name))
    (insert "See [[file:CONTEXT.md][CONTEXT.md]] for domain vocabulary, key people, and priorities.\n\n")
    (dolist (section org-fractional-cto-sections)
      (let ((heading (car section)) (subtag (cadr section)))
        (if (string-empty-p subtag)
            (insert (format "** %s  :%s:\n\n" heading tag))
          (insert (format "** %s  :%s:%s:\n\n" heading tag subtag)))))))
```

- [ ] **Step 5: Extract `--read-name-and-slug` and `--scaffold`, rewrite `new-client`**

In `org-fractional-cto-scaffold.el`, add these two declarations near the top with the other `declare-function` lines:

```elisp
(declare-function org-fractional-cto-set-active-client "org-fractional-cto")
(defvar org-fractional-cto-default-stage)
(defvar org-fractional-cto-lead-stage)
```

Then replace the entire `org-fractional-cto-new-client` defun with the following three definitions:

```elisp
(defun org-fractional-cto--read-name-and-slug ()
  "Prompt for a client display name and slug; return the list (NAME SLUG)."
  (let* ((name (read-string "Client name (display): "))
         (slug (read-string "Client slug (lowercase, no spaces): "
                            (replace-regexp-in-string
                             "[^a-z0-9]" "_" (downcase name)))))
    (list name slug)))

(defun org-fractional-cto--scaffold (client-name slug stage)
  "Create the on-disk workspace for CLIENT-NAME under SLUG at STAGE.
Writes the hub, standup, and CONTEXT.md, registers the directory with
`org-agenda-files', and returns the client directory."
  (when (string-empty-p (string-trim slug))
    (user-error "Client slug must not be empty"))
  (let* ((tag     (org-fractional-cto-client-tag slug))
         (dir     (expand-file-name slug (org-fractional-cto--clients-dir)))
         (hub     (org-fractional-cto-client-org-file slug))
         (standup (org-fractional-cto-client-standup-file slug))
         (context (org-fractional-cto-client-context-file slug)))
    (when (and (file-exists-p dir)
               (not (yes-or-no-p
                     (format "Client '%s' already exists.  Continue? " slug))))
      (user-error "Aborted"))
    (make-directory dir t)
    (org-fractional-cto--write-hub hub client-name tag stage)
    (org-fractional-cto--write-standup standup tag)
    (org-fractional-cto--write-context context client-name slug)
    (dolist (d (org-fractional-cto-agenda-files))
      (add-to-list 'org-agenda-files d t))
    dir))

;;;###autoload
(defun org-fractional-cto-new-client (client-name slug)
  "Scaffold a new ACTIVE engagement for CLIENT-NAME under SLUG.
Creates the client directory with its operational hub, standup template, and
CONTEXT.md, then opens CONTEXT.md for editing."
  (interactive (org-fractional-cto--read-name-and-slug))
  (org-fractional-cto--scaffold client-name slug org-fractional-cto-default-stage)
  (find-file (org-fractional-cto-client-context-file slug))
  (message "Engagement '%s' created.  Fill in CONTEXT.md, then M-x org-fractional-cto-set-active-client."
           client-name))
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `make test 2>&1 | tail -20`
Expected: `ofc-new-client-engagement-is-active` PASS; all prior tests still PASS.

- [ ] **Step 7: Commit**

```bash
git add org-fractional-cto.el org-fractional-cto-scaffold.el test/org-fractional-cto-prospect-test.el
git commit -m "feat: stamp engagement stage tag on scaffolded hubs"
```

---

## Task 3: `new-prospect` command

**Files:**
- Modify: `org-fractional-cto-scaffold.el`
- Test: `test/org-fractional-cto-prospect-test.el`

- [ ] **Step 1: Write the failing test**

Append to `test/org-fractional-cto-prospect-test.el`:

```elisp
(ert-deftest ofc-new-prospect-engagement-is-lead ()
  (ofc-prospect-test-with-clients-dir
    (org-fractional-cto-new-prospect "Beta Co" "beta")
    (should (equal org-fractional-cto-active-client "beta"))
    (find-file (org-fractional-cto-client-org-file "beta"))
    (goto-char (point-min))
    (org-mode)
    (re-search-forward "^\\* Beta Co Engagement")
    (org-back-to-heading t)
    (should (member "LEAD" (org-get-tags nil t)))))
```

- [ ] **Step 2: Run to verify it fails**

Run: `make test 2>&1 | grep -A3 ofc-new-prospect-engagement-is-lead`
Expected: FAIL — `org-fractional-cto-new-prospect` is void.

- [ ] **Step 3: Add `new-prospect`**

In `org-fractional-cto-scaffold.el`, add immediately after the `org-fractional-cto-new-client` defun:

```elisp
;;;###autoload
(defun org-fractional-cto-new-prospect (client-name slug)
  "Scaffold a new LEAD-stage prospect for CLIENT-NAME under SLUG.
Identical to `org-fractional-cto-new-client' but starts at the LEAD stage,
sets the prospect active, and (called interactively) opens the pre-sales call
capture so the first conversation is recorded immediately."
  (interactive (org-fractional-cto--read-name-and-slug))
  (org-fractional-cto--scaffold client-name slug org-fractional-cto-lead-stage)
  (org-fractional-cto-set-active-client slug)
  (if (called-interactively-p 'any)
      (org-capture nil "el")
    slug))
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `make test 2>&1 | tail -20`
Expected: `ofc-new-prospect-engagement-is-lead` PASS; all prior tests still PASS.

- [ ] **Step 5: Commit**

```bash
git add org-fractional-cto-scaffold.el test/org-fractional-cto-prospect-test.el
git commit -m "feat: add org-fractional-cto-new-prospect"
```

---

## Task 4: Stage module — `set-stage`

**Files:**
- Create: `org-fractional-cto-stage.el`
- Modify: `org-fractional-cto.el` (require the new module)
- Test: `test/org-fractional-cto-prospect-test.el`

- [ ] **Step 1: Write the failing tests**

Append to `test/org-fractional-cto-prospect-test.el`:

```elisp
(ert-deftest ofc-set-stage-replaces-stage-tag ()
  (ofc-prospect-test-with-clients-dir
    (org-fractional-cto-new-client "Acme Corp" "acme")
    (setq org-fractional-cto-active-client "acme")
    (org-fractional-cto-set-stage "QUALIFIED")
    (find-file (org-fractional-cto-client-org-file "acme"))
    (goto-char (point-min))
    (org-mode)
    (re-search-forward "^\\* Acme Corp Engagement")
    (org-back-to-heading t)
    (should (member "QUALIFIED" (org-get-tags nil t)))
    (should-not (member "ACTIVE" (org-get-tags nil t)))
    (should (member "ACME" (org-get-tags nil t)))))

(ert-deftest ofc-set-stage-rejects-unknown ()
  (ofc-prospect-test-with-clients-dir
    (org-fractional-cto-new-client "Acme Corp" "acme")
    (setq org-fractional-cto-active-client "acme")
    (should-error (org-fractional-cto-set-stage "BOGUS") :type 'user-error)))
```

- [ ] **Step 2: Run to verify they fail**

Run: `make test 2>&1 | grep -A3 ofc-set-stage`
Expected: FAIL — `org-fractional-cto-set-stage` is void.

- [ ] **Step 3: Create the stage module**

Create `org-fractional-cto-stage.el`:

```elisp
;;; org-fractional-cto-stage.el --- Engagement stage lifecycle -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Dhruva Sagar
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Engagement stage is a single tag (from `org-fractional-cto-stages') on the
;; level-1 engagement heading of a client hub.  `org-fractional-cto-set-stage'
;; switches it; `org-fractional-cto-upgrade-hub' brings a pre-existing hub up to
;; the current section list and gives it a stage tag if it lacks one.

;;; Code:

(require 'org)
(require 'seq)
(require 'subr-x)

(declare-function org-fractional-cto--select-client "org-fractional-cto")
(declare-function org-fractional-cto-client-org-file "org-fractional-cto")
(defvar org-fractional-cto-stages)
(defvar org-fractional-cto-default-stage)
(defvar org-fractional-cto-sections)

(defun org-fractional-cto--goto-engagement-heading ()
  "Move point to the first level-1 heading (the engagement heading).
Signal a `user-error' if the buffer has no top-level heading."
  (widen)
  (goto-char (point-min))
  (unless (re-search-forward "^\\* " nil t)
    (user-error "No engagement heading in %s"
                (or (buffer-file-name) (buffer-name))))
  (org-back-to-heading t))

(defun org-fractional-cto--engagement-client-tag ()
  "Return the non-stage tag on the engagement heading at point, or nil."
  (car (seq-remove (lambda (tag) (member tag org-fractional-cto-stages))
                   (org-get-tags nil t))))

;;;###autoload
(defun org-fractional-cto-set-stage (stage)
  "Set the engagement STAGE tag on the active client's hub.
Removes any existing stage in `org-fractional-cto-stages' and adds STAGE,
leaving the client tag and any other tags untouched."
  (interactive
   (list (completing-read "Stage: " org-fractional-cto-stages nil t)))
  (unless (member stage org-fractional-cto-stages)
    (user-error "Unknown stage: %s" stage))
  (with-current-buffer (find-file-noselect
                        (org-fractional-cto-client-org-file
                         (org-fractional-cto--select-client)))
    (save-excursion
      (org-fractional-cto--goto-engagement-heading)
      (let ((tags (seq-remove (lambda (tag) (member tag org-fractional-cto-stages))
                              (org-get-tags nil t))))
        (org-set-tags (cons stage tags))))
    (save-buffer))
  (message "Stage set to %s" stage))

(provide 'org-fractional-cto-stage)

;;; org-fractional-cto-stage.el ends here
```

- [ ] **Step 4: Require the stage module from core**

In `org-fractional-cto.el`, in the `;;;; Sub-modules` section, add the require after `org-fractional-cto-scaffold`:

```elisp
(require 'org-fractional-cto-capture)
(require 'org-fractional-cto-agenda)
(require 'org-fractional-cto-scaffold)
(require 'org-fractional-cto-stage)
(require 'org-fractional-cto-actions)
(require 'org-fractional-cto-doc)
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `make test 2>&1 | tail -20`
Expected: both `ofc-set-stage-*` tests PASS; all prior tests still PASS.

- [ ] **Step 6: Commit**

```bash
git add org-fractional-cto-stage.el org-fractional-cto.el test/org-fractional-cto-prospect-test.el
git commit -m "feat: add org-fractional-cto-set-stage"
```

---

## Task 5: Stage module — `upgrade-hub`

**Files:**
- Modify: `org-fractional-cto-stage.el`
- Test: `test/org-fractional-cto-prospect-test.el`

- [ ] **Step 1: Write the failing tests**

Append to `test/org-fractional-cto-prospect-test.el`:

```elisp
(ert-deftest ofc-upgrade-hub-adds-stage-and-sections ()
  (ofc-prospect-test-with-clients-dir
    (let* ((dir (expand-file-name "legacy" org-fractional-cto-clients-directory))
           (hub (org-fractional-cto-client-org-file "legacy")))
      (make-directory dir t)
      (with-temp-file hub
        (insert "#+TODO: TODO NEXT INPROGRESS WAITING | DONE CANCELLED\n\n"
                "* Legacy Engagement  :LEGACY:\n"
                "** Actions  :LEGACY:\n"))
      (setq org-fractional-cto-active-client "legacy")
      (org-fractional-cto-upgrade-hub)
      (find-file hub)
      (goto-char (point-min))
      (org-mode)
      (re-search-forward "^\\* Legacy Engagement")
      (org-back-to-heading t)
      (should (member "ACTIVE" (org-get-tags nil t)))
      (goto-char (point-min))
      (should (re-search-forward "^\\*\\* Pre-Sales Notes .*:LEGACY:PRESALES:" nil t))
      (goto-char (point-min))
      (should (re-search-forward "^\\*\\* Qualification .*:LEGACY:QUALIFICATION:" nil t)))))

(ert-deftest ofc-upgrade-hub-is-idempotent ()
  (ofc-prospect-test-with-clients-dir
    (let* ((dir (expand-file-name "legacy" org-fractional-cto-clients-directory))
           (hub (org-fractional-cto-client-org-file "legacy")))
      (make-directory dir t)
      (with-temp-file hub
        (insert "* Legacy Engagement  :LEGACY:\n** Actions  :LEGACY:\n"))
      (setq org-fractional-cto-active-client "legacy")
      (org-fractional-cto-upgrade-hub)
      (org-fractional-cto-upgrade-hub)
      (find-file hub)
      (goto-char (point-min))
      (org-mode)
      (let ((count 0))
        (while (re-search-forward "^\\*\\* Pre-Sales Notes" nil t)
          (setq count (1+ count)))
        (should (= count 1))))))
```

- [ ] **Step 2: Run to verify they fail**

Run: `make test 2>&1 | grep -A3 ofc-upgrade-hub`
Expected: FAIL — `org-fractional-cto-upgrade-hub` is void.

- [ ] **Step 3: Add `upgrade-hub` and helpers**

In `org-fractional-cto-stage.el`, add immediately before the `(provide 'org-fractional-cto-stage)` line:

```elisp
(defun org-fractional-cto--ensure-stage-tag ()
  "Add the default stage tag to the engagement heading if it lacks one."
  (save-excursion
    (org-fractional-cto--goto-engagement-heading)
    (let ((tags (org-get-tags nil t)))
      (unless (seq-some (lambda (tag) (member tag org-fractional-cto-stages)) tags)
        (org-set-tags (cons org-fractional-cto-default-stage tags))))))

(defun org-fractional-cto--ensure-sections ()
  "Append any `org-fractional-cto-sections' headings missing from the buffer.
Appended sections carry the engagement heading's client tag."
  (let ((client-tag (save-excursion
                      (org-fractional-cto--goto-engagement-heading)
                      (org-fractional-cto--engagement-client-tag))))
    (dolist (section org-fractional-cto-sections)
      (let ((heading (car section)) (subtag (cadr section)))
        (goto-char (point-min))
        (unless (re-search-forward
                 (concat "^\\*+ " (regexp-quote heading) "\\(?:[ \t]\\|$\\)") nil t)
          (goto-char (point-max))
          (unless (bolp) (insert "\n"))
          (if (string-empty-p subtag)
              (insert (format "** %s  :%s:\n\n" heading client-tag))
            (insert (format "** %s  :%s:%s:\n\n" heading client-tag subtag))))))))

;;;###autoload
(defun org-fractional-cto-upgrade-hub ()
  "Bring the active client's hub up to date.
Ensures the engagement heading carries a stage tag (defaulting to
`org-fractional-cto-default-stage') and appends any sections from
`org-fractional-cto-sections' that are missing.  Idempotent."
  (interactive)
  (with-current-buffer (find-file-noselect
                        (org-fractional-cto-client-org-file
                         (org-fractional-cto--select-client)))
    (org-fractional-cto--ensure-stage-tag)
    (org-fractional-cto--ensure-sections)
    (save-buffer))
  (message "Hub upgraded."))
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `make test 2>&1 | tail -20`
Expected: both `ofc-upgrade-hub-*` tests PASS; all prior tests still PASS.

- [ ] **Step 5: Commit**

```bash
git add org-fractional-cto-stage.el test/org-fractional-cto-prospect-test.el
git commit -m "feat: add idempotent org-fractional-cto-upgrade-hub"
```

---

## Task 6: Pre-sales captures (`el`, `eo`, `eF`)

**Files:**
- Create: `templates/presales_call.org`
- Create: `templates/qualification.org`
- Modify: `org-fractional-cto-capture.el`
- Test: `test/org-fractional-cto-prospect-test.el`

- [ ] **Step 1: Write the failing tests**

Append to `test/org-fractional-cto-prospect-test.el`:

```elisp
(ert-deftest ofc-capture-templates-include-presales ()
  (let* ((templates (org-fractional-cto-capture-templates))
         (keys (mapcar #'car templates)))
    (should (member "el" keys))
    (should (member "eo" keys))
    (should (member "eF" keys))))

(ert-deftest ofc-presales-template-files-exist ()
  (should (file-exists-p (org-fractional-cto--template "presales_call.org")))
  (should (file-exists-p (org-fractional-cto--template "qualification.org"))))
```

- [ ] **Step 2: Run to verify they fail**

Run: `make test 2>&1 | grep -A3 ofc-capture-templates-include-presales`
Expected: FAIL — keys `el`/`eo`/`eF` not registered; template files missing.

- [ ] **Step 3: Create `templates/presales_call.org`**

```org
* PRE-SALES CALL: %^{Company / contact}  :%(org-capture-get :ofc-client-tag):PRESALES:
%U
Source / referral: %^{How did this come in}
Attendees: %^{Who was on the call}

** The Ask
(What are they actually asking for? In their words.)
%?

** Pain Points / Triggers
(What's driving this now? What hurts today?)
-

** Current State (as heard)
- Team / org shape:
- Tech hints:
- What exists today:

** Signals
- Budget: %^{Budget signal|Strong|Some|Unclear|None}
- Timeline: %^{Timeline|Urgent|This quarter|Exploratory|Unknown}
- Decision-maker(s): %^{Who decides}

** Next Step
- [ ] %^{Immediate next step} (by %^{Next step by}t)
```

- [ ] **Step 4: Create `templates/qualification.org`**

```org
* QUALIFICATION: %^{Company}  :%(org-capture-get :ofc-client-tag):QUALIFICATION:
%U

** Scorecard
| Dimension          | Read (High/Med/Low) | Notes |
|--------------------+---------------------+-------|
| Need / pain        |                     |       |
| Budget             |                     |       |
| Authority (access) |                     |       |
| Timing             |                     |       |
| Technical fit      |                     |       |
| Strategic fit      |                     |       |

** Risks / Red Flags
-

** Verdict
%^{Verdict|Pursue|Hold|Pass}

** Rationale
%?

** If Pursue — Prep for Discovery
- [ ] What to validate in the first deep discovery (ed):
```

- [ ] **Step 5: Register the three captures**

In `org-fractional-cto-capture.el`, inside the backquoted list returned by `org-fractional-cto-capture-templates`, insert this block immediately after the `("e" "Engagement (select client)")` line and before the `;; -- Action tracking & delegation` comment:

```elisp
    ;; -- Pre-sales / pipeline ---------------------------------------------
    ("el" "Pre-sales call / lead intake" entry
     (function ,(org-fractional-cto--target "Pre-Sales Notes"))
     (function ,(org-fractional-cto--file "presales_call.org"))
     :clock-in t :clock-resume t)
    ("eo" "Research note" entry
     (function ,(org-fractional-cto--target "Research"))
     "* RESEARCH: %^{Topic} :%(org-capture-get :ofc-client-tag):RESEARCH:\n%U\nArea: %^{Area|Company|Market|Competitor|Tech stack|People|Funding|Other}\nSource: %^{Source / link}\n\n** Finding\n%?\n\n** Implication\n\n** Follow-up\n- [ ]\n")
    ("eF" "Fit / qualification" entry
     (function ,(org-fractional-cto--target "Qualification"))
     (function ,(org-fractional-cto--file "qualification.org"))
     :clock-in t :clock-resume t)
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `make test 2>&1 | tail -20`
Expected: both new tests PASS; all prior tests still PASS.

- [ ] **Step 7: Commit**

```bash
git add templates/presales_call.org templates/qualification.org org-fractional-cto-capture.el test/org-fractional-cto-prospect-test.el
git commit -m "feat: add el/eo/eF pre-sales captures"
```

---

## Task 7: Pipeline agenda view

**Files:**
- Modify: `org-fractional-cto-agenda.el`
- Test: `test/org-fractional-cto-prospect-test.el`

- [ ] **Step 1: Write the failing tests**

Append to `test/org-fractional-cto-prospect-test.el`:

```elisp
(ert-deftest ofc-pipeline-skip-keeps-level-1 ()
  (with-temp-buffer
    (org-mode)
    (insert "* Acme Engagement  :ACME:LEAD:\n** Actions  :ACME:\n*** TODO x  :ACME:\n")
    (goto-char (point-min))
    (org-back-to-heading t)
    (should-not (org-fractional-cto--pipeline-skip))
    (goto-char (point-min))
    (re-search-forward "^\\*\\* Actions")
    (org-back-to-heading t)
    (should (org-fractional-cto--pipeline-skip))))

(ert-deftest ofc-pipeline-install-registers-command ()
  (let ((org-agenda-custom-commands nil)
        (org-fractional-cto-pipeline-key "P")
        (org-fractional-cto-pipeline-stages "LEAD|QUALIFIED"))
    (org-fractional-cto-pipeline-install)
    (should (assoc "P" org-agenda-custom-commands))))
```

- [ ] **Step 2: Run to verify they fail**

Run: `make test 2>&1 | grep -A3 ofc-pipeline`
Expected: FAIL — `org-fractional-cto--pipeline-skip` and `org-fractional-cto-pipeline-install` are void.

- [ ] **Step 3: Add the pipeline view to the agenda module**

In `org-fractional-cto-agenda.el`, add these `defvar`/`declare-function` lines next to the existing `(defvar org-fractional-cto-agenda-key)` near the top:

```elisp
(defvar org-fractional-cto-pipeline-key)
(defvar org-fractional-cto-pipeline-stages)
(declare-function org-fractional-cto-agenda-files "org-fractional-cto")
```

Then add the following immediately before the `(provide 'org-fractional-cto-agenda)` line:

```elisp
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
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `make test 2>&1 | tail -20`
Expected: both `ofc-pipeline-*` tests PASS; all prior tests still PASS.

- [ ] **Step 5: Commit**

```bash
git add org-fractional-cto-agenda.el test/org-fractional-cto-prospect-test.el
git commit -m "feat: add cross-client prospect pipeline agenda view"
```

---

## Task 8: Core wiring — keymap + setup

**Files:**
- Modify: `org-fractional-cto.el` (command map, `setup`)
- Test: `test/org-fractional-cto-prospect-test.el`

- [ ] **Step 1: Write the failing tests**

Append to `test/org-fractional-cto-prospect-test.el`:

```elisp
(ert-deftest ofc-command-map-has-prospect-bindings ()
  (should (eq (lookup-key org-fractional-cto-command-map "p")
              #'org-fractional-cto-new-prospect))
  (should (eq (lookup-key org-fractional-cto-command-map "S")
              #'org-fractional-cto-set-stage)))

(ert-deftest ofc-setup-installs-pipeline ()
  (let ((org-agenda-custom-commands nil)
        (org-capture-templates nil)
        (org-agenda-files nil)
        (org-fractional-cto-clients-directory (make-temp-file "ofc-setupclients" t)))
    (unwind-protect
        (progn
          (org-fractional-cto-setup)
          (should (assoc org-fractional-cto-pipeline-key org-agenda-custom-commands))
          (should (assoc org-fractional-cto-agenda-key org-agenda-custom-commands)))
      (delete-directory org-fractional-cto-clients-directory t))))
```

- [ ] **Step 2: Run to verify they fail**

Run: `make test 2>&1 | grep -A3 -e ofc-command-map-has-prospect-bindings -e ofc-setup-installs-pipeline`
Expected: FAIL — `p`/`S` unbound; `setup` does not register the pipeline command.

- [ ] **Step 3: Add the keymap bindings**

In `org-fractional-cto.el`, in the `org-fractional-cto-command-map` definition, add the two bindings after the `"w"` binding:

```elisp
    (define-key map "d" #'org-fractional-cto-dashboard)
    (define-key map "w" #'org-fractional-cto-switch-client)
    (define-key map "p" #'org-fractional-cto-new-prospect)
    (define-key map "S" #'org-fractional-cto-set-stage)
    (define-key map "g" #'org-fractional-cto-delegate-at-point)
    (define-key map "b" #'org-fractional-cto-block-at-point)
    (define-key map "h" #'org-fractional-cto-docs)
    map)
```

- [ ] **Step 4: Install the pipeline command in `setup`**

In `org-fractional-cto.el`, in `org-fractional-cto-setup`, add the pipeline install after the dashboard install:

```elisp
  (org-fractional-cto-capture-install)
  (org-fractional-cto-agenda-install)
  (org-fractional-cto-pipeline-install)
  (dolist (dir (org-fractional-cto-agenda-files))
    (add-to-list 'org-agenda-files dir t))
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `make test 2>&1 | tail -20`
Expected: both new tests PASS; ALL tests (actions + prospect) PASS.

- [ ] **Step 6: Verify the package byte-compiles cleanly**

Run:
```bash
emacs -Q --batch -L . -f batch-byte-compile \
  org-fractional-cto.el org-fractional-cto-scaffold.el \
  org-fractional-cto-stage.el org-fractional-cto-capture.el \
  org-fractional-cto-agenda.el; rm -f *.elc
```
Expected: no warnings or errors.

- [ ] **Step 7: Commit**

```bash
git add org-fractional-cto.el test/org-fractional-cto-prospect-test.el
git commit -m "feat: wire new-prospect/set-stage keys and pipeline into setup"
```

---

## Task 9: Documentation + regenerate manual

**Files:**
- Modify: `doc/reference.org`, `doc/guide.org`, `doc/playbook.org`
- Regenerate: `org-fractional-cto.texi`

- [ ] **Step 1: Add the captures + commands to the reference quick-lookup**

In `doc/reference.org`, in the `*** Capture something` table, add three rows after the `| Quick action / TODO … |` row:

```org
| Pre-sales call / lead intake       | =C-c c el=    | <client>.org → Pre-Sales Notes             |
| Research note                      | =C-c c eo=    | <client>.org → Research                    |
| Fit / qualification                | =C-c c eF=    | <client>.org → Qualification               |
```

In the `*** Act on an existing item` table (added in a prior feature), add two rows:

```org
| Create a new prospect (LEAD)          | =M-x org-fractional-cto-new-prospect=      |
| Set the engagement stage              | =M-x org-fractional-cto-set-stage=         |
```

In the `*** Look up / analyse` table, add one row after the dashboard rows:

```org
| Prospect pipeline (all leads)              | =C-c a P= (or =M-x org-fractional-cto-pipeline=)  |
```

- [ ] **Step 2: Add the stage legend to the reference**

In `doc/reference.org`, immediately after the `*** TODO keywords (client files)` subsection (before `*** Priorities`), add:

```org
*** Engagement stages (tag on the engagement heading)
One stage tag sits on the top =* … Engagement= heading and is inherited by the
whole tree. Switch it with =M-x org-fractional-cto-set-stage=.

| Stage       | Meaning                                          |
|-------------+--------------------------------------------------|
| =LEAD=      | Captured from a pre-sales call; raw              |
| =QUALIFIED= | Researched and worth pursuing (pre-contract)     |
| =ACTIVE=    | Won / engaged — the default for new-client       |
| =LOST=      | Did not convert                                  |
| =DORMANT=   | Paused / on hold                                 |

The pipeline view (=C-c a P=) lists every =LEAD=/=QUALIFIED= engagement across
all clients, one line per prospect.
```

- [ ] **Step 3: Add type-tag rows to the reference legend**

In `doc/reference.org`, in the `*** Type tags` table, add three rows:

```org
| =PRESALES=      | Pre-Sales Notes (=el=)        |
| =RESEARCH=      | Research (=eo=)               |
| =QUALIFICATION= | Qualification (=eF=)          |
```

- [ ] **Step 4: Add the management-command rows to the reference key bindings**

In `doc/reference.org`, in the `*** Key bindings` table, add after the `switch-client` row:

```org
| =M-x org-fractional-cto-new-prospect=      | New prospect (LEAD stage)       |
| =M-x org-fractional-cto-set-stage=         | Set engagement stage            |
| =M-x org-fractional-cto-upgrade-hub=       | Upgrade an old hub in place     |
| =C-c a P=                                  | Prospect pipeline (all leads)   |
```

And update the command-map key list line to read:

```org
They also live in =org-fractional-cto-command-map= (keys =n s k d w p S g b h=); set
```

- [ ] **Step 5: Add a guide step for the pre-sales workflow**

In `doc/guide.org`, after the `* Step 3 — Onboard your first client` section (immediately before `* Step 4 — Fill in CONTEXT.md`), add:

```org
* Step 3b — Capture a prospect (pre-sales)

A prospect is just a client at an earlier stage. Before an engagement is won you
still want to capture calls, do research, and track follow-ups — and the
dashboard already does that. Onboard a prospect with:

: M-x org-fractional-cto-new-prospect

It scaffolds the same hub as a client but stamps the engagement heading with the
=LEAD= stage tag, sets the prospect active, and opens the *pre-sales call*
capture (=el=) so you record the conversation immediately. From there:

- =C-c c el= — capture each pre-sales call (the ask, pain, signals, next step).
- =C-c c eo= — log research findings as you learn about the company, market, and
  tech. Fold the durable facts into =CONTEXT.md=.
- =C-c c eF= — record a fit / qualification verdict (Pursue / Hold / Pass).
- =C-c c ew= / =eg= / =eb= — ordinary actions, delegations, and blockers work
  here too, so your pre-sales follow-ups land on the dashboard like any work.

As the prospect advances, move the stage with =M-x org-fractional-cto-set-stage=
(=LEAD= → =QUALIFIED= → =ACTIVE= when you win, or =LOST=). Across all clients,
=C-c a P= shows the whole pipeline — every =LEAD= / =QUALIFIED= engagement, one
line each.

If you have hubs created before stages existed, run =M-x
org-fractional-cto-upgrade-hub= on each to add the new sections and an =ACTIVE=
stage tag.
```

- [ ] **Step 6: Add a Phase −1 section to the playbook**

In `doc/playbook.org`, immediately before the `** Phase 0 — Engagement Setup` section, add:

```org
** Phase −1 — Pre-Sales / Pipeline
/Before the engagement exists. Hat: Trusted Advisor (selling by helping)./

You meet a prospect with almost no information. The goal is to capture
everything you hear, research to fill the gaps, and decide whether to pursue —
without yet committing to the deep, team-by-team discovery of Phase 1.

- =M-x org-fractional-cto-new-prospect= — create the prospect at =LEAD= stage.
- =C-c c el= — capture each pre-sales call: the ask in their words, pain
  points, budget/timing signals, decision-makers, and the next step.
- =C-c c eo= — log research findings (company, market, competitors, tech hints,
  funding, people). Promote durable facts into =CONTEXT.md=.
- =C-c c eF= — a fit/qualification scorecard ending in a verdict: Pursue, Hold,
  or Pass. On Pursue, note what to validate in the first deep discovery (=ed=).

Advance the stage as conviction grows (=M-x org-fractional-cto-set-stage=:
=LEAD= → =QUALIFIED=), and =C-c a P= is your funnel board across all prospects.
When you win, =set-stage= → =ACTIVE= and proceed to Phase 0 — the hub, its
history, and every captured artifact carry straight over.
```

- [ ] **Step 7: Regenerate the manual**

Run: `make info`
Expected: command completes; `org-fractional-cto.texi` is regenerated.

- [ ] **Step 8: Verify the manual compiles and contains the new content**

Run:
```bash
grep -c "new-prospect\|set-stage\|Pre-Sales\|pipeline" org-fractional-cto.texi
makeinfo --no-split -o /tmp/ofc.info org-fractional-cto.texi; echo "makeinfo exit: $?"
```
Expected: grep count > 0; `makeinfo exit: 0`.

- [ ] **Step 9: Final full test run**

Run: `make test 2>&1 | tail -5`
Expected: all tests across both test files pass, "0 unexpected".

- [ ] **Step 10: Commit**

```bash
git add doc/reference.org doc/guide.org doc/playbook.org org-fractional-cto.texi
git commit -m "docs: document pre-sales/prospect capture and regenerate manual"
```

---

## Self-review notes (for the implementer)

- **Spec coverage:** Task 1 (sections), Task 2 (stage tag + constants), Task 3 (new-prospect), Task 4 (set-stage), Task 5 (upgrade-hub), Task 6 (captures + templates), Task 7 (pipeline), Task 8 (keymap + setup), Task 9 (docs) — together cover every section of the spec. The deep `ed` discovery is intentionally never touched.
- **Naming consistency:** the engagement-heading helper is `org-fractional-cto--goto-engagement-heading` everywhere; the pipeline skip is `org-fractional-cto--pipeline-skip` everywhere; constants are `org-fractional-cto-{stages,default-stage,lead-stage,pipeline-stages,pipeline-key}`.
- **Inheritance note:** the pipeline matches the *explicit* stage tag on the level-1 heading via the skip function, so it works even if a user disables `org-use-tag-inheritance`.
- **Ordering:** stage constants (Task 2) must precede their consumers (Tasks 3–8). The stage module is required by core in Task 4 so its commands are loadable by the test harness from that point on.
```
