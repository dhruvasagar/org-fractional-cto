# Pre-Sales / Prospect Capture — Design

**Date:** 2026-06-15
**Status:** Approved (pending implementation plan)
**Package:** org-fractional-cto

## Problem

The package's lifecycle starts at the playbook's **Phase 0 — Engagement Setup**,
which assumes the client is already won. There is no support for the *sales
funnel* that precedes it: a pre-sales call where you have very little
information, the research you do afterward to understand the prospect, and the
go/no-go read before you commit. The existing `discovery` capture (`ed`) is the
closest fit but is deeply engagement-specific (teams, roles, streams, API
surfaces, schemas) and wrong for this thin, early stage.

## Goal

Let the operator capture a prospect from the first pre-sales contact, track
pre-sales work (actions, follow-ups, blockers) on the existing dashboard,
accumulate research, record a fit/qualification verdict, and convert a won
prospect into an active engagement with no structural migration and full
history preserved.

## Non-goals

- No CRM, no email/calendar integration, no contact database.
- No new dashboard — the per-client dashboard is reused unchanged.
- No change to the deep engagement discovery template (`ed`).
- No proposal/SOW document tooling (out of scope; tracked as ordinary
  actions/commitments if needed).

## Core decisions (resolved during brainstorming)

1. **A prospect is a client from day one** — same directory, same hub, same
   client picker, same per-client dashboard. Rationale: pre-sales already
   generates action items and follow-ups worth tracking, and the per-client
   dashboard is already scoped to one client, so leads don't pollute it.
2. **Engagement stage is a tag** on the top `* … Engagement` heading, exactly
   one at a time. Org tag inheritance is leveraged, not fought.
3. **Pre-sales content lives in new canonical sections** added to
   `org-fractional-cto-sections`, so every hub carries them and funnel history
   survives conversion.
4. **New lightweight pre-sales captures**; the deep `ed` discovery is left
   untouched.

## Lifecycle: stage tags

A single stage tag sits on the level-1 engagement heading:

```
LEAD → QUALIFIED → ACTIVE → (DORMANT)
                 ↘ LOST
```

| Stage       | Meaning                                              |
|-------------|------------------------------------------------------|
| `LEAD`      | Captured from a pre-sales call; raw                  |
| `QUALIFIED` | Researched and worth pursuing (pre-contract)         |
| `ACTIVE`    | Won / engaged — the default for `new-client`         |
| `LOST`      | Did not convert                                      |
| `DORMANT`   | Paused / on hold                                     |

Defined in core as `org-fractional-cto-stages` (ordered list). Conversion is a
one-line tag flip (`set-stage` → `ACTIVE`).

### Tag-inheritance contract

The stage tag is set on the engagement heading only. With Org's default
inheritance on, child entries inherit it, which is *desirable*:
`C-c a m LEAD` can surface a prospect's whole tree. The pipeline view (below)
matches the **explicit** stage tag on the engagement heading (restricted to
level-1 entries), so it works even if a user disables tag inheritance. The
existing per-client dashboard tag matches (`WAITING`, `BLOCKER`, …) never
reference stage tags, so inheritance does not perturb them.

## Hub sections

Three sections appended to `org-fractional-cto-sections` (appended, not
prepended, so a freshly scaffolded hub and an upgraded one produce identical
layout):

| Heading           | Sub-tag         | Holds                              |
|-------------------|-----------------|------------------------------------|
| `Pre-Sales Notes` | `PRESALES`      | pre-sales call / lead intake       |
| `Research`        | `RESEARCH`      | research findings, recon           |
| `Qualification`   | `QUALIFICATION` | fit / go-no-go assessments         |

Operational sections (`Actions`, `Delegations`, `Blockers`, `Commitments`,
`Risks`) are reused as-is — that is what gives dashboard-tracked pre-sales work
with no new machinery.

## New captures

All under the existing `e` prefix. Keys: `el` (Lead), `eo` (research — a
deliberately arbitrary free letter, `r` being taken by Risk), `eF` (Fit).
Each carries the client tag (`%(org-capture-get :ofc-client-tag)`) plus its
type tag, matching the existing convention.

### `el` — Pre-sales call / lead intake → Pre-Sales Notes

File template (`templates/presales_call.org`), clocks in. Fields: source /
referral, attendees, **The Ask** (their words), **Pain Points / Triggers**,
**Current State (as heard)** (org shape, tech hints, what exists), **Signals**
(budget signal, timeline signal, decision-makers — all `%^{…|choice}` menus),
**Next Step** as a checkbox + `DEADLINE`. Tagged `:<CLIENT>:PRESALES:`.

### `eo` — Research note → Research

Inline template (lightweight, repeatable, like `er`/`et`). Fields: `Area`
(Company/Market/Competitor/Tech stack/People/Funding/Other), `Source` (link),
**Finding** (`%?`), **Implication**, **Follow-up** checkbox. Tagged
`:<CLIENT>:RESEARCH:`.

### `eF` — Fit / qualification → Qualification

