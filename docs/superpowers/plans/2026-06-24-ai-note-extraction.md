# AI Note Extraction Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** When a flagged capture (standup, discovery, …) is finalized, run a pluggable LLM over the note and let the user review-then-file extracted Actions/Risks/Blockers/Decisions into the right client-hub sections.

**Architecture:** A new `org-fractional-cto-ai.el` module owns prompt construction, response parsing, rendering, the Org-native review buffer, and filing. The model transport is a single user-supplied async function (`org-fractional-cto-ai-request-function`); absent ⇒ feature off. A `before-finalize` hook reads the note synchronously and defers the model call via `run-at-time 0` so capture never blocks.

**Tech Stack:** Emacs Lisp, ERT, `org`, `org-id`, `org-capture`, `json` (json.el), reusing existing `org-fractional-cto-*` helpers.

## Global Constraints

- Emacs 27.1+, Org 9.4+ (copied from `Package-Requires`). Use only APIs available there.
- No new hard dependencies. The model backend is pluggable and `nil` by default.
- Naming: public symbols `org-fractional-cto-ai-…`; internal `org-fractional-cto-ai--…`. Match the package's existing prefix conventions.
- Never abort `org-capture-finalize`: every finalize-path function wraps its work in `condition-case` and logs on failure (mirror `org-fractional-cto--apply-person-tag`).
- Treat the model's JSON as untrusted: validate/type every field at the boundary.
- New module target < 400 lines; if it exceeds, a later split of the review buffer is acceptable but is out of scope here.
- Run the suite with `make test`. Each task ends green and committed.

---

### Task 1: Factor `org-fractional-cto--goto-section` out of capture targeting

Both capture targeting and AI filing need "visit FILE, find-or-create HEADING, leave point on its line." Extract the shared helper without changing capture behavior.

**Files:**
- Modify: `org-fractional-cto-capture.el` (`org-fractional-cto--capture-to-heading`, ~lines 44-63)
- Test: `test/org-fractional-cto-capture-test.el`

**Interfaces:**
- Produces: `(org-fractional-cto--goto-section FILE HEADING)` — visits FILE, widens, moves point to the end of the first `^\*+ HEADING` line, creating `** HEADING` at end of file if absent. Returns nothing meaningful (used for point position).

- [ ] **Step 1: Write the failing test**

Add to `test/org-fractional-cto-capture-test.el`:

```elisp
(ert-deftest ofc-goto-section-finds-existing ()
  (let ((file (make-temp-file "ofc-hub" nil ".org"
                              "#+title: X\n\n* Eng\n** Actions\n** Risks\n")))
    (unwind-protect
        (save-window-excursion
          (org-fractional-cto--goto-section file "Risks")
          (should (equal (buffer-file-name) file))
          (should (string-match-p "Risks"
                                  (buffer-substring (line-beginning-position)
                                                    (line-end-position)))))
      (when (get-file-buffer file) (kill-buffer (get-file-buffer file)))
      (delete-file file))))

(ert-deftest ofc-goto-section-creates-missing ()
  (let ((file (make-temp-file "ofc-hub" nil ".org" "#+title: X\n\n* Eng\n")))
    (unwind-protect
        (save-window-excursion
          (org-fractional-cto--goto-section file "Blockers")
          (goto-char (point-min))
          (should (re-search-forward "^\\*+ Blockers" nil t)))
      (when (get-file-buffer file) (kill-buffer (get-file-buffer file)))
      (delete-file file))))
```

- [ ] **Step 2: Run test to verify it fails**

Run: `emacs -Q --batch -L . -l test/org-fractional-cto-capture-test.el -f ert-run-tests-batch-and-exit`
Expected: FAIL — `org-fractional-cto--goto-section` is void.

- [ ] **Step 3: Add the helper and call it from `--capture-to-heading`**

In `org-fractional-cto-capture.el`, add before `org-fractional-cto--capture-to-heading`:

```elisp
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
    (insert (format "\n** %s\n" heading)))
  (end-of-line))
```

Then replace the body of `org-fractional-cto--capture-to-heading` so its file-navigation delegates to the helper (keep the capture-puts):

