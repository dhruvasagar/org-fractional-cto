# Design: Per-client capture template overrides

**Date:** 2026-06-16
**Status:** Approved (pending spec review)
**Topic:** Generalize the standup-only per-client template override to all
capture templates, materialized at client onboarding.

## Motivation

Client onboarding generates a `standup.org` that the user then edits with
client-specific context. A recent fix (`494b20e`) made the `es` standup
capture actually read that per-client file instead of the bundled generic
template. That exposed a broader gap:

1. **Only standup is overridable.** Every other capture template is fixed —
   either a bundled file read verbatim, or an inline string baked into
   `org-fractional-cto-capture.el`. Every client engagement is different, and
   the templates bake in a lot of one-size-fits-all assumptions (risk fields,
   scope-change workflow, security taxonomy, stakeholder structure, …).
2. **Onboarding is the natural customization point.** Onboarding is where the
   user already tailors the workspace to a client; it should be where the base
   templates get client-specific corrections too.
3. **Two template-loading paths invite drift.** `--file` always loads the
   bundled copy; `--standup-template` was a one-off per-client path. Two paths
   are why standup silently diverged. There is also a *second* drift: the
   bundled `templates/standup.org` (3 streams) and the scaffold's hand-written
   `--write-standup` (6 streams) are already out of sync — two sources of truth
   for the same template.

The guiding principle (consistent with [[native-org-first-preference]] and the
prior dashboard rethink): **one uniform mechanism**, lean on the filesystem,
no bespoke per-template special-casing.

## Decisions (from brainstorming)

| Question | Decision |
|----------|----------|
| Scope / sequencing | **Two specs; this one (overrides) first.** People-as-linked-pages is a separate later spec. |
| Where overrides live | **`<clients-dir>/<slug>/templates/<name>.org`** (a `templates/` subdir per client). |
| Resolution order | **Per-client `templates/<name>` → global dir (`org-fractional-cto-template-directory`, default = bundled).** Two layers, no legacy fallback. |
| Onboarding behaviour | **Copy all bundled templates** into the new client's `templates/`. |
| Drift management | **None (YAGNI).** Copied templates are the client's to edit; bundled improvements do not propagate. |
| Existing clients | **No migration code.** They fall through to bundled templates. User manually moves any edited `<slug>/standup.org` → `<slug>/templates/standup.org`. |
| `upgrade-hub` changes | **None.** It is hub-only and orthogonal; confirmed no references to standup/templates. |
| Inline templates | **Externalize all 13 to files**, so every capture is overridable. |
| Standup duplication | **Collapse to one source.** Delete `--write-standup`; onboarding copies the bundled `templates/standup.org` like any other template. |

## Architecture

### Resolution (the core)

Today there are two template paths. Unify them into one resolver:

```elisp
(defun org-fractional-cto--resolve-template-file (name)
  "Return a path for template NAME, preferring the active client's override.
  1. <clients-dir>/<slug>/templates/<name>   ; per-client override
  2. (org-fractional-cto--template name)      ; global dir, default = bundled
SLUG comes from the memoised `org-fractional-cto--capture-client-slug'."
  ...)
