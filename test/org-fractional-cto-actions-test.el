;;; org-fractional-cto-actions-test.el --- Tests for at-point commands -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Dhruva Sagar
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; ERT tests for `org-fractional-cto-delegate-at-point' and
;; `org-fractional-cto-block-at-point'.  Run with: make test
;;
;; Each test runs inside a throwaway client hub on disk (named acme.org) that
;; declares `#+filetags: :ACME:' — the commands derive the client tag from that
;; file-level tag, not from the filename.  Tests drive commands non-interactively
;; by passing their arguments directly.

;;; Code:

(require 'ert)
(require 'org-fractional-cto)

(defconst ofc-test-hub "\
#+TITLE: Acme Corp
#+TODO: TODO NEXT INPROGRESS WAITING | DONE CANCELLED
#+filetags: :ACME:

* Acme Corp Engagement
** Actions
*** TODO Ship the thing
** Blockers :BLOCKER:
"
  "Minimal client hub used as the fixture for every test.")

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
          (org-id-files nil)
          (org-id-track-globally nil))
     (unwind-protect
         (progn
           (with-temp-file file (insert ofc-test-hub))
           (find-file file)
           (org-mode)
           (goto-char (point-min))
           ,@body)
       (when (get-file-buffer file) (kill-buffer (get-file-buffer file)))
       (delete-directory dir t))))

(defun ofc-test-goto (substring)
  "Move to the heading containing SUBSTRING, point at its bol."
  (goto-char (point-min))
  (search-forward substring)
  (org-back-to-heading t))

(defun ofc-test-goto-blocker (what)
  "Move to the BLOCKER heading for WHAT (the headline, not the back-reference)."
  (goto-char (point-min))
  (re-search-forward (concat "^\\*+ .*BLOCKER: " (regexp-quote what)))
  (org-back-to-heading t))

;;;; Delegate

(ert-deftest ofc-delegate-sets-waiting-state ()
  (ofc-test-with-hub
    (ofc-test-goto "Ship the thing")
    (org-fractional-cto-delegate-at-point "Alice" nil nil)
    (ofc-test-goto "Ship the thing")
    (should (equal (org-get-todo-state) "WAITING"))))

(ert-deftest ofc-delegate-records-link-and-person-tag ()
  (ofc-test-with-hub
    (ofc-test-goto "Ship the thing")
    (org-fractional-cto-delegate-at-point "Alice" nil nil)
    (ofc-test-goto "Ship the thing")
    (should (member "DELEGATED" (org-get-tags nil t)))
    (should (member "@alice" (org-get-tags nil t)))
    (let ((assigned (org-entry-get nil "ASSIGNED_TO")))
      (should (string-match-p "\\[\\[id:.+\\]\\[Alice\\]\\]" assigned)))))

(ert-deftest ofc-delegate-records-dates ()
  (ofc-test-with-hub
    (ofc-test-goto "Ship the thing")
    (org-fractional-cto-delegate-at-point "Alice" "2026-07-01" "2026-07-15")
    (ofc-test-goto "Ship the thing")
    (should (member "DELEGATED" (org-get-tags nil t)))
    (should (member "ACME" (org-get-tags)))
    (let ((assigned (org-entry-get nil "ASSIGNED_TO")))
      (should (string-match-p "\\[\\[id:.+\\]\\[Alice\\]\\]" assigned)))
    (should (string-match-p "\\`\\[[0-9]\\{4\\}-" (org-entry-get nil "DELEGATED_ON")))
    (should (string-match-p "2026-07-01" (org-entry-get nil "SCHEDULED")))
    (should (string-match-p "2026-07-15" (org-entry-get nil "DEADLINE")))))

(ert-deftest ofc-delegate-without-dates-sets-no-planning ()
  (ofc-test-with-hub
    (ofc-test-goto "Ship the thing")
    (org-fractional-cto-delegate-at-point "Alice" nil nil)
    (ofc-test-goto "Ship the thing")
    (should-not (org-entry-get nil "SCHEDULED"))
    (should-not (org-entry-get nil "DEADLINE"))))

