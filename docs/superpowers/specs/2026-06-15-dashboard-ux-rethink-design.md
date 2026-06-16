# Design: Dashboard & capture UX rethink

**Date:** 2026-06-15
**Status:** Approved (pending spec review)
**Topic:** Filetag-based client identity, auto-filled client name, a global
dashboard with native client focus, and agenda-driven at-point actions.

## Motivation

Two concrete complaints, and one broader rethink behind them:

1. **Redundant prompts.** Most capture templates prompt for the client name
   (`Client: %^{Client}`, and the meeting/QBR headlines) even though an active
   client is already selected — the system already knows who the note is for.
2. **No cross-client view.** The dashboard (`C-c a E`) is scoped to one client
   at a time. There is no way to see ongoing work across all clients to plan
   and prioritise.
3. **Tag noise.** Every section heading and every captured item carries the
   client tag (`:ACME:…`), which is repetitive and clutters the outline and
   agenda lines.

The guiding principle for the redesign: **lean on native Org behaviour wherever
possible** so the user does not have to learn bespoke commands or keybindings.
Filtering, inheritance, and the agenda category column are all standard Org
features that already do most of the work.

## Decisions (from brainstorming)

| Question | Decision |
|----------|----------|
| Per-client vs global dashboard | **One unified dashboard, global by default.** |
| How to focus a client | **Native `/` tag filter** (no custom focus command). |
| Opening default | **(B)** open pre-filtered to the active client when one is set (via native `org-agenda-tag-filter-preset`), else global. |
| Tag-noise reduction depth | **Client tag → `#+filetags`; keep type subtags** (`:RISK:`, `:COMMITMENT:`, …) on items. |
| Existing hubs | **Migrate via `org-fractional-cto-upgrade-hub`** (per client, idempotent). |
| Client name in notes | **Auto-fill from the hub `#+title`** — name still appears, never prompted. |
| At-point actions in agenda | **Make `delegate`/`block` agenda-aware.** |
| Agenda keybindings | **Comma (`,`) localleader**, **bound across all Org agendas**, evil bindings included. |
| Tag inheritance config | **On by default**, installed by `org-fractional-cto-setup`. |

## Design

### 1. Client identity as a filetag

**Scaffold** (`org-fractional-cto--write-hub`):
- Emit `#+filetags: :ACME:` in the file header (after the existing `#+TODO:`
  line).
- Drop the client tag from the engagement heading, keeping the stage:
  `* Acme Corp Engagement :ACTIVE:`.
- Drop the client tag from every section heading, keeping the type subtag:
  `** Risks :RISK:`, `** Actions` (no tag, as today it only had the client tag).

**Why safe:** Dashboard blocks match on type subtags (`+RISK`, `BLOCKER`,
`COMMITMENT`, `SECURITY`, `TECHDEBT`, `SCOPE`) and TODO state — none of which
move. The client tag only changes *location* (heading → file); Org tag
inheritance keeps it on every entry, so tag filtering and `C-c a m ACME` still
work.

### 2. Capture templates: no client tag, auto-filled name

- **Remove** `:%(org-capture-get :ofc-client-tag):` from all inline templates in
  `org-fractional-cto-capture.el`, keeping the type subtag (e.g.
  `* [RISK] %^{Risk} :RISK:`). Action items lose their lone client tag entirely
  (`* TODO %^{Action}`), inheriting the client from the filetag.
- **Remove** the client tag from the bundled `templates/*.org` files, and fix
  `client_meeting.org`'s dead `:ENGAGEMENT:MEETING:` → `:MEETING:`.
- **Auto-fill the name:** add `org-fractional-cto-client-name (slug)` which reads
  the hub's `#+title:` keyword (falling back to the slug if absent).
  `org-fractional-cto--capture-to-heading` stashes it in the capture plist as
  `:ofc-client-name`. Replace every `%^{Client}` (the 9 `Client:` metadata lines
  in the file templates and the meeting/QBR headlines) with
  `%(org-capture-get :ofc-client-name)`. The name still renders in the note for
  standalone reading and export; it is simply never prompted for.

`%^{Client attendees}` / `%^{Our attendees}` are **not** touched — they ask *who
attended*, not which client, and remain genuine prompts.

### 3. Migration via `upgrade-hub`

`org-fractional-cto-upgrade-hub` gains a migration step,
`org-fractional-cto--migrate-to-filetags`:
1. Derive the client tag from the **filename** (`file-name-base`), robust even
   after heading tags are stripped.
2. Ensure `#+filetags: :TAG:` is present in the header (insert if absent).
3. Strip the client tag from the engagement heading (keep stage) and from every
   section heading (keep type subtag).
4. Idempotent — running twice is a no-op.

`org-fractional-cto--ensure-sections` is updated to derive the client tag from
the filename and to append **tag-free** (client) sections — i.e. new sections
written during an upgrade match the filetag scheme rather than re-introducing
the per-heading client tag. (`--engagement-client-tag` is no longer the source
of truth for the client tag; it remains only as a stage-exclusion helper if
still needed.)

### 4. Global dashboard with native focus

`org-fractional-cto-agenda-install` changes the dashboard command's general
settings only — **the 9 blocks are unchanged**:

- `org-agenda-files` → `(org-fractional-cto-agenda-files)` (all client dirs,
  exactly as the existing pipeline view does), replacing
  `(org-fractional-cto--dashboard-files)`.
- `org-agenda-tag-filter-preset` → computed at run time:
  `(when org-fractional-cto-active-client (list (concat "+" (client-tag …))))`.
  With an active client the view **opens focused**; with none it opens global.

The native **CATEGORY column** already shows the client name per line (the
scaffold sets `:CATEGORY:` on the engagement heading), so the unfiltered global
view is readable. Refocusing, widening, and clearing are all native `/`
(`org-agenda-filter`) — nothing custom.

