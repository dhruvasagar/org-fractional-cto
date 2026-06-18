# People Assignment & Reference Links — Design

**Date:** 2026-06-18
**Status:** Approved (pending implementation plan)
**Builds on:** [2026-06-17-people-stakeholder-references-design.md](2026-06-17-people-stakeholder-references-design.md) (global person nodes, `org-id` links, `org-fractional-cto-insert-person`, `org-fractional-cto-create-person`).

## Problem

The person-node feature made people first-class, linkable entities. But the
places that actually *assign work to* or *reference* people are still
free-text: delegation `:ASSIGNED_TO:`, blocker `:UNBLOCK_OWNER:`, commitment /
risk / security `Owner:`, meeting attendees, authorship lines ("Conducted by",
"Made by"), and the `delegate-at-point` / `block-at-point` commands all prompt
with `%^{...}` or `read-string` and store a bare name. Consequences:

- A name in `:ASSIGNED_TO:` does not link to the person node, so there is no
  navigation, no roam backlink, and no deterministic identity.
- The dashboard cannot answer "what open work is assigned to Jane?" — the
  "Delegated — awaiting response" block is `(todo "WAITING")`, unsliced, and
  `:ASSIGNED_TO:` is a dead property never surfaced or filtered.

## Goals

- Every people-reference across the templates and at-point commands becomes an
  `[[id:...][Name]]` link to the global person node.
- Single-owner actionable TODO headings are additionally **tagged** with a
  stable per-person tag, so the existing tag-driven dashboard and Org's native
  `/` agenda filter can slice work by person.
- Link and tag derive from a single person pick, so they never drift.
- No new hard dependency; org-roam stays optional. Reuse the existing person
  picker / creation path. Stay native: querying is the built-in agenda `/`
  filter, not a bespoke command.

## Non-Goals

- No new dashboard command for per-person work (native `/` tag filter covers
  it; YAGNI / native-first).
- No tags on multi-person or descriptive references (attendees, table-cell
  owners, authorship) — those get links only, to avoid tag sprawl and
  role-conflation on meeting headings.
- No destructive migration of existing free-text assignments.
- No org-roam dependency.

## Design

### Two representations from one pick

Every people-reference becomes a link `[[id:ID][Name]]`. Single-owner **TODO**
headings additionally carry a person **tag** `@<slug>`, where `<slug>` is the
person node's filename base (produced by `org-fractional-cto-people-slug`,
already constrained to `[a-z0-9_]`, which is a valid Org tag). The tag is
therefore **derived** from the node, never stored separately. Link and tag are
always written together from the same pick and cannot drift.

**Tagged set (single-owner TODO headings) — exactly five capture types and
their at-point twins:**

| Type | Field today | Becomes |
|------|-------------|---------|
| delegation (`eg`) + `delegate-at-point` | `:ASSIGNED_TO: %^{Assigned to}` | link in property + `@slug` tag |
| blocker (`eb`) + `block-at-point` | `:UNBLOCK_OWNER: %^{...}` | link in property + `@slug` tag |
| commitment (`ec`) | `Owner (internal): %^{Owner}` | link in line + `@slug` tag |
| risk (`er`) | `Owner: %^{Owner}` | link in line + `@slug` tag |
| security (`ex`) | `Owner: %^{Owner}` | link in line + `@slug` tag |

**Link-only set (no tag):** meeting / discovery / QBR / retro / presales /
innovation attendees and facilitator (multi-person link lists); authorship
("Conducted by", "Evaluated by", "Made by", "Identified by", "Raised by");
decision-makers and escalation paths; "Owner" table columns. These get
`[[id:]]` links; per-person history for them comes from roam backlinks (roam
users) — not from heading tags.

### One person-picker, two entry points

A single resolver `org-fractional-cto--read-person` does completing-read over
people by `#+title` with insert-or-create (reusing
`org-fractional-cto-create-person`), returning a record
`(:id ID :name NAME :slug SLUG)`.

**Capture templates** call it through `%(...)` escapes (template files already
expand `%(elisp)` at capture time). A `%(sexp)` escape is *replaced by the
sexp's return value* — these helpers therefore **return** the text Org inserts
(they do not call `insert` themselves) and perform any plist side-effect along
the way:

