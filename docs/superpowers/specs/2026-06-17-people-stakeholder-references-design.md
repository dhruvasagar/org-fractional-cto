# People & Stakeholder References — Design

**Date:** 2026-06-17
**Status:** Approved (pending implementation plan)

## Problem

People — stakeholders, team members, vendors, advisors — are currently
referenced as static text scattered across the workspace:

- The `eP` "Person / team member note" capture files a heading under the
  client hub's *People* section.
- The `ep` "Stakeholder profile" capture files a heading under *Stakeholder
  Profiles*.
- `CONTEXT.md` carries static "Key People" markdown tables.

Nothing links to a canonical record. A mention of a person in a meeting note,
action, or ADR is plain text, so there is no deterministic way to find
everything about a person, and the same human appears redundantly across
clients with no shared identity.

The previous org-roam-based workflow modelled each person as a dedicated node
(a "page") capturing socials, photos, biography, and history, referenced
explicitly by `[[id:...]]` links. We want that determinism here, while keeping
this package's native-Org philosophy and its zero org-roam dependency.

## Goals

- A person is a first-class, linkable entity with a durable, canonical record.
- People knowledge persists for the long term, independent of any client —
  archiving or deleting a client must never lose information about a person.
- References resolve deterministically via Org's built-in `org-id`.
- No new hard dependency. Existing org-roam users keep their full workflow.
- Keep the per-client, engagement-specific relationship tracking that exists
  today.

## Non-Goals

- No dependency on org-roam (hard or optional). The package emits plain
  `org-id` nodes; roam, if the user has it, consumes them without any
  package-side code.
- No destructive migration of existing in-hub person/stakeholder data.
- No bespoke navigation/backlinks UI — opening a link (`C-c C-o`) and (for roam
  users) the roam backlinks buffer already cover this.

## Design

### Two entities

**Person node (global, durable).** One Org file per person under a new
directory, `org-fractional-cto-people-directory`. Each file is a file-level
`org-id` node:

```org
:PROPERTIES:
:ID:       <uuid>
:END:
#+title: Jane Doe
#+filetags: :PERSON:

Role / title:
Organisation:
Side:            Our team | Client | Vendor | External
Contact:         email · phone
Socials:         LinkedIn · X · GitHub · website
Photo:           [[file:...]] or URL

* About

* Notes / History
```

This is the canonical, durable record. Long-term, cross-engagement knowledge
(how the relationship evolved across several clients) accumulates here under
*Notes / History*. "Team members" are not a separate entity — they are person
nodes whose `Side:` is *Our team*.

**Stakeholder profile (client-scoped, ephemeral).** Stays under the client
hub's *Stakeholder Profiles* section with all of today's relationship fields
(decision role/influence, what success looks like to them, communication
preferences, relationship status, engagement goal). It gains a single line near
the top linking to the global identity:

```org
Person: [[id:<uuid>][Jane Doe]]
```

The same human can hold stakeholder profiles in several clients, each pointing
at one shared person node. Deleting a client removes only the engagement
snapshot; the durable person record is untouched.

### Directory & configuration

New defcustom:

```elisp
(defcustom org-fractional-cto-people-directory
  (expand-file-name "people" (or (bound-and-true-p org-directory) "~/org"))
  "Directory holding one Org node per person (global, cross-client)."
  :type 'directory
  :group 'org-fractional-cto)
```

It is a **sibling** of the clients directory and fully independent of it.

**roam colocation tip (documented, not enforced):** a user who already uses
org-roam points this directory at a folder inside their `org-roam-directory`.
roam then indexes the person nodes automatically, and their
`org-roam-node-insert` / backlinks buffer / `org-roam-node-find` continue to
work unchanged — with no roam-specific code in the package.

### Reference mechanism — native `org-id`

- Person nodes are plain `org-id` nodes. The package registers the people
  directory with `org-id` so every `[[id:...]]` link resolves from anywhere in
  the workspace (meeting notes, actions, stakeholder profiles, ADRs).
