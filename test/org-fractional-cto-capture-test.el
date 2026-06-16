;;; org-fractional-cto-capture-test.el --- Tests for capture templates -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Dhruva Sagar
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; ERT tests for the `e' capture group, focused on the standup template's
;; per-client resolution.  Run with: make test
;;
;; The standup capture must use the client's edited <slug>/standup.org rather
;; than the bundled generic template.  Regression guard: Org resolves a
;; (function ...) template via `org-capture-get-template' BEFORE it runs the
;; target function, so the template cannot read a slug the target has not
;; stashed yet -- both must route through
;; `org-fractional-cto--capture-client-slug'.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'org-capture)
(require 'org-fractional-cto)
(require 'org-fractional-cto-capture)

(defmacro ofc-capture-test-with-client (&rest body)
  "Run BODY with a throwaway clients dir holding a scaffolded acme client.
Binds a clean capture plist and clears any active client / session state."
  (declare (indent 0) (debug t))
  `(let* ((org-fractional-cto-clients-directory (make-temp-file "ofc-capture" t))
          (org-fractional-cto-active-client "acme")
          (org-capture-plist nil)
          (dir (expand-file-name "acme" org-fractional-cto-clients-directory)))
     (unwind-protect
         (progn
           (make-directory dir t)
           ,@body)
       (delete-directory org-fractional-cto-clients-directory t))))

(ert-deftest ofc-standup-template-uses-per-client-file ()
  "The standup template returns the client's edited standup.org, not the bundle."
  (ofc-capture-test-with-client
    (let ((standup (org-fractional-cto-client-standup-file "acme")))
      (with-temp-file standup
        (insert "* STANDUP CLIENT-SPECIFIC MARKER\n** Payments stream\n"))
      (let ((result (org-fractional-cto--standup-template)))
        (should (string-match-p "CLIENT-SPECIFIC MARKER" result))))))

(ert-deftest ofc-standup-template-falls-back-to-bundle ()
  "With no per-client standup.org on disk, the bundled template is used."
  (ofc-capture-test-with-client
    ;; No standup.org written under the client dir.
    (let ((result (org-fractional-cto--standup-template))
          (bundled (org-fractional-cto--file-contents
                    (org-fractional-cto--template "standup.org"))))
      (should (string= result bundled)))))

(ert-deftest ofc-standup-template-resolves-slug-before-target ()
  "Template resolves the client itself when the target has not run yet.
Mirrors Org's real order: `org-capture-get-template' runs before
`org-capture-set-target-location'.  With an empty plist (no :ofc-client-slug),
the template must still pick up the active client's file."
  (ofc-capture-test-with-client
    (should (null (org-capture-get :ofc-client-slug)))
    (let ((standup (org-fractional-cto-client-standup-file "acme")))
      (with-temp-file standup
        (insert "* STANDUP EARLY-RESOLUTION MARKER\n"))
      (let ((result (org-fractional-cto--standup-template)))
        (should (string-match-p "EARLY-RESOLUTION MARKER" result))
        ;; ...and the helper memoised the choice into the plist.
        (should (equal (org-capture-get :ofc-client-slug) "acme"))))))

(ert-deftest ofc-capture-client-slug-memoises ()
  "The slug helper selects once and reuses the stored value thereafter."
  (ofc-capture-test-with-client
    (should (equal (org-fractional-cto--capture-client-slug) "acme"))
    ;; Change the active client; the memoised plist value must win so the
    ;; template and target agree within a single capture.
    (let ((org-fractional-cto-active-client "other"))
      (should (equal (org-fractional-cto--capture-client-slug) "acme")))))

(ert-deftest ofc-capture-client-slug-prompts-when-no-active-client ()
  "With no active client, the slug helper prompts via `completing-read'.
The selection is also memoised so it happens only once per capture."
  (ofc-capture-test-with-client
    (let ((org-fractional-cto-active-client nil)
          (prompts 0))
      (cl-letf (((symbol-function 'completing-read)
                 (lambda (&rest _) (cl-incf prompts) "acme")))
        ;; First resolution prompts...
        (should (equal (org-fractional-cto--capture-client-slug) "acme"))
        (should (= prompts 1))
        ;; ...and the second reuses the memoised value (no extra prompt),
        ;; so template + target across one capture prompt the user once.
        (should (equal (org-fractional-cto--capture-client-slug) "acme"))
        (should (= prompts 1))))))

(provide 'org-fractional-cto-capture-test)

;;; org-fractional-cto-capture-test.el ends here