- `%(org-fractional-cto--capture-person "Owner" t)` — picks a person, returns
  `[[id:ID][Name]]`, and (because TAG is `t`) stashes the person under
  `:ofc-person` to flag the heading for tagging.
- `%(org-fractional-cto--capture-person "Made by")` — returns the link only, no
  tag flag.
- `%(org-fractional-cto--capture-people "Attendees")` — repeatedly picks people
  (empty input ends), returns a comma-separated list of `[[id:]]` links; no
  tag.

**At-point commands** (`org-fractional-cto-actions.el`): the `read-string`
assignee/owner prompts in `delegate-at-point` and `block-at-point` are replaced
by `org-fractional-cto--read-person`. They set the property to the link and
apply the `@slug` tag to the heading. Public command arguments stay
string/record-shaped so tests can drive them non-interactively.

### Tag application — decoupled via finalize hook

The tagging `%(...)` sexp stashes the chosen person record in the capture plist
under `:ofc-person`. A function `org-fractional-cto--apply-person-tag`, added to
`org-capture-before-finalize-hook`, reads `:ofc-person` and applies `@slug` to
the captured heading; it no-ops when the key is absent. This:

- auto-scopes to exactly the templates that opt in (those whose body called the
  tagging sexp) — no hard-coded capture-key list;
- keeps headline/tag mechanics out of the template text (the template only
  needs the `%(...)` link escape in the owner field).

The hook is registered (idempotently) in `org-fractional-cto-capture-install`.

### Querying — native

`@slug` tags plug into the existing tag-driven dashboard and Org's built-in
agenda `/` filter with no new machinery: in any dashboard block press `/` and
type the person's tag to narrow to their items. Documented; no command added.

### Migration

Non-destructive. Existing plain-text `:ASSIGNED_TO: Jane` / `Owner: Jane`
remain valid (untagged, unlinked). Re-assigning through the upgraded capture or
`delegate-at-point` / `block-at-point` upgrades an item in place. Docs explain
this.

## Components & boundaries

| Unit | Responsibility | Depends on |
|------|----------------|------------|
| `org-fractional-cto-person-tag (file-or-slug)` | Derive `@slug` from a person node | people module |
| `org-fractional-cto--read-person` | Interactive pick-or-create → record `(:id :name :slug)` | `org-fractional-cto-people`, `create-person` |
| `org-fractional-cto--capture-person (prompt &optional tag)` | Capture `%()` helper: return link string; if TAG, stash `:ofc-person` | `--read-person` |
| `org-fractional-cto--capture-people (prompt)` | Capture `%()` helper: return comma-separated link-list string | `--read-person` |
| `org-fractional-cto--apply-person-tag` | `before-finalize-hook`: tag captured heading from `:ofc-person` | org-capture plist |
| `delegate-at-point` / `block-at-point` (modified) | Pick person → link property + `@slug` tag | `--read-person`, `person-tag` |
| Template edits | Swap `%^{...}`/owner fields for `%(...)` person escapes | the helpers |
| Docs | Document escapes, `@person` tag convention, `/` filtering | — |

## Testing

- **Unit:** `person-tag` derivation (`jane_doe.org` → `@jane_doe`);
  `--read-person` existing-pick and create-new paths (stub `completing-read` /
  `y-or-n-p`) returning the right record; `--capture-person` returns the link
  string and sets/omits `:ofc-person` per the TAG arg; `--capture-people` returns
  a comma-separated link list and ends on empty input; `--apply-person-tag` tags
  the heading when `:ofc-person` is set and no-ops otherwise.
- **Integration:** `delegate-at-point` on a heading sets `:ASSIGNED_TO:` to a
  link and adds the `@slug` tag; `block-at-point` puts the link in
  `:UNBLOCK_OWNER:` and tags the new blocker; a delegation capture run end to
  end yields a WAITING heading carrying both the link property and the `@slug`
  tag (exercises the finalize hook).
- **Regression:** existing capture routing, the dashboard blocks, and the
  person-node suite stay green; person tags do not leak into client filtering
  or `org-agenda-files` behavior.

## Open questions

None blocking. Whether commitment/risk/security "Owner" should migrate from a
body line to a real property (for uniformity with delegation/blocker) is an
implementation-time tidiness call; the tag does not depend on it.
