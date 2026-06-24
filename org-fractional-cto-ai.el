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

(provide 'org-fractional-cto-ai)

;;; org-fractional-cto-ai.el ends here
