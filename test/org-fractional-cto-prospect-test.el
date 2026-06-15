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
    (should (member "ACTIVE" (org-get-tags nil t)))))

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
    (with-temp-buffer
      (insert-file-contents (org-fractional-cto-client-org-file "beta"))
      (goto-char (point-min))
      (should (re-search-forward "^#\\+filetags:[ \t]+:BETA:" nil t)))))

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
    (with-temp-buffer
      (insert-file-contents (org-fractional-cto-client-org-file "acme"))
      (goto-char (point-min))
      (should (re-search-forward "^#\\+filetags:[ \t]+:ACME:" nil t)))))

(ert-deftest ofc-set-stage-rejects-unknown ()
  (ofc-prospect-test-with-clients-dir
    (org-fractional-cto-new-client "Acme Corp" "acme")
    (setq org-fractional-cto-active-client "acme")
    (should-error (org-fractional-cto-set-stage "BOGUS") :type 'user-error)))

(ert-deftest ofc-upgrade-hub-adds-stage-and-sections ()
  (ofc-prospect-test-with-clients-dir
    (let* ((dir (expand-file-name "legacy" org-fractional-cto-clients-directory))
           (hub (org-fractional-cto-client-org-file "legacy")))
      (make-directory dir t)
      (with-temp-file hub
        (insert "#+TODO: TODO NEXT INPROGRESS WAITING | DONE CANCELLED\n\n"
                "* Legacy Engagement  :LEGACY:\n"
                "** Actions  :LEGACY:\n"))
      (setq org-fractional-cto-active-client "legacy")
      (org-fractional-cto-upgrade-hub)
      (find-file hub)
      (goto-char (point-min))
      (org-mode)
      (re-search-forward "^\\* Legacy Engagement")
      (org-back-to-heading t)
      (should (member "ACTIVE" (org-get-tags nil t)))
      (goto-char (point-min))
      (should (re-search-forward "^\\*\\* Pre-Sales Notes .*:PRESALES:" nil t))
      (goto-char (point-min))
      (should (re-search-forward "^\\*\\* Qualification .*:QUALIFICATION:" nil t))
      (goto-char (point-min))
      (should-not (re-search-forward "^\\*+ .*:LEGACY:" nil t)))))

(ert-deftest ofc-upgrade-hub-is-idempotent ()
  (ofc-prospect-test-with-clients-dir
    (let* ((dir (expand-file-name "legacy" org-fractional-cto-clients-directory))
           (hub (org-fractional-cto-client-org-file "legacy")))
      (make-directory dir t)
      (with-temp-file hub
        (insert "* Legacy Engagement  :LEGACY:\n** Actions  :LEGACY:\n"))
      (setq org-fractional-cto-active-client "legacy")
      (org-fractional-cto-upgrade-hub)
      (org-fractional-cto-upgrade-hub)
      (find-file hub)
      (goto-char (point-min))
      (org-mode)
      (let ((count 0))
        (while (re-search-forward "^\\*\\* Pre-Sales Notes" nil t)
          (setq count (1+ count)))
        (should (= count 1))))))

(ert-deftest ofc-migrate-amends-existing-filetags ()
  "Migration amends an existing filetags line rather than adding a second."
  (ofc-prospect-test-with-clients-dir
    (let* ((slug "acme")
           (dir (expand-file-name slug (org-fractional-cto--clients-dir)))
           (file (org-fractional-cto-client-org-file slug)))
      (make-directory dir t)
      (with-temp-file file
        (insert "#+title: Acme Corp\n")
        (insert "#+TODO: TODO NEXT INPROGRESS WAITING | DONE CANCELLED\n")
        (insert "#+filetags: :OTHER:\n\n")
        (insert "* Acme Corp Engagement  :ACTIVE:\n"))
      (org-fractional-cto-set-active-client slug)
      (org-fractional-cto-upgrade-hub)
      (with-temp-buffer
        (insert-file-contents file)
        (goto-char (point-min))
        (let ((n 0))
          (while (re-search-forward "^#\\+filetags:" nil t) (setq n (1+ n)))
          (should (= n 1)))
        (goto-char (point-min))
        (should (re-search-forward "^#\\+filetags:.*:OTHER:" nil t))
        (goto-char (point-min))
        (should (re-search-forward "^#\\+filetags:.*:ACME:" nil t))))))

(ert-deftest ofc-capture-templates-include-presales ()
  (let* ((templates (org-fractional-cto-capture-templates))
         (keys (mapcar #'car templates)))
    (should (member "el" keys))
    (should (member "eo" keys))
    (should (member "eF" keys))))

(ert-deftest ofc-presales-template-files-exist ()
  (should (file-exists-p (org-fractional-cto--template "presales_call.org")))
  (should (file-exists-p (org-fractional-cto--template "qualification.org"))))

(ert-deftest ofc-pipeline-skip-keeps-level-1 ()
  (with-temp-buffer
    (org-mode)
    (insert "* Acme Engagement  :ACME:LEAD:\n** Actions  :ACME:\n*** TODO x  :ACME:\n")
    (goto-char (point-min))
    (org-back-to-heading t)
    (should-not (org-fractional-cto--pipeline-skip))
    (goto-char (point-min))
    (re-search-forward "^\\*\\* Actions")
    (org-back-to-heading t)
    (should (org-fractional-cto--pipeline-skip))))

(ert-deftest ofc-pipeline-install-registers-command ()
  (let ((org-agenda-custom-commands nil)
        (org-fractional-cto-pipeline-key "P")
        (org-fractional-cto-pipeline-stages "LEAD|QUALIFIED"))
    (org-fractional-cto-pipeline-install)
    (should (assoc "P" org-agenda-custom-commands))))

(ert-deftest ofc-command-map-has-prospect-bindings ()
  (should (eq (lookup-key org-fractional-cto-command-map "p")
              #'org-fractional-cto-new-prospect))
  (should (eq (lookup-key org-fractional-cto-command-map "S")
              #'org-fractional-cto-set-stage)))

(ert-deftest ofc-setup-installs-pipeline ()
  (let ((org-agenda-custom-commands nil)
        (org-capture-templates nil)
        (org-agenda-files nil)
        (org-fractional-cto-clients-directory (make-temp-file "ofc-setupclients" t)))
    (unwind-protect
        (progn
          (org-fractional-cto-setup)
          (should (assoc org-fractional-cto-pipeline-key org-agenda-custom-commands))
          (should (assoc org-fractional-cto-agenda-key org-agenda-custom-commands)))
      (delete-directory org-fractional-cto-clients-directory t))))

(defun ofc-test-hub-skeleton (slug client-tag)
  "Return SLUG's hub heading lines with CLIENT-TAG and stage tags stripped.
Normalizing those away lets two hubs that differ only in slug and stage be
compared for structural equality."
  (with-temp-buffer
    (insert-file-contents (org-fractional-cto-client-org-file slug))
    (goto-char (point-min))
    (let (heads)
      (while (re-search-forward "^\\*+ .*$" nil t)
        (let ((line (match-string 0)))
          (setq line (replace-regexp-in-string (concat client-tag ":") "" line))
          (dolist (s org-fractional-cto-stages)
            (setq line (replace-regexp-in-string (concat s ":") "" line)))
          (push line heads)))
      (nreverse heads))))

(ert-deftest ofc-prospect-hub-structure-matches-client ()
  "A prospect hub is structurally identical to a client hub but for the stage.
This is the architectural keystone: new-prospect and new-client share one
scaffold, so their hubs agree on every heading once slug and stage are removed."
  (ofc-prospect-test-with-clients-dir
    (org-fractional-cto-new-client "Acme Corp" "acme")
    (org-fractional-cto-new-prospect "Acme Corp" "acme2")
    (should (equal (ofc-test-hub-skeleton "acme" "ACME")
                   (ofc-test-hub-skeleton "acme2" "ACME2")))))

;;;; TODO keyword installation -------------------------------------------------

(ert-deftest ofc-install-todo-keywords-adds-inprogress ()
  "Setup registers INPROGRESS (and its face) when it is not already known."
  (let ((org-todo-keywords '((sequence "TODO" "|" "DONE")))
        (org-todo-keyword-faces nil))
    (org-fractional-cto--install-todo-keywords)
    (should (member "INPROGRESS" (org-fractional-cto--known-todo-keywords)))
    (should (assoc "INPROGRESS" org-todo-keyword-faces))))

(ert-deftest ofc-install-todo-keywords-is-idempotent ()
  "Re-running keyword install does not append a duplicate sequence."
  (let ((org-todo-keywords '((sequence "TODO" "|" "DONE")))
        (org-todo-keyword-faces nil))
    (org-fractional-cto--install-todo-keywords)
    (let ((after-first (copy-tree org-todo-keywords)))
      (org-fractional-cto--install-todo-keywords)
      (should (equal org-todo-keywords after-first)))))

(ert-deftest ofc-install-todo-keywords-skips-when-known ()
  "No sequence is added when all its keywords are already recognised."
  (let ((org-todo-keywords
         '((sequence "TODO" "NEXT" "INPROGRESS" "WAITING" "|" "DONE" "CANCELLED")))
        (org-todo-keyword-faces nil))
    (let ((before (copy-tree org-todo-keywords)))
      (org-fractional-cto--install-todo-keywords)
      (should (equal org-todo-keywords before)))))

(ert-deftest ofc-install-todo-keywords-preserves-existing-faces ()
  "An INPROGRESS face the user already defined is left untouched."
  (let ((org-todo-keywords '((sequence "TODO" "INPROGRESS" "|" "DONE")))
        (org-todo-keyword-faces '(("INPROGRESS" . my-face))))
    (org-fractional-cto--install-todo-keywords)
    (should (eq (cdr (assoc "INPROGRESS" org-todo-keyword-faces)) 'my-face))))

;;;; Dashboard coverage --------------------------------------------------------

(ert-deftest ofc-dashboard-covers-risk-family ()
  "The dashboard surfaces risks, security findings, tech debt, and scope."
  (let ((matches (mapcar (lambda (block) (nth 1 block))
                         org-fractional-cto-dashboard-blocks)))
    (should (member "+RISK" matches))
    (should (member "+SECURITY" matches))
    (should (member "+TECHDEBT" matches))
    (should (member "+SCOPE" matches))))

(ert-deftest ofc-risk-and-security-blocks-hide-closed ()
  "Risks and security findings hide the same closed set: Resolved and Mitigated."
  (dolist (match '("+RISK" "+SECURITY"))
    (let* ((block (seq-find (lambda (b) (equal (nth 1 b) match))
                            org-fractional-cto-dashboard-blocks))
           (skip (format "%S" (cadr (assq 'org-agenda-skip-function
                                          (nth 2 block))))))
      (should (string-match-p "Resolved" skip))
      (should (string-match-p "Mitigated" skip))
      ;; Accepted is NOT closed -- it stays on the board.
      (should-not (string-match-p "Accepted" skip)))))

(ert-deftest ofc-risk-and-security-templates-have-status-field ()
  "Both the risk and security templates offer the same closeable Status field."
  (let ((templates (org-fractional-cto-capture-templates)))
    (dolist (key '("er" "ex"))
      (let ((body (nth 4 (seq-find (lambda (tpl) (equal (car-safe tpl) key))
                                   templates))))
        (should (string-match-p
                 "Status: %\\^{Status|Open|Mitigated|Resolved|Accepted}" body))))))

(ert-deftest ofc-client-name-reads-title ()
  "client-name returns the hub's #+title."
  (ofc-prospect-test-with-clients-dir
    (org-fractional-cto-new-client "Acme Corp" "acme")
    (should (equal (org-fractional-cto-client-name "acme") "Acme Corp"))))

(ert-deftest ofc-client-name-falls-back-to-slug ()
  "client-name returns the slug when no hub/title exists."
  (ofc-prospect-test-with-clients-dir
    (should (equal (org-fractional-cto-client-name "ghost") "ghost"))))

(ert-deftest ofc-client-name-handles-case-and-whitespace ()
  "client-name matches #+TITLE case-insensitively and trims whitespace."
  (ofc-prospect-test-with-clients-dir
    (let* ((file (org-fractional-cto-client-org-file "pad")))
      (make-directory (file-name-directory file) t)
      (with-temp-file file
        (insert "#+TITLE:   Padded Name   \n\n* Pad Engagement\n"))
      (should (equal (org-fractional-cto-client-name "pad") "Padded Name")))))

(ert-deftest ofc-hub-has-filetags ()
  "A scaffolded hub declares the client tag as a filetag."
  (ofc-prospect-test-with-clients-dir
    (org-fractional-cto-new-client "Acme Corp" "acme")
    (with-temp-buffer
      (insert-file-contents (org-fractional-cto-client-org-file "acme"))
      (goto-char (point-min))
      (should (re-search-forward "^#\\+filetags:[ \t]+:ACME:" nil t)))))

(ert-deftest ofc-hub-headings-omit-client-tag ()
  "No heading carries the client tag; stage and type subtags remain."
  (ofc-prospect-test-with-clients-dir
    (org-fractional-cto-new-client "Acme Corp" "acme")
    (with-temp-buffer
      (insert-file-contents (org-fractional-cto-client-org-file "acme"))
      (goto-char (point-min))
      (should (re-search-forward "^\\* Acme Corp Engagement[ \t]+:ACTIVE:$" nil t))
      (goto-char (point-min))
      (should (re-search-forward "^\\*\\* Risks[ \t]+:RISK:$" nil t))
      (goto-char (point-min))
      (should-not (re-search-forward "^\\*+ .*:ACME:" nil t)))))

(ert-deftest ofc-upgrade-hub-migrates-to-filetags ()
  "Upgrading an old-style hub adds a filetag and strips heading client tags."
  (ofc-prospect-test-with-clients-dir
    (let* ((slug "acme")
           (dir (expand-file-name slug (org-fractional-cto--clients-dir)))
           (file (org-fractional-cto-client-org-file slug)))
      (make-directory dir t)
      (with-temp-file file
        (insert "#+title: Acme Corp\n")
        (insert "#+TODO: TODO NEXT INPROGRESS WAITING | DONE CANCELLED\n\n")
        (insert "* Acme Corp Engagement  :ACME:ACTIVE:\n\n")
        (insert "** Risks  :ACME:RISK:\n\n")
        (insert "** Actions  :ACME:\n\n"))
      (org-fractional-cto-set-active-client slug)
      (org-fractional-cto-upgrade-hub)
      (with-temp-buffer
        (insert-file-contents file)
        (goto-char (point-min))
        (should (re-search-forward "^#\\+filetags:[ \t]+:ACME:" nil t))
        (goto-char (point-min))
        (should-not (re-search-forward "^\\*+ .*:ACME:" nil t))
        (goto-char (point-min))
        (should (re-search-forward "^\\* Acme Corp Engagement[ \t]+:ACTIVE:$" nil t))
        (goto-char (point-min))
        (should (re-search-forward "^\\*\\* Risks[ \t]+:RISK:$" nil t))))))

(ert-deftest ofc-upgrade-hub-filetags-idempotent ()
  "Re-upgrading a migrated hub does not add a second filetags line."
  (ofc-prospect-test-with-clients-dir
    (org-fractional-cto-new-client "Acme Corp" "acme")
    (org-fractional-cto-set-active-client "acme")
    (org-fractional-cto-upgrade-hub)
    (org-fractional-cto-upgrade-hub)
    (with-temp-buffer
      (insert-file-contents (org-fractional-cto-client-org-file "acme"))
      (goto-char (point-min))
      (let ((n 0))
        (while (re-search-forward "^#\\+filetags:" nil t) (setq n (1+ n)))
        (should (= n 1))))))

(ert-deftest ofc-inline-templates-drop-client-tag ()
  "No inline capture template references the client tag any more."
  (dolist (tpl (org-fractional-cto-capture-templates))
    (let ((body (and (> (length tpl) 4) (nth 4 tpl))))
      (when (stringp body)
        (should-not (string-match-p ":ofc-client-tag" body))))))

(ert-deftest ofc-templates-keep-type-subtags ()
  "The risk template still carries its :RISK: subtag."
  (let ((body (nth 4 (seq-find (lambda (tpl) (equal (car-safe tpl) "er"))
                               (org-fractional-cto-capture-templates)))))
    (should (string-match-p ":RISK:" body))
    (should-not (string-match-p ":ofc-client-tag" body))))

(ert-deftest ofc-file-templates-drop-client-tag ()
  "No bundled file template embeds the client tag (it comes from #+filetags)."
  (let ((dir (file-name-directory
              (org-fractional-cto--template "x.org"))))
    (dolist (f (directory-files dir t "\\.org\\'"))
      (with-temp-buffer
        (insert-file-contents f)
        (goto-char (point-min))
        (should-not (re-search-forward "ofc-client-tag" nil t))))))

(provide 'org-fractional-cto-prospect-test)

;;; org-fractional-cto-prospect-test.el ends here
