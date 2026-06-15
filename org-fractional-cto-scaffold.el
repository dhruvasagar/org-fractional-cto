;;; org-fractional-cto-scaffold.el --- New client onboarding -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Dhruva Sagar
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; `org-fractional-cto-new-client' scaffolds a complete per-client workspace:
;;
;;   <clients-dir>/<slug>/<slug>.org   -- operational hub, one section per
;;                                        capture type, each pre-tagged
;;   <clients-dir>/<slug>/standup.org  -- per-client standup template
;;   <clients-dir>/<slug>/CONTEXT.md   -- domain glossary / people / stack
;;
;; The section list below is the single source of truth: the hub headings, the
;; capture targets (`org-fractional-cto-capture.el'), and the dashboard
;; (`org-fractional-cto-agenda.el') all agree by construction.

;;; Code:

(require 'org-agenda)
(require 'subr-x)

(declare-function org-fractional-cto-client-tag "org-fractional-cto")
(declare-function org-fractional-cto-client-org-file "org-fractional-cto")
(declare-function org-fractional-cto-client-standup-file "org-fractional-cto")
(declare-function org-fractional-cto-client-context-file "org-fractional-cto")
(declare-function org-fractional-cto-agenda-files "org-fractional-cto")
(declare-function org-fractional-cto--clients-dir "org-fractional-cto")
;; Pre-declared for `org-fractional-cto-new-prospect'.
(declare-function org-fractional-cto-set-active-client "org-fractional-cto")
(defvar org-fractional-cto-author)
(defvar org-fractional-cto-stages)
(defvar org-fractional-cto-default-stage)
(defvar org-fractional-cto-lead-stage)

(defconst org-fractional-cto-sections
  '(("Actions"                "")
    ("Delegations"            "DELEGATED")
    ("Blockers"               "BLOCKER")
    ("People"                 "PEOPLE")
    ("Weekly Reviews"         "REVIEW")
    ("Commitments"            "COMMITMENT")
    ("Risks"                  "RISK")
    ("Meeting Notes"          "MEETING")
    ("Standup Notes"          "STANDUP")
    ("Internal Syncs"         "INTERNAL")
    ("Discovery Sessions"     "DISCOVERY")
    ("Stakeholder Profiles"   "STAKEHOLDER")
    ("Architecture Decisions" "ADR")
    ("Architecture Reviews"   "ARCHREVIEW")
    ("Vendor Evaluations"     "VENDOR")
    ("Technical Debt"         "TECHDEBT")
    ("Security Findings"      "SECURITY")
    ("Health Checks"          "HEALTH")
    ("QBRs"                   "QBR")
    ("Innovation Pipeline"    "INNOVATION")
    ("Scope Changes"          "SCOPE")
    ("Post-Mortems"           "POSTMORTEM")
    ("Retrospectives"         "RETRO")
    ("Pre-Sales Notes"        "PRESALES")
    ("Research"               "RESEARCH")
    ("Qualification"          "QUALIFICATION"))
  "Ordered (HEADING . SUBTAG) sections written into a new client hub file.")

(defun org-fractional-cto--write-hub (file client-name tag stage)
  "Write the operational hub FILE for CLIENT-NAME tagged TAG at STAGE.
STAGE is a string from `org-fractional-cto-stages' placed on the engagement
heading; TAG is written as the file's `#+filetags'."
  (with-temp-file file
    (insert (format "#+title: %s\n" client-name))
    (insert (format "#+AUTHOR: %s\n" org-fractional-cto-author))
    (insert "#+STARTUP: overview\n")
    (insert "#+TODO: TODO NEXT INPROGRESS WAITING | DONE CANCELLED\n")
    (insert (format "#+filetags: :%s:\n" tag))
    (insert "#+OPTIONS: date:nil\n\n")
    (insert (format "* %s Engagement  :%s:\n" client-name stage))
    (insert (format ":PROPERTIES:\n:ID:       %s-OPS\n:CATEGORY: %s\n:END:\n\n"
                    tag client-name))
    (insert "See [[file:CONTEXT.md][CONTEXT.md]] for domain vocabulary, key people, and priorities.\n\n")
    (dolist (section org-fractional-cto-sections)
      (let ((heading (car section)) (subtag (cadr section)))
        (if (string-empty-p subtag)
            (insert (format "** %s\n\n" heading))
          (insert (format "** %s  :%s:\n\n" heading subtag)))))))

(defun org-fractional-cto--write-standup (file tag)
  "Write a per-client standup template FILE tagged TAG."
  (with-temp-file file
    (insert (format "* STANDUP %%^{Date|%%<%%Y-%%m-%%d>}  :%s:STANDUP:\n%%U\n\n" tag))
    (dotimes (i 6)
      (insert (format "** Stream %d — Lead: (TBD)\n- Shipped: %%?\n- Next:\n- Blockers:\n\n"
                      (1+ i))))
    (insert "** Key Metrics This Week\n")
    (insert "| Metric | This Week | Last Week | Trend |\n")
    (insert "|--------+-----------+-----------+-------|\n")
    (insert "|        |           |           |       |\n\n")
    (insert "** Escalations / Actions\n- [ ]\n")))