File template (`templates/qualification.org`). A scorecard table (Need/pain,
Budget, Authority, Timing, Technical fit, Strategic fit) + **Risks / Red
Flags** + **Verdict** (`%^{Verdict|Pursue|Hold|Pass}`) + **Rationale** + an
**If Pursue — Prep for Discovery** checklist linking the funnel to `ed`.
Tagged `:<CLIENT>:QUALIFICATION:`.

These plus the reference legend update keep the capture set self-documenting.

## New commands

### `org-fractional-cto-new-prospect`

Same scaffold as `new-client`, but seeds the engagement heading with the `LEAD`
stage tag and, after creation, sets the prospect active and opens the `el`
pre-sales capture so the first call is recorded immediately. Implementation
refactors the hub writer to accept a `stage` argument; `new-client` passes the
default (`ACTIVE`), `new-prospect` passes `LEAD`. The hub is otherwise
identical.

### `org-fractional-cto-set-stage`

Prompts for a stage from `org-fractional-cto-stages`, visits the active
client's hub, moves to the engagement heading (first level-1 heading), removes
any existing stage tag, and adds the chosen one (`org-get-tags` filter +
`org-set-tags`). Promotion-to-won is `set-stage → ACTIVE`.

### `org-fractional-cto-upgrade-hub`

Idempotent migration for hubs created before this change: ensures the
engagement heading carries a stage tag (defaulting to `ACTIVE` if none), and
appends any sections from `org-fractional-cto-sections` that are missing. Safe
to re-run; makes no change to an already-current hub.

### Keymap

Added to `org-fractional-cto-command-map`: `p` → `new-prospect`,
`S` → `set-stage`. (`upgrade-hub` is `M-x`-only; it is a one-off.)

## Pipeline view

A second custom agenda command — the funnel board — registered alongside the
dashboard under a new customizable key `org-fractional-cto-pipeline-key`
(default `"P"`, i.e. `C-c a P`). It runs over **all** client directories
(`org-fractional-cto-agenda-files`) and lists every engagement tagged `LEAD`
or `QUALIFIED`, one line per prospect.

Implementation: a `tags` block matching `org-fractional-cto-pipeline-stages`
(`"LEAD|QUALIFIED"`) with an `org-agenda-skip-function` that skips entries
whose level is greater than 1, so only the engagement headings appear (not the
inherited children). Installed by `org-fractional-cto-setup` the same way the
dashboard is, and refreshable/idempotent in the same manner.

## File / module change map

- **`org-fractional-cto.el`** (core): add stage defcustoms/defconsts
  (`org-fractional-cto-stages`, `-default-stage`, `-lead-stage`,
  `-pipeline-stages`, `-pipeline-key`) before the submodule `require`s; require
  the new stage module; add `p`/`S` keymap bindings; install the pipeline
  command in `setup`.
- **`org-fractional-cto-scaffold.el`**: append the 3 sections to
  `org-fractional-cto-sections`; parameterize `--write-hub` with a stage; add
  the stage tag to the engagement heading; refactor `new-client`; add
  `new-prospect`.
- **`org-fractional-cto-stage.el`** (new, small): `set-stage`, `upgrade-hub`,
  and an engagement-heading helper.
- **`org-fractional-cto-capture.el`**: add `el`, `eo`, `eF` templates.
- **`org-fractional-cto-agenda.el`**: pipeline custom command, its install
  function, and the key defcustom.
- **`templates/`**: `presales_call.org`, `qualification.org` (file templates);
  `eo` is inline.
- **`test/`**: extend the ERT suite.
- **`doc/`**: `guide.org` (a pre-sales step), `reference.org` (keys + stage
  legend), `playbook.org` (a "Phase −1 — Pre-Sales / Pipeline" section);
  regenerate `org-fractional-cto.texi` via `make info`.

## Testing plan

ERT, reusing the existing on-disk-hub fixture pattern in
`test/org-fractional-cto-actions-test.el`:

- **Sections**: `org-fractional-cto-sections` includes the 3 new sections; a
  scaffolded hub contains their headings with the right sub-tags.
- **Stage on creation**: `new-client` hub engagement heading carries `ACTIVE`;
  `new-prospect` hub carries `LEAD`.
- **`set-stage`**: replaces the existing stage tag, leaves the client tag and
  other tags intact, and refuses an unknown stage.
- **`upgrade-hub`**: on a legacy hub (no stage tag, missing new sections) adds
  `ACTIVE` and the missing sections; running it twice is a no-op (idempotent).
- **Captures**: `org-fractional-cto-capture-templates` registers keys `el`,
  `eo`, `eF` targeting the correct sections (structural assertion, matching how
  capture installation is otherwise verified).
- **Pipeline**: the custom command is registered under the pipeline key; the
  skip predicate keeps level-1 engagement headings and drops deeper entries
  (tested against a small multi-heading buffer).

Interactive prompt-driven bodies are exercised by calling commands with
explicit arguments (the established pattern), not by simulating `org-capture`.

## Open questions

None. Stage vocabulary, pipeline view, upgrade-hub, and the `eo` key are all
confirmed as proposed.
