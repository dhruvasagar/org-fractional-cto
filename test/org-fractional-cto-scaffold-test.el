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