(defun org-fractional-cto--write-context (file client-name slug)
  "Write the CONTEXT.md FILE for CLIENT-NAME with SLUG."
  (let ((date (format-time-string "%Y-%m-%d")))
    (with-temp-file file
      (insert (format "# %s Engagement Context\n\nLast updated: %s\n\n---\n\n"
                      client-name date))
      (insert "## What We're Building\n\n\n\n---\n\n")
      (insert "## Domain Vocabulary\n\n| Term | Meaning |\n|------|---------|\n|      |         |\n\n---\n\n")
      (insert "## Tech Stack\n\n| Layer | Technology | Notes |\n|-------|------------|-------|\n|       |            |       |\n\n---\n\n")
      (insert "## Key People\n\n### Client Side\n| Name | Role | Notes |\n|------|------|-------|\n|      |      |       |\n\n")
      (insert "### Our Side\n| Name | Role / Stream | Notes |\n|------|---------------|-------|\n|      |               |       |\n\n---\n\n")
      (insert "## Active Work Streams\n\n| Stream | Lead(s) | Status | Key Risk |\n|--------|---------|--------|----------|\n|        |         |        |          |\n\n---\n\n")
      (insert (format "## Current Priorities (as of %s)\n\n1. \n2. \n3. \n\n---\n\n" date))
      (insert "## Key Documents\n\n| Document | Location |\n|----------|----------|\n|          |          |\n\n---\n\n")
      (insert "## Important Conventions\n\n")
      (insert (format "- Set active client: `M-x org-fractional-cto-set-active-client` -> \"%s\"\n" slug))
      (insert "- All captures use the `C-c c e` prefix\n")
      (insert "- Dashboard: `C-c a E` (or `M-x org-fractional-cto-dashboard`)\n"))))

(defun org-fractional-cto--read-name-and-slug ()
  "Prompt for a client display name and slug; return the list (NAME SLUG)."
  (let* ((name (read-string "Client name (display): "))
         (slug (read-string "Client slug (lowercase, no spaces): "
                            (replace-regexp-in-string
                             "[^a-z0-9]" "_" (downcase name)))))
    (list name slug)))

(defun org-fractional-cto--scaffold (client-name slug stage)
  "Create the on-disk workspace for CLIENT-NAME under SLUG at STAGE.
Writes the hub, standup, and CONTEXT.md, registers the directory with
`org-agenda-files', and returns the client directory."
  (when (string-empty-p (string-trim slug))
    (user-error "Client slug must not be empty"))
  (unless (member stage org-fractional-cto-stages)
    (user-error "Stage %S is not one of `org-fractional-cto-stages'" stage))
  (let* ((tag     (org-fractional-cto-client-tag slug))
         (dir     (expand-file-name slug (org-fractional-cto--clients-dir)))
         (hub     (org-fractional-cto-client-org-file slug))
         (standup (org-fractional-cto-client-standup-file slug))
         (context (org-fractional-cto-client-context-file slug)))
    (when (and (file-exists-p dir)
               (not (yes-or-no-p
                     (format "Client '%s' already exists.  Continue? " slug))))
      (user-error "Aborted"))
    (make-directory dir t)
    (org-fractional-cto--write-hub hub client-name tag stage)
    (org-fractional-cto--write-standup standup tag)
    (org-fractional-cto--write-context context client-name slug)
    (dolist (d (org-fractional-cto-agenda-files))
      (add-to-list 'org-agenda-files d t))
    dir))

;;;###autoload
(defun org-fractional-cto-new-client (client-name slug)
  "Scaffold a new ACTIVE engagement for CLIENT-NAME under SLUG.
Creates the client directory with its operational hub, standup template, and
CONTEXT.md, then opens CONTEXT.md for editing."
  (interactive (org-fractional-cto--read-name-and-slug))
  (org-fractional-cto--scaffold client-name slug org-fractional-cto-default-stage)
  (find-file (org-fractional-cto-client-context-file slug))
  (message "Engagement '%s' created.  Fill in CONTEXT.md, then M-x org-fractional-cto-set-active-client."
           client-name))

;;;###autoload
(defun org-fractional-cto-new-prospect (client-name slug)
  "Scaffold a new LEAD-stage prospect for CLIENT-NAME under SLUG.
Identical to `org-fractional-cto-new-client' but starts at the LEAD stage,
sets the prospect active, and (called interactively) opens the pre-sales call
capture so the first conversation is recorded immediately."
  (interactive (org-fractional-cto--read-name-and-slug))
  (org-fractional-cto--scaffold client-name slug org-fractional-cto-lead-stage)
  (org-fractional-cto-set-active-client slug)
  (if (called-interactively-p 'any)
      (org-capture nil "el")
    slug))

(provide 'org-fractional-cto-scaffold)

;;; org-fractional-cto-scaffold.el ends here
