# People Assignment & Reference Links Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make every people-reference in the templates and at-point commands a deterministic `[[id:...][Name]]` link, and tag single-owner TODO headings with a stable `@slug` person tag so the native agenda `/` filter can slice work by person.

**Architecture:** A single resolver (`org-fractional-cto-person-record`) turns a name into a `(:id :name :slug :tag :link)` record (creating the node if new, reusing Task-4's `create-person`). Capture templates call thin `%(...)` helpers that return link text and, for owners, stash the person in the capture plist; an `org-capture-before-finalize-hook` reads that and applies the `@slug` tag. The two at-point commands swap their `read-string` prompts for the same resolver. Querying stays native (Org's `/` agenda tag filter); no new command.

**Tech Stack:** Emacs Lisp, Org mode (`org-capture`, `org-id`, tags), ERT.

## Global Constraints

- Emacs 27.1+, Org 9.4+ APIs only. No org-roam dependency, reference, or runtime assumption.
- Public symbols prefixed `org-fractional-cto-`; private `org-fractional-cto--`.
- `.el` files carry `;; SPDX-License-Identifier: GPL-3.0-or-later` and `-*- lexical-binding: t; -*-`.
- Person tag is exactly `@` + the node's filename slug (e.g. `jane_doe.org` → `@jane_doe`). Slugs are already `[a-z0-9_]`, valid in Org tags.
- Heading tags are applied ONLY for the five single-owner TODO types: delegation (`:ASSIGNED_TO:`), blocker (`:UNBLOCK_OWNER:`), commitment, risk, security `Owner`. Everything else gets links only.
- Person nodes are never added to `org-agenda-files`.
- Typing a name with no existing node creates the node (no confirmation) in the capture/at-point path — this is the intended fast flow.
- Querying per person uses Org's native `/` agenda filter; do NOT add a per-person agenda command.
- Run the suite with `make test`; it must stay green after every task. Current baseline: 87 tests.

---

## File Structure

- **Modify** `org-fractional-cto-people.el` — add `org-fractional-cto-person-tag`, `org-fractional-cto-person-record`, `org-fractional-cto--read-person-name` (Task 1); `org-fractional-cto--capture-person`, `org-fractional-cto--capture-people`, `org-fractional-cto--apply-person-tag` (Task 2).
- **Modify** `org-fractional-cto-capture.el` — register the finalize hook in `org-fractional-cto-capture-install`; declare-functions (Task 2).
- **Modify** `org-fractional-cto-actions.el` — upgrade `delegate-at-point`, `block-at-point`, `--blocker-subtree` to the resolver + tag (Task 4).
- **Modify templates (tagged owners):** `delegation.org`, `blocker.org`, `commitment.org`, `risk.org`, `security.org` (Task 3).
- **Modify templates (link-only):** `client_meeting.org`, `discovery.org`, `presales_call.org`, `qbr.org`, `retrospective.org`, `innovation_meeting.org`, `arch_review.org`, `vendor_eval.org`, `quick_decision.org`, `scope_change.org` (Task 5).
- **Modify tests:** `test/org-fractional-cto-people-test.el` (Tasks 1–3), `test/org-fractional-cto-actions-test.el` (Task 4 — incl. fixture isolation), `test/org-fractional-cto-capture-test.el` (Tasks 3, 5 — template content assertions).
- **Modify docs:** `docs/guide.org`, `docs/reference.org`, `README.org`, regenerate `org-fractional-cto.texi` (Task 6).

> **Out of automated scope (documented, not coded):** Owner *columns inside tables* (e.g. the "| Action | Owner | Due |" tables) are filled by hand after capture; users link them with `M-x org-fractional-cto-insert-person`. Capture `%(...)` escapes cannot target table cells, so these stay free-text headers. Task 6 documents this.

---

### Task 1: Person resolver and tag helper

**Files:**
- Modify: `org-fractional-cto-people.el` (add before `(provide ...)`)
- Test: `test/org-fractional-cto-people-test.el`

**Interfaces:**
- Consumes: `org-fractional-cto-create-person (name) => id`, `org-fractional-cto-people () => alist<(title . file)>`, `org-fractional-cto-person-file (slug) => path`, `org-fractional-cto--person-files`.
- Produces: `org-fractional-cto-person-tag (slug) => "@slug"`; `org-fractional-cto-person-record (name) => plist (:id :name :slug :tag :link)` (creates-or-reuses the node); `org-fractional-cto--read-person-name (prompt) => string` (completing-read over people by name, free text allowed).

