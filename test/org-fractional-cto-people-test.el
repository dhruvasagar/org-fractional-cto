;;; org-fractional-cto-people-test.el --- Tests for people nodes -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Dhruva Sagar
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; ERT tests for org-fractional-cto-people: slug/path helpers, node listing,
;; pure node creation, org-id registration, the insert-or-create helper, and
;; the eP capture target.  Run with: make test

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'org-id)
(require 'org-fractional-cto)
(require 'org-fractional-cto-people)

(defmacro ofc-people-test (&rest body)
  "Run BODY with a throwaway people directory and isolated org-id state."
  (declare (indent 0) (debug t))
  `(let* ((org-fractional-cto-people-directory (make-temp-file "ofc-people" t))
          (org-id-extra-files nil)
          (org-id-locations (make-hash-table :test 'equal))
          (org-id-files nil))
     (unwind-protect (progn ,@body)
       (delete-directory org-fractional-cto-people-directory t))))

(ert-deftest ofc-people-slug-normalises-name ()
  (should (equal (org-fractional-cto-people-slug "Jane Doe") "jane_doe"))
  (should (equal (org-fractional-cto-people-slug "  O'Brien, Pat!  ") "o_brien_pat"))
  (should (equal (org-fractional-cto-people-slug "Ann-Marie") "ann_marie")))

(ert-deftest ofc-person-file-lives-under-people-dir ()
  (ofc-people-test
    (should (equal (org-fractional-cto-person-file "jane_doe")
                   (expand-file-name "jane_doe.org"
                                     (org-fractional-cto--people-dir))))))

(ert-deftest ofc-people-lists-titles-and-files ()
  (ofc-people-test
    (let ((f (org-fractional-cto-person-file "jane_doe")))
      (with-temp-file f
        (insert ":PROPERTIES:\n:ID:       abc-123\n:END:\n#+title: Jane Doe\n"))
      (should (equal (org-fractional-cto-people) (list (cons "Jane Doe" f))))
      (should (equal (org-fractional-cto--person-title f) "Jane Doe"))
      (should (equal (org-fractional-cto--person-id f) "abc-123")))))

(ert-deftest ofc-create-person-writes-registered-node ()
  (ofc-people-test
    (let* ((id (org-fractional-cto-create-person "Jane Doe"))
           (file (org-fractional-cto-person-file "jane_doe")))
      (should (stringp id))
      (should (file-exists-p file))
      (should (equal (org-fractional-cto--person-id file) id))
      (should (equal (org-fractional-cto--person-title file) "Jane Doe"))
      (with-temp-buffer
        (insert-file-contents file)
        (should (string-match-p "#\\+filetags: :PERSON:" (buffer-string)))
        (should (string-match-p "^\\* Notes / History" (buffer-string))))
      ;; Registered so [[id:...]] resolves.
      (should (equal (file-name-nondirectory (org-id-find-id-file id))
                     "jane_doe.org")))))

(ert-deftest ofc-create-person-reuses-existing-title ()
  (ofc-people-test
    (let ((id1 (org-fractional-cto-create-person "Jane Doe"))
          (id2 (org-fractional-cto-create-person "Jane Doe")))
      (should (equal id1 id2))
      (should (= 1 (length (org-fractional-cto--person-files)))))))

(ert-deftest ofc-unique-slug-suffixes-on-collision ()
  (ofc-people-test
    (make-directory (org-fractional-cto--people-dir) t)
    (with-temp-file (org-fractional-cto-person-file "jane_doe") (insert ""))
    (should (equal (org-fractional-cto--unique-slug "jane_doe") "jane_doe_2"))))

(ert-deftest ofc-register-people-makes-nodes-resolvable ()
  (ofc-people-test
    (let ((id1 (org-fractional-cto-create-person "Jane Doe"))
          (id2 (org-fractional-cto-create-person "Pat Lee")))
      ;; Simulate a fresh session: drop the in-memory id locations that
      ;; create-person populated, so resolution must come from registration.
      (clrhash org-id-locations)
      (setq org-id-files nil)
      (org-fractional-cto--register-people-with-org-id)
      (should (equal (file-name-nondirectory (org-id-find-id-file id1))
                     "jane_doe.org"))
      (should (equal (file-name-nondirectory (org-id-find-id-file id2))
                     "pat_lee.org")))))

(ert-deftest ofc-register-people-works-with-symbol-extra-files ()
  (ofc-people-test
    (let ((id (org-fractional-cto-create-person "Jane Doe")))
      (clrhash org-id-locations)
      (setq org-id-files nil)
      (let ((org-id-extra-files 'org-agenda-text-search-extra-files))
        (org-fractional-cto--register-people-with-org-id)
        (should (equal (file-name-nondirectory (org-id-find-id-file id))
                       "jane_doe.org"))
        ;; Must NOT have mutated the agenda text-search bucket.
        (should (null (ignore-errors
                        (symbol-value 'org-agenda-text-search-extra-files))))))))

(ert-deftest ofc-insert-person-links-existing ()
  (ofc-people-test
    (let ((id (org-fractional-cto-create-person "Jane Doe")))
      (with-temp-buffer
        (cl-letf (((symbol-function 'completing-read)
                   (lambda (&rest _) "Jane Doe")))
          (org-fractional-cto-insert-person))
        (should (equal (buffer-string)
                       (format "[[id:%s][Jane Doe]]" id)))))))

(ert-deftest ofc-insert-person-creates-on-unknown-name ()
  (ofc-people-test
    (with-temp-buffer
      (cl-letf (((symbol-function 'completing-read)
                 (lambda (&rest _) "New Person"))
                ((symbol-function 'y-or-n-p) (lambda (&rest _) t)))
        (org-fractional-cto-insert-person))
      (should (file-exists-p (org-fractional-cto-person-file "new_person")))
      (let ((id (org-fractional-cto--person-id
                 (org-fractional-cto-person-file "new_person"))))
        (should (equal (buffer-string)
                       (format "[[id:%s][New Person]]" id)))))))

(ert-deftest ofc-insert-person-declined-inserts-nothing ()
  (ofc-people-test
    (with-temp-buffer
      (cl-letf (((symbol-function 'completing-read)
                 (lambda (&rest _) "Nope"))
                ((symbol-function 'y-or-n-p) (lambda (&rest _) nil)))
        (org-fractional-cto-insert-person))
      (should (equal (buffer-string) "")))))

(ert-deftest ofc-person-goto-notes-positions-in-history ()
  (ofc-people-test
    (org-fractional-cto-create-person "Jane Doe")
    (let ((file (org-fractional-cto-person-file "jane_doe")))
      (save-window-excursion
        (org-fractional-cto--person-goto-notes file)
        (should (equal (buffer-file-name) file))
        ;; Point sits on the Notes / History heading line.
        (should (string-match-p "Notes / History"
                                (buffer-substring (line-beginning-position)
                                                  (line-end-position)))))
      (kill-buffer (find-file-noselect file)))))

(ert-deftest ofc-person-tag-prefixes-at ()
  (should (equal (org-fractional-cto-person-tag "jane_doe") "@jane_doe")))

(ert-deftest ofc-person-record-creates-and-describes ()
  (ofc-people-test
    (let ((rec (org-fractional-cto-person-record "Jane Doe")))
      (should (equal (plist-get rec :name) "Jane Doe"))
      (should (equal (plist-get rec :slug) "jane_doe"))
      (should (equal (plist-get rec :tag) "@jane_doe"))
      (should (equal (plist-get rec :link)
                     (format "[[id:%s][Jane Doe]]" (plist-get rec :id))))
      (should (file-exists-p (org-fractional-cto-person-file "jane_doe"))))))

(ert-deftest ofc-person-record-reuses-existing ()
  (ofc-people-test
    (let ((r1 (org-fractional-cto-person-record "Jane Doe"))
          (r2 (org-fractional-cto-person-record "Jane Doe")))
      (should (equal (plist-get r1 :id) (plist-get r2 :id)))
      (should (= 1 (length (org-fractional-cto--person-files)))))))

(ert-deftest ofc-read-person-name-returns-completion ()
  (ofc-people-test
    (cl-letf (((symbol-function 'completing-read)
               (lambda (&rest _) "Typed Name")))
      (should (equal (org-fractional-cto--read-person-name "Owner") "Typed Name")))))

(ert-deftest ofc-capture-person-returns-link-and-flags-tag ()
  (ofc-people-test
    (let ((org-capture-plist nil))
      (cl-letf (((symbol-function 'org-fractional-cto--read-person-name)
                 (lambda (&rest _) "Jane Doe")))
        (let ((link (org-fractional-cto--capture-person "Owner" t)))
          (should (string-match-p "\\`\\[\\[id:.+\\]\\[Jane Doe\\]\\]\\'" link))
          (should (equal (plist-get (org-capture-get :ofc-person) :tag)
                         "@jane_doe")))))))

