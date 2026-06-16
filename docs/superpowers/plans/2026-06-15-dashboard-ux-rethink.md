# Dashboard & Capture UX Rethink — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move client identity to `#+filetags`, auto-fill the client name in captures, turn the per-client dashboard into a global one that opens focused on the active client via a native filter, and make the at-point delegate/block actions work from the agenda with comma-localleader evil bindings.

**Architecture:** All changes lean on native Org behaviour — filetag inheritance, the agenda CATEGORY column, `org-agenda-tag-filter-preset`, and `org-agenda-with-point-at-orig-entry`. No bespoke focus command. The client tag changes *location* (heading → file) only; dashboard blocks keep matching on the unchanged type subtags and TODO state.

**Tech Stack:** Emacs Lisp, Org mode (9.4+), ERT for tests, optional Evil.

**Spec:** `docs/superpowers/specs/2026-06-15-dashboard-ux-rethink-design.md`

---

## Conventions (referenced by every task)

**Run the whole suite** (`TEST_ALL`):
```bash
cd /Users/dhruva/src/dhruvasagar/org-fractional-cto && make test
```
Expected on success: a line `Ran N tests, N results as expected, 0 unexpected`.

**Run a single test** (`TEST_ONE <name>`): the test files are `test/org-fractional-cto-prospect-test.el` (general) and `test/org-fractional-cto-actions-test.el` (at-point actions).
```bash
cd /Users/dhruva/src/dhruvasagar/org-fractional-cto && \
emacs -Q --batch -L . -l test/org-fractional-cto-prospect-test.el \
  --eval '(ert-run-tests-batch-and-exit "TESTNAME")'
```
(Use `-l test/org-fractional-cto-actions-test.el` for action tests. The selector is a regexp matching the test name.)

**Byte-compile with warnings-as-errors** (`BYTECOMPILE`):
```bash
cd /Users/dhruva/src/dhruvasagar/org-fractional-cto && \
emacs -Q --batch --eval '(progn (add-to-list (quote load-path) default-directory) (setq byte-compile-error-on-warn t) (dolist (f (directory-files default-directory t "^org-fractional-cto.*\\.el$")) (byte-compile-file f)))' ; rm -f *.elc
```
Expected on success: no `Error`/`Warning` lines (ignore the harmless `tree-sitter`/`stdin` notes).

**Commit style:** Conventional Commits (`feat:`, `refactor:`, `test:`, `docs:`). No attribution trailer (matches this repo).

---

## Task 0: Land the pre-existing dashboard work as its own commit

The working tree already contains the (reviewed, tested) security/tech-debt/scope blocks and closeable-risk changes from earlier. Commit them first so later tasks build on a clean base.

**Files:** `org-fractional-cto-agenda.el`, `org-fractional-cto-capture.el`, `test/org-fractional-cto-prospect-test.el`, `README.org`, `doc/guide.org`, `doc/reference.org`, `org-fractional-cto.texi` (whatever `git status` shows as modified).

- [ ] **Step 1: Confirm green and clean compile**

Run `TEST_ALL`. Expected: `Ran 34 tests ... 0 unexpected`.
Run `BYTECOMPILE`. Expected: no warnings/errors.

- [ ] **Step 2: Commit the existing changes**

```bash
git add org-fractional-cto-agenda.el org-fractional-cto-capture.el \
  test/org-fractional-cto-prospect-test.el README.org doc/guide.org \
  doc/reference.org org-fractional-cto.texi
git commit -m "feat: add security, tech-debt and scope dashboard blocks; closeable risks"
```

- [ ] **Step 3: Verify a clean tree**

Run `git status --short`. Expected: empty output.

---

## Task 1: `client-name` helper + capture-plist name

Foundation for auto-filling the client name. Adds a function that reads the hub's `#+title:` and stashes the name in the capture plist.

**Files:**
- Modify: `org-fractional-cto.el` (add `org-fractional-cto-client-name`)
- Modify: `org-fractional-cto-capture.el` (declare + plist put)
- Test: `test/org-fractional-cto-prospect-test.el`

- [ ] **Step 1: Write failing tests**

Add to `test/org-fractional-cto-prospect-test.el` before the final `(provide ...)`:

```elisp
(ert-deftest ofc-client-name-reads-title ()
  "client-name returns the hub's #+title."
  (ofc-prospect-test-with-clients-dir
    (org-fractional-cto-new-client "Acme Corp" "acme")
    (should (equal (org-fractional-cto-client-name "acme") "Acme Corp"))))

(ert-deftest ofc-client-name-falls-back-to-slug ()
  "client-name returns the slug when no hub/title exists."
  (ofc-prospect-test-with-clients-dir
    (should (equal (org-fractional-cto-client-name "ghost") "ghost"))))
```

- [ ] **Step 2: Run tests, verify they fail**

Run `TEST_ONE 'ofc-client-name'`. Expected: FAIL (`void-function org-fractional-cto-client-name`).

- [ ] **Step 3: Implement `client-name`**

In `org-fractional-cto.el`, add after `org-fractional-cto-client-context-file` (around line 165):

