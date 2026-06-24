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

(ert-deftest ofc-ai-build-prompt-includes-types-and-note ()
  (let ((p (org-fractional-cto-ai--build-prompt "We must rotate the API keys." "Acme")))
    (should (string-match-p "Acme" p))
    (should (string-match-p "action" p))
    (should (string-match-p "risk" p))
    (should (string-match-p "JSON" p))
    (should (string-match-p "rotate the API keys" p))))

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

(provide 'org-fractional-cto-ai-test)

;;; org-fractional-cto-ai-test.el ends here
