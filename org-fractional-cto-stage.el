;;; org-fractional-cto-stage.el --- Engagement stage lifecycle -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Dhruva Sagar
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Engagement stage is a single tag (from `org-fractional-cto-stages') on the
;; level-1 engagement heading of a client hub.  `org-fractional-cto-set-stage'
;; switches it.  `org-fractional-cto-upgrade-hub' brings a pre-existing hub up
;; to the current section list and gives it a stage tag if it lacks one.

;;; Code:

(require 'org)
(require 'seq)
(require 'subr-x)

(declare-function org-fractional-cto--select-client "org-fractional-cto")
(declare-function org-fractional-cto-client-org-file "org-fractional-cto")
(defvar org-fractional-cto-stages)
(defvar org-fractional-cto-default-stage)
(defvar org-fractional-cto-sections)

(defun org-fractional-cto--goto-engagement-heading ()
  "Move point to the first level-1 heading (the engagement heading).
Signal a `user-error' if the buffer has no top-level heading."
  (widen)
  (goto-char (point-min))
  (unless (re-search-forward "^\\* " nil t)
    (user-error "No engagement heading in %s"
                (or (buffer-file-name) (buffer-name))))
  (org-back-to-heading t))

(defun org-fractional-cto--engagement-client-tag ()
  "Return the non-stage tag on the engagement heading at point, or nil."
  (car (seq-remove (lambda (tag) (member tag org-fractional-cto-stages))
                   (org-get-tags nil t))))

;;;###autoload
(defun org-fractional-cto-set-stage (stage)
  "Set the engagement STAGE tag on the active client's hub.
Removes any existing stage in `org-fractional-cto-stages' and adds STAGE,
leaving the client tag and any other tags untouched."
  (interactive
   (list (completing-read "Stage: " org-fractional-cto-stages nil t)))
  (unless (member stage org-fractional-cto-stages)
    (user-error "Unknown stage: %s" stage))
  (with-current-buffer (find-file-noselect
                        (org-fractional-cto-client-org-file
                         (org-fractional-cto--select-client)))
    (let ((was-modified (buffer-modified-p)))
      (save-excursion
        (org-fractional-cto--goto-engagement-heading)
        (let ((tags (seq-remove (lambda (tag) (member tag org-fractional-cto-stages))
                                (org-get-tags nil t))))
          (org-set-tags (cons stage tags))))
      ;; Only persist if we opened a clean buffer; if the hub already had
      ;; unsaved edits, leave saving to the user rather than committing them.
      (unless was-modified
        (save-buffer))))
  (message "Stage set to %s" stage))

(defun org-fractional-cto--ensure-stage-tag ()
  "Add the default stage tag to the engagement heading if it lacks one."
  (save-excursion
    (org-fractional-cto--goto-engagement-heading)
    (let ((tags (org-get-tags nil t)))
      (unless (seq-some (lambda (tag) (member tag org-fractional-cto-stages)) tags)
        (org-set-tags (cons org-fractional-cto-default-stage tags))))))

(defun org-fractional-cto--ensure-sections ()
  "Append any `org-fractional-cto-sections' headings missing from the buffer.
Appended sections carry the engagement heading's client tag."
  (let ((client-tag (save-excursion
                      (org-fractional-cto--goto-engagement-heading)
                      (org-fractional-cto--engagement-client-tag))))
    (dolist (section org-fractional-cto-sections)
      (let ((heading (car section)) (subtag (cadr section)))
        (goto-char (point-min))
        (unless (re-search-forward
                 (concat "^\\*+ " (regexp-quote heading) "\\(?:[ \t]\\|$\\)") nil t)
          (goto-char (point-max))
          (unless (bolp) (insert "\n"))
          (if (string-empty-p subtag)
              (insert (format "** %s  :%s:\n\n" heading client-tag))
            (insert (format "** %s  :%s:%s:\n\n" heading client-tag subtag))))))))

;;;###autoload
(defun org-fractional-cto-upgrade-hub ()
  "Bring the active client's hub up to date.
Ensures the engagement heading carries a stage tag (defaulting to
`org-fractional-cto-default-stage') and appends any sections from
`org-fractional-cto-sections' that are missing.  Idempotent."
  (interactive)
  (with-current-buffer (find-file-noselect
                        (org-fractional-cto-client-org-file
                         (org-fractional-cto--select-client)))
    (let ((was-modified (buffer-modified-p)))
      (save-excursion
        (org-fractional-cto--ensure-stage-tag)
        (org-fractional-cto--ensure-sections))
      ;; Only persist if we opened a clean buffer; if the hub already had
      ;; unsaved edits, leave saving to the user rather than committing them.
      (unless was-modified
        (save-buffer))))
  (message "Hub upgraded."))

(provide 'org-fractional-cto-stage)

;;; org-fractional-cto-stage.el ends here