- [ ] **Step 1: Write the failing test**

Append to `test/org-fractional-cto-people-test.el`:

```elisp
(ert-deftest ofc-person-tag-prefixes-at ()
  (should (equal (org-fractional-cto-person-tag "jane_doe") "@jane_doe")))

(ert-deftest ofc-person-record-creates-and-describes ()
  (ofc-people-test
    (let ((rec (org-fractional-cto-person-record "Jane Doe")))
      (should (equal (plist-get rec :name) "Jane Doe"))
      (should (equal (plist-get rec :slug) "jane_doe"))
      (should (equal (plist-get rec :tag) "@jane_doe"))
      (should (equal (plist-get rec :link)
                     (format "[[id:%s][Jane Doe]]" (plist-get rec :id))))
      (should (file-exists-p (org-fractional-cto-person-file "jane_doe"))))))

(ert-deftest ofc-person-record-reuses-existing ()
  (ofc-people-test
    (let ((r1 (org-fractional-cto-person-record "Jane Doe"))
          (r2 (org-fractional-cto-person-record "Jane Doe")))
      (should (equal (plist-get r1 :id) (plist-get r2 :id)))
      (should (= 1 (length (org-fractional-cto--person-files)))))))

(ert-deftest ofc-read-person-name-returns-completion ()
  (ofc-people-test
    (cl-letf (((symbol-function 'completing-read)
               (lambda (&rest _) "Typed Name")))
      (should (equal (org-fractional-cto--read-person-name "Owner") "Typed Name")))))
```

- [ ] **Step 2: Run test to verify it fails**

Run: `make test`
Expected: FAIL — `void-function org-fractional-cto-person-tag` (and the other new symbols).

- [ ] **Step 3: Write minimal implementation**

Add to `org-fractional-cto-people.el` before `(provide ...)`:

```elisp
(defun org-fractional-cto-person-tag (slug)
  "Return the Org heading tag for person SLUG (e.g. \"jane_doe\" -> \"@jane_doe\").
SLUG is a person node's filename base; it is already `[a-z0-9_]', valid in an
Org tag."
  (concat "@" slug))