`org-fractional-cto--dashboard-files` is removed (no longer used).
`org-fractional-cto-dashboard` and `switch-client` keep working; the dashboard
simply no longer needs the active client to *render*, only to *pre-focus*.

### 5. Agenda-aware at-point actions

`org-fractional-cto-delegate-at-point` and `org-fractional-cto-block-at-point`
gain an agenda branch: when `(derived-mode-p 'org-agenda-mode)`, run the existing
mutation inside `org-agenda-with-point-at-orig-entry` (point becomes the real
heading in the source file), then refresh the affected agenda line. In an Org
buffer they behave exactly as today.

`org-fractional-cto--blocker-subtree` stops embedding the client tag (now
inherited from the filetag) — a simplification that also makes it correct when
invoked from the agenda, where `buffer-file-name` would otherwise be nil.

### 6. Agenda + evil keybindings

- New `org-fractional-cto-agenda-command-map` keymap with `g` → delegate,
  `b` → block (mirroring the `eg`/`eb` capture mnemonics and the existing
  command-map).
- **Evil (primary):** when `(featurep 'evil)`, bind the comma (`,`) localleader
  in the agenda's evil state across `org-agenda-mode-map`, so `, g` / `, b` work
  in **every** Org agenda buffer. The commands no-op gracefully on a non-hub
  entry (they derive the client tag from the file and `user-error` cleanly off a
  non-Org line).
- **Non-evil:** plain `,` is `org-agenda-priority` in vanilla `org-agenda-mode`,
  so we do **not** clobber it. Non-evil users reach the actions via `M-x` or a
  configurable prefix (`org-fractional-cto-agenda-keymap-prefix`, default nil).
- Installed by `org-fractional-cto-setup`.

### 7. Bundled Org config (keeps config self-contained)

`org-fractional-cto-setup` ensures tag inheritance is configured so client
**filetag** filtering works in the agenda — i.e. inherited tags are available to
`org-agenda-tag-filter-preset` and the `/` filter. Done additively and
non-destructively, in the same spirit as the existing keyword install
(`org-use-tag-inheritance` left at its default `t`; the relevant agenda view
types added to `org-agenda-use-tag-inheritance` only if missing). On by default.

## File-by-file impact

| File | Change |
|------|--------|
| `org-fractional-cto-scaffold.el` | `--write-hub`: emit `#+filetags`, tag-free engagement + section headings. |
| `org-fractional-cto-stage.el` | Add `--migrate-to-filetags`; call from `upgrade-hub`; `--ensure-sections` derives tag from filename, appends tag-free sections. |
| `org-fractional-cto-capture.el` | Strip client tag from inline templates; add `:ofc-client-name` to plist; interpolate name. |
| `templates/*.org` | Strip client tag; `Client:` lines → `%(org-capture-get :ofc-client-name)`; fix `client_meeting.org` `:ENGAGEMENT:`→`:MEETING:`; meeting/QBR headline name auto-filled. |
| `org-fractional-cto-agenda.el` | Dashboard command: global `org-agenda-files` + active-client `tag-filter-preset`; remove `--dashboard-files`. |
| `org-fractional-cto-actions.el` | Agenda-aware `delegate`/`block`; drop client tag from blocker subtree. |
| `org-fractional-cto.el` | Add `client-name`; tag-inheritance install in setup; agenda command-map + evil/`,` bindings + `agenda-keymap-prefix` defcustom. |
| `test/*.el` | New/updated tests (below). |
| `README.org`, `doc/guide.org`, `doc/reference.org`, `.texi` | Document filetags, the global dashboard + `/` focus, auto-fill, agenda keybindings; regenerate manual. |

## Testing

- **Scaffold:** hub emits `#+filetags: :TAG:`; engagement + section headings
  carry no client tag; stage + type subtags present.
- **Migration:** an old-style hub (client tag on headings, no filetag) gains the
  filetag and loses heading client tags after `upgrade-hub`; idempotent on a
  second run; a newly-scaffolded hub is unchanged by `upgrade-hub`.
- **Capture:** inline templates contain no `:ofc-client-tag` reference and do
  carry the type subtag; meeting/`Client:` lines interpolate `:ofc-client-name`;
  `client-name` returns the `#+title` and falls back to the slug.
- **Dashboard:** the installed command's settings put all client dirs in
  `org-agenda-files`; `tag-filter-preset` is `("+TAG")` with an active client and
  `nil` without.
- **Actions:** `delegate-at-point` / `block-at-point` invoked with point on a
  simulated agenda line mutate the correct source entry; blocker subtree carries
  no client tag.
- **Inheritance install:** setup adds the agenda inheritance config when missing
  and is idempotent.

## Non-goals / out of scope

- Dropping type subtags from items (the deeper inheritance option was explicitly
  declined — keep type subtags).
- A custom one-key "focus active client" toggle (declined in favour of native
  `/`).
- Reworking the cross-client **pipeline** view (`C-c a P`) — it already spans all
  clients and is unaffected beyond inheriting the filetag scheme.
- Grouping the global dashboard by client (the CATEGORY column + native sorting
  is sufficient; revisit only if the flat view proves noisy in practice).

## Risks / edge cases

- **Inherited-tag filtering subtleties.** `tag-filter-preset` and `/` must see
  the inherited filetag. Mitigated by the §7 inheritance install and covered by
  a dashboard test.
- **Hubs with unsaved edits during migration.** `upgrade-hub` already declines to
  save a buffer that was modified before it ran; the migration step inherits
  that guard.
- **Mixed-scheme period.** Until each hub is migrated, old hubs keep heading
  client tags. Both schemes filter correctly (explicit and inherited tags
  coexist), so the dashboard works throughout the transition.