```elisp
(defun org-fractional-cto-client-name (slug)
  "Return the display name for client SLUG.
Read from the hub file's \"#+title:\" keyword; fall back to SLUG when the file
is missing or carries no title."
  (let ((file (org-fractional-cto-client-org-file slug)))
    (or (and (file-readable-p file)
             (with-temp-buffer
               (insert-file-contents file)
               (goto-char (point-min))
               (when (re-search-forward "^#\\+title:[ \t]*\\(.+\\)$" nil t)
                 (string-trim (match-string 1)))))
        slug)))
```

- [ ] **Step 4: Stash the name in the capture plist**

In `org-fractional-cto-capture.el`: add the declare-function near the others (after line 20):

```elisp
(declare-function org-fractional-cto-client-name "org-fractional-cto")
```

Then in `org-fractional-cto--capture-to-heading`, after the `(org-capture-put :ofc-client-tag tag)` line (line 34), add:

```elisp
    (org-capture-put :ofc-client-name (org-fractional-cto-client-name slug))
```

- [ ] **Step 5: Run tests + compile**

Run `TEST_ONE 'ofc-client-name'`. Expected: PASS (2/2).
Run `BYTECOMPILE`. Expected: clean.

- [ ] **Step 6: Commit**

```bash
git add org-fractional-cto.el org-fractional-cto-capture.el test/org-fractional-cto-prospect-test.el
git commit -m "feat: add client-name helper and stash it in the capture plist"
```

---

## Task 2: Scaffold writes filetags, tag-free headings

**Files:**
- Modify: `org-fractional-cto-scaffold.el:66-84` (`org-fractional-cto--write-hub`)
- Test: `test/org-fractional-cto-prospect-test.el`

- [ ] **Step 1: Write failing tests**

Add to `test/org-fractional-cto-prospect-test.el`:

```elisp
(ert-deftest ofc-hub-has-filetags ()
  "A scaffolded hub declares the client tag as a filetag."
  (ofc-prospect-test-with-clients-dir
    (org-fractional-cto-new-client "Acme Corp" "acme")
    (with-temp-buffer
      (insert-file-contents (org-fractional-cto-client-org-file "acme"))
      (goto-char (point-min))
      (should (re-search-forward "^#\\+filetags:[ \t]+:ACME:" nil t)))))

(ert-deftest ofc-hub-headings-omit-client-tag ()
  "No heading carries the client tag; stage and type subtags remain."
  (ofc-prospect-test-with-clients-dir
    (org-fractional-cto-new-client "Acme Corp" "acme")
    (with-temp-buffer
      (insert-file-contents (org-fractional-cto-client-org-file "acme"))
      (goto-char (point-min))
      (should (re-search-forward "^\\* Acme Corp Engagement[ \t]+:ACTIVE:$" nil t))
      (goto-char (point-min))
      (should (re-search-forward "^\\*\\* Risks[ \t]+:RISK:$" nil t))
      (goto-char (point-min))
      (should-not (re-search-forward "^\\*+ .*:ACME:" nil t)))))
```

- [ ] **Step 2: Run tests, verify they fail**

Run `TEST_ONE 'ofc-hub-'`. Expected: FAIL (headings still carry `:ACME:`, no filetags line).

- [ ] **Step 3: Rewrite `--write-hub`**

Replace the body of `org-fractional-cto--write-hub` (scaffold.el:70-84) with:

```elisp
  (with-temp-file file
    (insert (format "#+title: %s\n" client-name))
    (insert (format "#+AUTHOR: %s\n" org-fractional-cto-author))
    (insert "#+STARTUP: overview\n")
    (insert "#+TODO: TODO NEXT INPROGRESS WAITING | DONE CANCELLED\n")
    (insert (format "#+filetags: :%s:\n" tag))
    (insert "#+OPTIONS: date:nil\n\n")
    (insert (format "* %s Engagement  :%s:\n" client-name stage))
    (insert (format ":PROPERTIES:\n:ID:       %s-OPS\n:CATEGORY: %s\n:END:\n\n"
                    tag client-name))
    (insert "See [[file:CONTEXT.md][CONTEXT.md]] for domain vocabulary, key people, and priorities.\n\n")
    (dolist (section org-fractional-cto-sections)
      (let ((heading (car section)) (subtag (cadr section)))
        (if (string-empty-p subtag)
            (insert (format "** %s\n\n" heading))
          (insert (format "** %s  :%s:\n\n" heading subtag)))))))
```

- [ ] **Step 4: Run tests + the structural test that already exists**

Run `TEST_ONE 'ofc-hub-'`. Expected: PASS.
Run `TEST_ALL`. Expected: all pass — in particular `ofc-prospect-hub-structure-matches-client` and `ofc-new-client-hub-has-presales-sections` still pass (they compare structure / section presence, which is preserved). If `ofc-new-client-hub-has-presales-sections` asserts a client tag on a section heading, update its expected strings to the tag-free form (e.g. `** Pre-Sales Notes  :PRESALES:`).

- [ ] **Step 5: Compile + commit**