(defun org-fractional-cto-person-record (name)
  "Ensure a person node exists for NAME and return a descriptor plist.
The plist has :id, :name, :slug, :tag (see `org-fractional-cto-person-tag'),
and :link (an `[[id:ID][NAME]]' string).  Reuses an existing node whose title
equals NAME, otherwise creates one."
  (let* ((id   (org-fractional-cto-create-person name))
         (file (cdr (assoc name (org-fractional-cto-people))))
         (slug (and file (file-name-base file))))
    (list :id id :name name :slug slug
          :tag (and slug (org-fractional-cto-person-tag slug))
          :link (format "[[id:%s][%s]]" id name))))

(defun org-fractional-cto--read-person-name (prompt)
  "Completing-read a person by display name for PROMPT.
Existing person titles are offered; free text is allowed so a new name flows
through to node creation.  Returns the chosen/typed string (possibly empty)."
  (completing-read (format "%s: " prompt)
                   (mapcar #'car (org-fractional-cto-people)) nil nil))
```

- [ ] **Step 4: Run test to verify it passes**

Run: `make test`
Expected: PASS — the four new tests pass; suite green.

- [ ] **Step 5: Commit**

```bash
git add org-fractional-cto-people.el test/org-fractional-cto-people-test.el
git commit -m "feat: person resolver record and @slug tag helper"
```

---

### Task 2: Capture %() helpers and the tag finalize hook

**Files:**
- Modify: `org-fractional-cto-people.el` (add before `(provide ...)`)
- Modify: `org-fractional-cto-capture.el` (register hook + declare-functions)
- Test: `test/org-fractional-cto-people-test.el`

**Interfaces:**
- Consumes: `org-fractional-cto-person-record`, `org-fractional-cto--read-person-name`, `org-capture-get`/`org-capture-put`.
- Produces: `org-fractional-cto--capture-person (prompt &optional tag) => link-string` (returns `[[id:]]` link; with TAG non-nil also `org-capture-put`s the record under `:ofc-person`); `org-fractional-cto--capture-people (prompt) => string` (comma-separated link list, empty input ends); `org-fractional-cto--apply-person-tag ()` (before-finalize hook: tag the captured heading with the `:ofc-person` record's `:tag`, no-op when absent). Hook registered in `org-fractional-cto-capture-install`.

- [ ] **Step 1: Write the failing test**

Append to `test/org-fractional-cto-people-test.el`:

```elisp
(ert-deftest ofc-capture-person-returns-link-and-flags-tag ()
  (ofc-people-test
    (let ((org-capture-plist nil))
      (cl-letf (((symbol-function 'org-fractional-cto--read-person-name)
                 (lambda (&rest _) "Jane Doe")))
        (let ((link (org-fractional-cto--capture-person "Owner" t)))
          (should (string-match-p "\\`\\[\\[id:.+\\]\\[Jane Doe\\]\\]\\'" link))
          (should (equal (plist-get (org-capture-get :ofc-person) :tag)
                         "@jane_doe")))))))

(ert-deftest ofc-capture-person-without-tag-does-not-flag ()
  (ofc-people-test
    (let ((org-capture-plist nil))
      (cl-letf (((symbol-function 'org-fractional-cto--read-person-name)
                 (lambda (&rest _) "Jane Doe")))
        (org-fractional-cto--capture-person "Made by")
        (should-not (org-capture-get :ofc-person))))))

(ert-deftest ofc-capture-people-builds-comma-list ()
  (ofc-people-test
    (let ((names (list "Ann" "Bob" "")))
      (cl-letf (((symbol-function 'org-fractional-cto--read-person-name)
                 (lambda (&rest _) (pop names))))
        (let ((result (org-fractional-cto--capture-people "Attendees")))
          (should (string-match-p
                   "\\`\\[\\[id:.+\\]\\[Ann\\]\\], \\[\\[id:.+\\]\\[Bob\\]\\]\\'"
                   result)))))))

(ert-deftest ofc-apply-person-tag-tags-heading ()
  (with-temp-buffer
    (org-mode)
    (insert "* WAITING Do the thing\n")
    (let ((org-capture-plist (list :ofc-person '(:tag "@alice"))))
      (org-fractional-cto--apply-person-tag))
    (goto-char (point-min))
    (should (member "@alice" (org-get-tags)))))

(ert-deftest ofc-apply-person-tag-noop-without-person ()
  (with-temp-buffer
    (org-mode)
    (insert "* WAITING Do the thing\n")
    (let ((org-capture-plist nil))
      (org-fractional-cto--apply-person-tag))
    (goto-char (point-min))
    (should-not (org-get-tags))))

(ert-deftest ofc-capture-install-registers-finalize-hook ()
  (let ((org-capture-before-finalize-hook nil))
    (org-fractional-cto-capture-install)
    (should (memq 'org-fractional-cto--apply-person-tag
                  org-capture-before-finalize-hook))))
```

- [ ] **Step 2: Run test to verify it fails**

Run: `make test`
Expected: FAIL — `void-function org-fractional-cto--capture-person` (and the hook is not yet registered).

- [ ] **Step 3: Write minimal implementation**

Add to `org-fractional-cto-people.el` before `(provide ...)`:

```elisp
(defun org-fractional-cto--capture-person (prompt &optional tag)
  "Capture `%()' helper: pick a person for PROMPT and return an `[[id:]]' link.
With TAG non-nil, also stash the person record under `:ofc-person' in the
capture plist so `org-fractional-cto--apply-person-tag' tags the heading on
finalize.  Returns an empty string when no name is entered."
  (let ((name (org-fractional-cto--read-person-name prompt)))
    (if (or (null name) (string-empty-p (string-trim name)))
        ""
      (let ((rec (org-fractional-cto-person-record name)))
        (when tag (org-capture-put :ofc-person rec))
        (plist-get rec :link)))))

(defun org-fractional-cto--capture-people (prompt)
  "Capture `%()' helper: pick people for PROMPT until empty input.
Returns a comma-separated string of `[[id:]]' links (empty string if none)."
  (let ((links nil)
        (name (org-fractional-cto--read-person-name prompt)))
    (while (and name (not (string-empty-p (string-trim name))))
      (push (plist-get (org-fractional-cto-person-record name) :link) links)
      (setq name (org-fractional-cto--read-person-name
                  (format "%s (another; empty to finish)" prompt))))
    (mapconcat #'identity (nreverse links) ", ")))

(defun org-fractional-cto--apply-person-tag ()
  "Tag the captured heading with the `:ofc-person' record's tag, if any.
Registered on `org-capture-before-finalize-hook'; a no-op for captures that did
not select a taggable person."
  (let ((rec (org-capture-get :ofc-person)))
    (when rec
      (save-excursion
        (goto-char (point-min))
        (unless (org-at-heading-p) (outline-next-heading))
        (when (org-at-heading-p)
          (org-toggle-tag (plist-get rec :tag) 'on))))))
```

In `org-fractional-cto-capture.el`, add declare-functions near the top (with the other `declare-function`s):

```elisp
(declare-function org-fractional-cto--apply-person-tag "org-fractional-cto-people")
```

In `org-fractional-cto-capture.el`, register the hook inside `org-fractional-cto-capture-install` (add as the first form in its `let` body, before the `setq org-capture-templates`):

```elisp
    (add-hook 'org-capture-before-finalize-hook
              #'org-fractional-cto--apply-person-tag)
```

- [ ] **Step 4: Run test to verify it passes**

Run: `make test`
Expected: PASS — six new tests pass; suite green.

- [ ] **Step 5: Commit**

```bash
git add org-fractional-cto-people.el org-fractional-cto-capture.el test/org-fractional-cto-people-test.el
git commit -m "feat: capture person helpers and @slug tag finalize hook"
```

---

### Task 3: Tagged-owner template edits

**Files:**
- Modify: `templates/delegation.org`, `templates/blocker.org`, `templates/commitment.org`, `templates/risk.org`, `templates/security.org`
- Test: `test/org-fractional-cto-capture-test.el`

**Interfaces:**
- Consumes: `org-fractional-cto--capture-person` (Task 2). The trailing `t` makes the finalize hook tag the heading.

> Rationale for content-assertion tests: driving the full `org-capture` UI in batch is flaky. The tag mechanism itself is verified by Task 2's `ofc-apply-person-tag-tags-heading` and `ofc-capture-person-returns-link-and-flags-tag`. Here we assert each template now invokes the tagging helper.

- [ ] **Step 1: Write the failing test**

Append to `test/org-fractional-cto-capture-test.el`:

```elisp
(ert-deftest ofc-owner-templates-use-tagging-person-helper ()
  "Each single-owner template invokes the person helper with the tag flag."
  (dolist (name '("delegation.org" "blocker.org" "commitment.org"
                  "risk.org" "security.org"))
    (let ((text (org-fractional-cto--file-contents
                 (org-fractional-cto--template name))))
      (should (string-match-p
               "%(org-fractional-cto--capture-person \"[^\"]+\" t)" text)))))
```

- [ ] **Step 2: Run test to verify it fails**

Run: `make test`
Expected: FAIL — the templates still use `%^{...}` prompts.

- [ ] **Step 3: Write minimal implementation**

Edit each template, replacing exactly the owner field line:

`templates/delegation.org` — replace `:ASSIGNED_TO: %^{Assigned to}` with:
```
:ASSIGNED_TO: %(org-fractional-cto--capture-person "Assigned to" t)
```

`templates/blocker.org` — replace `:UNBLOCK_OWNER: %^{Who can remove this blocker}` with:
```
:UNBLOCK_OWNER: %(org-fractional-cto--capture-person "Who can remove this blocker" t)
```

`templates/commitment.org` — replace `Owner (internal): %^{Owner}` with:
```
Owner (internal): %(org-fractional-cto--capture-person "Owner" t)
```

`templates/risk.org` — replace `Owner: %^{Owner}` with:
```
Owner: %(org-fractional-cto--capture-person "Owner" t)
```

`templates/security.org` — replace `Owner: %^{Owner}` with:
```
Owner: %(org-fractional-cto--capture-person "Owner" t)
```

- [ ] **Step 4: Run test to verify it passes**

Run: `make test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add templates/delegation.org templates/blocker.org templates/commitment.org templates/risk.org templates/security.org test/org-fractional-cto-capture-test.el
git commit -m "feat: tagged-owner templates link and tag the assignee"
```

---

### Task 4: Upgrade at-point commands to link + tag

**Files:**
- Modify: `org-fractional-cto-actions.el` (`delegate-at-point`, `block-at-point`, `--blocker-subtree`)
- Test: `test/org-fractional-cto-actions-test.el` (fixture isolation + updated assertions)

**Interfaces:**
- Consumes: `org-fractional-cto-person-record`, `org-fractional-cto--read-person-name` (Task 1).
- Produces: `delegate-at-point` sets `:ASSIGNED_TO:` to the `[[id:]]` link and adds the `@slug` tag; `block-at-point` puts the link in `:UNBLOCK_OWNER:` and tags the new blocker heading. `--blocker-subtree` gains a trailing optional `person-tag` argument appended to the BLOCKER headline's tag cluster.

- [ ] **Step 1: Write the failing test**

In `test/org-fractional-cto-actions-test.el`, first make the fixture isolate people/org-id state. Replace the `ofc-test-with-hub` macro body so the `let*` also binds a temp people directory and fresh org-id state:

```elisp
(defmacro ofc-test-with-hub (&rest body)
  "Visit a fresh acme.org hub in a temp dir and run BODY at its start.
Also isolates the people directory and `org-id' state so delegating/blocking
to a person never touches the user's real files."
  (declare (indent 0) (debug t))
  `(let* ((dir (make-temp-file "ofc-test" t))
          (file (expand-file-name "acme.org" dir))
          (org-fractional-cto-people-directory
           (expand-file-name "people" dir))
          (org-id-extra-files nil)
          (org-id-locations (make-hash-table :test 'equal))
          (org-id-files nil))
     (unwind-protect
         (progn
           (with-temp-file file (insert ofc-test-hub))
           (find-file file)
           (org-mode)
           (goto-char (point-min))
           ,@body)
       (when (get-file-buffer file) (kill-buffer (get-file-buffer file)))
       (delete-directory dir t))))
```

Then update the delegate assertion test and add a tag assertion. Replace `ofc-delegate-records-tag-and-properties` with:

```elisp
(ert-deftest ofc-delegate-records-link-and-person-tag ()
  (ofc-test-with-hub
    (ofc-test-goto "Ship the thing")
    (org-fractional-cto-delegate-at-point "Alice" nil nil)
    (ofc-test-goto "Ship the thing")
    (should (member "DELEGATED" (org-get-tags nil t)))
    (should (member "@alice" (org-get-tags nil t)))
    (let ((assigned (org-entry-get nil "ASSIGNED_TO")))
      (should (string-match-p "\\[\\[id:.+\\]\\[Alice\\]\\]" assigned)))))
```

Add a blocker-owner test:

```elisp
(ert-deftest ofc-block-links-and-tags-owner ()
  (ofc-test-with-hub
    (ofc-test-goto "Ship the thing")
    (org-fractional-cto-block-at-point "API keys missing" "Bob" nil)
    (ofc-test-goto-blocker "API keys missing")
    (should (member "@bob" (org-get-tags nil t)))
    (let ((owner (org-entry-get nil "UNBLOCK_OWNER")))
      (should (string-match-p "\\[\\[id:.+\\]\\[Bob\\]\\]" owner)))))
```

> Any other existing test that asserts `:ASSIGNED_TO:`/`:UNBLOCK_OWNER:` equals a bare name (e.g. an assertion `(equal ... "Alice")`) must be updated to the link form above. Scan `test/org-fractional-cto-actions-test.el` for `ASSIGNED_TO`/`UNBLOCK_OWNER` string-equality assertions and convert them.

- [ ] **Step 2: Run test to verify it fails**

Run: `make test`
Expected: FAIL — the commands still store bare names and add no `@person` tag.

- [ ] **Step 3: Write minimal implementation**

In `org-fractional-cto-actions.el`:

Add a declare/require so the resolver is available. Near the top `require`s, add:
```elisp
(require 'org-fractional-cto-people)
```
(`org-fractional-cto-people` requires only `org-id`/`seq`/`subr-x`, so there is no load cycle.)

Replace the `interactive` form and body of `org-fractional-cto-delegate-at-point` so the assignee resolves to a record:

```elisp
(defun org-fractional-cto-delegate-at-point (assignee &optional check-in delivery)
  "Turn the Org heading at point into a WAITING delegation.
This is the `eg' capture applied to a heading that already exists: it sets the
TODO state to WAITING, adds the DELEGATED tag, links ASSIGNED_TO to the
assignee's person node, tags the heading with the assignee's `@slug' tag,
records DELEGATED_ON, and SCHEDULEs a follow-up.

ASSIGNEE is the person's display name (required); the node is created if new.
CHECK-IN, when given, is the follow-up date set as SCHEDULED.  DELIVERY, when
given, is the expected-delivery date set as DEADLINE.  Date arguments are
strings any Org date parser accepts."
  (interactive
   (list (org-fractional-cto--read-person-name "Assigned to")
         (org-read-date nil nil nil "Check-in / follow-up")
         (when (y-or-n-p "Set an expected-delivery deadline? ")
           (org-read-date nil nil nil "Expected delivery"))))
  (when (string-empty-p (string-trim assignee))
    (user-error "An assignee is required to delegate"))
  (let ((rec (org-fractional-cto-person-record assignee)))
    (org-fractional-cto--at-entry
      (org-fractional-cto--require-heading)
      (save-excursion
        (org-back-to-heading t)
        (org-todo "WAITING")
        (org-toggle-tag "DELEGATED" 'on)
        (org-toggle-tag (plist-get rec :tag) 'on)
        (org-set-property "ASSIGNED_TO" (plist-get rec :link))
        (org-set-property "DELEGATED_ON" (org-fractional-cto--inactive-timestamp))
        (when (and check-in (not (string-empty-p check-in)))
          (org-schedule nil check-in))
        (when (and delivery (not (string-empty-p delivery)))
          (org-deadline nil delivery))))
    (message "Delegated to %s%s" assignee
             (if (and check-in (not (string-empty-p check-in)))
                 (format " — check in %s" check-in) ""))))
```

Give `--blocker-subtree` a trailing `person-tag` argument and append it to the headline's tag cluster:

```elisp
(defun org-fractional-cto--blocker-subtree (level what owner resolve-by link &optional person-tag)
  "Return the text of a BLOCKER subtree at LEVEL stars.
WHAT is what is blocked; OWNER is the unblock owner (an `[[id:]]' link string or
plain text); RESOLVE-BY (optional) becomes a DEADLINE; LINK is an Org link
stored in the BLOCKING property; PERSON-TAG, when non-nil, is appended to the
headline's tag cluster (e.g. \"@bob\")."
  (let* ((stars (make-string level ?*))
         (tags (concat ":BLOCKER:"
                       (if (and person-tag (not (string-empty-p person-tag)))
                           (concat person-tag ":") ""))))
    (concat
     (format "%s TODO [#A] BLOCKER: %s  %s\n" stars what tags)
     (when (and resolve-by (not (string-empty-p resolve-by)))
       (format "DEADLINE: %s\n" (org-fractional-cto--active-timestamp resolve-by)))
     ":PROPERTIES:\n"
     (format ":BLOCKING: %s\n" link)
     (when (and owner (not (string-empty-p owner)))
       (format ":UNBLOCK_OWNER: %s\n" owner))
     (format ":CREATED: %s\n" (org-fractional-cto--inactive-timestamp))
     ":END:\n"
     "\n*Root cause:* \n\n*Options:*\n- [ ] \n")))
```

Update `org-fractional-cto-block-at-point`: change the owner prompt to the picker, resolve a record when an owner is given, and pass the link + tag:

```elisp
(defun org-fractional-cto-block-at-point (what &optional owner resolve-by)
  "File a BLOCKER against the action heading at point.
Mirrors the `eb' capture, pre-wired to the action under point: a new
\[#A] BLOCKER entry is filed into this file's Blockers section with its BLOCKING
property linking back to the action, and a back-reference is inserted under the
action itself.

WHAT describes what is blocked; OWNER (optional) is the person who can clear it
\(linked to their node and added as an `@slug' tag on the blocker); RESOLVE-BY
\(optional) is a date string set as the blocker's DEADLINE."
  (interactive
   (list (read-string "What is blocked? " (org-fractional-cto--context-heading-title))
         (org-fractional-cto--read-person-name "Who can remove this blocker")
         (when (y-or-n-p "Set a resolve-by deadline? ")
           (org-read-date nil nil nil "Resolve by"))))
  (when (string-empty-p (string-trim what))
    (user-error "Describe what is blocked"))
  (let* ((rec (and owner (not (string-empty-p (string-trim owner)))
                   (org-fractional-cto-person-record owner)))
         (owner-link (if rec (plist-get rec :link) owner))
         (person-tag (and rec (plist-get rec :tag)))
         (action-title
          (org-fractional-cto--at-entry
            (org-fractional-cto--require-heading)
            (let* ((title (org-fractional-cto--heading-title))
                   (action-link (format "[[*%s][%s]]" title title)))
              (save-excursion
                (let ((level (1+ (org-fractional-cto--goto-section "Blockers"))))
                  (org-end-of-subtree t t)
                  (unless (bolp) (insert "\n"))
                  (insert (org-fractional-cto--blocker-subtree
                           level what owner-link resolve-by action-link person-tag))
                  (unless (bolp) (insert "\n"))))
              (save-excursion
                (org-back-to-heading t)
                (org-end-of-meta-data t)
                (insert (format "- Blocked by [[*BLOCKER: %s][BLOCKER: %s]]\n" what what)))
              title))))
    (message "Filed blocker against %S" action-title)))
```

- [ ] **Step 4: Run test to verify it passes**

Run: `make test`
Expected: PASS — the updated/added actions tests pass; suite green.

- [ ] **Step 5: Commit**

```bash
git add org-fractional-cto-actions.el test/org-fractional-cto-actions-test.el
git commit -m "feat: at-point delegate/block link and tag the person"
```

---

### Task 5: Link-only template edits (attendees, authorship, decision-makers)

**Files:**
- Modify: `templates/client_meeting.org`, `templates/discovery.org`, `templates/presales_call.org`, `templates/qbr.org`, `templates/retrospective.org`, `templates/innovation_meeting.org`, `templates/arch_review.org`, `templates/vendor_eval.org`, `templates/quick_decision.org`, `templates/scope_change.org`
- Test: `test/org-fractional-cto-capture-test.el`

**Interfaces:**
- Consumes: `org-fractional-cto--capture-people` (multi), `org-fractional-cto--capture-person` (single, no tag — note: NO trailing `t`).

- [ ] **Step 1: Write the failing test**

Append to `test/org-fractional-cto-capture-test.el`:

```elisp
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `make test`
Expected: FAIL — templates still use `%^{...}` prompts.

- [ ] **Step 3: Write minimal implementation**

Apply these exact line replacements:

`templates/client_meeting.org`:
- `Attendees (Client): %^{Client attendees}` → `Attendees (Client): %(org-fractional-cto--capture-people "Client attendees")`
- `Attendees (Us): %^{Our attendees}` → `Attendees (Us): %(org-fractional-cto--capture-people "Our attendees")`

`templates/discovery.org`:
- `Attendees: %^{Attendees}` → `Attendees: %(org-fractional-cto--capture-people "Attendees")`

`templates/qbr.org`:
- `Attendees (Client): %^{Client attendees}` → `Attendees (Client): %(org-fractional-cto--capture-people "Client attendees")`
- `Attendees (Us): %^{Our attendees}` → `Attendees (Us): %(org-fractional-cto--capture-people "Our attendees")`

`templates/retrospective.org`:
- `Facilitator: %^{Facilitator}` → `Facilitator: %(org-fractional-cto--capture-person "Facilitator")`
- `Attendees: %^{Attendees}` → `Attendees: %(org-fractional-cto--capture-people "Attendees")`

`templates/innovation_meeting.org`:
- `Attendees: %^{Attendees}` → `Attendees: %(org-fractional-cto--capture-people "Attendees")`
- `Raised by: %^{Who raised it}` → `Raised by: %(org-fractional-cto--capture-person "Who raised it")`

`templates/presales_call.org`:
- `Attendees: %^{Who was on the call}` → `Attendees: %(org-fractional-cto--capture-people "Who was on the call")`
- `- Decision-maker(s): %^{Who decides}` → `- Decision-maker(s): %(org-fractional-cto--capture-people "Who decides")`

`templates/arch_review.org`:
- `Conducted by: %^{Your name}` → `Conducted by: %(org-fractional-cto--capture-person "Conducted by")`

`templates/vendor_eval.org`:
- `Evaluated by: %^{Your name}` → `Evaluated by: %(org-fractional-cto--capture-person "Evaluated by")`

`templates/quick_decision.org`:
- `Made by: %^{Who}` → `Made by: %(org-fractional-cto--capture-person "Made by")`

`templates/scope_change.org`:
- `Identified by: %^{Who}` → `Identified by: %(org-fractional-cto--capture-person "Identified by")`

- [ ] **Step 4: Run test to verify it passes**

Run: `make test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add templates/client_meeting.org templates/discovery.org templates/presales_call.org templates/qbr.org templates/retrospective.org templates/innovation_meeting.org templates/arch_review.org templates/vendor_eval.org templates/quick_decision.org templates/scope_change.org test/org-fractional-cto-capture-test.el
git commit -m "feat: link attendee, authorship, and decision-maker fields"
```

---

### Task 6: Documentation

**Files:**
- Modify: `docs/guide.org`, `docs/reference.org`, `README.org`
- Regenerate: `org-fractional-cto.texi`

> The Makefile `info` target already points at `docs/` (fixed in the prior feature). `make info` should build cleanly.

**Interfaces:** none (documentation only).

- [ ] **Step 1: Extend the People & Stakeholders guide section**

In `docs/guide.org`, under the existing "People & Stakeholders" section, add a subsection:

```org
** Assigning and referencing people

Assignment and reference fields link to person nodes instead of storing bare
names.  When a capture or command asks for an owner, assignee, attendee, or
author, type a name: an existing person is completed and linked, a new name
creates the node on the spot.  The field stores an =[[id:...][Name]]= link.

Five single-owner item types also tag the heading with the person's =@slug=
tag — delegation, blocker, commitment, risk, and security.  Because they are
tags, the dashboard slices by person natively: open the dashboard, press =/=
and type the tag (e.g. =@jane_doe=) to see just that person's open work.  This
needs no extra command and works without org-roam.

=M-x org-fractional-cto-delegate-at-point= and
=M-x org-fractional-cto-block-at-point= do the same for an existing heading:
they link the assignee / unblock-owner and add the =@slug= tag.

Owner *columns inside tables* are filled by hand — use
=M-x org-fractional-cto-insert-person= in the cell.

Existing notes with plain-text owners keep working; re-assigning through the
capture or command upgrades them to a link and tag in place.
```

- [ ] **Step 2: Update the reference**

In `docs/reference.org`, in the customization/command lists, add one-line entries describing `org-fractional-cto-person-tag` (derives the `@slug` tag) only if the file documents private/derived helpers; otherwise add a note under the People section that the five single-owner types carry a `@<person-slug>` tag filterable with `/`. Match the file's existing list formatting.

- [ ] **Step 3: Update the README**

In `README.org`, in the "People & stakeholders" subsection, add 2–3 lines: assignment/reference fields link to person nodes; the five single-owner types also carry an `@person` tag you filter with `/` in the dashboard; table owners are filled with `insert-person`.

- [ ] **Step 4: Regenerate the Texinfo manual**

Run: `make info`
Expected: `org-fractional-cto.texi` regenerates without error.

- [ ] **Step 5: Verify suite and commit**

Run: `make test`
Expected: PASS — full suite green.

```bash
git add docs/guide.org docs/reference.org README.org org-fractional-cto.texi
git commit -m "docs: document people assignment links and @person tag filtering"
```

---

## Self-Review

**Spec coverage:**
- Every people-reference becomes a link → Tasks 3 (owners), 4 (at-point), 5 (attendees/authorship/decision-makers); table cells documented as manual (Task 6).
- `@slug` tag on the five single-owner TODO types → Task 3 (templates + finalize hook via Task 2) and Task 4 (at-point).
- Link + tag from one pick, no drift → Task 1 `person-record`; Task 2 helper stashes the same record the hook consumes.
- One resolver, two entry points (capture `%()` + at-point) → Tasks 1, 2, 4.
- Tag application via `org-capture-before-finalize-hook` → Task 2 (`--apply-person-tag`, registered in capture-install).
- Native `/` querying, no new command → Task 6 docs; no command added anywhere.
- Reuse `create-person`, no org-roam → Task 1 builds on `create-person`; no org-roam reference in any task.
- Non-destructive migration → no task rewrites existing data; documented Task 6.
- Person files never in `org-agenda-files` → unchanged; Task 4 fixture isolates people dir + org-id so tests don't pollute.

**Placeholder scan:** No "TBD"/"handle errors"/"similar to". Every code and template edit shows exact before/after text. Task 4 explicitly instructs scanning for and converting any remaining bare-name assertions (a concrete action, not a vague one).

**Type consistency:** `person-record` returns the plist `(:id :name :slug :tag :link)` in Task 1 and is consumed with those exact keys in Tasks 2 and 4. `--capture-person (prompt &optional tag)` and `--capture-people (prompt)` signatures match between Task 2 (definition) and Tasks 3/5 (template call sites). `--apply-person-tag` reads `:ofc-person` set by `--capture-person` (Task 2) — same key. `--blocker-subtree` gains a trailing optional `person-tag` arg (Task 4) consistent with its single new call site.
