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
                     (file-truename org-fractional-cto-clients-directory)
                     (file-truename (buffer-file-name buf))))
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

(ert-deftest ofc-new-client-engagement-is-active ()
  (ofc-prospect-test-with-clients-dir
    (org-fractional-cto-new-client "Acme Corp" "acme")
    (find-file (org-fractional-cto-client-org-file "acme"))
    (goto-char (point-min))
    (org-mode)
    (should (re-search-forward "^\\* Acme Corp Engagement" nil t))
    (org-back-to-heading t)
    (should (member "ACTIVE" (org-get-tags nil t)))
    (should (member "ACME" (org-get-tags nil t)))))

(ert-deftest ofc-scaffold-rejects-unknown-stage ()
  (ofc-prospect-test-with-clients-dir
    (should-error (org-fractional-cto--scaffold "Acme Corp" "acme" "BOGUS")
                  :type 'user-error)))

(ert-deftest ofc-new-prospect-engagement-is-lead ()
  (ofc-prospect-test-with-clients-dir
    (org-fractional-cto-new-prospect "Beta Co" "beta")
    (should (equal org-fractional-cto-active-client "beta"))
    (find-file (org-fractional-cto-client-org-file "beta"))
    (goto-char (point-min))
    (org-mode)
    (should (re-search-forward "^\\* Beta Co Engagement" nil t))
    (org-back-to-heading t)
    (should (member "LEAD" (org-get-tags nil t)))
    (should (member "BETA" (org-get-tags nil t)))))

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

(provide 'org-fractional-cto-prospect-test)

;;; org-fractional-cto-prospect-test.el ends here