Run `BYTECOMPILE`. Expected: clean.
```bash
git add org-fractional-cto-scaffold.el test/org-fractional-cto-prospect-test.el
git commit -m "feat: scaffold client identity as a filetag instead of per-heading tags"
```

---

## Task 3: Migrate existing hubs via `upgrade-hub`

**Files:**
- Modify: `org-fractional-cto-stage.el` (add `--migrate-to-filetags`; call it from `upgrade-hub`; simplify `--ensure-sections`; remove now-unused `--engagement-client-tag`)
- Test: `test/org-fractional-cto-prospect-test.el`

- [ ] **Step 1: Write failing tests**

Add to `test/org-fractional-cto-prospect-test.el`:

```elisp
(ert-deftest ofc-upgrade-hub-migrates-to-filetags ()
  "Upgrading an old-style hub adds a filetag and strips heading client tags."
  (ofc-prospect-test-with-clients-dir
    (let* ((slug "acme")
           (dir (expand-file-name slug (org-fractional-cto--clients-dir)))
           (file (org-fractional-cto-client-org-file slug)))
      (make-directory dir t)
      (with-temp-file file
        (insert "#+title: Acme Corp\n")
        (insert "#+TODO: TODO NEXT INPROGRESS WAITING | DONE CANCELLED\n\n")
        (insert "* Acme Corp Engagement  :ACME:ACTIVE:\n\n")
        (insert "** Risks  :ACME:RISK:\n\n")
        (insert "** Actions  :ACME:\n\n"))
      (org-fractional-cto-set-active-client slug)
      (org-fractional-cto-upgrade-hub)
      (with-temp-buffer
        (insert-file-contents file)
        (goto-char (point-min))
        (should (re-search-forward "^#\\+filetags:[ \t]+:ACME:" nil t))
        (goto-char (point-min))
        (should-not (re-search-forward "^\\*+ .*:ACME:" nil t))
        (goto-char (point-min))
        (should (re-search-forward "^\\* Acme Corp Engagement[ \t]+:ACTIVE:$" nil t))
        (goto-char (point-min))
        (should (re-search-forward "^\\*\\* Risks[ \t]+:RISK:$" nil t))))))

(ert-deftest ofc-upgrade-hub-filetags-idempotent ()
  "Re-upgrading a migrated hub does not add a second filetags line."
  (ofc-prospect-test-with-clients-dir
    (org-fractional-cto-new-client "Acme Corp" "acme")
    (org-fractional-cto-set-active-client "acme")
    (org-fractional-cto-upgrade-hub)
    (org-fractional-cto-upgrade-hub)
    (with-temp-buffer
      (insert-file-contents (org-fractional-cto-client-org-file "acme"))
      (goto-char (point-min))
      (let ((n 0))
        (while (re-search-forward "^#\\+filetags:" nil t) (setq n (1+ n)))
        (should (= n 1))))))
```

- [ ] **Step 2: Run tests, verify they fail**

Run `TEST_ONE 'ofc-upgrade-hub-(migrates|filetags)'`. Expected: FAIL (`migrate-to-filetags` undefined / second filetags line).

- [ ] **Step 3: Add the migration function**

In `org-fractional-cto-stage.el`, add a declare-function near line 20:

```elisp
(declare-function org-fractional-cto-client-tag "org-fractional-cto")
```

Add the function before `org-fractional-cto-upgrade-hub` (around line 88):

```elisp
(defun org-fractional-cto--migrate-to-filetags ()
  "Ensure a \"#+filetags\" line and strip the client tag from every heading.
The client tag is derived from the hub's filename so it is correct even after
the engagement heading's tag has already been stripped.  Idempotent."
  (let ((tag (org-fractional-cto-client-tag
              (file-name-base (buffer-file-name)))))
    (goto-char (point-min))
    (unless (re-search-forward
             (format "^#\\+filetags:.*:%s:" (regexp-quote tag)) nil t)
      (goto-char (point-min))
      (if (re-search-forward "^#\\+TODO:.*$" nil t)
          (progn (end-of-line) (insert (format "\n#+filetags: :%s:" tag)))
        (goto-char (point-min))
        (insert (format "#+filetags: :%s:\n" tag))))
    (goto-char (point-min))
    (while (re-search-forward "^\\*+ " nil t)
      (let ((tags (org-get-tags nil t)))
        (when (member tag tags)
          (org-set-tags (remove tag tags)))))))
```

- [ ] **Step 4: Call it from `upgrade-hub` and simplify `--ensure-sections`**

In `org-fractional-cto-upgrade-hub`, add the migration as the first action inside `save-excursion` (stage.el:100-102):

```elisp
      (save-excursion
        (org-fractional-cto--migrate-to-filetags)
        (org-fractional-cto--ensure-stage-tag)
        (org-fractional-cto--ensure-sections))
```

Replace `org-fractional-cto--ensure-sections` (stage.el:72-87) with the client-tag-free version:

```elisp
(defun org-fractional-cto--ensure-sections ()
  "Append any `org-fractional-cto-sections' headings missing from the buffer.