(ert-deftest ofc-capture-person-without-tag-does-not-flag ()
  (ofc-people-test
    (let ((org-capture-plist nil))
      (cl-letf (((symbol-function 'org-fractional-cto--read-person-name)
                 (lambda (&rest _) "Jane Doe")))
        (org-fractional-cto--capture-person "Made by")
        (should-not (org-capture-get :ofc-person))))))

(ert-deftest ofc-capture-people-builds-comma-list ()
  (ofc-people-test
    (let ((names (list "Ann" "Bob" "")))
      (cl-letf (((symbol-function 'org-fractional-cto--read-person-name)
                 (lambda (&rest _) (pop names))))
        (let ((result (org-fractional-cto--capture-people "Attendees")))
          (should (string-match-p
                   "\\`\\[\\[id:.+\\]\\[Ann\\]\\], \\[\\[id:.+\\]\\[Bob\\]\\]\\'"
                   result)))))))

(ert-deftest ofc-apply-person-tag-tags-heading ()
  (with-temp-buffer
    (org-mode)
    (insert "* WAITING Do the thing\n")
    (let ((org-capture-plist (list :ofc-person '(:tag "@alice"))))
      (org-fractional-cto--apply-person-tag))
    (goto-char (point-min))
    (should (member "@alice" (org-get-tags)))))

(ert-deftest ofc-apply-person-tag-noop-without-person ()
  (with-temp-buffer
    (org-mode)
    (insert "* WAITING Do the thing\n")
    (let ((org-capture-plist nil))
      (org-fractional-cto--apply-person-tag))
    (goto-char (point-min))
    (should-not (org-get-tags))))

(ert-deftest ofc-capture-install-registers-finalize-hook ()
  (let ((org-capture-before-finalize-hook nil))
    (org-fractional-cto-capture-install)
    (should (memq 'org-fractional-cto--apply-person-tag
                  org-capture-before-finalize-hook))))
