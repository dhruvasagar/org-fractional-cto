;;; org-fractional-cto-actions.el --- At-point action lifecycle commands -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Dhruva Sagar
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; The capture group (`org-fractional-cto-capture') creates new items; the
;; dashboard (`org-fractional-cto-agenda') reads them.  This module covers the
;; step in between: acting on an item that already exists, in place.
;;
;; Two commands, mirroring the `eg' and `eb' captures but applied to the Org
;; heading at point:
;;
;;   `org-fractional-cto-delegate-at-point' -- flip the heading to WAITING, tag
;;       it DELEGATED, record who owns it and when, and schedule a follow-up.
;;       This is "delegate this existing action" without re-typing it.
;;
;;   `org-fractional-cto-block-at-point' -- file a [#A] BLOCKER into the same
;;       client's Blockers section, its BLOCKING property linking back to the
;;       action, plus a back-reference under the action itself.
;;
;; Both are pure Org-mode underneath: TODO state, tags, properties, planning
;; lines, and internal `[[*heading]]' links.  Each public command takes its
;; inputs as arguments (gathered interactively via the `interactive' form) so
;; it can be driven non-interactively from tests.

;;; Code:

(require 'org)
(require 'org-agenda)
(require 'seq)
(require 'subr-x)
(require 'org-fractional-cto-people)

;;;; Small helpers

(defun org-fractional-cto--require-heading ()
  "Signal a `user-error' unless point is on (or within) an Org heading."
  (unless (derived-mode-p 'org-mode)
    (user-error "Not in an Org buffer"))
  (when (org-before-first-heading-p)
    (user-error "Point is not on an Org heading")))

(defun org-fractional-cto--heading-title ()
  "Return the heading at point with TODO, priority, tags and comment stripped."
  (save-excursion
    (org-back-to-heading t)
    (org-get-heading t t t t)))

(defun org-fractional-cto--context-heading-title ()
  "Return the heading title for the current context, or nil if unavailable.
In an agenda buffer, read it from the entry the current line points to; in an
Org buffer, read the heading at point.  Returns nil rather than signalling when
point is not on a usable heading, so it is safe as an `interactive' default."
  (ignore-errors
    (if (derived-mode-p 'org-agenda-mode)
        (org-agenda-with-point-at-orig-entry nil
          (org-fractional-cto--heading-title))
      (org-fractional-cto--heading-title))))

(defun org-fractional-cto--inactive-timestamp ()
  "Return the current time as an inactive Org timestamp string."
  (format-time-string "[%Y-%m-%d %a %H:%M]"))

(defun org-fractional-cto--active-timestamp (date)
  "Return DATE (a string Org can parse) as an active timestamp string."
  (format-time-string "<%Y-%m-%d %a>" (org-time-string-to-time date)))

(defun org-fractional-cto--goto-section (heading)
  "Move point to the headline named HEADING, creating it if absent.
Search is from the top of the (widened) buffer.  When the section is missing it
is appended at end of buffer as a level-2 heading.  Returns the heading's level
\(number of leading stars)."
  (widen)
  (goto-char (point-min))
  (if (re-search-forward
       (concat "^\\(\\*+\\) " (regexp-quote heading) "\\(?:[ \t]\\|$\\)") nil t)
      (let ((level (length (match-string 1))))
        (beginning-of-line)
        level)
    (goto-char (point-max))
    (unless (bolp) (insert "\n"))
    (insert (format "** %s\n" heading))
    (forward-line -1)
    2))

;;;; Agenda / buffer dispatch

(defmacro org-fractional-cto--at-entry (&rest body)
  "Evaluate BODY at the Org heading for the current context.
In an agenda buffer, run BODY at the entry the line points to (via
`org-agenda-with-point-at-orig-entry') and refresh the agenda; in an Org
buffer run BODY directly."
  (declare (indent 0) (debug t))
  `(if (derived-mode-p 'org-agenda-mode)
       (prog1 (org-agenda-with-point-at-orig-entry nil ,@body)
         (ignore-errors (org-agenda-redo)))
     (progn ,@body)))

;;;; Delegate an existing action

;;;###autoload
(defun org-fractional-cto-delegate-at-point (assignee &optional check-in delivery)
  "Turn the Org heading at point into a WAITING delegation.
This is the `eg' capture applied to a heading that already exists: it sets the
TODO state to WAITING, adds the DELEGATED tag, links ASSIGNED_TO to the
assignee's person node, tags the heading with the assignee's `@slug' tag,
records DELEGATED_ON, and SCHEDULEs a follow-up.

ASSIGNEE is the person's display name (required); the node is created if new.
CHECK-IN, when given, is the follow-up date set as SCHEDULED.  DELIVERY, when
given, is the expected-delivery date set as DEADLINE.  Date arguments are
strings any Org date parser accepts."
  (interactive
   (list (org-fractional-cto--read-person-name "Assigned to")
         (org-read-date nil nil nil "Check-in / follow-up")
         (when (y-or-n-p "Set an expected-delivery deadline? ")
           (org-read-date nil nil nil "Expected delivery"))))
  (when (string-empty-p (string-trim assignee))
    (user-error "An assignee is required to delegate"))
  (let ((rec (org-fractional-cto-person-record assignee)))
    (org-fractional-cto--at-entry
      (org-fractional-cto--require-heading)
      (save-excursion
        (org-back-to-heading t)
        (org-todo "WAITING")
        (org-toggle-tag "DELEGATED" 'on)
        (org-toggle-tag (plist-get rec :tag) 'on)
        (org-set-property "ASSIGNED_TO" (plist-get rec :link))
        (org-set-property "DELEGATED_ON" (org-fractional-cto--inactive-timestamp))
        (when (and check-in (not (string-empty-p check-in)))
          (org-schedule nil check-in))
        (when (and delivery (not (string-empty-p delivery)))
          (org-deadline nil delivery))))
    (message "Delegated to %s%s" assignee
             (if (and check-in (not (string-empty-p check-in)))
                 (format " — check in %s" check-in) ""))))

;;;; Block an existing action

(defun org-fractional-cto--blocker-subtree (level what owner resolve-by link &optional person-tag)
  "Return the text of a BLOCKER subtree at LEVEL stars.
WHAT is what is blocked; OWNER is the unblock owner (an `[[id:]]' link string or
plain text); RESOLVE-BY (optional) becomes a DEADLINE; LINK is an Org link
stored in the BLOCKING property; PERSON-TAG, when non-nil, is appended to the
headline's tag cluster (e.g. \"@bob\")."
  (let* ((stars (make-string level ?*))
         (tags (concat ":BLOCKER:"
                       (if (and person-tag (not (string-empty-p person-tag)))
                           (concat person-tag ":") ""))))
    (concat
     (format "%s TODO [#A] BLOCKER: %s  %s\n" stars what tags)
     (when (and resolve-by (not (string-empty-p resolve-by)))
       (format "DEADLINE: %s\n" (org-fractional-cto--active-timestamp resolve-by)))
     ":PROPERTIES:\n"
     (format ":BLOCKING: %s\n" link)
     (when (and owner (not (string-empty-p owner)))
       (format ":UNBLOCK_OWNER: %s\n" owner))
     (format ":CREATED: %s\n" (org-fractional-cto--inactive-timestamp))
     ":END:\n"
     "\n*Root cause:* \n\n*Options:*\n- [ ] \n")))

;;;###autoload
(defun org-fractional-cto-block-at-point (what &optional owner resolve-by)
  "File a BLOCKER against the action heading at point.
Mirrors the `eb' capture, pre-wired to the action under point: a new
\[#A] BLOCKER entry is filed into this file's Blockers section with its BLOCKING
property linking back to the action, and a back-reference is inserted under the
action itself.

WHAT describes what is blocked; OWNER (optional) is the person who can clear it
\(linked to their node and added as an `@slug' tag on the blocker); RESOLVE-BY
\(optional) is a date string set as the blocker's DEADLINE."
  (interactive
   (list (read-string "What is blocked? " (org-fractional-cto--context-heading-title))
         (org-fractional-cto--read-person-name "Who can remove this blocker")
         (when (y-or-n-p "Set a resolve-by deadline? ")
           (org-read-date nil nil nil "Resolve by"))))
  (when (string-empty-p (string-trim what))
    (user-error "Describe what is blocked"))
  (let* ((rec (and owner (not (string-empty-p (string-trim owner)))
                   (org-fractional-cto-person-record owner)))
         (owner-link (if rec (plist-get rec :link) owner))
         (person-tag (and rec (plist-get rec :tag)))
         (action-title
          (org-fractional-cto--at-entry
            (org-fractional-cto--require-heading)
            (let* ((title (org-fractional-cto--heading-title))
                   (action-link (format "[[*%s][%s]]" title title)))
              (save-excursion
                (let ((level (1+ (org-fractional-cto--goto-section "Blockers"))))
                  (org-end-of-subtree t t)
                  (unless (bolp) (insert "\n"))
                  (insert (org-fractional-cto--blocker-subtree
                           level what owner-link resolve-by action-link person-tag))
                  (unless (bolp) (insert "\n"))))
              (save-excursion
                (org-back-to-heading t)
                (org-end-of-meta-data t)
                (insert (format "- Blocked by [[*BLOCKER: %s][BLOCKER: %s]]\n" what what)))
              title))))
    (message "Filed blocker against %S" action-title)))

(provide 'org-fractional-cto-actions)

;;; org-fractional-cto-actions.el ends here
