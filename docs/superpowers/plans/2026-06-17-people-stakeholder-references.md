# People & Stakeholder References Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make people first-class, linkable Org nodes — durable global identities referenced deterministically by `org-id` links — replacing today's static-text mentions, while keeping the per-client stakeholder relationship tracking.

**Architecture:** A new module `org-fractional-cto-people.el` owns a global people directory (one `org-id` node file per person), pure node-creation, `org-id` registration, an insert-or-create helper, and a capture target. The package emits plain `org-id` nodes only — org-roam, if the user colocates the people directory inside their roam graph, consumes them with zero package-side code. Captures and scaffolding are adjusted to create/link these nodes instead of inline text.

**Tech Stack:** Emacs Lisp, Org mode (`org-id`, `org-capture`), ERT.

## Global Constraints

- Emacs 27.1+, Org 9.4+ (from `Package-Requires`). Use only APIs available there.
- No new package dependency. `org-id` ships with Org; org-roam must NOT be required, referenced, or assumed at runtime.
- Every public symbol is prefixed `org-fractional-cto-`; private helpers `org-fractional-cto--`.
- File headers carry `;; SPDX-License-Identifier: GPL-3.0-or-later` and `-*- lexical-binding: t; -*-`.
- New interactive commands are NOT bound to keys by default (native-first / minimal-keybinding stance); they are documented for the user to bind.
- Person node files are registered with `org-id`, never added to `org-agenda-files`.
- Run the suite with `make test`; it must stay green after every task.

---

## File Structure

- **Create** `org-fractional-cto-people.el` — people directory + slug/path helpers, node listing/reading, pure node creation, `org-id` registration, `org-fractional-cto-insert-person`, and the `eP` capture target.
- **Create** `test/org-fractional-cto-people-test.el` — ERT tests for the module.
- **Create** `templates/person_note.org` — dated note template for the `eP` capture.
- **Modify** `org-fractional-cto.el` — add `org-fractional-cto-people-directory` defcustom + `org-fractional-cto--people-dir`, `require` the new module, call registration in `org-fractional-cto-setup`.
- **Modify** `org-fractional-cto-capture.el` — add a bundled-only template thunk; repoint the `eP` entry at the person target + person_note template.
- **Modify** `templates/person.org` — rewrite into the global person-node scaffold (`%NAME%`/`%ID%` placeholders + identity fields + `* About` + `* Notes / History`).
- **Modify** `templates/stakeholder.org` — add a `Person:` link line.
- **Modify** `org-fractional-cto-scaffold.el` — People section roster hint; CONTEXT.md "Key People" gains a Person-node column.
- **Modify** `Makefile` — load the new test file in the `test` target.
- **Modify** `doc/guide.org`, `doc/reference.org`, `README.org` — document the model, helper, and roam colocation; regenerate `org-fractional-cto.texi`.

> Note: `org-fractional-cto--copy-templates` copies every bundled `.org` (now including `person.org` and `person_note.org`) into each client's `templates/`. This is harmless — node creation always reads the bundled scaffold via `org-fractional-cto--template`, never a per-client override.

---

### Task 1: People directory, paths, and node listing

**Files:**
- Modify: `org-fractional-cto.el` (add defcustom after `org-fractional-cto-clients-directory` ~line 68; add `org-fractional-cto--people-dir` near `org-fractional-cto--clients-dir` ~line 180)
- Create: `org-fractional-cto-people.el`
- Create: `test/org-fractional-cto-people-test.el`
- Modify: `Makefile`

**Interfaces:**
- Produces: `org-fractional-cto-people-directory` (defcustom, directory string); `org-fractional-cto--people-dir () => string`; `org-fractional-cto-people-slug (name) => string`; `org-fractional-cto-person-file (slug) => path`; `org-fractional-cto--person-files () => list<path>`; `org-fractional-cto--person-title (file) => string|nil`; `org-fractional-cto--person-id (file) => string|nil`; `org-fractional-cto-people () => alist<(title . file)>`.

- [ ] **Step 1: Write the failing test**

Create `test/org-fractional-cto-people-test.el`:

```elisp
;;; org-fractional-cto-people-test.el --- Tests for people nodes -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Dhruva Sagar
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; ERT tests for org-fractional-cto-people: slug/path helpers, node listing,
;; pure node creation, org-id registration, the insert-or-create helper, and
;; the eP capture target.  Run with: make test

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'org-id)
(require 'org-fractional-cto)
(require 'org-fractional-cto-people)

(defmacro ofc-people-test (&rest body)
  "Run BODY with a throwaway people directory and isolated org-id state."
  (declare (indent 0) (debug t))
  `(let* ((org-fractional-cto-people-directory (make-temp-file "ofc-people" t))
          (org-id-extra-files nil)
          (org-id-locations (make-hash-table :test 'equal))
          (org-id-files nil))
     (unwind-protect (progn ,@body)
       (delete-directory org-fractional-cto-people-directory t))))

(ert-deftest ofc-people-slug-normalises-name ()
  (should (equal (org-fractional-cto-people-slug "Jane Doe") "jane_doe"))
  (should (equal (org-fractional-cto-people-slug "  O'Brien, Pat!  ") "o_brien_pat"))
  (should (equal (org-fractional-cto-people-slug "Ann-Marie") "ann_marie")))

(ert-deftest ofc-person-file-lives-under-people-dir ()
  (ofc-people-test
    (should (equal (org-fractional-cto-person-file "jane_doe")
                   (expand-file-name "jane_doe.org"
                                     (org-fractional-cto--people-dir))))))

(ert-deftest ofc-people-lists-titles-and-files ()
  (ofc-people-test
    (let ((f (org-fractional-cto-person-file "jane_doe")))
      (with-temp-file f
        (insert ":PROPERTIES:\n:ID:       abc-123\n:END:\n#+title: Jane Doe\n"))
      (should (equal (org-fractional-cto-people) (list (cons "Jane Doe" f))))
      (should (equal (org-fractional-cto--person-title f) "Jane Doe"))
      (should (equal (org-fractional-cto--person-id f) "abc-123")))))
```

Add to `Makefile` `test` target (after the prospect/capture `-l` lines):

```makefile
	  -l test/org-fractional-cto-people-test.el \
```

- [ ] **Step 2: Run test to verify it fails**

Run: `make test`
Expected: FAIL — `Cannot open load file ... org-fractional-cto-people` (module does not exist yet).

- [ ] **Step 3: Write minimal implementation**

In `org-fractional-cto.el`, add the defcustom after the `org-fractional-cto-clients-directory` block:

```elisp
(defcustom org-fractional-cto-people-directory
  (expand-file-name "people" (or (bound-and-true-p org-directory) "~/org"))
  "Directory holding one Org node per person (global, cross-client).
Each person is a file-level `org-id' node (an `:ID:' property drawer plus a
`#+title').  Point this inside your `org-roam-directory' to have roam index
the nodes; the package itself never requires org-roam."
  :type 'directory
  :group 'org-fractional-cto)
```

In `org-fractional-cto.el`, add near `org-fractional-cto--clients-dir`:

```elisp
(defun org-fractional-cto--people-dir ()
  "Return the configured people directory, expanded."
  (expand-file-name org-fractional-cto-people-directory))
```

Add `(require 'org-fractional-cto-people)` to the submodule `require` block (after `(require 'org-fractional-cto-doc)`).

Create `org-fractional-cto-people.el`:

```elisp
;;; org-fractional-cto-people.el --- Global person nodes -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Dhruva Sagar
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; People are first-class, linkable Org nodes: one file per person under
;; `org-fractional-cto-people-directory', each a file-level `org-id' node
;; (`:ID:' drawer + `#+title').  References elsewhere are plain `[[id:...]]'
;; links resolved by built-in `org-id'.  This module owns the directory/path
;; helpers, pure node creation, `org-id' registration, the insert-or-create
;; helper, and the `eP' capture target.  No org-roam dependency: roam, if the
;; people directory is inside the user's roam graph, consumes these files
;; unchanged.

;;; Code:

(require 'org-id)
(require 'seq)
(require 'subr-x)

(declare-function org-fractional-cto--people-dir "org-fractional-cto")
(declare-function org-fractional-cto--template "org-fractional-cto")
(defvar org-fractional-cto-people-directory)

(defun org-fractional-cto-people-slug (name)
  "Derive a filesystem slug from person NAME.
Lowercases, maps non-alphanumerics to single underscores, and trims."
  (let ((base (replace-regexp-in-string
               "_+" "_"
               (replace-regexp-in-string
                "[^a-z0-9]" "_" (downcase (string-trim name))))))
    (replace-regexp-in-string "\\`_+\\|_+\\'" "" base)))

(defun org-fractional-cto-person-file (slug)
  "Return the node file path for person SLUG."
  (expand-file-name (format "%s.org" slug) (org-fractional-cto--people-dir)))

(defun org-fractional-cto--person-files ()
  "Return the list of person node files on disk (absolute paths)."
  (let ((dir (org-fractional-cto--people-dir)))
    (when (file-directory-p dir)
      (directory-files dir t "\\.org\\'"))))

(defun org-fractional-cto--person-title (file)
  "Return the `#+title' of person node FILE, or nil."
  (when (file-readable-p file)
    (with-temp-buffer
      (insert-file-contents file)
      (goto-char (point-min))
      (let ((case-fold-search t))
        (when (re-search-forward "^#\\+title:[ \t]*\\(.+\\)$" nil t)
          (string-trim (match-string 1)))))))

(defun org-fractional-cto--person-id (file)
  "Return the top-level `:ID:' of person node FILE, or nil."
  (when (file-readable-p file)
    (with-temp-buffer
      (insert-file-contents file)
      (goto-char (point-min))
      (when (re-search-forward "^[ \t]*:ID:[ \t]*\\(\\S-+\\)" nil t)
        (string-trim (match-string 1))))))

(defun org-fractional-cto-people ()
  "Return an alist of (TITLE . FILE) for all titled person nodes."
  (delq nil
        (mapcar (lambda (f)
                  (let ((title (org-fractional-cto--person-title f)))
                    (and title (cons title f))))
                (org-fractional-cto--person-files))))

(provide 'org-fractional-cto-people)

;;; org-fractional-cto-people.el ends here
```

- [ ] **Step 4: Run test to verify it passes**

Run: `make test`
Expected: PASS — the three Task 1 tests pass; existing suites still pass.

- [ ] **Step 5: Commit**

```bash
git add org-fractional-cto.el org-fractional-cto-people.el test/org-fractional-cto-people-test.el Makefile
git commit -m "feat: people directory, path helpers, and node listing"
```

---

### Task 2: Pure person-node creation with org-id registration

**Files:**
- Modify: `org-fractional-cto-people.el`
- Modify: `templates/person.org` (rewrite)
- Modify: `test/org-fractional-cto-people-test.el`

**Interfaces:**
- Consumes: `org-fractional-cto-people`, `org-fractional-cto-person-file`, `org-fractional-cto--person-id`, `org-fractional-cto--people-dir`, `org-fractional-cto--template`.
- Produces: `org-fractional-cto--unique-slug (slug) => string`; `org-fractional-cto-create-person (name) => id-string` (reuses an existing node whose title equals NAME; otherwise writes a new file from the `person.org` scaffold, mints an ID via `org-id-new`, and registers it with `org-id-add-location`).

- [ ] **Step 1: Write the failing test**

Append to `test/org-fractional-cto-people-test.el`:

```elisp
(ert-deftest ofc-create-person-writes-registered-node ()
  (ofc-people-test
    (let* ((id (org-fractional-cto-create-person "Jane Doe"))
           (file (org-fractional-cto-person-file "jane_doe")))
      (should (stringp id))
      (should (file-exists-p file))
      (should (equal (org-fractional-cto--person-id file) id))
      (should (equal (org-fractional-cto--person-title file) "Jane Doe"))
      (with-temp-buffer
        (insert-file-contents file)
        (should (string-match-p "#\\+filetags: :PERSON:" (buffer-string)))
        (should (string-match-p "^\\* Notes / History" (buffer-string))))
      ;; Registered so [[id:...]] resolves.
      (should (equal (file-name-nondirectory (org-id-find-id-file id))
                     "jane_doe.org")))))

(ert-deftest ofc-create-person-reuses-existing-title ()
  (ofc-people-test
    (let ((id1 (org-fractional-cto-create-person "Jane Doe"))
          (id2 (org-fractional-cto-create-person "Jane Doe")))
      (should (equal id1 id2))
      (should (= 1 (length (org-fractional-cto--person-files)))))))

(ert-deftest ofc-unique-slug-suffixes-on-collision ()
  (ofc-people-test
    (make-directory (org-fractional-cto--people-dir) t)
    (with-temp-file (org-fractional-cto-person-file "jane_doe") (insert ""))
    (should (equal (org-fractional-cto--unique-slug "jane_doe") "jane_doe_2"))))
```

- [ ] **Step 2: Run test to verify it fails**

Run: `make test`
Expected: FAIL — `void-function org-fractional-cto-create-person`.

- [ ] **Step 3: Write minimal implementation**

Rewrite `templates/person.org` to (exact contents):

```org
:PROPERTIES:
:ID:       %ID%
:END:
#+title: %NAME%
#+filetags: :PERSON:

- Role / title:
- Organisation:
- Side: Our team | Client | Vendor | External
- Contact (email · phone):
- Socials (LinkedIn · X · GitHub · website):
- Photo:

* About

* Notes / History
```

Add to `org-fractional-cto-people.el` (before `(provide ...)`):

```elisp
(defun org-fractional-cto--unique-slug (slug)
  "Return SLUG, numerically suffixed if a node file already exists."
  (let ((candidate slug) (n 1))
    (while (file-exists-p (org-fractional-cto-person-file candidate))
      (setq n (1+ n)
            candidate (format "%s_%d" slug n)))
    candidate))

(defun org-fractional-cto--person-scaffold (name id)
  "Return new-node text for NAME with ID, from the bundled person.org scaffold."
  (let ((tpl (with-temp-buffer
               (insert-file-contents (org-fractional-cto--template "person.org"))
               (buffer-string))))
    (replace-regexp-in-string
     "%NAME%" name
     (replace-regexp-in-string "%ID%" id tpl t t) t t)))

(defun org-fractional-cto-create-person (name)
  "Create (or reuse) the person node for NAME and return its `org-id'.
A node whose `#+title' equals NAME is reused.  Otherwise a new file is written
under the people directory, given a fresh ID, and registered with `org-id'."
  (let ((existing (seq-find (lambda (cell) (string= (car cell) name))
                            (org-fractional-cto-people))))
    (if existing
        (org-fractional-cto--person-id (cdr existing))
      (let* ((slug (org-fractional-cto--unique-slug
                    (org-fractional-cto-people-slug name)))
             (file (org-fractional-cto-person-file slug))
             (id   (org-id-new)))
        (make-directory (org-fractional-cto--people-dir) t)
        (with-temp-file file
          (insert (org-fractional-cto--person-scaffold name id)))
        (org-id-add-location id file)
        id))))
```

- [ ] **Step 4: Run test to verify it passes**

Run: `make test`
Expected: PASS — Task 2 tests pass; suite green.

- [ ] **Step 5: Commit**

```bash
git add org-fractional-cto-people.el templates/person.org test/org-fractional-cto-people-test.el
git commit -m "feat: pure person-node creation with org-id registration"
```

---

### Task 3: Register existing people with org-id at setup

**Files:**
- Modify: `org-fractional-cto-people.el`
- Modify: `org-fractional-cto.el` (`org-fractional-cto-setup`, ~line 384)
- Modify: `test/org-fractional-cto-people-test.el`

**Interfaces:**
- Consumes: `org-fractional-cto--person-files`.
- Produces: `org-fractional-cto--register-people-with-org-id () => nil` (adds every person node file to `org-id-extra-files` when that variable holds a list, so links resolve in a fresh session). Called from `org-fractional-cto-setup`.

- [ ] **Step 1: Write the failing test**

Append to `test/org-fractional-cto-people-test.el`:

```elisp
(ert-deftest ofc-register-people-adds-extra-files ()
  (ofc-people-test
    (org-fractional-cto-create-person "Jane Doe")
    (org-fractional-cto-create-person "Pat Lee")
    (setq org-id-extra-files nil)
    (org-fractional-cto--register-people-with-org-id)
    (should (member (org-fractional-cto-person-file "jane_doe") org-id-extra-files))
    (should (member (org-fractional-cto-person-file "pat_lee") org-id-extra-files))))

(ert-deftest ofc-register-people-tolerates-symbol-extra-files ()
  (ofc-people-test
    (org-fractional-cto-create-person "Jane Doe")
    (let ((org-id-extra-files 'org-agenda-text-search-extra-files))
      ;; Must not error when the variable is a symbol rather than a list.
      (should (progn (org-fractional-cto--register-people-with-org-id) t)))))
```

- [ ] **Step 2: Run test to verify it fails**

Run: `make test`
Expected: FAIL — `void-function org-fractional-cto--register-people-with-org-id`.

- [ ] **Step 3: Write minimal implementation**

Add to `org-fractional-cto-people.el` (before `(provide ...)`):

```elisp
(defun org-fractional-cto--register-people-with-org-id ()
  "Make every person node resolvable by `org-id' in a fresh session.
Adds the node files to `org-id-extra-files' when that variable holds a list."
  (when (listp org-id-extra-files)
    (dolist (file (org-fractional-cto--person-files))
      (add-to-list 'org-id-extra-files file))))
```

In `org-fractional-cto.el`, add to `org-fractional-cto-setup` (after the `org-agenda-files` dolist, before the keymap block):

```elisp
  (org-fractional-cto--register-people-with-org-id)
```

Add a `declare-function` near the other submodule declarations in `org-fractional-cto.el`:

```elisp
(declare-function org-fractional-cto--register-people-with-org-id "org-fractional-cto-people")
```

- [ ] **Step 4: Run test to verify it passes**

Run: `make test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add org-fractional-cto-people.el org-fractional-cto.el test/org-fractional-cto-people-test.el
git commit -m "feat: register person nodes with org-id at setup"
```

---

### Task 4: Insert-or-create helper

**Files:**
- Modify: `org-fractional-cto-people.el`
- Modify: `test/org-fractional-cto-people-test.el`

**Interfaces:**
- Consumes: `org-fractional-cto-people`, `org-fractional-cto--person-id`, `org-fractional-cto-create-person`.
- Produces: `org-fractional-cto-insert-person ()` (interactive) — completes over people by title and inserts `[[id:ID][Name]]` at point; on an unknown name, prompts (`y-or-n-p`) to create the node, then inserts the link to it.

- [ ] **Step 1: Write the failing test**

Append to `test/org-fractional-cto-people-test.el`:

```elisp
(ert-deftest ofc-insert-person-links-existing ()
  (ofc-people-test
    (let ((id (org-fractional-cto-create-person "Jane Doe")))
      (with-temp-buffer
        (cl-letf (((symbol-function 'completing-read)
                   (lambda (&rest _) "Jane Doe")))
          (org-fractional-cto-insert-person))
        (should (equal (buffer-string)
                       (format "[[id:%s][Jane Doe]]" id)))))))

(ert-deftest ofc-insert-person-creates-on-unknown-name ()
  (ofc-people-test
    (with-temp-buffer
      (cl-letf (((symbol-function 'completing-read)
                 (lambda (&rest _) "New Person"))
                ((symbol-function 'y-or-n-p) (lambda (&rest _) t)))
        (org-fractional-cto-insert-person))
      (should (file-exists-p (org-fractional-cto-person-file "new_person")))
      (let ((id (org-fractional-cto--person-id
                 (org-fractional-cto-person-file "new_person"))))
        (should (equal (buffer-string)
                       (format "[[id:%s][New Person]]" id)))))))

(ert-deftest ofc-insert-person-declined-inserts-nothing ()
  (ofc-people-test
    (with-temp-buffer
      (cl-letf (((symbol-function 'completing-read)
                 (lambda (&rest _) "Nope"))
                ((symbol-function 'y-or-n-p) (lambda (&rest _) nil)))
        (org-fractional-cto-insert-person))
      (should (equal (buffer-string) "")))))
```

- [ ] **Step 2: Run test to verify it fails**

Run: `make test`
Expected: FAIL — `void-function org-fractional-cto-insert-person`.

- [ ] **Step 3: Write minimal implementation**

Add to `org-fractional-cto-people.el` (before `(provide ...)`):

```elisp
;;;###autoload
(defun org-fractional-cto-insert-person ()
  "Insert an `[[id:...][Name]]' link to a person, creating the node if new.
Completes over existing person nodes by name.  Entering a name with no match
offers to create the node and then links it.  Bind it yourself if you like;
org-roam users may instead use `org-roam-node-insert'."
  (interactive)
  (let* ((people (org-fractional-cto-people))
         (name (completing-read "Person: " (mapcar #'car people) nil nil))
         (cell (assoc name people))
         (id (if cell
                 (org-fractional-cto--person-id (cdr cell))
               (when (y-or-n-p (format "Create new person \"%s\"? " name))
                 (org-fractional-cto-create-person name)))))
    (when id
      (insert (format "[[id:%s][%s]]" id name)))))
```

- [ ] **Step 4: Run test to verify it passes**

Run: `make test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add org-fractional-cto-people.el test/org-fractional-cto-people-test.el
git commit -m "feat: org-fractional-cto-insert-person insert-or-create helper"
```

---

### Task 5: Repoint the `eP` capture at global person nodes

**Files:**
- Modify: `org-fractional-cto-people.el` (capture target)
- Create: `templates/person_note.org`
- Modify: `org-fractional-cto-capture.el` (bundled-only thunk + `eP` entry)
- Modify: `test/org-fractional-cto-people-test.el`
- Modify: `test/org-fractional-cto-capture-test.el`

**Interfaces:**
- Consumes: `org-fractional-cto-people`, `org-fractional-cto-create-person`.
- Produces: `org-fractional-cto--person-goto-notes (file)` (visit FILE, move point to end of its `Notes / History`, creating that heading if absent); `org-fractional-cto--capture-to-person ()` (capture target: pick or create a person, then goto its Notes / History); `org-fractional-cto--bundled-file (filename)` in capture.el (a `(function ...)` thunk yielding the bundled template, with NO client selection).

- [ ] **Step 1: Write the failing test**

Append to `test/org-fractional-cto-people-test.el`:

```elisp
(ert-deftest ofc-person-goto-notes-positions-in-history ()
  (ofc-people-test
    (org-fractional-cto-create-person "Jane Doe")
    (let ((file (org-fractional-cto-person-file "jane_doe")))
      (save-window-excursion
        (org-fractional-cto--person-goto-notes file)
        (should (equal (buffer-file-name) file))
        ;; Point sits on the Notes / History heading line.
        (should (string-match-p "Notes / History"
                                (buffer-substring (line-beginning-position)
                                                  (line-end-position)))))
      (kill-buffer (find-file-noselect file)))))
```

Append to `test/org-fractional-cto-capture-test.el`:

```elisp
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `make test`
Expected: FAIL — `void-function org-fractional-cto--capture-to-person` and the `eP` entry assertion fails.

- [ ] **Step 3: Write minimal implementation**

Create `templates/person_note.org` (exact contents):

```org
* %U %?
```

Add to `org-fractional-cto-people.el` (before `(provide ...)`):

```elisp
(defun org-fractional-cto--person-goto-notes (file)
  "Visit person FILE and move point onto its `Notes / History' heading.
Appends the heading if the node lacks one."
  (find-file file)
  (widen)
  (goto-char (point-min))
  (if (re-search-forward "^\\*+ Notes / History[ \t]*$" nil t)
      (beginning-of-line)
    (goto-char (point-max))
    (unless (bolp) (insert "\n"))
    (insert "* Notes / History\n")
    (forward-line -1)))

(defun org-fractional-cto--capture-to-person ()
  "Capture target for `eP': pick or create a person; file under Notes / History."
  (let* ((people (org-fractional-cto-people))
         (name (completing-read "Person: " (mapcar #'car people) nil nil))
         (cell (assoc name people))
         (file (if cell
                   (cdr cell)
                 (progn (org-fractional-cto-create-person name)
                        (cdr (assoc name (org-fractional-cto-people)))))))
    (org-fractional-cto--person-goto-notes file)))
```

In `org-fractional-cto-capture.el`, add a bundled-only thunk after `org-fractional-cto--file`:

```elisp
(defun org-fractional-cto--bundled-file (filename)
  "Return a capture-template thunk yielding bundled FILENAME's contents.
Unlike `org-fractional-cto--file' this performs NO client selection or
per-client override resolution; use it for templates (e.g. person notes) that
are not scoped to a client."
  (lambda () (org-fractional-cto--file-contents
              (org-fractional-cto--template filename))))
```

Add a `declare-function` near the top of `org-fractional-cto-capture.el`:

```elisp
(declare-function org-fractional-cto--capture-to-person "org-fractional-cto-people")
```

Replace the existing `eP` entry in `org-fractional-cto-capture-templates`:

```elisp
    ("eP" "Person note (global)" entry
     (function org-fractional-cto--capture-to-person)
     (function ,(org-fractional-cto--bundled-file "person_note.org")))
```

- [ ] **Step 4: Run test to verify it passes**

Run: `make test`
Expected: PASS — new tests pass; existing capture tests still pass.

- [ ] **Step 5: Commit**

```bash
git add org-fractional-cto-people.el templates/person_note.org org-fractional-cto-capture.el test/org-fractional-cto-people-test.el test/org-fractional-cto-capture-test.el
git commit -m "feat: route eP capture to global person nodes"
```

---

### Task 6: Link stakeholder profiles to the person node

**Files:**
- Modify: `templates/stakeholder.org`
- Modify: `test/org-fractional-cto-capture-test.el`

**Interfaces:**
- Produces: a `Person:` line in the stakeholder template for an `[[id:...]]` link to the global node.

- [ ] **Step 1: Write the failing test**

Append to `test/org-fractional-cto-capture-test.el`:

```elisp
(ert-deftest ofc-stakeholder-template-has-person-link-line ()
  "The bundled stakeholder template prompts for a link to the global person."
  (let ((text (org-fractional-cto--file-contents
               (org-fractional-cto--template "stakeholder.org"))))
    (should (string-match-p "^Person (global node):" text))))
```

- [ ] **Step 2: Run test to verify it fails**

Run: `make test`
Expected: FAIL — pattern not found in `stakeholder.org`.

- [ ] **Step 3: Write minimal implementation**

In `templates/stakeholder.org`, insert one line after the `Organisation:` line (line 5), before the `%?`:

```org
Person (global node): %?
```

Adjust so the existing `%?` is not duplicated — the final template head reads:

```org
* STAKEHOLDER: %^{Full name} :STAKEHOLDER:
%U
Client: %(org-capture-get :ofc-client-name)
Role / Title: %^{Role}
Organisation: %^{Organisation}
Person (global node): 

** Decision & Influence
```

(Leave the `Person (global node):` value blank — the user fills it with `C-c C-l` / `org-fractional-cto-insert-person`. Keep the remaining body — Decision & Influence through Notes / History — unchanged. The original `%?` after Organisation is removed, since the cursor now rests via the structured body; if you prefer a landing point, append `%?` to the `Person (global node):` line instead.)

- [ ] **Step 4: Run test to verify it passes**

Run: `make test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add templates/stakeholder.org test/org-fractional-cto-capture-test.el
git commit -m "feat: link stakeholder profiles to global person node"
```

---

### Task 7: Scaffold — People roster hint and CONTEXT Person column

**Files:**
- Modify: `org-fractional-cto-scaffold.el` (`org-fractional-cto--write-hub`, `org-fractional-cto--write-context`)
- Create/Modify: `test/org-fractional-cto-scaffold-test.el` (new test file)
- Modify: `Makefile`

**Interfaces:**
- Consumes: `org-fractional-cto--scaffold` (existing), `org-fractional-cto-client-org-file`, `org-fractional-cto-client-context-file`.
- Produces: hub *People* section carries a one-line roster hint; CONTEXT.md "Key People" tables gain a `Person node` column.

- [ ] **Step 1: Write the failing test**

Create `test/org-fractional-cto-scaffold-test.el`:

```elisp
;;; org-fractional-cto-scaffold-test.el --- Tests for scaffolding -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Dhruva Sagar
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; ERT tests for people-related scaffold output.  Run with: make test

;;; Code:

(require 'ert)
(require 'org-fractional-cto)
(require 'org-fractional-cto-scaffold)

(defmacro ofc-scaffold-test (&rest body)
  (declare (indent 0) (debug t))
  `(let ((org-fractional-cto-clients-directory (make-temp-file "ofc-scaffold" t)))
     (unwind-protect (progn ,@body)
       (delete-directory org-fractional-cto-clients-directory t))))

(defun ofc-scaffold-test--contents (file)
  (with-temp-buffer (insert-file-contents file) (buffer-string)))

(ert-deftest ofc-hub-people-section-has-roster-hint ()
  (ofc-scaffold-test
    (org-fractional-cto--scaffold "Acme" "acme"
                                  org-fractional-cto-default-stage)
    (let ((hub (ofc-scaffold-test--contents
                (org-fractional-cto-client-org-file "acme"))))
      (should (string-match-p "people directory" hub)))))

(ert-deftest ofc-context-key-people-has-person-column ()
  (ofc-scaffold-test
    (org-fractional-cto--scaffold "Acme" "acme"
                                  org-fractional-cto-default-stage)
    (let ((ctx (ofc-scaffold-test--contents
                (org-fractional-cto-client-context-file "acme"))))
      (should (string-match-p "Person node" ctx)))))
```

Add to `Makefile` `test` target:

```makefile
	  -l test/org-fractional-cto-scaffold-test.el \
```

- [ ] **Step 2: Run test to verify it fails**

Run: `make test`
Expected: FAIL — neither "people directory" nor "Person node" is present yet.

- [ ] **Step 3: Write minimal implementation**

In `org-fractional-cto-scaffold.el`, change the `dolist` in `org-fractional-cto--write-hub` to add a hint under the People section:

```elisp
    (dolist (section org-fractional-cto-sections)
      (let ((heading (car section)) (subtag (cadr section)))
        (if (string-empty-p subtag)
            (insert (format "** %s\n" heading))
          (insert (format "** %s  :%s:\n" heading subtag)))
        (when (string= subtag "PEOPLE")
          (insert "Roster — link the people in this engagement with [[id:...]] (C-c C-l, or M-x org-fractional-cto-insert-person).  Canonical person nodes live in the people directory.\n"))
        (insert "\n")))))
```

In `org-fractional-cto--write-context`, update the two "Key People" tables to add a Person-node column:

```elisp
      (insert "## Key People\n\n### Client Side\n| Name | Role | Person node | Notes |\n|------|------|-------------|-------|\n|      |      |             |       |\n\n")
      (insert "### Our Side\n| Name | Role / Stream | Person node | Notes |\n|------|---------------|-------------|-------|\n|      |               |             |       |\n\n---\n\n")
```

- [ ] **Step 4: Run test to verify it passes**

Run: `make test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add org-fractional-cto-scaffold.el test/org-fractional-cto-scaffold-test.el Makefile
git commit -m "feat: link-aware People roster hint and CONTEXT Person column"
```

---

### Task 8: Documentation and Texinfo regeneration

**Files:**
- Modify: `doc/guide.org`, `doc/reference.org`, `README.org`
- Regenerate: `org-fractional-cto.texi`

> Note: the repo's git status shows `doc/` is being renamed to `docs/`. Edit whichever path is current on the working branch (`git ls-files doc docs | grep guide`). The Makefile `info` target reads `doc/*.org`; if the sources have moved to `docs/`, update the `info` target's prerequisites and `--visit` path to match before running `make info`.

**Interfaces:** none (documentation only).

- [ ] **Step 1: Add a People & Stakeholders section to the guide**

In `doc/guide.org` (or `docs/guide.org`), add a section documenting:

```org
* People & Stakeholders

People are first-class Org nodes, not inline text.  Each person is one file
under =org-fractional-cto-people-directory= (default =~/org/people=), a
file-level =org-id= node with an =:ID:= and a =#+title=.  This record is
global and durable: it survives any client being archived or deleted, and is
where long-term, cross-engagement history about a person accumulates.

A *stakeholder profile* is different: it lives in the client hub's
=Stakeholder Profiles= section and captures engagement-specific relationship
data (influence, what success means to them, communication cadence).  It links
to the global person via its =Person (global node):= line.  One person can be a
stakeholder at several clients.

** Referencing a person

- =M-x org-fractional-cto-insert-person= — complete by name and insert an
  =[[id:...][Name]]= link; type a new name to create the node on the fly.
- Or the native dance: visit the person node, =C-c l= (=org-store-link=), then
  =C-c C-l= (=org-insert-link=) where you are writing.
- The =eP= capture (=C-c c e P=) files a timestamped note under a person's
  =Notes / History=, creating the node if needed.

** org-roam users

org-roam is *not* required.  If you already use roam, set
=org-fractional-cto-people-directory= to a folder inside your
=org-roam-directory=; roam then indexes these nodes and your
=org-roam-node-insert= and backlinks buffer work unchanged.
```

- [ ] **Step 2: Document the custom and command in the reference**

In `doc/reference.org` (or `docs/reference.org`), add `org-fractional-cto-people-directory` to the customization list and `org-fractional-cto-insert-person` to the command list, with one-line descriptions matching the docstrings.

- [ ] **Step 3: Update the README**

In `README.org`, add a short "People & stakeholders" subsection mirroring the guide: the person/stakeholder split, `org-fractional-cto-insert-person`, and the roam colocation tip.

- [ ] **Step 4: Regenerate the Texinfo manual**

Run: `make info`
Expected: `org-fractional-cto.texi` regenerates with no error (broken-link export is tolerated by the target).

- [ ] **Step 5: Verify the suite and commit**

Run: `make test`
Expected: PASS — full suite green.

```bash
git add doc docs README.org org-fractional-cto.texi
git commit -m "docs: document people nodes, insert-person, and roam colocation"
```

---

## Self-Review

**Spec coverage:**
- Two entities (global person / client stakeholder) → Tasks 2, 6.
- People directory defcustom, sibling default → Task 1.
- Native org-id resolution, not agenda-files → Tasks 2 (`org-id-add-location`), 3 (`org-id-extra-files`).
- No org-roam dependency; colocation documented → Task 8 (no roam code anywhere).
- Insert-or-create helper, unbound, insert-or-create semantics → Task 4.
- Person fields (role/org/side/contact/socials/photo/about/notes-history) → Task 2 (`person.org`).
- `eP` repurposed to global node; `ep`/stakeholder gains Person link → Tasks 5, 6.
- People section roster + CONTEXT Person column → Task 7.
- Non-destructive migration → no task removes existing data; documented in Task 8.
- Docs across guide/reference/README/texinfo → Task 8.

**Placeholder scan:** No "TBD"/"handle edge cases"/"similar to" — every code and test step shows full content. The same-name-different-person edge case is implemented (`org-fractional-cto--unique-slug`, Task 2) rather than deferred.

**Type consistency:** `org-fractional-cto-create-person` returns an id string (Tasks 2, 4, 5 agree). `org-fractional-cto-people` returns `(title . file)` alist (consumed consistently in Tasks 1–5). `org-fractional-cto--capture-to-person` is referenced identically in the capture entry and its declare-function (Task 5). `org-fractional-cto--register-people-with-org-id` declared in `org-fractional-cto.el` and defined in the people module with matching name (Task 3).