(ert-deftest ofc-delegate-requires-assignee ()
  (ofc-test-with-hub
    (ofc-test-goto "Ship the thing")
    (should-error (org-fractional-cto-delegate-at-point "   " nil nil)
                  :type 'user-error)))

(ert-deftest ofc-delegate-errors-before-first-heading ()
  (ofc-test-with-hub
    (goto-char (point-min))
    (should-error (org-fractional-cto-delegate-at-point "Alice" nil nil)
                  :type 'user-error)))

;;;; Block

(ert-deftest ofc-block-creates-blocker-under-blockers-section ()
  (ofc-test-with-hub
    (ofc-test-goto "Ship the thing")
    (org-fractional-cto-block-at-point "Payments API down" "Dave" "2026-07-20")
    (ofc-test-goto-blocker "Payments API down")
    (should (= (org-current-level) 3))
    (should (member "BLOCKER" (org-get-tags nil t)))
    (should (member "ACME" (org-get-tags)))
    (should (string-match-p "\\[#A\\]" (org-get-heading)))))

(ert-deftest ofc-block-links-back-to-action ()
  (ofc-test-with-hub
    (ofc-test-goto "Ship the thing")
    (org-fractional-cto-block-at-point "Payments API down" "Dave" "2026-07-20")
    (ofc-test-goto-blocker "Payments API down")
    (should (string-match-p "Ship the thing" (org-entry-get nil "BLOCKING")))
    (let ((owner (org-entry-get nil "UNBLOCK_OWNER")))
      (should (string-match-p "\\[\\[id:.+\\]\\[Dave\\]\\]" owner)))
    (should (string-match-p "2026-07-20" (org-entry-get nil "DEADLINE")))))

(ert-deftest ofc-block-links-and-tags-owner ()
  (ofc-test-with-hub
    (ofc-test-goto "Ship the thing")
    (org-fractional-cto-block-at-point "API keys missing" "Bob" nil)
    (ofc-test-goto-blocker "API keys missing")
    (should (member "@bob" (org-get-tags nil t)))
    (let ((owner (org-entry-get nil "UNBLOCK_OWNER")))
      (should (string-match-p "\\[\\[id:.+\\]\\[Bob\\]\\]" owner)))))

(ert-deftest ofc-block-adds-backreference-to-action ()
  (ofc-test-with-hub
    (ofc-test-goto "Ship the thing")
    (org-fractional-cto-block-at-point "Payments API down" "Dave" nil)
    (ofc-test-goto "Ship the thing")
    (let ((end (save-excursion (org-end-of-subtree t t) (point))))
      (should (re-search-forward "Blocked by \\[\\[\\*BLOCKER: Payments API down"
                                 end t)))))

(ert-deftest ofc-block-deadline-is-optional ()
  (ofc-test-with-hub
    (ofc-test-goto "Ship the thing")
    (org-fractional-cto-block-at-point "Payments API down" "Dave" nil)
    (ofc-test-goto-blocker "Payments API down")
    (should-not (org-entry-get nil "DEADLINE"))))

(ert-deftest ofc-block-requires-description ()
  (ofc-test-with-hub
    (ofc-test-goto "Ship the thing")
    (should-error (org-fractional-cto-block-at-point "  " "Dave" nil)
                  :type 'user-error)))

(ert-deftest ofc-block-errors-before-first-heading ()
  (ofc-test-with-hub
    (goto-char (point-min))
    (should-error (org-fractional-cto-block-at-point "X" "Dave" nil)
                  :type 'user-error)))

;;;; Agenda dispatch

(ert-deftest ofc-delegate-at-point-from-agenda ()
  "Delegating from an agenda line flips the source entry to WAITING."
  (let* ((dir (make-temp-file "ofc-agtest" t))
         (file (expand-file-name "acme.org" dir))
         (org-agenda-files (list file)))
    (unwind-protect
        (progn
          (with-temp-file file
            (insert "#+TODO: TODO NEXT INPROGRESS WAITING | DONE CANCELLED\n")
            (insert "#+filetags: :ACME:\n\n")
            (insert "* TODO Ship the thing\n"))
          (org-todo-list)
          (set-buffer org-agenda-buffer-name)
          (goto-char (point-min))
          (should (re-search-forward "Ship the thing" nil t))
          (beginning-of-line)
          (org-fractional-cto-delegate-at-point "Bob" "2026-07-01" nil)
          (with-current-buffer (find-file-noselect file)
            (goto-char (point-min))
            (should (re-search-forward "^\\* WAITING Ship the thing" nil t))
            (org-back-to-heading t)
            (should (member "DELEGATED" (org-get-tags nil t)))))
      (when (get-buffer org-agenda-buffer-name)
        (kill-buffer org-agenda-buffer-name))
      (dolist (b (buffer-list))
        (when (and (buffer-file-name b)
                   (string-prefix-p (file-truename dir)
                                    (file-truename (buffer-file-name b))))
          (with-current-buffer b (set-buffer-modified-p nil))
          (kill-buffer b)))
      (delete-directory dir t))))

(ert-deftest ofc-context-heading-title-from-agenda ()
  "The context heading-title helper reads the entry from an agenda line."
  (let* ((dir (make-temp-file "ofc-cht" t))
         (file (expand-file-name "acme.org" dir))
         (org-agenda-files (list file)))
    (unwind-protect
        (progn
          (with-temp-file file
            (insert "#+TODO: TODO NEXT INPROGRESS WAITING | DONE CANCELLED\n")
            (insert "#+filetags: :ACME:\n\n")
            (insert "* TODO Ship the thing\n"))
          (org-todo-list)
          (set-buffer org-agenda-buffer-name)
          (goto-char (point-min))
          (should (re-search-forward "Ship the thing" nil t))
          (beginning-of-line)
          (should (equal (org-fractional-cto--context-heading-title)
                         "Ship the thing")))
      (when (get-buffer org-agenda-buffer-name)
        (kill-buffer org-agenda-buffer-name))
      (dolist (b (buffer-list))
        (when (and (buffer-file-name b)
                   (string-prefix-p (file-truename dir)
                                    (file-truename (buffer-file-name b))))
          (with-current-buffer b (set-buffer-modified-p nil))
          (kill-buffer b)))
      (delete-directory dir t))))

(ert-deftest ofc-block-at-point-from-agenda ()
  "Blocking from an agenda line files a BLOCKER into the source hub."
  (let* ((dir (make-temp-file "ofc-blkag" t))
         (file (expand-file-name "acme.org" dir))
         (org-agenda-files (list file)))
    (unwind-protect
        (progn
          (with-temp-file file
            (insert "#+TODO: TODO NEXT INPROGRESS WAITING | DONE CANCELLED\n")
            (insert "#+filetags: :ACME:\n\n")
            (insert "* TODO Ship the thing\n")
            (insert "** Blockers  :BLOCKER:\n"))
          (org-todo-list)
          (set-buffer org-agenda-buffer-name)
          (goto-char (point-min))
          (should (re-search-forward "Ship the thing" nil t))
          (beginning-of-line)
          (org-fractional-cto-block-at-point "Payments API down" "Dave" nil)
          (with-current-buffer (find-file-noselect file)
            (goto-char (point-min))
            (should (re-search-forward "BLOCKER: Payments API down" nil t))))
      (when (get-buffer org-agenda-buffer-name)
        (kill-buffer org-agenda-buffer-name))
      (dolist (b (buffer-list))
        (when (and (buffer-file-name b)
                   (string-prefix-p (file-truename dir)
                                    (file-truename (buffer-file-name b))))
          (with-current-buffer b (set-buffer-modified-p nil))
          (kill-buffer b)))
      (delete-directory dir t))))

(provide 'org-fractional-cto-actions-test)

;;; org-fractional-cto-actions-test.el ends here