```elisp
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
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `make test`
Expected: PASS (new tests plus the existing capture suite — `--capture-to-heading` behavior is unchanged).

- [ ] **Step 5: Commit**

```bash
git add org-fractional-cto-capture.el test/org-fractional-cto-capture-test.el
git commit -m "refactor: extract org-fractional-cto--goto-section for reuse"
```

---

### Task 2: Module skeleton — config, taxonomy, `--enabled-p`, `--type-spec`

Create the module with its three defcustoms and the two predicates the rest of the engine builds on.

**Files:**
- Create: `org-fractional-cto-ai.el`
- Create: `test/org-fractional-cto-ai-test.el`
- Modify: `Makefile` (add the new test file)

**Interfaces:**
- Consumes: `org-fractional-cto-sections` (defconst, scaffold).
- Produces:
  - `org-fractional-cto-ai-request-function` (defcustom, default `nil`)
  - `org-fractional-cto-ai-item-types` (defcustom, alist `(TYPE . PLIST)` with `:section`/`:tag`/`:desc`/`:render`)
  - `org-fractional-cto-ai-provenance-tag` (defcustom, default `"AI"`)
  - `(org-fractional-cto-ai--enabled-p)` → non-nil iff request function is a function
  - `(org-fractional-cto-ai--type-spec TYPE)` → the plist for symbol TYPE, but only when its `:section` names a real hub section; else `nil`

- [ ] **Step 1: Write the failing test**

Create `test/org-fractional-cto-ai-test.el`:

```elisp
;;; org-fractional-cto-ai-test.el --- Tests for AI extraction -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Dhruva Sagar
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; ERT tests for org-fractional-cto-ai: config predicates, prompt building,
;; response parsing, normalization, rendering, the review buffer, and filing.
;; Run with: make test

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'org-id)
(require 'org-fractional-cto)
(require 'org-fractional-cto-ai)

(defmacro ofc-ai-test (&rest body)
  "Run BODY with throwaway client + people dirs and isolated org-id state."
  (declare (indent 0) (debug t))
  `(let* ((org-fractional-cto-clients-directory (make-temp-file "ofc-ai" t))
          (org-fractional-cto-people-directory (make-temp-file "ofc-ai-ppl" t))
          (org-id-extra-files nil)
          (org-id-locations (make-hash-table :test 'equal))
          (org-id-files nil))
     (unwind-protect (progn ,@body)
       (delete-directory org-fractional-cto-clients-directory t)
       (delete-directory org-fractional-cto-people-directory t))))

(defun ofc-ai-test--make-hub (slug)
  "Create a minimal hub for SLUG with the sections used in tests; return its file."
  (let ((dir (expand-file-name slug (org-fractional-cto--clients-dir))))
    (make-directory dir t)
    (let ((file (org-fractional-cto-client-org-file slug)))
      (with-temp-file file
        (insert "#+title: Acme\n#+filetags: :ACME:\n\n* Acme Engagement\n"
                "** Actions\n** Risks\n** Blockers\n** Architecture Decisions\n"))
      file)))

(ert-deftest ofc-ai-enabled-tracks-request-function ()
  (let ((org-fractional-cto-ai-request-function nil))
    (should-not (org-fractional-cto-ai--enabled-p)))
  (let ((org-fractional-cto-ai-request-function (lambda (_p _cb) nil)))
    (should (org-fractional-cto-ai--enabled-p))))

(ert-deftest ofc-ai-type-spec-returns-known-type ()
  (let ((spec (org-fractional-cto-ai--type-spec 'risk)))
    (should (equal (plist-get spec :section) "Risks"))
    (should (equal (plist-get spec :tag) "RISK")))
  (should-not (org-fractional-cto-ai--type-spec 'nonsense)))
```

- [ ] **Step 2: Run test to verify it fails**

Run: `emacs -Q --batch -L . -l test/org-fractional-cto-ai-test.el -f ert-run-tests-batch-and-exit`
Expected: FAIL — cannot load `org-fractional-cto-ai`.

- [ ] **Step 3: Create the module skeleton**

Create `org-fractional-cto-ai.el`:

```elisp
;;; org-fractional-cto-ai.el --- AI extraction of items from notes -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Dhruva Sagar
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; When a flagged capture is finalized, this module sends the note text to a
;; user-supplied language-model backend (`org-fractional-cto-ai-request-function')
;; and offers the extracted Actions/Risks/Blockers/Decisions in an Org-native
;; review buffer.  Surviving entries are filed into the client hub's sections,
;; each linked back to the source note.  The backend is the only pluggable piece;
;; with none configured the feature is simply off.  See
;; docs/superpowers/specs/2026-06-24-ai-note-extraction-design.md.

;;; Code:

(require 'org)
(require 'org-id)
(require 'org-capture)
(require 'json)
(require 'cl-lib)
(require 'subr-x)
(require 'org-fractional-cto-scaffold)   ; org-fractional-cto-sections
(require 'org-fractional-cto-capture)    ; org-fractional-cto--goto-section
(require 'org-fractional-cto-people)     ; org-fractional-cto-person-record

(declare-function org-fractional-cto-client-org-file "org-fractional-cto")
(defvar org-fractional-cto-sections)

;;;; Configuration

(defcustom org-fractional-cto-ai-request-function nil
  "Function used to send a prompt to a language model.
Called as (FN PROMPT CALLBACK).  FN must arrange for CALLBACK to be invoked
with one argument: the model's raw response string, or nil on failure.  FN
should be asynchronous; the engine additionally defers the call so a
synchronous implementation cannot block capture finalize.  When nil, AI
extraction is disabled."
  :type '(choice (const :tag \"Disabled\" nil) function)
  :group 'org-fractional-cto)

(defcustom org-fractional-cto-ai-item-types
  '((action   :section \"Actions\"                :tag nil
              :desc \"A concrete follow-up task someone must do.\"
              :render org-fractional-cto-ai--render-action)
    (risk     :section \"Risks\"                  :tag \"RISK\"
              :desc \"A risk to the engagement, with likelihood and impact.\"
              :render org-fractional-cto-ai--render-risk)
    (blocker  :section \"Blockers\"               :tag \"BLOCKER\"
              :desc \"Something actively blocking a work stream.\"
              :render org-fractional-cto-ai--render-blocker)
    (decision :section \"Architecture Decisions\" :tag \"DECISION\"
              :desc \"A decision reached during the discussion, worth recording.\"
              :render org-fractional-cto-ai--render-decision))
  \"Taxonomy of AI-extractable item types.
Each entry is (TYPE . PLIST).  :section must name a heading in
`org-fractional-cto-sections'.  :tag is the per-item Org tag mirroring the
bundled capture template (nil for none).  :desc is fed to the model to guide
classification.  :render is a function taking a normalized item plist and
returning Org entry text.  Add a row to extend the taxonomy.\"
  :type 'sexp
  :group 'org-fractional-cto)

(defcustom org-fractional-cto-ai-provenance-tag \"AI\"
  \"Org tag added to items filed by AI extraction, or nil to add none.\"
  :type '(choice (const :tag \"None\" nil) string)
  :group 'org-fractional-cto)

;;;; Predicates

(defun org-fractional-cto-ai--enabled-p ()
  \"Return non-nil when a model request function is configured.\"
  (functionp org-fractional-cto-ai-request-function))

(defun org-fractional-cto-ai--type-spec (type)
  \"Return the taxonomy plist for symbol TYPE, or nil.
Only returns a spec whose :section names a real hub section.\"
  (let ((spec (cdr (assq type org-fractional-cto-ai-item-types))))
    (when (and spec
               (member (plist-get spec :section)
                       (mapcar #'car org-fractional-cto-sections)))
      spec)))

(provide 'org-fractional-cto-ai)

;;; org-fractional-cto-ai.el ends here
```

NOTE for the implementer: the docstrings above show escaped quotes only because they appear inside this Markdown code fence — write real `"` characters in the `.el` file.

- [ ] **Step 4: Wire the test into the Makefile**

In `Makefile`, add the new test file to the `test` target's `-l` list (after the people test line):

```make
	  -l test/org-fractional-cto-people-test.el \
	  -l test/org-fractional-cto-ai-test.el \
	  -l test/org-fractional-cto-scaffold-test.el \
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `make test`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add org-fractional-cto-ai.el test/org-fractional-cto-ai-test.el Makefile
git commit -m "feat: scaffold AI extraction module with taxonomy and config"
```

---

### Task 3: Prompt builder

Turn a note + client name + taxonomy into a single prompt string.

**Files:**
- Modify: `org-fractional-cto-ai.el`
- Test: `test/org-fractional-cto-ai-test.el`

**Interfaces:**
- Produces: `(org-fractional-cto-ai--build-prompt TEXT CLIENT-NAME)` → string containing each type key + its `:desc`, the JSON output contract, and the note text.

- [ ] **Step 1: Write the failing test**

```elisp
(ert-deftest ofc-ai-build-prompt-includes-types-and-note ()
  (let ((p (org-fractional-cto-ai--build-prompt "We must rotate the API keys." "Acme")))
    (should (string-match-p "Acme" p))
    (should (string-match-p "action" p))
    (should (string-match-p "risk" p))
    (should (string-match-p "JSON" p))
    (should (string-match-p "rotate the API keys" p))))
```

- [ ] **Step 2: Run test to verify it fails**

Run: `emacs -Q --batch -L . -l test/org-fractional-cto-ai-test.el -f ert-run-tests-batch-and-exit`
Expected: FAIL — `org-fractional-cto-ai--build-prompt` is void.

- [ ] **Step 3: Implement the builder**

Add to `org-fractional-cto-ai.el` (after the predicates):

```elisp
;;;; Prompt

(defun org-fractional-cto-ai--build-prompt (text client-name)
  "Build the extraction prompt for note TEXT belonging to CLIENT-NAME."
  (let ((types (mapconcat
                (lambda (entry)
                  (format "- \"%s\": %s"
                          (car entry) (plist-get (cdr entry) :desc)))
                org-fractional-cto-ai-item-types "\n")))
    (concat
     "You analyze a consulting engagement note and extract concrete, "
     "trackable items.\n"
     (format "Client: %s\n\n" (or client-name ""))
     "Extract only items clearly supported by the note. Use these types:\n"
     types "\n\n"
     "Return ONLY a JSON array (no prose, no code fence). Each element:\n"
     "{\"type\": <one of the type keys above>, \"title\": <short imperative title>,\n"
     " \"owner\": <person name or null>, \"deadline\": <ISO date or null>,\n"
     " \"priority\": <\"A\"|\"B\"|\"C\" or null>, \"body\": <one-line detail or null>,\n"
     " \"fields\": {\"likelihood\": ..., \"impact\": ..., \"blocking\": ...} or null}\n"
     "If nothing qualifies, return [].\n\n"
     "NOTE:\n" text)))
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `make test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add org-fractional-cto-ai.el test/org-fractional-cto-ai-test.el
git commit -m "feat: build AI extraction prompt from taxonomy and note"
```

---

### Task 4: Response parsing — fence stripping + tolerant JSON

Parse raw model output into a list of plists, tolerating code fences and an `{"items": [...]}` wrapper.

**Files:**
- Modify: `org-fractional-cto-ai.el`
- Test: `test/org-fractional-cto-ai-test.el`

**Interfaces:**
- Produces:
  - `(org-fractional-cto-ai--strip-fences RAW)` → string with surrounding Markdown code fence removed
  - `(org-fractional-cto-ai--parse-response RAW)` → list of plists (each a parsed JSON object, keys as keywords); `[]` → nil; signals `error` on unparseable input

- [ ] **Step 1: Write the failing test**

```elisp
(ert-deftest ofc-ai-strip-fences-removes-code-block ()
  (should (equal (org-fractional-cto-ai--strip-fences "```json\n[1]\n```") "[1]"))
  (should (equal (org-fractional-cto-ai--strip-fences "  [2]  ") "[2]")))

(ert-deftest ofc-ai-parse-response-reads-array-of-objects ()
  (let ((items (org-fractional-cto-ai--parse-response
                "[{\"type\":\"action\",\"title\":\"Do X\"}]")))
    (should (= 1 (length items)))
    (should (equal (plist-get (car items) :type) "action"))
    (should (equal (plist-get (car items) :title) "Do X"))))

(ert-deftest ofc-ai-parse-response-unwraps-items-key ()
  (let ((items (org-fractional-cto-ai--parse-response
                "```json\n{\"items\":[{\"type\":\"risk\",\"title\":\"R\"}]}\n```")))
    (should (equal (plist-get (car items) :title) "R"))))

(ert-deftest ofc-ai-parse-response-empty-array-is-nil ()
  (should (null (org-fractional-cto-ai--parse-response "[]"))))

(ert-deftest ofc-ai-parse-response-signals-on-garbage ()
  (should-error (org-fractional-cto-ai--parse-response "not json")))
```

- [ ] **Step 2: Run test to verify it fails**

Run: `emacs -Q --batch -L . -l test/org-fractional-cto-ai-test.el -f ert-run-tests-batch-and-exit`
Expected: FAIL — functions void.

- [ ] **Step 3: Implement parsing**

Add to `org-fractional-cto-ai.el`:

```elisp
;;;; Parsing

(defun org-fractional-cto-ai--strip-fences (raw)
  "Return RAW trimmed, with a surrounding Markdown code fence removed if present."
  (let ((s (string-trim raw)))
    (if (string-prefix-p "```" s)
        (string-trim
         (replace-regexp-in-string
          "\n?```[ \t]*\\'" ""
          (replace-regexp-in-string "\\````[a-zA-Z]*[ \t]*\n?" "" s)))
      s)))

(defun org-fractional-cto-ai--parse-response (raw)
  "Parse RAW model output into a list of item plists.
Tolerates a Markdown code fence and an optional {\"items\": [...]} wrapper.
Signals an error when RAW contains no parseable JSON."
  (let* ((json (org-fractional-cto-ai--strip-fences raw))
         (data (let ((json-object-type 'plist)
                     (json-array-type 'list)
                     (json-false nil)
                     (json-null nil))
                 (json-read-from-string json))))
    (cond
     ;; A JSON object parses to a plist whose car is a keyword.
     ((keywordp (car-safe data))
      (or (plist-get data :items) (list data)))
     ;; A JSON array parses to a list of plists (or nil when empty).
     ((listp data) data)
     (t (error "Unexpected JSON shape")))))
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `make test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add org-fractional-cto-ai.el test/org-fractional-cto-ai-test.el
git commit -m "feat: parse model responses tolerantly into item plists"
```

---

### Task 5: Normalization

Validate and normalize a parsed plist into a clean item, dropping unknown types and blank titles.

**Files:**
- Modify: `org-fractional-cto-ai.el`
- Test: `test/org-fractional-cto-ai-test.el`

**Interfaces:**
- Produces:
  - `(org-fractional-cto-ai--clean-string V)` → trimmed non-empty string, else nil
  - `(org-fractional-cto-ai--normalize-item RAW)` → plist `(:type SYM :title STR :owner :deadline :priority :body :fields)` or nil if invalid. `:type` is interned, lower-cased, and must resolve via `--type-spec`.

- [ ] **Step 1: Write the failing test**

```elisp
(ert-deftest ofc-ai-clean-string-trims-and-nils ()
  (should (equal (org-fractional-cto-ai--clean-string "  hi ") "hi"))
  (should (null (org-fractional-cto-ai--clean-string "   ")))
  (should (null (org-fractional-cto-ai--clean-string nil))))

(ert-deftest ofc-ai-normalize-keeps-valid-item ()
  (let ((item (org-fractional-cto-ai--normalize-item
               '(:type "Action" :title "  Chase spec " :owner "Jun"))))
    (should (eq (plist-get item :type) 'action))
    (should (equal (plist-get item :title) "Chase spec"))
    (should (equal (plist-get item :owner) "Jun"))))

(ert-deftest ofc-ai-normalize-drops-unknown-type ()
  (should (null (org-fractional-cto-ai--normalize-item
                 '(:type "gossip" :title "x")))))

(ert-deftest ofc-ai-normalize-drops-blank-title ()
  (should (null (org-fractional-cto-ai--normalize-item
                 '(:type "risk" :title "   ")))))
```

- [ ] **Step 2: Run test to verify it fails**

Run: `emacs -Q --batch -L . -l test/org-fractional-cto-ai-test.el -f ert-run-tests-batch-and-exit`
Expected: FAIL — functions void.

- [ ] **Step 3: Implement normalization**

Add to `org-fractional-cto-ai.el`:

```elisp
;;;; Normalization

(defun org-fractional-cto-ai--clean-string (v)
  "Return V trimmed when it is a non-empty string, else nil."
  (and (stringp v)
       (let ((s (string-trim v)))
         (and (not (string-empty-p s)) s))))

(defun org-fractional-cto-ai--normalize-item (raw)
  "Return a normalized item plist from parsed RAW, or nil when invalid.
RAW's :type is matched case-insensitively against the taxonomy; items with an
unknown type or a blank title are dropped."
  (let* ((type-str (org-fractional-cto-ai--clean-string (plist-get raw :type)))
         (type (and type-str (intern (downcase type-str))))
         (title (org-fractional-cto-ai--clean-string (plist-get raw :title))))
    (when (and type title (org-fractional-cto-ai--type-spec type))
      (list :type type
            :title title
            :owner (org-fractional-cto-ai--clean-string (plist-get raw :owner))
            :deadline (org-fractional-cto-ai--clean-string (plist-get raw :deadline))
            :priority (org-fractional-cto-ai--clean-string (plist-get raw :priority))
            :body (org-fractional-cto-ai--clean-string (plist-get raw :body))
            :fields (plist-get raw :fields)))))
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `make test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add org-fractional-cto-ai.el test/org-fractional-cto-ai-test.el
git commit -m "feat: normalize and validate extracted items"
```

---

### Task 6: Renderers

Render each normalized item into a single-heading Org entry carrying `:OFC_AI_SECTION:` (and `:OFC_AI_OWNER:` when an owner is present). Mirror the bundled template shapes.

**Files:**
- Modify: `org-fractional-cto-ai.el`
- Test: `test/org-fractional-cto-ai-test.el`

**Interfaces:**
- Produces:
  - `(org-fractional-cto-ai--entry HEADING TAG SECTION OWNER BODY-LINES)` → entry string: `* HEADING  :TAG:` + a PROPERTIES drawer with `:OFC_AI_SECTION: SECTION` and optional `:OFC_AI_OWNER: OWNER`, then BODY-LINES (a list of strings).
  - `(org-fractional-cto-ai--render-action ITEM)` / `--render-risk` / `--render-blocker` / `--render-decision` → entry strings
  - `(org-fractional-cto-ai--render-item ITEM)` → dispatches via the type's `:render`

- [ ] **Step 1: Write the failing test**

```elisp
(ert-deftest ofc-ai-render-action-has-todo-and-section ()
  (let ((s (org-fractional-cto-ai--render-item
            '(:type action :title "Chase spec" :owner "Jun"
              :deadline "2026-06-30" :priority "A"))))
    (should (string-match-p "^\\* TODO \\[#A\\] Chase spec" s))
    (should (string-match-p "DEADLINE: <2026-06-30>" s))
    (should (string-match-p ":OFC_AI_SECTION: Actions" s))
    (should (string-match-p ":OFC_AI_OWNER: Jun" s))))

(ert-deftest ofc-ai-render-risk-matches-template-shape ()
  (let ((s (org-fractional-cto-ai--render-item
            '(:type risk :title "Vendor lock-in"
              :body "Migrate off proprietary API"
              :fields (:likelihood "High" :impact "High")))))
    (should (string-match-p "^\\* \\[RISK\\] Vendor lock-in[ \t]+:RISK:" s))
    (should (string-match-p "Likelihood: High" s))
    (should (string-match-p "Impact: High" s))
    (should (string-match-p "Mitigation: Migrate off proprietary API" s))))

(ert-deftest ofc-ai-render-blocker-is-priority-a-todo ()
  (let ((s (org-fractional-cto-ai--render-item
            '(:type blocker :title "Staging down"
              :fields (:blocking "Release 2.0")))))
    (should (string-match-p "^\\* TODO \\[#A\\] BLOCKER: Staging down[ \t]+:BLOCKER:" s))
    (should (string-match-p "Blocking: Release 2.0" s))))

(ert-deftest ofc-ai-render-decision-records-body ()
  (let ((s (org-fractional-cto-ai--render-item
            '(:type decision :title "Adopt Postgres" :body "Over MySQL for JSONB"))))
    (should (string-match-p "^\\* DECISION: Adopt Postgres[ \t]+:DECISION:" s))
    (should (string-match-p "Over MySQL for JSONB" s))
    (should (string-match-p ":OFC_AI_SECTION: Architecture Decisions" s))))
```

- [ ] **Step 2: Run test to verify it fails**

Run: `emacs -Q --batch -L . -l test/org-fractional-cto-ai-test.el -f ert-run-tests-batch-and-exit`
Expected: FAIL — render functions void.

- [ ] **Step 3: Implement renderers**

Add to `org-fractional-cto-ai.el`:

```elisp
;;;; Rendering

(defun org-fractional-cto-ai--entry (heading tag section owner body-lines)
  "Build a single-heading Org entry string.
HEADING is headline text (no stars).  TAG is a per-item tag or nil.  SECTION is
the destination heading, stored in the :OFC_AI_SECTION: property.  OWNER, when
non-nil, is stored in :OFC_AI_OWNER:.  BODY-LINES is a list of strings placed
after the property drawer."
  (concat
   (format "* %s%s\n" heading (if tag (format "  :%s:" tag) ""))
   ":PROPERTIES:\n"
   (format ":OFC_AI_SECTION: %s\n" section)
   (if owner (format ":OFC_AI_OWNER: %s\n" owner) "")
   ":END:\n"
   (mapconcat #'identity body-lines "\n")
   (if body-lines "\n" "")))

(defun org-fractional-cto-ai--render-action (item)
  "Render an action ITEM as a TODO entry."
  (let ((spec (org-fractional-cto-ai--type-spec 'action))
        (deadline (plist-get item :deadline))
        (priority (plist-get item :priority))
        (body (plist-get item :body)))
    (org-fractional-cto-ai--entry
     (concat "TODO "
             (if priority (format "[#%s] " (upcase priority)) "")
             (plist-get item :title))
     (plist-get spec :tag) (plist-get spec :section) (plist-get item :owner)
     (delq nil (list (and deadline (format "DEADLINE: <%s>" deadline))
                     body)))))

(defun org-fractional-cto-ai--render-risk (item)
  "Render a risk ITEM mirroring the bundled risk template."
  (let* ((spec (org-fractional-cto-ai--type-spec 'risk))
         (fields (plist-get item :fields))
         (likelihood (or (org-fractional-cto-ai--clean-string
                          (plist-get fields :likelihood)) "Medium"))
         (impact (or (org-fractional-cto-ai--clean-string
                      (plist-get fields :impact)) "Medium"))
         (body (plist-get item :body)))
    (org-fractional-cto-ai--entry
     (format "[RISK] %s" (plist-get item :title))
     (plist-get spec :tag) (plist-get spec :section) (plist-get item :owner)
     (delq nil (list "Status: Open"
                     (format "Likelihood: %s" likelihood)
                     (format "Impact: %s" impact)
                     (and body (format "Mitigation: %s" body)))))))

(defun org-fractional-cto-ai--render-blocker (item)
  "Render a blocker ITEM mirroring the bundled blocker template."
  (let* ((spec (org-fractional-cto-ai--type-spec 'blocker))
         (fields (plist-get item :fields))
         (blocking (org-fractional-cto-ai--clean-string (plist-get fields :blocking)))
         (body (plist-get item :body)))
    (org-fractional-cto-ai--entry
     (format "TODO [#A] BLOCKER: %s" (plist-get item :title))
     (plist-get spec :tag) (plist-get spec :section) (plist-get item :owner)
     (delq nil (list (and blocking (format "Blocking: %s" blocking))
                     (and body (format "*Root cause:* %s" body)))))))

(defun org-fractional-cto-ai--render-decision (item)
  "Render a decision ITEM mirroring the bundled quick-decision template."
  (let ((spec (org-fractional-cto-ai--type-spec 'decision))
        (body (plist-get item :body)))
    (org-fractional-cto-ai--entry
     (format "DECISION: %s" (plist-get item :title))
     (plist-get spec :tag) (plist-get spec :section) (plist-get item :owner)
     (delq nil (list body)))))

(defun org-fractional-cto-ai--render-item (item)
  "Render normalized ITEM via its taxonomy :render function."
  (funcall (plist-get (org-fractional-cto-ai--type-spec (plist-get item :type))
                      :render)
           item))
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `make test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add org-fractional-cto-ai.el test/org-fractional-cto-ai-test.el
git commit -m "feat: render extracted items as org entries"
```

---

### Task 7: Review buffer

Build and pop the `*ofc-ai-review*` Org buffer: a parent heading plus each rendered item demoted one level, with commit/discard keys and buffer-local context.

**Files:**
- Modify: `org-fractional-cto-ai.el`
- Test: `test/org-fractional-cto-ai-test.el`

**Interfaces:**
- Produces:
  - `(org-fractional-cto-ai--demote TEXT N)` → TEXT with N extra stars on each heading line
  - buffer-locals `org-fractional-cto-ai--hub-file`, `org-fractional-cto-ai--source-id`, `org-fractional-cto-ai--note-title`
  - `org-fractional-cto-ai-review-mode` (derived from `org-mode`)
  - `(org-fractional-cto-ai--review-buffer NOTE-TITLE SOURCE-ID HUB-FILE ITEMS)` → creates/pops `*ofc-ai-review*`, returns the buffer

- [ ] **Step 1: Write the failing test**

```elisp
(ert-deftest ofc-ai-demote-adds-stars ()
  (should (equal (org-fractional-cto-ai--demote "* A\nbody\n" 1) "** A\nbody\n")))

(ert-deftest ofc-ai-review-buffer-lists-items ()
  (ofc-ai-test
    (let* ((hub (ofc-ai-test--make-hub "acme"))
           (items '((:type action :title "Chase spec")
                    (:type risk :title "Lock-in" :fields (:impact "High"))))
           (buf (org-fractional-cto-ai--review-buffer "STANDUP" "src-1" hub items)))
      (unwind-protect
          (with-current-buffer buf
            (should (derived-mode-p 'org-mode))
            (goto-char (point-min))
            (should (re-search-forward "Proposed from STANDUP" nil t))
            (should (re-search-forward "^\\*\\* TODO Chase spec" nil t))
            (should (re-search-forward "^\\*\\* \\[RISK\\] Lock-in" nil t))
            (should (equal org-fractional-cto-ai--hub-file hub))
            (should (equal org-fractional-cto-ai--source-id "src-1")))
        (kill-buffer buf)))))
```

- [ ] **Step 2: Run test to verify it fails**

Run: `emacs -Q --batch -L . -l test/org-fractional-cto-ai-test.el -f ert-run-tests-batch-and-exit`
Expected: FAIL — functions/mode void.

- [ ] **Step 3: Implement the review buffer**

Add to `org-fractional-cto-ai.el`:

```elisp
;;;; Review buffer

(defvar-local org-fractional-cto-ai--hub-file nil
  "Hub file the review buffer's accepted items will be filed into.")
(defvar-local org-fractional-cto-ai--source-id nil
  "org-id of the source note, used for the provenance back-link.")
(defvar-local org-fractional-cto-ai--note-title nil
  "Display title of the source note.")

(defvar org-fractional-cto-ai-review-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c C-c") #'org-fractional-cto-ai-commit)
    (define-key map (kbd "C-c C-k") #'org-fractional-cto-ai-discard)
    map)
  "Keymap for `org-fractional-cto-ai-review-mode'.")

(define-derived-mode org-fractional-cto-ai-review-mode org-mode "OFC-AI-Review"
  "Major mode for reviewing AI-extracted items before filing.
Edit or delete entries freely, then \\[org-fractional-cto-ai-commit] to file the
survivors, or \\[org-fractional-cto-ai-discard] to discard them all.")

(defun org-fractional-cto-ai--demote (text n)
  "Return TEXT with N extra leading stars on every heading line."
  (let ((stars (make-string n ?*)))
    (replace-regexp-in-string "^\\(\\*+\\) " (concat stars "\\1 ") text)))

(defun org-fractional-cto-ai--review-buffer (note-title source-id hub-file items)
  "Pop a review buffer for ITEMS extracted from NOTE-TITLE.
SOURCE-ID and HUB-FILE are stored buffer-locally for the commit step.  Returns
the buffer."
  (let ((buf (get-buffer-create "*ofc-ai-review*"))
        (n (length items)))
    (with-current-buffer buf
      (org-fractional-cto-ai-review-mode)
      (erase-buffer)
      (insert (format "* Proposed from %s — %d item%s\n"
                      note-title n (if (= n 1) "" "s")))
      (insert "  Edit or delete entries below, then C-c C-c to file the "
              "survivors (C-c C-k discards all).\n")
      (dolist (item items)
        (insert (org-fractional-cto-ai--demote
                 (org-fractional-cto-ai--render-item item) 1))
        (unless (bolp) (insert "\n")))
      (setq org-fractional-cto-ai--hub-file hub-file
            org-fractional-cto-ai--source-id source-id
            org-fractional-cto-ai--note-title note-title)
      (goto-char (point-min)))
    (pop-to-buffer buf)
    buf))
```

NOTE: `org-fractional-cto-ai-commit` and `-discard` are referenced by the keymap but defined in Task 8. Add forward declarations now so byte-compile is clean:

```elisp
(declare-function org-fractional-cto-ai-commit "org-fractional-cto-ai")
(declare-function org-fractional-cto-ai-discard "org-fractional-cto-ai")
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `make test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add org-fractional-cto-ai.el test/org-fractional-cto-ai-test.el
git commit -m "feat: org-native review buffer for extracted items"
```

---

### Task 8: Commit & discard — file survivors into the hub

Collect surviving entries, strip the `OFC_AI_*` properties, file each under its section with owner resolution, provenance link, and provenance tag.

**Files:**
- Modify: `org-fractional-cto-ai.el`
- Test: `test/org-fractional-cto-ai-test.el`

**Interfaces:**
- Consumes: `org-fractional-cto--goto-section`, `org-fractional-cto-person-record`, buffer-locals from Task 7.
- Produces:
  - `(org-fractional-cto-ai--strip-properties TEXT)` → TEXT with the PROPERTIES drawer removed and the heading promoted back to level 1
  - `(org-fractional-cto-ai--collect-entries)` → list of `(SECTION OWNER TEXT)` for each surviving level-2 entry in the current review buffer
  - `(org-fractional-cto-ai--file-entry HUB SECTION OWNER TEXT SOURCE-ID NOTE-TITLE)` → files one entry into HUB and saves the buffer
  - `(org-fractional-cto-ai-commit)` (interactive) → files all survivors, kills the review buffer
  - `(org-fractional-cto-ai-discard)` (interactive) → kills the review buffer

- [ ] **Step 1: Write the failing test**

```elisp
(ert-deftest ofc-ai-strip-properties-removes-drawer-and-promotes ()
  (let ((s (org-fractional-cto-ai--strip-properties
            "** TODO X\n:PROPERTIES:\n:OFC_AI_SECTION: Actions\n:END:\nbody\n")))
    (should (string-match-p "\\`\\* TODO X" s))
    (should-not (string-match-p "OFC_AI_SECTION" s))
    (should (string-match-p "body" s))))

(ert-deftest ofc-ai-commit-files-into-sections ()
  (ofc-ai-test
    (let* ((hub (ofc-ai-test--make-hub "acme"))
           (items '((:type action :title "Chase spec" :owner "Jun Tanaka")
                    (:type risk :title "Lock-in" :fields (:impact "High"))))
           (buf (org-fractional-cto-ai--review-buffer "STANDUP 2026-06-24"
                                                      "src-1" hub items)))
      (unwind-protect
          (with-current-buffer buf (org-fractional-cto-ai-commit))
        (when (buffer-live-p buf) (kill-buffer buf)))
      ;; The review buffer was killed by commit.
      (should-not (get-buffer "*ofc-ai-review*"))
      (with-current-buffer (find-file-noselect hub)
        (let ((text (buffer-string)))
          ;; Action filed under Actions with owner link and provenance.
          (should (string-match-p "\\*\\* Actions\n\\*\\*\\* TODO Chase spec.*:AI:" text))
          (should (string-match-p "Owner: \\[\\[id:.+\\]\\[Jun Tanaka\\]\\]" text))
          (should (string-match-p "Source: \\[\\[id:src-1\\]\\[STANDUP 2026-06-24\\]\\]" text))
          ;; Risk filed under Risks.
          (should (string-match-p "\\*\\* Risks\n\\*\\*\\* \\[RISK\\] Lock-in" text)))
        ;; Owner became a real person node.
        (should (file-exists-p (org-fractional-cto-person-file "jun_tanaka")))
        (kill-buffer)))))

(ert-deftest ofc-ai-discard-kills-buffer-without-filing ()
  (ofc-ai-test
    (let* ((hub (ofc-ai-test--make-hub "acme"))
           (buf (org-fractional-cto-ai--review-buffer
                 "STANDUP" "src-1" hub '((:type action :title "X")))))
      (with-current-buffer buf (org-fractional-cto-ai-discard))
      (should-not (get-buffer "*ofc-ai-review*"))
      (with-current-buffer (find-file-noselect hub)
        (should-not (string-match-p "TODO X" (buffer-string)))
        (kill-buffer)))))
```

- [ ] **Step 2: Run test to verify it fails**

Run: `emacs -Q --batch -L . -l test/org-fractional-cto-ai-test.el -f ert-run-tests-batch-and-exit`
Expected: FAIL — commit/discard/helpers void.

- [ ] **Step 3: Implement filing, commit, and discard**

Add to `org-fractional-cto-ai.el`:

```elisp
;;;; Filing

(defun org-fractional-cto-ai--strip-properties (text)
  "Return entry TEXT with its PROPERTIES drawer removed and heading promoted.
Demotes the level-2 review heading back to a level-1 entry."
  (let ((s (replace-regexp-in-string
            ":PROPERTIES:\n\\(?:.*\n\\)*?:END:\n" "" text)))
    (replace-regexp-in-string "^\\*\\(\\*+\\) " "\\1 " s)))

(defun org-fractional-cto-ai--collect-entries ()
  "Return (SECTION OWNER TEXT) for each level-2 entry in the review buffer.
TEXT has the OFC_AI_* properties removed and the heading promoted to level 1."
  (let (entries)
    (save-excursion
      (goto-char (point-min))
      (while (re-search-forward "^\\*\\* " nil t)
        (beginning-of-line)
        (let* ((beg (point))
               (end (save-excursion (org-end-of-subtree t t) (point)))
               (section (org-entry-get (point) "OFC_AI_SECTION"))
               (owner (org-entry-get (point) "OFC_AI_OWNER"))
               (raw (buffer-substring-no-properties beg end)))
          (when section
            (push (list section owner
                        (org-fractional-cto-ai--strip-properties raw))
                  entries))
          (goto-char end))))
    (nreverse entries)))

(defun org-fractional-cto-ai--file-entry (hub section owner text source-id note-title)
  "File entry TEXT under SECTION in HUB, adding owner, provenance, and tag.
OWNER (a name or nil) becomes an `[[id:]]' person link; SOURCE-ID/NOTE-TITLE
become a `Source:' back-link; `org-fractional-cto-ai-provenance-tag' is added."
  (org-fractional-cto--goto-section hub section)
  (org-back-to-heading t)
  (org-end-of-subtree t t)
  (unless (bolp) (insert "\n"))
  (let ((start (point)))
    (insert (string-trim-right text) "\n")
    (goto-char start)
    (org-back-to-heading t)
    (let* ((owner-name (org-fractional-cto-ai--clean-string owner))
           (owner-link (and owner-name
                            (plist-get (org-fractional-cto-person-record owner-name)
                                       :link)))
           (lines (delq nil
                        (list (and owner-link (format "Owner: %s" owner-link))
                              (and source-id note-title
                                   (format "Source: [[id:%s][%s]]"
                                           source-id note-title))))))
      (when lines
        (end-of-line)
        (insert "\n" (mapconcat #'identity lines "\n")))
      (when org-fractional-cto-ai-provenance-tag
        (org-back-to-heading t)
        (org-toggle-tag org-fractional-cto-ai-provenance-tag 'on))))
  (save-buffer))

(defun org-fractional-cto-ai-commit ()
  "File every surviving proposed entry into the hub, then close the review."
  (interactive)
  (let ((hub org-fractional-cto-ai--hub-file)
        (source-id org-fractional-cto-ai--source-id)
        (note-title org-fractional-cto-ai--note-title)
        (entries (org-fractional-cto-ai--collect-entries)))
    (save-window-excursion
      (dolist (e entries)
        (org-fractional-cto-ai--file-entry hub (nth 0 e) (nth 1 e) (nth 2 e)
                                           source-id note-title)))
    (let ((n (length entries)))
      (kill-buffer (current-buffer))
      (message "org-fractional-cto: filed %d item%s" n (if (= n 1) "" "s")))))

(defun org-fractional-cto-ai-discard ()
  "Discard all proposed items and close the review buffer."
  (interactive)
  (kill-buffer (current-buffer)))
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `make test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add org-fractional-cto-ai.el test/org-fractional-cto-ai-test.el
git commit -m "feat: file reviewed items into hub with owner and provenance"
```

---

### Task 9: Extraction driver — wire prompt → request → review

Connect the pieces behind the request function, with defensive handling that never throws.

**Files:**
- Modify: `org-fractional-cto-ai.el`
- Test: `test/org-fractional-cto-ai-test.el`

**Interfaces:**
- Consumes: `org-fractional-cto-ai-request-function`.
- Produces:
  - `(org-fractional-cto-ai--on-response RAW HUB-FILE SOURCE-ID NOTE-TITLE)` → parses/normalizes RAW and pops the review buffer; messages (never throws) on empty/garbage/no-items.
  - `(org-fractional-cto-ai--extract TEXT CLIENT-NAME HUB-FILE SOURCE-ID NOTE-TITLE)` → builds the prompt and calls the request function with a callback to `--on-response`.

- [ ] **Step 1: Write the failing test**

```elisp
(ert-deftest ofc-ai-extract-pops-review-from-fake-backend ()
  (ofc-ai-test
    (let* ((hub (ofc-ai-test--make-hub "acme"))
           (org-fractional-cto-ai-request-function
            (lambda (_prompt cb)
              (funcall cb "[{\"type\":\"action\",\"title\":\"Chase spec\"}]"))))
      (org-fractional-cto-ai--extract "note text" "Acme" hub "src-1" "STANDUP")
      (let ((buf (get-buffer "*ofc-ai-review*")))
        (should buf)
        (unwind-protect
            (with-current-buffer buf
              (should (re-search-forward "Chase spec" nil t)))
          (kill-buffer buf))))))

(ert-deftest ofc-ai-on-response-no-items-pops-nothing ()
  (ofc-ai-test
    (let ((hub (ofc-ai-test--make-hub "acme")))
      (org-fractional-cto-ai--on-response "[]" hub "src-1" "STANDUP")
      (should-not (get-buffer "*ofc-ai-review*")))))

(ert-deftest ofc-ai-on-response-garbage-does-not-throw ()
  (ofc-ai-test
    (let ((hub (ofc-ai-test--make-hub "acme")))
      ;; Returns normally despite unparseable input.
      (should (progn (org-fractional-cto-ai--on-response "nonsense" hub "s" "N") t))
      (should-not (get-buffer "*ofc-ai-review*")))))
```

- [ ] **Step 2: Run test to verify it fails**

Run: `emacs -Q --batch -L . -l test/org-fractional-cto-ai-test.el -f ert-run-tests-batch-and-exit`
Expected: FAIL — functions void.

- [ ] **Step 3: Implement the driver**

Add to `org-fractional-cto-ai.el`:

```elisp
;;;; Driver

(defun org-fractional-cto-ai--on-response (raw hub-file source-id note-title)
  "Turn RAW model output into a review buffer for HUB-FILE.
SOURCE-ID/NOTE-TITLE identify the source note.  Never throws: empty output,
unparseable output, and a zero-item result each just message."
  (condition-case err
      (if (or (null raw) (string-empty-p (string-trim raw)))
          (message "org-fractional-cto: AI returned no output")
        (let* ((parsed (org-fractional-cto-ai--parse-response raw))
               (items (delq nil (mapcar #'org-fractional-cto-ai--normalize-item
                                        parsed))))
          (if (null items)
              (message "org-fractional-cto: AI found no items to extract")
            (org-fractional-cto-ai--review-buffer note-title source-id
                                                  hub-file items))))
    (error
     (message "org-fractional-cto: AI extraction failed (%s)"
              (error-message-string err)))))

(defun org-fractional-cto-ai--extract (text client-name hub-file source-id note-title)
  "Send note TEXT to the model and review the items it extracts.
CLIENT-NAME labels the prompt; HUB-FILE/SOURCE-ID/NOTE-TITLE thread through to
filing and provenance."
  (funcall org-fractional-cto-ai-request-function
           (org-fractional-cto-ai--build-prompt text client-name)
           (lambda (raw)
             (org-fractional-cto-ai--on-response raw hub-file source-id note-title))))
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `make test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add org-fractional-cto-ai.el test/org-fractional-cto-ai-test.el
git commit -m "feat: wire extraction driver from prompt to review"
```

---

### Task 10: Finalize trigger + wiring (hook, template flags, require)

Fire extraction from `before-finalize` for flagged captures, register the hook, flag the templates, and load the module.

**Files:**
- Modify: `org-fractional-cto-ai.el` (the trigger + helpers)
- Modify: `org-fractional-cto-capture.el` (declare + register hook; add `:ofc-ai-extract t` flags)
- Modify: `org-fractional-cto.el` (require the module)
- Test: `test/org-fractional-cto-ai-test.el`, `test/org-fractional-cto-capture-test.el`

**Interfaces:**
- Consumes: `org-capture-get`, `org-id-get-create`, `org-fractional-cto-client-org-file`.
- Produces:
  - `(org-fractional-cto-ai--heading-title)` → title text of the heading at point (no stars/keyword/tags)
  - `(org-fractional-cto-ai--subtree-text)` → plain text of the subtree at point
  - `(org-fractional-cto-ai-maybe-extract)` → `before-finalize` hook: for flagged + enabled captures, ensures a source id, reads the note, and defers `--extract` via `run-at-time 0`; never throws.

- [ ] **Step 1: Write the failing tests**

Add to `test/org-fractional-cto-ai-test.el`:

```elisp
(ert-deftest ofc-ai-subtree-text-and-title ()
  (with-temp-buffer
    (org-mode)
    (insert "* STANDUP 2026-06-24  :STANDUP:\nbody line\n** sub\nmore\n")
    (goto-char (point-min))
    (should (equal (org-fractional-cto-ai--heading-title) "STANDUP 2026-06-24"))
    (should (string-match-p "body line" (org-fractional-cto-ai--subtree-text)))))

(ert-deftest ofc-ai-maybe-extract-noop-when-not-flagged ()
  (ofc-ai-test
    (let ((calls 0))
      (cl-letf (((symbol-function 'run-at-time)
                 (lambda (&rest _) (cl-incf calls))))
        (let ((org-capture-plist nil)            ; :ofc-ai-extract not set
              (org-fractional-cto-ai-request-function (lambda (_p _cb) nil)))
          (org-fractional-cto-ai-maybe-extract)))
      (should (= calls 0)))))

(ert-deftest ofc-ai-maybe-extract-queues-when-flagged ()
  (ofc-ai-test
    (ofc-ai-test--make-hub "acme")
    (let ((queued nil))
      (cl-letf (((symbol-function 'run-at-time)
                 (lambda (_t _r fn &rest args) (setq queued (cons fn args)))))
        (with-temp-buffer
          (org-mode)
          (insert "* STANDUP  :STANDUP:\nnote body\n")
          (goto-char (point-min))
          (let ((org-capture-plist
                 (list :ofc-ai-extract t :ofc-client-slug "acme"
                       :ofc-client-name "Acme"))
                (org-fractional-cto-ai-request-function (lambda (_p _cb) nil)))
            (org-fractional-cto-ai-maybe-extract))))
      (should (eq (car queued) #'org-fractional-cto-ai--extract))
      ;; args: text client-name hub-file source-id note-title
      (should (string-match-p "note body" (nth 1 queued)))
      (should (equal (nth 2 queued) "Acme")))))

(ert-deftest ofc-ai-maybe-extract-never-throws ()
  (ofc-ai-test
    (cl-letf (((symbol-function 'org-id-get-create)
               (lambda (&rest _) (error "boom"))))
      (with-temp-buffer
        (org-mode)
        (insert "* STANDUP  :STANDUP:\nx\n")
        (goto-char (point-min))
        (let ((org-capture-plist (list :ofc-ai-extract t :ofc-client-slug "acme"))
              (org-fractional-cto-ai-request-function (lambda (_p _cb) nil)))
          (should (progn (org-fractional-cto-ai-maybe-extract) t)))))))
```

Add to `test/org-fractional-cto-capture-test.el`:

```elisp
(ert-deftest ofc-capture-install-registers-ai-finalize-hook ()
  (let ((org-capture-before-finalize-hook nil))
    (org-fractional-cto-capture-install)
    (should (memq 'org-fractional-cto-ai-maybe-extract
                  org-capture-before-finalize-hook))))

(ert-deftest ofc-capture-standup-template-is-ai-flagged ()
  (let* ((tpls (org-fractional-cto-capture-templates))
         (standup (assoc "es" tpls)))
    (should (plist-get (nthcdr 5 standup) :ofc-ai-extract))))
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `make test`
Expected: FAIL — `org-fractional-cto-ai-maybe-extract` void; hook not registered; template not flagged.

- [ ] **Step 3a: Add the trigger to `org-fractional-cto-ai.el`**

```elisp
;;;; Finalize trigger

(defun org-fractional-cto-ai--heading-title ()
  "Return the title of the heading at point (no stars, keyword, or tags)."
  (org-back-to-heading t)
  (or (nth 4 (org-heading-components)) ""))

(defun org-fractional-cto-ai--subtree-text ()
  "Return the plain text of the subtree at point (heading plus body)."
  (save-excursion
    (org-back-to-heading t)
    (buffer-substring-no-properties
     (point)
     (progn (org-end-of-subtree t t) (point)))))

(defun org-fractional-cto-ai-maybe-extract ()
  "On `org-capture-before-finalize-hook', queue AI extraction for flagged captures.
A no-op unless the capture template carries `:ofc-ai-extract' and a request
function is configured.  Reads the note synchronously, then defers the model
call so finalize never blocks.  Wrapped so a failure can never abort finalize."
  (when (and (org-capture-get :ofc-ai-extract)
             (org-fractional-cto-ai--enabled-p))
    (condition-case err
        (let* ((slug (org-capture-get :ofc-client-slug))
               (client-name (org-capture-get :ofc-client-name))
               (hub-file (and slug (org-fractional-cto-client-org-file slug))))
          (save-excursion
            (when (ignore-errors (org-back-to-heading t))
              (let ((source-id (org-id-get-create))
                    (note-title (org-fractional-cto-ai--heading-title))
                    (text (org-fractional-cto-ai--subtree-text)))
                (run-at-time 0 nil #'org-fractional-cto-ai--extract
                             text client-name hub-file source-id note-title)))))
      (error
       (message "org-fractional-cto: AI extraction not queued (%s)"
                (error-message-string err))))))
```

- [ ] **Step 3b: Register the hook and declare the function in `org-fractional-cto-capture.el`**

Add near the other `declare-function` forms at the top:

```elisp
(declare-function org-fractional-cto-ai-maybe-extract "org-fractional-cto-ai")
```

In `org-fractional-cto-capture-install`, add the hook beside the person-tag hook:

```elisp
  (add-hook 'org-capture-before-finalize-hook
            #'org-fractional-cto--apply-person-tag)
  (add-hook 'org-capture-before-finalize-hook
            #'org-fractional-cto-ai-maybe-extract)
```

- [ ] **Step 3c: Flag the templates in `org-fractional-cto-capture-templates`**

Append `:ofc-ai-extract t` to these entries' property lists: `"ew"`→no; flag the note-style captures — `"em"` (Client meeting), `"ei"` (Internal sync), `"es"` (Standup), `"eW"` (Weekly review), `"eq"` (QBR), `"eR"` (Retrospective), `"ed"` (Discovery session). For example, the standup entry becomes:

```elisp
    ("es" "Standup" entry
     (function ,(org-fractional-cto--target "Standup Notes"))
     (function ,(org-fractional-cto--file "standup.org"))
     :clock-in t :clock-resume t :ofc-ai-extract t)
```

Apply the same `:ofc-ai-extract t` addition to `"em"`, `"ei"`, `"eW"`, `"eq"`, `"eR"`, and `"ed"`. (`"eR"` and `"ed"` already end with `:clock-in t :clock-resume t`; `"eW"`/`"em"`/`"ei"`/`"eq"` likewise — append the flag to the existing property list on each.)

- [ ] **Step 3d: Require the module from `org-fractional-cto.el`**

In the "Sub-modules" section, add after the people require:

```elisp
(require 'org-fractional-cto-people)
(require 'org-fractional-cto-ai)
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `make test`
Expected: PASS (all suites).

- [ ] **Step 5: Byte-compile clean-check**

Run: `emacs -Q --batch -L . --eval "(setq byte-compile-error-on-warn t)" -f batch-byte-compile org-fractional-cto-ai.el org-fractional-cto-capture.el`
Expected: no errors/warnings. Then remove artifacts: `rm -f *.elc`.

- [ ] **Step 6: Commit**

```bash
git add org-fractional-cto-ai.el org-fractional-cto-capture.el org-fractional-cto.el \
        test/org-fractional-cto-ai-test.el test/org-fractional-cto-capture-test.el
git commit -m "feat: fire AI extraction on finalize for flagged captures"
```

---

### Task 11: Documentation

Document the feature and the backend contract in README.org so users can wire a backend.

**Files:**
- Modify: `README.org`

**Interfaces:** none (prose only).

- [ ] **Step 1: Add a section to `README.org`**

Add a section (place it after the capture documentation) describing:
- what the feature does (extract Actions/Risks/Blockers/Decisions from flagged notes on finalize, review-then-file);
- that it is off until `org-fractional-cto-ai-request-function` is set, with a worked example backend over a CLI, e.g.:

```elisp
(setq org-fractional-cto-ai-request-function
      (lambda (prompt callback)
        (let ((buf (generate-new-buffer " *ofc-ai*")))
          (make-process
           :name "ofc-ai" :buffer buf
           :command '("llm" "--no-stream")   ; any CLI reading the prompt on stdin
           :connection-type 'pipe
           :sentinel (lambda (proc _e)
                       (when (memq (process-status proc) '(exit signal))
                         (with-current-buffer (process-buffer proc)
                           (funcall callback (buffer-string)))
                         (kill-buffer (process-buffer proc)))))
          (process-send-string
           (get-buffer-process buf) prompt)
          (process-send-eof (get-buffer-process buf)))))
```

- the review keys (`C-c C-c` file survivors, `C-c C-k` discard; delete a subtree to reject it);
- the `:AI:` provenance tag and `Source:` back-link;
- how to extend the taxonomy by adding a row to `org-fractional-cto-ai-item-types`;
- which templates are flagged, and that adding `:ofc-ai-extract t` to a capture template opts it in.

- [ ] **Step 2: Commit**

```bash
git add README.org
git commit -m "docs: document AI note extraction and backend contract"
```

---

## Self-Review

**Spec coverage:**
- Transport (pluggable, nil default) → Task 2 (`-request-function`, `--enabled-p`).
- Taxonomy table / generalization → Task 2 (`-item-types`, `--type-spec`).
- Prompt construction → Task 3. Parsing → Task 4. Normalization/validation → Task 5.
- Renderers mirroring templates → Task 6. Owner via `:OFC_AI_OWNER:` → Tasks 6 (carry) + 8 (resolve at commit).
- Review buffer, delete-to-reject, `C-c C-c`/`C-c C-k` → Tasks 7-8.
- Filing: `--goto-section`, depth normalization, provenance link, `:AI:` tag → Tasks 1, 8.
- Driver + defensive `--on-response` → Task 9.
- Finalize trigger (opt-in flag, `org-id` back-link, `run-at-time 0`, never-abort) → Task 10.
- Config surface table → Tasks 2 (3 defcustoms) + 10 (`:ofc-ai-extract`).
- Error handling/boundaries → Tasks 9 (`--on-response`) + 10 (`maybe-extract`).
- Testing strategy (pure units + full-flow with fake backend) → Tasks 3-10.
- Docs / reference backend → Task 11.

**Placeholder scan:** No "TBD"/"implement later"; every code step shows complete code. The escaped-quote note in Tasks 2 is an artifact of Markdown fencing and is called out explicitly.

**Type consistency:** Item plist keys (`:type :title :owner :deadline :priority :body :fields`) are consistent across Tasks 5-6-8. `--type-spec` returns the same `:section`/`:tag`/`:render` plist everywhere. `--review-buffer` arg order `(NOTE-TITLE SOURCE-ID HUB-FILE ITEMS)` matches its call in `--on-response` (Task 9). `--file-entry` arg order `(HUB SECTION OWNER TEXT SOURCE-ID NOTE-TITLE)` matches its call in `-commit` (Task 8). `--extract` arg order `(TEXT CLIENT-NAME HUB-FILE SOURCE-ID NOTE-TITLE)` matches the `run-at-time` call in Task 10 and the test in Task 9.

## Execution Handoff

(See the writing-plans handoff in the next message.)
