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

(provide 'org-fractional-cto-ai-test)

;;; org-fractional-cto-ai-test.el ends here