- Registration uses `org-id`'s own facilities (`org-id-extra-files` and/or an
  `org-id-update-id-locations` pass over the people directory) — **not**
  `org-agenda-files`. Person nodes are not actionable, so keeping them out of
  the agenda avoids cluttering it.
- Inserting references by display name is the one thing Org cannot do natively
  over a global set of files; that is what the helper below provides. roam
  users may instead use `org-roam-node-insert`.

### Helper command

`org-fractional-cto-insert-person` — insert-or-create:

1. `completing-read` over existing person nodes by `#+title`.
2. Selecting one inserts `[[id:<uuid>][Name]]` at point.
3. Typing an unknown name offers to create the person node (mint `:ID:`, write
   `#+title` and the field scaffold), then inserts the link to the new node.

No jump command — opening a person link is already native (`C-c C-o`). The
command is **unbound by default** and documented for the user to bind,
consistent with the package's native-first / minimal-keybinding stance.

### Capture changes

- `eP` ("Person / team member note") is repurposed: instead of a heading in the
  client's *People* section, it creates/visits a **global** person node. A
  rewritten bundled `person.org` template provides the file-level `:ID:` (via
  `%(org-id-new)`), `#+title`, and the fields listed above. The capture target
  is a function that derives a slug from the name, creates
  `<people-directory>/<slug>.org` if absent, and positions point for editing.
- `ep` ("Stakeholder profile") template gains the `Person: [[id:...][Name]]`
  line.

### Per-client People section & CONTEXT "Key People"

- The hub's *People* section is repurposed into a **roster of `[[id:]]` links**
  to the global person nodes relevant to that client — each client keeps a
  one-glance who's-who, but every entry points at the canonical node.
- `CONTEXT.md`'s "Key People" tables gain a Person column holding the same
  `[[id:]]` links.
- Nothing is deleted; the data becomes link-backed.

### Migration

Non-destructive. Existing in-hub person headings and stakeholder profiles keep
working as plain text. Documentation explains how to lift a person out into a
global node (capture/create the node, then replace the inline mention with an
`[[id:]]` link) when the richer page is wanted.

### Documentation

Update `guide.org`, `reference.org`, `README.org`, and the texinfo manual to
cover:

- the people directory and the global person / client-scoped stakeholder split,
- the `org-fractional-cto-insert-person` helper,
- the native `C-c l` / `C-c C-l` store/insert workflow,
- the org-roam colocation tip for users who want backlinks.

## Components & boundaries

| Unit | Responsibility | Depends on |
|------|----------------|------------|
| `org-fractional-cto-people-directory` (defcustom) + path helpers | Locate the people dir and per-person node files | core |
| `org-id` registration on load | Ensure `[[id:]]` links to person nodes resolve | `org-id`, people dir |
| `person.org` template (rewritten) | Field scaffold for a new global person node | — |
| Person capture target function (`eP`) | Create/visit `<people-dir>/<slug>.org`, position point | people dir, `org-id` |
| `org-fractional-cto-insert-person` | Insert-or-create person reference by name | people dir, `org-id` |
| `stakeholder.org` template (extended) | Add `Person:` link line | — |
| Scaffold/CONTEXT changes | People section as link roster; Key People Person column | scaffold |
| Docs | Explain model + workflow | — |

## Testing

- **Unit:** path helpers (people dir, per-person file path, slug derivation);
  person-node creation (file written with `:ID:`, `#+title`, `#+filetags`);
  insert-or-create helper for both the existing-pick and create-new paths
  (link text, new file contents, point position).
- **Integration:** `[[id:]]` link from a client hub note resolves to the person
  node after `org-id` registration; stakeholder capture produces the `Person:`
  link line; `eP` capture lands a node in the people directory rather than the
  client hub.
- **Regression:** existing client scaffold, capture routing, and dashboard are
  unaffected; the people directory is excluded from `org-agenda-files`.

## Open questions

None blocking. Slug-collision handling for two people with the same name (e.g.
suffixing) is an implementation detail to settle in the plan.