Appended sections carry only their type subtag; the client tag is supplied by
the file's \"#+filetags\" line."
  (dolist (section org-fractional-cto-sections)
    (let ((heading (car section)) (subtag (cadr section)))
      (goto-char (point-min))
      (unless (re-search-forward
               (concat "^\\*+ " (regexp-quote heading) "\\(?:[ \t]\\|$\\)") nil t)
        (goto-char (point-max))
        (unless (bolp) (insert "\n"))
        (if (string-empty-p subtag)
            (insert (format "** %s\n\n" heading))
          (insert (format "** %s  :%s:\n\n" heading subtag)))))))
```

Delete the now-unused `org-fractional-cto--engagement-client-tag` (stage.el:35-38).

- [ ] **Step 5: Run tests + compile**

Run `TEST_ONE 'ofc-upgrade-hub'`. Expected: PASS (including the pre-existing `ofc-upgrade-hub-adds-stage-and-sections` and `ofc-upgrade-hub-is-idempotent`; if either asserted client tags on appended sections, update their expected strings to the tag-free form).
Run `BYTECOMPILE`. Expected: clean (no "unused" / "undefined" warnings).

- [ ] **Step 6: Commit**

```bash
git add org-fractional-cto-stage.el test/org-fractional-cto-prospect-test.el
git commit -m "feat: migrate existing hubs to filetags via upgrade-hub"
```

---

## Task 4: Strip client tag from captures; auto-fill the name

**Files:**
- Modify: `org-fractional-cto-capture.el` (inline templates)
- Modify: `templates/*.org` (file templates)
- Test: `test/org-fractional-cto-prospect-test.el`

- [ ] **Step 1: Write failing tests**

Add to `test/org-fractional-cto-prospect-test.el`:

```elisp
(ert-deftest ofc-inline-templates-drop-client-tag ()
  "No inline capture template references the client tag any more."
  (dolist (tpl (org-fractional-cto-capture-templates))
    (let ((body (and (> (length tpl) 4) (nth 4 tpl))))
      (when (stringp body)
        (should-not (string-match-p ":ofc-client-tag" body))))))

(ert-deftest ofc-templates-keep-type-subtags ()
  "The risk template still carries its :RISK: subtag."
  (let ((body (nth 4 (seq-find (lambda (tpl) (equal (car-safe tpl) "er"))
                               (org-fractional-cto-capture-templates)))))
    (should (string-match-p ":RISK:" body))
    (should-not (string-match-p ":ofc-client-tag" body))))
```

- [ ] **Step 2: Run tests, verify they fail**

Run `TEST_ONE 'ofc-(inline-templates|templates-keep)'`. Expected: FAIL (templates still contain `:%(org-capture-get :ofc-client-tag):`).

- [ ] **Step 3: Strip the client tag from inline templates**

In `org-fractional-cto-capture.el`, for every inline template string, remove the `%(org-capture-get :ofc-client-tag)` segment, collapsing the tag block. Apply these exact edits:

- `eo` Research: `:%(org-capture-get :ofc-client-tag):RESEARCH:` → `:RESEARCH:`
- `ew` Action item: `* TODO %^{Action} :%(org-capture-get :ofc-client-tag):\nDEADLINE` → `* TODO %^{Action}\nDEADLINE`
- `eP` Person: `:%(org-capture-get :ofc-client-tag):PEOPLE:` → `:PEOPLE:`
- `ec` Commitment: `:%(org-capture-get :ofc-client-tag):COMMITMENT:` → `:COMMITMENT:`
- `eh` Health check: `:%(org-capture-get :ofc-client-tag):HEALTH:` → `:HEALTH:`
- `eM` Metrics: `:%(org-capture-get :ofc-client-tag):METRICS:` → `:METRICS:`
- `er` Risk: `:%(org-capture-get :ofc-client-tag):RISK:` → `:RISK:`
- `ee` Scope change: `:%(org-capture-get :ofc-client-tag):SCOPE:` → `:SCOPE:`
- `ef` Post-mortem: `:%(org-capture-get :ofc-client-tag):POSTMORTEM:` → `:POSTMORTEM:`
- `eD` Quick decision: `:%(org-capture-get :ofc-client-tag):DECISION:` → `:DECISION:`
- `et` Tech debt: `:%(org-capture-get :ofc-client-tag):TECHDEBT:` → `:TECHDEBT:`
- `ex` Security: `:%(org-capture-get :ofc-client-tag):SECURITY:` → `:SECURITY:`
- `en` Innovation idea: `:%(org-capture-get :ofc-client-tag):INNOVATION:` → `:INNOVATION:`

After editing, confirm none remain:
```bash
grep -n "ofc-client-tag" org-fractional-cto-capture.el
```
Expected: no output (the docstring comment mentioning it may stay or be reworded).

- [ ] **Step 4: Update the file templates (tag + auto-filled name)**

Replace the client-name prompt and drop the dead placeholder tag across `templates/`:
```bash
cd /Users/dhruva/src/dhruvasagar/org-fractional-cto
grep -rl '%^{Client}' templates/   # the 9 metadata + 2 headline files
```
For each match, replace `%^{Client}` with `%(org-capture-get :ofc-client-name)`. In `templates/client_meeting.org` also change the headline tag `:ENGAGEMENT:MEETING:` → `:MEETING:`. Do **not** touch `%^{Client attendees}` or `%^{Our attendees}` — those are genuine prompts.

Verify:
```bash
grep -rn '%^{Client}' templates/        # expect: no output
grep -rn ':ENGAGEMENT:' templates/      # expect: no output
grep -rn 'ofc-client-name' templates/   # expect: the replaced lines
```

- [ ] **Step 5: Run tests + compile**

Run `TEST_ONE 'ofc-(inline-templates|templates-keep)'`. Expected: PASS.
Run `TEST_ALL`. Expected: all pass (`ofc-presales-template-files-exist` etc. unaffected).
Run `BYTECOMPILE`. Expected: clean.

- [ ] **Step 6: Commit**

```bash
git add org-fractional-cto-capture.el templates test/org-fractional-cto-prospect-test.el
git commit -m "feat: drop client tag from captures and auto-fill the client name"
```

---

## Task 5: Global dashboard with native active-client focus

**Files:**
- Modify: `org-fractional-cto-agenda.el` (add `--active-client-filter`; rewrite the dashboard command's settings; remove `--dashboard-files`)
- Test: `test/org-fractional-cto-prospect-test.el`

- [ ] **Step 1: Write failing tests**

Add to `test/org-fractional-cto-prospect-test.el`:

```elisp
(ert-deftest ofc-active-client-filter-preset ()
  "The focus filter is +TAG with an active client, nil without."
  (let ((org-fractional-cto-active-client "acme"))
    (should (equal (org-fractional-cto--active-client-filter) '("+ACME"))))
  (let ((org-fractional-cto-active-client nil))
    (should (null (org-fractional-cto--active-client-filter)))))

(ert-deftest ofc-dashboard-is-global-with-focus-preset ()
  "The dashboard command spans all clients and seeds a tag-filter preset."
  (let ((org-agenda-custom-commands nil)
        (org-fractional-cto-clients-directory (make-temp-file "ofc-dash" t)))
    (unwind-protect
        (progn
          (org-fractional-cto-agenda-install)
          (let* ((cmd (assoc org-fractional-cto-agenda-key org-agenda-custom-commands))
                 (settings (nth 3 cmd)))
            (should (assq 'org-agenda-files settings))
            (should (assq 'org-agenda-tag-filter-preset settings))))
      (delete-directory org-fractional-cto-clients-directory t))))
```

- [ ] **Step 2: Run tests, verify they fail**

Run `TEST_ONE 'ofc-(active-client-filter|dashboard-is-global)'`. Expected: FAIL.

- [ ] **Step 3: Add the filter helper + forward declarations**

In `org-fractional-cto-agenda.el`, near the existing declarations (after line 31), add:

```elisp
(declare-function org-fractional-cto-client-tag "org-fractional-cto")
(defvar org-fractional-cto-active-client)
```

Add the helper after `org-fractional-cto--dashboard-files` (which you will remove in Step 4 — add this helper just below the defcustom block instead, around line 59):

```elisp
(defun org-fractional-cto--active-client-filter ()
  "Return an `org-agenda-tag-filter-preset' focusing the active client, or nil.
With an active client the dashboard opens filtered to it; with none it opens
global.  Widen, refocus, or clear with the native agenda filter (\\[org-agenda-filter])."
  (when org-fractional-cto-active-client
    (list (concat "+" (org-fractional-cto-client-tag
                       org-fractional-cto-active-client)))))
```

- [ ] **Step 4: Make the dashboard global and remove `--dashboard-files`**

Delete `org-fractional-cto--dashboard-files` (agenda.el:60-65 in the original numbering — the `defun` that returns the one active client's file).

In `org-fractional-cto-agenda-install`, change the command's general-settings list from:

```elisp
     ((org-agenda-files (org-fractional-cto--dashboard-files))))))
```

to:

```elisp
     ((org-agenda-files (org-fractional-cto-agenda-files))
      (org-agenda-tag-filter-preset (org-fractional-cto--active-client-filter))))))
```

Update the file's Commentary header (agenda.el:16-19) to describe the global-with-filter behaviour instead of the per-client file scoping.

- [ ] **Step 5: Run tests + compile**

Run `TEST_ONE 'ofc-(active-client-filter|dashboard-is-global)'`. Expected: PASS.
Run `TEST_ALL`. Expected: all pass (`ofc-setup-installs-pipeline` still finds the `E` command).
Run `BYTECOMPILE`. Expected: clean.

- [ ] **Step 6: Commit**

```bash
git add org-fractional-cto-agenda.el test/org-fractional-cto-prospect-test.el
git commit -m "feat: make the dashboard global, focusing the active client via a native filter"
```

---

## Task 6: Install agenda tag inheritance in setup

So the inherited client filetag is filterable in the agenda.

**Files:**
- Modify: `org-fractional-cto.el` (defcustom + helper + setup call)
- Test: `test/org-fractional-cto-prospect-test.el`

- [ ] **Step 1: Write failing test**

```elisp
(ert-deftest ofc-install-tag-inheritance-enables ()
  "Setup turns on agenda tag inheritance so filetag focus works."
  (let ((org-agenda-use-tag-inheritance nil)
        (org-fractional-cto-set-tag-inheritance t))
    (org-fractional-cto--install-tag-inheritance)
    (should (eq org-agenda-use-tag-inheritance t))))
```

- [ ] **Step 2: Run test, verify it fails**

Run `TEST_ONE 'ofc-install-tag-inheritance'`. Expected: FAIL (`void-function`).

- [ ] **Step 3: Add the defcustom + helper, call from setup**

In `org-fractional-cto.el`, add a defcustom near the other dashboard customizables (after `org-fractional-cto-pipeline-key`, around line 128):

```elisp
(defcustom org-fractional-cto-set-tag-inheritance t
  "When non-nil, `org-fractional-cto-setup' enables agenda tag inheritance.
Filetag-based client focus on the dashboard relies on inherited tags being
visible to the agenda filter.  Set to nil to manage tag inheritance yourself."
  :type 'boolean
  :group 'org-fractional-cto)
```

Add the helper next to `org-fractional-cto--install-todo-keywords`:

```elisp
(defun org-fractional-cto--install-tag-inheritance ()
  "Enable agenda tag inheritance when `org-fractional-cto-set-tag-inheritance'.
Makes the inherited client filetag filterable in the dashboard."
  (when org-fractional-cto-set-tag-inheritance
    (setq org-agenda-use-tag-inheritance t)))
```

In `org-fractional-cto-setup`, add the call right after `(org-fractional-cto--install-todo-keywords)`:

```elisp
  (org-fractional-cto--install-tag-inheritance)
```

- [ ] **Step 4: Run test + compile**

Run `TEST_ONE 'ofc-install-tag-inheritance'`. Expected: PASS.
Run `BYTECOMPILE`. Expected: clean.

- [ ] **Step 5: Commit**

```bash
git add org-fractional-cto.el test/org-fractional-cto-prospect-test.el
git commit -m "feat: enable agenda tag inheritance in setup for filetag focus"
```

---

## Task 7: Make delegate/block work from the agenda

**Files:**
- Modify: `org-fractional-cto-actions.el` (add `--at-entry` macro; route both commands through it; drop client tag from the blocker subtree)
- Test: `test/org-fractional-cto-actions-test.el`

- [ ] **Step 1: Write failing test (agenda path)**

Add to `test/org-fractional-cto-actions-test.el` before the final `(provide ...)`:

```elisp
(ert-deftest ofc-delegate-at-point-from-agenda ()
  "Delegating from an agenda line flips the source entry to WAITING."
  (let* ((dir (make-temp-file "ofc-agtest" t))
         (file (expand-file-name "acme.org" dir))
         (org-agenda-files (list file)))
    (unwind-protect
        (progn
          (with-temp-file file
            (insert "#+TODO: TODO NEXT INPROGRESS WAITING | DONE CANCELLED\n")
            (insert "#+filetags: :ACME:\n\n")
            (insert "* TODO Ship the thing\n"))
          (org-todo-list)
          (set-buffer org-agenda-buffer-name)
          (goto-char (point-min))
          (should (re-search-forward "Ship the thing" nil t))
          (beginning-of-line)
          (org-fractional-cto-delegate-at-point "Bob" "2026-07-01" nil)
          (with-current-buffer (find-file-noselect file)
            (goto-char (point-min))
            (should (re-search-forward "^\\* WAITING Ship the thing" nil t))
            (goto-char (point-min))
            (should (re-search-forward ":DELEGATED:" nil t))))
      (dolist (b (buffer-list))
        (when (and (buffer-file-name b)
                   (string-prefix-p (file-truename dir)
                                    (file-truename (buffer-file-name b))))
          (with-current-buffer b (set-buffer-modified-p nil))
          (kill-buffer b)))
      (delete-directory dir t))))
```

- [ ] **Step 2: Run test, verify it fails**

Run `TEST_ONE 'ofc-delegate-at-point-from-agenda'` against the actions test file. Expected: FAIL (the command errors in the agenda buffer: "Not in an Org buffer").

- [ ] **Step 3: Add the dispatch macro + declarations**

In `org-fractional-cto-actions.el`, add declarations near line 34:

```elisp
(declare-function org-agenda-redo "org-agenda")
(defvar org-agenda-buffer-name)
```

Add the macro after the "Small helpers" section (around line 62):

```elisp
(defmacro org-fractional-cto--at-entry (&rest body)
  "Evaluate BODY at the Org heading for the current context.
In an agenda buffer, run BODY at the entry the line points to (via
`org-agenda-with-point-at-orig-entry') and refresh the agenda; in an Org buffer
run BODY directly."
  (declare (indent 0) (debug t))
  `(if (derived-mode-p 'org-agenda-mode)
       (prog1 (org-agenda-with-point-at-orig-entry nil ,@body)
         (ignore-errors (org-agenda-redo)))
     (progn ,@body)))
```

- [ ] **Step 4: Route `delegate-at-point` through the macro**

Replace the body of `org-fractional-cto-delegate-at-point` after the `interactive` form (actions.el:102-117) with:

```elisp
  (when (string-empty-p (string-trim assignee))
    (user-error "An assignee is required to delegate"))
  (org-fractional-cto--at-entry
    (org-fractional-cto--require-heading)
    (save-excursion
      (org-back-to-heading t)
      (org-todo "WAITING")
      (org-toggle-tag "DELEGATED" 'on)
      (org-set-property "ASSIGNED_TO" assignee)
      (org-set-property "DELEGATED_ON" (org-fractional-cto--inactive-timestamp))
      (when (and check-in (not (string-empty-p check-in)))
        (org-schedule nil check-in))
      (when (and delivery (not (string-empty-p delivery)))
        (org-deadline nil delivery))))
  (message "Delegated to %s%s" assignee
           (if (and check-in (not (string-empty-p check-in)))
               (format " — check in %s" check-in) "")))
```

(Note: `--require-heading` now runs *inside* the macro, so in the agenda case it executes in the source Org buffer where the mode check passes.)

- [ ] **Step 5: Route `block-at-point` through the macro; drop the client tag**

In `org-fractional-cto--blocker-subtree` (actions.el:121-138), remove the client-tag lookup so the subtree relies on the inherited filetag. Replace its `let*` bindings and the headline line with:

```elisp
  (let ((stars (make-string level ?*)))
    (concat
     (format "%s TODO [#A] BLOCKER: %s  :BLOCKER:\n" stars what)
```

(Keep the rest of the `concat` body unchanged. The `client-tag`/`tags` bindings are deleted.)

Then wrap the mutating body of `org-fractional-cto-block-at-point` (actions.el:155-173, from `(org-fractional-cto--require-heading)` through the final `(message ...)`) in the macro:

```elisp
  (when (string-empty-p (string-trim what))
    (user-error "Describe what is blocked"))
  (org-fractional-cto--at-entry
    (org-fractional-cto--require-heading)
    (let* ((action-title (org-fractional-cto--heading-title))
           (action-link (format "[[*%s][%s]]" action-title action-title)))
      (save-excursion
        (let ((level (1+ (org-fractional-cto--goto-section "Blockers"))))
          (org-end-of-subtree t t)
          (unless (bolp) (insert "\n"))
          (insert (org-fractional-cto--blocker-subtree
                   level what owner resolve-by action-link))
          (unless (bolp) (insert "\n"))))
      (save-excursion
        (org-back-to-heading t)
        (org-end-of-meta-data t)
        (insert (format "- Blocked by [[*BLOCKER: %s][BLOCKER: %s]]\n" what what)))
      (message "Filed blocker against %S" action-title))))
```

Remove the now-unused `org-fractional-cto--buffer-client-tag` (actions.el:51-56) if nothing else references it (`grep -n buffer-client-tag *.el` to confirm).

- [ ] **Step 6: Run tests + compile**

Run `TEST_ALL`. Expected: all pass — both the existing org-buffer action tests and the new `ofc-delegate-at-point-from-agenda`. If an existing action test asserted `:ACME:BLOCKER:` on a filed blocker, update it to `:BLOCKER:`.
Run `BYTECOMPILE`. Expected: clean.

- [ ] **Step 7: Commit**

```bash
git add org-fractional-cto-actions.el test/org-fractional-cto-actions-test.el
git commit -m "feat: make delegate/block work from the agenda; filetag-aware blockers"
```

---

## Task 8: Agenda command-map + comma-localleader evil bindings

**Files:**
- Modify: `org-fractional-cto.el` (defcustom, command-map, install function, setup call)
- Test: `test/org-fractional-cto-prospect-test.el`

- [ ] **Step 1: Write failing test**

```elisp
(ert-deftest ofc-agenda-command-map-bindings ()
  "The agenda command map binds g/b to the at-point actions."
  (should (eq (lookup-key org-fractional-cto-agenda-command-map "g")
              #'org-fractional-cto-delegate-at-point))
  (should (eq (lookup-key org-fractional-cto-agenda-command-map "b")
              #'org-fractional-cto-block-at-point)))
```

- [ ] **Step 2: Run test, verify it fails**

Run `TEST_ONE 'ofc-agenda-command-map-bindings'`. Expected: FAIL (`void-variable`).

- [ ] **Step 3: Add defcustom, keymap, and install function**

In `org-fractional-cto.el`, add a defcustom near the other key customizables (after `org-fractional-cto-keymap-prefix`, around line 101):

```elisp
(defcustom org-fractional-cto-agenda-keymap-prefix nil
  "Optional prefix key for `org-fractional-cto-agenda-command-map' in agendas.
Bound in `org-agenda-mode-map' by `org-fractional-cto-setup' for non-Evil users.
Default nil: reach the at-point actions via \\[execute-extended-command], or —
under Evil — the comma (`,') localleader (`, g' delegate, `, b' block).  Plain
`,' is `org-agenda-priority' in vanilla agendas, so it is not overridden."
  :type '(choice (key-sequence :tag "Prefix") (const :tag "None" nil))
  :group 'org-fractional-cto)
```

Add the keymap and declarations near the other keymap (after `org-fractional-cto-command-map`, around line 251):

```elisp
(declare-function evil-define-key* "evil-core")
(declare-function org-fractional-cto-delegate-at-point "org-fractional-cto-actions")
(declare-function org-fractional-cto-block-at-point "org-fractional-cto-actions")
(defvar org-agenda-mode-map)

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
```

In `org-fractional-cto-setup`, add the call before the `keymap-prefix` block:

```elisp
  (org-fractional-cto-agenda-install-keys)
```

- [ ] **Step 4: Run test + compile**

Run `TEST_ONE 'ofc-agenda-command-map-bindings'`. Expected: PASS.
Run `BYTECOMPILE`. Expected: clean (the `evil-define-key*` declare-function silences the warning).

- [ ] **Step 5: Commit**

```bash
git add org-fractional-cto.el test/org-fractional-cto-prospect-test.el
git commit -m "feat: agenda command map with comma-localleader evil bindings"
```

---

## Task 9: Documentation + manual regen + final verification

**Files:**
- Modify: `README.org`, `doc/guide.org`, `doc/reference.org`
- Regenerate: `org-fractional-cto.texi`

- [ ] **Step 1: Update the docs**

Across `README.org`, `doc/guide.org`, `doc/reference.org`, update these points (find the relevant sections with `grep -n`):

1. **Filetags:** the hub now declares `#+filetags: :TAG:`; items/sections no longer repeat the client tag. Update the "TODO keywords"/hub-walkthrough and any sample hub listing to the filetag form (`** Risks :RISK:`, engagement heading `:ACTIVE:` only).
2. **Dashboard:** `C-c a E` is now **global across all clients**, opening **focused on the active client** (when set) via a tag filter; widen / refocus / clear with the **native `/`** agenda filter. The CATEGORY column labels each line with its client. Note the pipeline view (`C-c a P`) is unchanged.
3. **Captures:** the client name is auto-filled (no prompt); `upgrade-hub` migrates existing hubs to filetags.
4. **Keybindings:** in the agenda, Evil users get `, g` (delegate) / `, b` (block); others use `M-x` or `org-fractional-cto-agenda-keymap-prefix`. Mention `org-fractional-cto-set-tag-inheritance`.

- [ ] **Step 2: Regenerate the Texinfo manual**

```bash
cd /Users/dhruva/src/dhruvasagar/org-fractional-cto && make info
git status --short org-fractional-cto.texi   # expect: " M org-fractional-cto.texi"
```

- [ ] **Step 3: Full verification**

Run `TEST_ALL`. Expected: all tests pass, `0 unexpected`.
Run `BYTECOMPILE`. Expected: no warnings/errors.

- [ ] **Step 4: Commit**

```bash
git add README.org doc/guide.org doc/reference.org org-fractional-cto.texi
git commit -m "docs: filetags, global dashboard, agenda actions, auto-filled name"
```

- [ ] **Step 5: Manual smoke test (interactive, optional but recommended)**

In a real Emacs: `M-x org-fractional-cto-setup`; open two clients; `C-c a E` opens focused on the active client; press `/` to clear → all clients visible with client names in the CATEGORY column; on a TODO line press `, g` (Evil) to delegate and confirm the source entry flips to WAITING; run `M-x org-fractional-cto-upgrade-hub` on an old client and confirm it gains `#+filetags` and loses heading client tags.

---

## Self-Review

**Spec coverage:**
- §1 filetags identity → Tasks 2 (scaffold), 3 (migration). ✓
- §2 captures no tag + auto-fill name → Tasks 1 (name+plist), 4 (templates). ✓
- §3 migration via upgrade-hub → Task 3. ✓
- §4 global dashboard + (B) preset → Task 5. ✓
- §5 agenda-aware actions → Task 7. ✓
- §6 comma-localleader evil + agenda map → Task 8. ✓
- §7 bundled tag-inheritance config → Task 6. ✓
- File-by-file table & testing section → covered across Tasks 1-9; docs in Task 9. ✓

**Placeholder scan:** No TBD/TODO; every code step shows complete code; every command has an expected result.

**Type/name consistency:** `org-fractional-cto-client-name` (Task 1) used by the plist (Task 1) and docs; `org-fractional-cto--active-client-filter` defined and tested (Task 5); `org-fractional-cto--at-entry` defined (Task 7) and used by both commands (Task 7); `org-fractional-cto-agenda-command-map` / `org-fractional-cto-agenda-install-keys` / `org-fractional-cto-set-tag-inheritance` consistent between definition, setup call, and tests.

**Note for the implementer:** several pre-existing tests assert the old per-heading client tag (`:ACME:…`). Each task that changes tag output calls out updating the affected expected strings — treat a failing legacy assertion as "update the expectation to the filetag form," not as a regression.
