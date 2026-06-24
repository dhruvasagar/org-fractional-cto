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
  :type '(choice (const :tag "Disabled" nil) function)
  :group 'org-fractional-cto)

(defcustom org-fractional-cto-ai-item-types
  '((action   :section "Actions"                :tag nil
              :desc "A concrete follow-up task someone must do."
              :render org-fractional-cto-ai--render-action)
    (risk     :section "Risks"                  :tag "RISK"
              :desc "A risk to the engagement, with likelihood and impact."
              :render org-fractional-cto-ai--render-risk)
    (blocker  :section "Blockers"               :tag "BLOCKER"
              :desc "Something actively blocking a work stream."
              :render org-fractional-cto-ai--render-blocker)
    (decision :section "Architecture Decisions" :tag "DECISION"
              :desc "A decision reached during the discussion, worth recording."
              :render org-fractional-cto-ai--render-decision))
  "Taxonomy of AI-extractable item types.
Each entry is (TYPE . PLIST).  :section must name a heading in
`org-fractional-cto-sections'.  :tag is the per-item Org tag mirroring the
bundled capture template (nil for none).  :desc is fed to the model to guide
classification.  :render is a function taking a normalized item plist and
returning Org entry text.  Add a row to extend the taxonomy."
  :type 'sexp
  :group 'org-fractional-cto)

(defcustom org-fractional-cto-ai-provenance-tag "AI"
  "Org tag added to items filed by AI extraction, or nil to add none."
  :type '(choice (const :tag "None" nil) string)
  :group 'org-fractional-cto)

;;;; Predicates

(defun org-fractional-cto-ai--enabled-p ()
  "Return non-nil when a model request function is configured."
  (functionp org-fractional-cto-ai-request-function))

(defun org-fractional-cto-ai--type-spec (type)
  "Return the taxonomy plist for symbol TYPE, or nil.
Only returns a spec whose :section names a real hub section."
  (let ((spec (cdr (assq type org-fractional-cto-ai-item-types))))
    (when (and spec
               (member (plist-get spec :section)
                       (mapcar #'car org-fractional-cto-sections)))
      spec)))

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
    (insert (org-fractional-cto-ai--demote (string-trim-right text) 2) "\n")
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

(provide 'org-fractional-cto-ai)

;;; org-fractional-cto-ai.el ends here