```

- `--file` routes through this resolver instead of calling `--template`
  directly.
- `--standup-template` is **deleted**; the `es` entry becomes
  `(function ,(org-fractional-cto--file "standup.org"))` — standup is no longer
  a special case.
- Client selection timing is unchanged in effect: the resolver calls the
  memoised `org-fractional-cto--capture-client-slug`, so a template resolved
  before the target (per Org's `org-capture-get-template` ordering) still
  selects the client once, and the target reuses it. Single prompt.

### Helpers

- `org-fractional-cto-client-template-file (slug name)` →
  `<clients-dir>/<slug>/templates/<name>`. Replaces the removed
  `org-fractional-cto-client-standup-file` (which was
  `<clients-dir>/<slug>/standup.org`).
- `org-fractional-cto--copy-templates (slug)` → `make-directory` the client's
  `templates/`, then `copy-file` each bundled template that is not already
  present (idempotent at the file level, though onboarding only runs it once).

### Onboarding

`org-fractional-cto--scaffold` gains a call to `--copy-templates`.
`--write-standup` is removed; standup arrives as one of the copied files, with
no special handling. New clients get a full, editable `templates/` directory.
The bundled `templates/standup.org` is the single source of truth for the
standup default, exactly as every other template's bundled file is for its own.

### Externalizing inline templates

The 13 inline-string templates move to bundled files **verbatim** — identical
`%^{…}`, `%U`, `%?`, `%a` escapes — so capture output is byte-for-byte
unchanged; only the source location moves. New bundled files and their `e`
keys:

| Key | Template | New file |
|-----|----------|----------|
| `eo` | Research note | `research.org` |
| `ew` | Action item | `action.org` |
| `eP` | Person / team member note | `person.org` |
| `ec` | Commitment | `commitment.org` |
| `eh` | Client health check | `health_check.org` |
| `eM` | Metrics snapshot | `metrics.org` |
| `er` | Risk | `risk.org` |
| `ee` | Scope change | `scope_change.org` |
| `ef` | Post-mortem | `post_mortem.org` |
| `eD` | Quick decision | `quick_decision.org` |
| `et` | Tech debt item | `tech_debt.org` |
| `ex` | Security finding | `security.org` |
| `en` | Innovation idea (single) | `innovation_idea.org` |

Result: all 30 capture templates are file-based and overridable; the capture
`.el` shrinks to a uniform list of `(--file …)` entries.

## Data flow

```
C-c c e<key>
  └─ org-capture
       ├─ get-template  → (--file "name.org")
       │     └─ --resolve-template-file "name.org"
       │           ├─ <slug>/templates/name.org   (if exists) ──┐
       │           └─ --template "name.org" (bundled)  ─────────┤
       │                                                        ▼
       │                                            --file-contents → text
       │                                            (Org re-scans %-escapes)
       └─ set-target-location → files under the heading in the client hub
```

## Backward compatibility

- **No migration code.** Existing clients lack `templates/`; the resolver falls
  through to bundled templates — current behaviour preserved.
- **Standup:** the legacy flat `<slug>/standup.org` is **no longer consulted**.
  The user moves it to `<slug>/templates/standup.org` by hand per client. (A
  one-line note in the docs covers this.)
- **`org-fractional-cto-client-standup-file`** is removed; any references
  updated to `client-template-file slug "standup.org"`.

## Error handling

- `--resolve-template-file` only ever returns an existing per-client path or
  the bundled path; `--file-contents` then reads it. A missing bundled file is
  a packaging error (covered by the existing `every-file-template-exists`
  test).
- `--copy-templates` uses `copy-file` with `OK-IF-ALREADY-EXISTS` handled by a
  pre-check (skip files already present) so re-running never clobbers edits.

## Testing

- **Resolver:** per-client override wins; with no override, falls back to
  bundled; with no active client + bundled present, still resolves.
- **Regression snapshot (critical):** each of the 13 externalized files equals
  the previous inline string, guaranteeing identical capture output. Encode the
  old strings as fixtures and assert file contents match.
- **Onboarding:** after `new-client`, `<slug>/templates/` exists and contains
  every bundled template, including `standup.org`; `--write-standup` is gone.
- **Existing tests:** the current 59 (incl. the standup-fix suite) stay green;
  update any that referenced `client-standup-file` or the inline strings.

## Out of scope

- People-as-linked-pages / org-roam person nodes — **separate spec #2**.
- Template drift/sync tooling (refresh, diff, status commands) — YAGNI.
- Per-client overrides for the inline *string* fragments that are not whole
  templates (none remain after externalization).

## Documentation

- README, `doc/guide.org`, `doc/reference.org`, `doc/playbook.org`: add a
  "Per-client template overrides" section (the `templates/` dir, resolution
  order, how onboarding populates it, the manual standup move for existing
  clients).
- Regenerate `org-fractional-cto.texi` via `make info`.
