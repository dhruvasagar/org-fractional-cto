# AI-assisted item extraction from finalized notes

Date: 2026-06-24
Status: Approved (design)
Module: `org-fractional-cto-ai.el` (new)

## Summary

When a flagged capture (standup, discovery, meeting, retrospective…) is
finalized, its note text is sent — asynchronously — to a user-supplied model
backend, which returns candidate **Actions / Risks / Blockers / Decisions**.
The candidates appear in an Org-native review buffer the user prunes and edits;
one keystroke files the survivors into the correct client-hub sections, each
linked back to the source note. Nothing reaches the hub without confirmation,
and capture finalize never blocks on the network.

This generalizes: each extractable item type is one row in a mapping table.
Adding a future "scenario" (e.g. tech-debt items, innovation ideas, scope
changes) means adding a row — no engine changes.

## Goals

- Turn unstructured notes into structured, tracked hub items with AI help.
- Keep the core package dependency-free: the model backend is pluggable and
  absent by default (feature simply off until configured).
- Stay Org-native (the project's standing preference): the review surface is a
  real Org buffer the user already knows how to edit; filing reuses existing
  section/template machinery.
- Never compromise capture: finalize must finish cleanly and instantly
  regardless of backend latency, errors, or absence.

## Non-goals

- Shipping a concrete model backend (transport is user-supplied; a reference
  adapter may live in docs/contrib later, not in core).
- A manual "extract this old subtree" command. Auto-on-finalize only for v1;
  the engine is factored so a manual entry point is a trivial later addition.
- Auto-filing without review, or draft/triage-later workflows. v1 is
  strictly review-then-commit.

## Architecture

Two layers keep the user-supplied piece trivial and make engine behavior
identical across backends.

### Transport (user-supplied)

```elisp
(defcustom org-fractional-cto-ai-request-function nil
  "Function used to send a prompt to a language model.
Called as (FN PROMPT CALLBACK).  FN must arrange for CALLBACK to be
invoked with one argument: the model's raw response string, or nil on
failure.  FN should be asynchronous; the engine additionally defers the
call so a synchronous implementation cannot block capture finalize.
When nil, AI extraction is disabled.")
```

A backend over gptel or a CLI is ~10 lines. The package owns prompt
construction and response parsing, so a backend only moves a string to a model
and back.

### Engine (package-owned)

Responsibilities, each an isolated, independently testable unit:

1. **Prompt builder** — assemble a prompt from the active note text, the client
   context, and the taxonomy descriptions, instructing the model to return a
   JSON array of items in a fixed shape.
2. **Response parser/normalizer** — tolerant JSON parse (strips code fences),
   producing normalized item plists; drops unknown/invalid items with a
   warning.
3. **Renderer** — turn a normalized item plist into Org entry text for its type
   (per-type `:render` function, reusing bundled template shapes).
4. **Review** — build and pop the `*ofc-ai-review*` Org buffer; bind commit and
   discard commands.
5. **Filing** — locate/create the target section in the hub and insert the
   entry, add provenance link and tag.
6. **Trigger** — the finalize-hook glue that builds a job and fires the request.

## The taxonomy table — generalization point

```elisp
(defcustom org-fractional-cto-ai-item-types
  '((action   :section "Actions"                :tag nil
              :desc "A concrete follow-up task someone must do."
              :render org-fractional-cto-ai--render-action)
    (risk     :section "Risks"                  :tag "RISK"
              :desc "A risk to the engagement, with likelihood and impact."
              :render org-fractional-cto-ai--render-risk)
    (blocker  :section "Blockers"               :tag "BLOCKER"
              :desc "Something actively blocking a work stream."
              :render org-fractional-cto-ai--render-blocker)
    (decision :section "Architecture Decisions" :tag "DECISION"
              :desc "A decision reached during the discussion, worth recording."
              :render org-fractional-cto-ai--render-decision))
  "Taxonomy of AI-extractable item types.
Each entry is (TYPE . PLIST).  :section must name a heading in
`org-fractional-cto-sections'.  :tag is the per-item Org tag mirroring the
bundled capture template.  :desc is fed to the model to guide classification.
:render is a function taking a normalized item plist and returning Org entry
text.")
```

Each entry maps a model-emitted `:type` to:
- a hub `:section` (validated against `org-fractional-cto-sections` at use
  time; an entry naming an unknown section is dropped with a warning),
- a per-item `:tag` matching the bundled templates,
- a `:desc` injected into the prompt,
- a `:render` function producing the Org entry text.

The `:render` functions mirror the shapes of the existing bundled templates
(`action.org`, `risk.org`, `blocker.org`, `quick_decision.org`) so AI-filed
items are indistinguishable in structure from hand-captured ones.

### Normalized item plist

The model's JSON objects map onto:

```
(:type     symbol   ; one of the taxonomy keys
 :title    string   ; the headline
 :owner    string   ; optional person NAME, resolved to a person node
 :deadline string   ; optional ISO date
 :priority string   ; optional "A"/"B"/"C"
 :body     string   ; optional rationale / detail
 :fields   plist)   ; optional type-specific extras (likelihood, impact,
                    ;   blocking work stream, options, …)
```

`:owner` is carried on the rendered review entry as an `:OFC_AI_OWNER:`
property (a plain name) and is resolved through the existing
`org-fractional-cto-person-record` into an `[[id:]]` people link only **at
commit time, for survivors** — so reviewing-then-rejecting a candidate never
creates an orphan person node.

## Trigger & data flow

### Opt-in per template

Flag benefiting templates in `org-fractional-cto-capture-templates` with an
extra property:

```elisp
("es" "Standup" entry
 (function ,(org-fractional-cto--target "Standup Notes"))
 (function ,(org-fractional-cto--file "standup.org"))
 :clock-in t :clock-resume t :ofc-ai-extract t)
```

Read at finalize via `(org-capture-get :ofc-ai-extract)` — the same plist
mechanism already used for `:ofc-client-slug`. Templates to flag initially:
standup, discovery, client meeting, internal sync, retrospective, weekly
review, QBR. Action/risk/blocker/decision captures are **not** flagged.

### Flow

1. **Finalize** (`org-capture-before-finalize-hook`, joining the existing
   `org-fractional-cto--apply-person-tag`): if `:ofc-ai-extract` is set and
   `org-fractional-cto-ai-request-function` is non-nil:
   - ensure the source heading has an `org-id` (for the back-link),
   - capture a **job**: subtree text, hub file path, client name/slug, source
     id,
   - `(run-at-time 0 nil ...)` to fire the request — finalize returns
     immediately even if the backend is synchronous.
2. **Request** — engine builds the prompt and calls
   `org-fractional-cto-ai-request-function` with it and a callback.
3. **Callback** — parse → normalize → render each item → pop the review buffer.
   On nil/parse failure, `message` and stop (capture is already done).

## Review buffer — Org-native

`*ofc-ai-review*` is a real `org-mode` buffer. Each candidate is a fully-formed
Org entry (correct TODO keyword / tag / properties) under a parent heading:

```org
* Proposed from STANDUP 2026-06-24 — 3 items
  Edit or delete entries below, then C-c C-c to file the survivors (C-c C-k discards all).
** TODO Chase auth spec from Jun
   DEADLINE: <2026-06-30>
   :PROPERTIES:
   :OFC_AI_SECTION: Actions
   :END:
** [RISK] Vendor API deprecation                                       :RISK:
   :PROPERTIES:
   :OFC_AI_SECTION: Risks
   :END:
   Status: Open
   Likelihood: Medium
   Impact: High
...
```

Interaction model (maximally native — no custom selection machinery):
- **Edit** an entry → just edit the Org text.
- **Reject** an entry → delete its subtree.
- **Accept** → leave it.
- `C-c C-c` (local binding) → file every surviving second-level entry into the
  section named by its `:OFC_AI_SECTION:` property; append provenance; close
  buffer.
- `C-c C-k` (local binding) → discard all, close buffer.

The `:OFC_AI_SECTION:` property is how the commit step knows the destination;
it is stripped from the filed entry.

## Filing / placement

Factor a filing helper from the existing `org-fractional-cto--capture-to-heading`:

- `org-fractional-cto--goto-section (file heading)` — the find-or-create-heading
  logic, without the capture-plist side effects. `--capture-to-heading` is
  refactored to call it, preserving current capture behavior.

For each filed item:
1. Read `:OFC_AI_SECTION:` (destination) and optional `:OFC_AI_OWNER:` from the
   review entry, then strip both properties.
2. Visit the hub file, locate/create the `:section` heading.
3. Insert the rendered entry as a new child (depth normalized to sit one level
   below the section heading).
4. If an owner was present, resolve it via `org-fractional-cto-person-record`
   and insert an `Owner: [[id:][NAME]]` line under the heading.
5. Append `Source: [[id:SOURCE-ID][<note title>]]` provenance line.
6. Add the provenance tag (`org-fractional-cto-ai-provenance-tag`, default
   `"AI"`; nil disables) to the entry.

Per-item tags (`:RISK:`, `:BLOCKER:`, `:ADR:`) come from the renderer, matching
the bundled templates; the client tag is inherited from the hub's `#+filetags`
as it is for all hub entries.

## Error handling & boundaries

- Backend absent → feature off, no trigger.
- Backend returns nil / request errors → `message`, no review buffer.
- Parse failure → `message` with a hint and the raw output length; never throws
  into the finalize path.
- Unknown `:type` or `:section` → item dropped with a `warn`.
- All filing destinations validated against `org-fractional-cto-sections`.
- The finalize hook wraps its work in `condition-case` and logs failures, never
  aborting finalize — matching the defensive stance of
  `org-fractional-cto--apply-person-tag`.
- Input validation at the boundary: the JSON response is untrusted external
  data; every field is checked/typed before use.

## Configuration surface

| Variable | Default | Purpose |
|----------|---------|---------|
| `org-fractional-cto-ai-request-function` | `nil` | Transport; nil = feature off |
| `org-fractional-cto-ai-item-types` | 4 types | Taxonomy / generalization point |
| `org-fractional-cto-ai-provenance-tag` | `"AI"` | Tag on filed items; nil disables |
| `:ofc-ai-extract` (per template) | unset | Opt a capture into extraction |

Master on/off is implicit: extraction runs only when the request function is
set *and* the template is flagged.

## Testing (ERT, matching `test/`)

Pure units, no live model:
- prompt builder produces the expected structure from a note + taxonomy,
- JSON parser tolerates code fences and missing fields; rejects malformed,
- normalizer drops unknown types/sections,
- each renderer produces well-formed Org matching its template shape,
- `--goto-section` finds an existing section and creates a missing one,
- filing inserts under the right heading with provenance link and tag.

Full-flow test: inject a fake `request-function` that calls back with canned
JSON; assert the review buffer is built, and that committing files the items
into a temp hub with correct sections, tags, owners (person links), and
back-links.

## File organization

Target `org-fractional-cto-ai.el` < 400 lines. If it grows, split the review
buffer (`-ai-review.el`) from the core engine. Module loaded/wired from
`org-fractional-cto.el` alongside the other feature modules; the finalize hook
is registered next to the existing person-tag hook in
`org-fractional-cto-capture-install`.

## Decisions made during design

- **Pluggable transport, no bundled backend** — keeps core dep-free.
- **Review-then-commit**, not auto-file or draft-triage.
- **Auto on finalize, opt-in templates** (single entry point); manual command
  deferred.
- **Taxonomy table** as the one generalization seam.
- **`:AI:` provenance tag** on filed items for auditability (configurable).
- **org-id back-link** to the source note (native, robust; org-id already a
  dependency).
- **Delete-to-reject** review UX over checkboxes — more native, less machinery.
- **Engine owns prompt+parse**; transport is a thin string-in/string-out async
  function, deferred via `run-at-time` so it can never block finalize.

## Future extensions (out of scope for v1)

- Manual `org-fractional-cto-ai-extract` command on any subtree (backfill).
- More item types (tech debt, innovation ideas, scope changes) — new taxonomy
  rows.
- Duplicate detection against existing hub items before filing.
- A reference gptel/CLI backend shipped under docs/contrib.
