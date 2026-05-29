# Labeling Platform — Tech-Debt Register

Audit date: **2026-05-28** · Audited against the working tree (uncommitted, ahead of `5e42121`).

A prioritized inventory of technical debt in this repo, with effort
estimates, business justification, and a phased remediation plan that
can run alongside feature work. The dominant category was **documentation
drift**: the app was refactored hard between `e94226b` (initial) and the
current working tree, but two of the four design docs (`LABELING.md`,
`LABELING-STACK.md`) still described the original architecture. Both have
since been rewritten — see D2 / D1 below, now resolved.

Re-run this audit when the app architecture changes again, or quarterly.

## How items are scored

`Priority = (Impact + Risk) × (6 − Effort)`, each axis 1–5.

- **Impact** — how much it slows a maintainer down right now.
- **Risk** — what goes wrong if left unfixed (wrong fix shipped, outage, data loss).
- **Effort** — fix size (1 = minutes, 5 = days). Inverted in the formula, so cheap fixes rank higher.

## Current architecture (the "truth" the docs should match)

Recorded here once so drift is easy to spot. This snapshot reflects the
current **working tree** of [`labeling-platform.html`](../labeling-platform.html)
(**2,853 lines**), which is ahead of committed `5e42121` with in-flight
edits — the polling removal, the *Delete* control, and the add-rule modal
are all uncommitted as of this audit:

- **No background polling.** `usePolling` is defined but never called.
  Data refreshes on load, document switch, after each mutation, and via
  the top-bar refresh button (which does a full `window.location.reload()`).
- **Explicit Save, not debounced field writes.** Classification commits
  via one `INSERT … ON CONFLICT` on the **Save Classification** button
  (`saveClassificationLabel`); there is no per-field debounced `UPDATE`.
- **`original_*` lives on the `rule` table**, not in side tables. There
  is no `rule_original_snapshot` and no `rule_edit_pointer`; `updateRule`
  preserves the extractor's first values via `COALESCE`.
- **Three tables created on connect**: `labeler`, `rule_extraction_label`,
  `rule_classification_label` (not five).
- **Extraction page has no accept/reject/skip buttons and no labeler
  badges.** It supports *Add Rule* (button → centered modal collecting
  rule text + note + 4 axes → insert + auto-accept), *Change Rule* (edits
  the rule text only; the line range stays as extracted), and *Delete*
  (children-first hard delete). An extraction `decision` row is written
  only by *Add Rule*.
- **Classification writes only `accept` (Save) or `skip`.** No reject path
  in the UI, though `label_decision` ENUM still includes `'reject'`.
- **Note fields do not pre-fill from the LLM prediction** (the prediction
  shows in its own "LLM Judge" box).
- **Add Rule produces an ordinary extracted rule.** It reuses the file's
  existing `extractor_version` — there is no human-vs-LLM provenance
  marker. The schema doc's `created_by_labeler_id` /
  `last_edited_by_labeler_id` columns were dropped to match prod and this
  decision (see the schema-doc trim in Phase 1).

## Priority ranking

| # | Item | Category | I | R | E | Priority |
|---|------|----------|---|---|---|---------:|
| D5 | `window.__evalQuery`/`__evalPrepared` documented but never exposed | Docs↔Code | 4 | 3 | 1 | **35** |
| D2 | `LABELING.md` describes removed architecture — ✅ **resolved** | Documentation | 5 | 4 | 3 | ~~27~~ |
| D3 | `README.md` broken doc links + wrong line count | Documentation | 3 | 2 | 1 | **25** |
| C1 | Dead hooks: `usePolling`, `useDebouncedCallback`, `POLL_INTERVAL_MS`, `DEBOUNCE_MS` | Code | 3 | 2 | 1 | **25** |
| D4 | `DATA-LAYER.md` / `RUNBOOK.md` cite renamed fn + abandoned approach | Documentation | 3 | 3 | 2 | **24** |
| D1 | `LABELING-STACK.md` describes removed architecture — ✅ **resolved** | Documentation | 5 | 4 | 4 | ~~18~~ |
| Dep1 | Runtime deps via CDN; pinned to pre-release wasm-client | Dependency | 3 | 3 | 3 | **18** |
| C2 | `window.__moduleStarted` set for a boot watchdog that doesn't exist | Code | 2 | 1 | 1 | **15** |
| A3 | Single WASM connection — one bad statement wedges the app | Architecture | 3 | 3 | 4 | **12** |
| T2 | No CI; deploy is manual Vercel promote | Infrastructure | 2 | 2 | 3 | **12** |
| C3 | `confidence` loaded into predictions but never rendered | Code | 1 | 1 | 1 | **10** |
| A1 | MotherDuck token shipped to browser, gated only by Basic Auth | Architecture/Security | 3 | 5 | 5 | **8** |
| A4 | `'reject'` in ENUM with no UI path to write it | Code/Schema | 1 | 1 | 2 | **8** |
| T1 | No automated tests | Test | 3 | 3 | 5 | **6** |
| A2 | HTML `CREATE TABLE` types diverge from prod types | Architecture | 2 | 3 | 5 | **5** |

## Details

### D5 — Debug hooks documented but never exposed `[Docs↔Code]`
Both [DATA-LAYER.md](DATA-LAYER.md) (§ silent-failure modes) and
[RUNBOOK.md](RUNBOOK.md) (§ Save hangs forever, § Add/Change Rule hangs)
tell the maintainer to run `await window.__evalQuery(...)` /
`window.__evalPrepared(...)` in DevTools as the *primary* way to surface
a hung prepared statement. **Neither hook is assigned anywhere in
`labeling-platform.html`** — `evalQuery`/`evalPrepared` are module-scoped
and never attached to `window`. The prescribed debugging workflow fails
at the console.
- **Justification:** every save-path bug in the runbook is diagnosed with
  these hooks; without them the next on-call hits a hang with no documented escape.
- **Fix (cheapest, recommended):** expose them in dev — two lines after
  `evalPrepared` is defined (~`labeling-platform.html:1221`):
  ```js
  window.__evalQuery = evalQuery;
  window.__evalPrepared = evalPrepared;
  ```
  Alternative: delete the hook references from both docs and document a
  different technique. Exposing is preferred — it makes 4 doc sections correct at once.

### D2 — `LABELING.md` describes a removed architecture `[Documentation]` — ✅ RESOLVED
The "functional contract" documented the pre-refactor app. Stale claims that were fixed:
- "Polling every 2 s" (rows in the v0.3/v0.4 table; "next 2-second poll").
- "Real-time field-level upserts, debounced 400 ms … no per-row Save button" — the opposite of the current explicit Save button.
- "Three decision buttons: Accept · Reject · Skip" + "labeler badges" on **both** pages — neither exists; extraction has Add/Change Rule only, classification has Save + Skip.
- `rule_original_snapshot` / `rule_edit_pointer` side tables and "five tables" — gone; `original_*` is on `rule`.
- "four axes are pre-filled from the latest `parse_ok=TRUE` row" — pre-fill was removed in `5e42121`.
- **Justification:** this is the doc a new contributor reads to learn what the app *does*. It was teaching the wrong model.
- **Fix (done):** rewritten against the architecture snapshot above — the
  v0.4 change table, decision model, both page descriptions, and the
  storage-schema section now match the current code. The interim staleness
  banner was replaced with a one-line freshness note.

### D3 — `README.md` broken links + wrong line count `[Documentation]`
After `6eeb53f` ("Move docs into documents/ folder"), README's links to
`LABELING.md`, `LABELING-STACK.md`, `schema-v0.4.duckdb.sql`, and
`UI-design.pen` still point at the repo root → all 404. README and
LABELING-STACK both said "~1.1k lines"; the file is 2,853.
- **Justification:** README is the entry point; four dead links is a bad first run.
- **Fix:** repoint links to `documents/…`; correct the line count. **Done in this audit.**

### C1 — Dead polling/debounce hooks `[Code]`
`labeling-platform.html:1933-1953` defines `useDebouncedCallback`,
`usePolling`, `POLL_INTERVAL_MS = 2000`, `DEBOUNCE_MS = 400`. Each now has
exactly one reference — its own definition — after the working-tree
refactor that removed the two `usePolling` call sites and the field-level
debounced writes.
- **Justification:** implies a polling/debounce model that no longer
  exists; misleads anyone reading the hook section.
- **Fix:** delete the four definitions (~20 lines). No behavior change.

### D4 — `DATA-LAYER.md` / `RUNBOOK.md` cite renamed fn + abandoned approach `[Documentation]`
These two docs are otherwise accurate and current, but:
- They reference `ensureClassificationRow`; the code now uses
  `saveClassificationLabel` / `skipClassificationLabel`.
- They describe a **placeholder UUID/BLOB** for the no-prediction branch
  (`'00000000-…'::UUID`, `decode('00','hex')`). The code does the
  opposite and binds **NULL** — a fabricated UUID violates the FK to
  `rule_llm_decision` and *hangs* the statement (the central lesson of
  `schema-v0.4.duckdb.sql:247-254`). DATA-LAYER.md also listed
  `predicted_decision_id` / `predicted_snapshot_hash` as NOT NULL; the
  schema file made them nullable for exactly this reason.
- RUNBOOK.md linked `DATA-LAYER.md#schema-reality-vs-ddl` — no such anchor (it's "Two schemas").
- **Justification:** these are the *trusted* docs; small wrong names erode that trust and send readers to nonexistent code.
- **Fix (done in this audit):**
  - DATA-LAYER.md: corrected the NOT-NULL→nullable claim, the prod-schema
    dump, the "why it matters" FK-hang row, and the force-throw diagnostic
    (it asserted a NOT NULL error on a now-nullable column).
  - RUNBOOK.md: renamed `ensureClassificationRow` →
    `saveClassificationLabel`/`skipClassificationLabel`, reconciled the
    "Save hangs forever" + "Hand-added rules" sections to the nullable/FK
    NULL-binding story (historical NOT NULL incident kept as a note), and
    repointed the broken anchor to `#two-schemas`.

### D1 — `LABELING-STACK.md` describes a removed architecture `[Documentation]` — ✅ RESOLVED
The "read this first" maintenance reference was the most-drifted doc. What was fixed:
- Documents `rule_original_snapshot` + `rule_edit_pointer` and "five
  `CREATE TABLE`" (§ Schema, § Data flow, § Where the data lives).
- "Polls every 2 seconds" throughout (§ What it is, § Data flow, § Cautions, § Where to look when…).
- "In-file layout" + "shared components" lists ~15 functions/components
  that don't exist (`backfillSnapshots`, `getExtractionItems`,
  `ensureSnapshotForRule`, `putClassificationField`, `StatusSelect`,
  `DecisionButtons`, `LabelerBadges`, `SourceLines`, …).
- "~1.1k lines."
- **Justification:** explicitly the first stop for "why did it break" —
  high blast radius for wrong mental models.
- **Effort 4** because the In-file-layout and Data-flow sections needed
  rebuilding from the current code, not just find/replace.
- **Fix (done):** rewrote §§ "What it is", "Data flow", "Schema", "In-file
  layout", and the polling cautions against the current code; the
  In-file-layout and Data-flow function lists were rebuilt from a verified
  inventory of the real functions/components. A one-line freshness note
  replaces the interim staleness banner.

### Dep1 — Runtime deps via CDN; pre-release pin `[Dependency]`
React/HTM load from `esm.sh`, `@motherduck/wasm-client@1.5.2-r.3` from
`jsdelivr/+esm`. There is no lockfile for runtime deps (they're CDN
URLs), and the wasm-client pin is a `-r.N` pre-release that has 404'd on
esm.sh before (documented in LABELING-STACK § cautions).
- **Justification:** a CDN outage or a yanked pre-release = app down, with no local fallback.
- **Fix:** vendor the three modules into the repo (or an `assets/` dir)
  and import locally; keeps the no-build-step property while removing the
  network SPOF. Revisit the pin against the npm registry when bumping.

### C2 — Orphaned boot-watchdog signal `[Code]`
`labeling-platform.html:1037` sets `window.__moduleStarted = true` with a
comment "Tell the boot watchdog (index <script>)". No watchdog script
reads it (none exists in the file).
- **Fix:** remove the line + comment, or re-add the watchdog it implies (a `setTimeout` in `<head>` that swaps the boot splash for an error if the module never starts — the original intent, and a genuinely useful UX guard if CDN imports stall).

### A3 — Single connection wedges on a bad statement `[Architecture]`
All queries serialize on one `MDConnection`. A prepared statement that
hits certain DuckDB-WASM failure modes (FK/NOT-NULL violation, bad param
type, `sha256(?)` into BLOB) **hangs the promise instead of throwing**,
and every later query queues behind it forever (RUNBOOK § Add/Change Rule
hangs). Current mitigations: JS-side hashing + `unhex`, NULL binding,
`withTimeout` on connect.
- **Fix (if it recurs):** wrap `evalPrepared` in a per-call timeout (like the connect path) so a wedge surfaces as an error and the UI can recover, rather than hanging silently. Effort 4 to do safely without breaking legitimate slow queries.

### T2 — No CI; manual deploy promote `[Infrastructure]`
No CI workflow. Deploys can build green but not promote to the
production alias (RUNBOOK § Vercel shows old code).
- **Fix:** a minimal GitHub Action (HTML lint / link-check on the docs)
  + document/automate the promote step. Low effort, catches the broken-link class early.

### C3 — `confidence` plumbed but unrendered `[Code]`
`getClassificationPredictions` reads `confidence` (`:1397`, `:1424`) into
each prediction, but no component displays it.
- **Fix:** render it in the LLM-Judge box, or drop it from the query. Trivial; likely left as a stub for a future surface.

### A1 — Token shipped to the browser `[Architecture/Security] — ACCEPTED, documented`
`config.js` / `.env` deliver the MotherDuck token to every authenticated
visitor; the only gate is Basic Auth (`middleware.js`) with a hardcoded
default password `'ritw'`. A leaked password = `view-source` = a working
read-write MotherDuck token. Well-documented in README and LABELING-STACK
with the recommended mitigations (Cloudflare Access SSO, narrowly-scoped token).
- **Status:** acceptable for the current internal/demo use; **must** be
  addressed (SSO + scoped token, ideally a server-side query proxy so the
  token never reaches the client) before any non-demo exposure.

### A4 — `'reject'` ENUM value unreachable from UI `[Code/Schema]`
`label_decision` includes `'reject'`; the UI writes only `accept`/`skip`.
- **Fix:** add a Reject control if the workflow needs it, or note in the contract that reject is reserved/unused. Decide intent first.

### A2 — DDL types vs prod types `[Architecture] — INTRINSIC, documented`
The `CREATE TABLE IF NOT EXISTS` DDL uses portable types (VARCHAR/JSON);
prod uses UUID/VARCHAR[]/ENUM/BLOB. `IF NOT EXISTS` is a no-op against
prod, so all read/write code must target prod types. This is by design
and thoroughly covered in [DATA-LAYER.md](DATA-LAYER.md); the cost is a
permanent cast-at-the-boundary discipline.
- **Status:** intrinsic to the "single file, runs against a fresh local
  DuckDB *or* prod" goal. Keep the DATA-LAYER guidance current; no fix planned.

### T1 — No tests `[Test] — ACCEPTED`
No test files, no harness. All five save-path bugs in the runbook shipped
and were caught by hand. Genuinely hard to test (browser + WASM + live
MotherDuck).
- **Fix (if it grows):** extract the pure helpers (`parseEnv`,
  `stableStringify`, `parseJsonField`, `sha256Hex`, `githubBlobUrl`) into
  a tiny module and unit-test those; they're where the wrapper-shape bugs live.

## Phased remediation plan

**Phase 0 — quick wins (<1 hr total, do alongside any PR).**
Done in this audit: D3 (README), D4 (DATA-LAYER/RUNBOOK surgical fixes).
The interim D1/D2 staleness banners have since been replaced by full
rewrites (Phase 1, done). Remaining, all low-risk code edits:
- D5 — expose `window.__evalQuery`/`__evalPrepared` (makes the docs true).
- C1 — delete the four dead hooks.
- C2 — remove the orphaned `__moduleStarted` line (or restore a real watchdog).

**Phase 1 — restore the design docs (this sprint).**
- D2 — **done:** `LABELING.md` rewritten against the architecture snapshot.
- D1 — **done:** drifted sections of `LABELING-STACK.md` rewritten.
- Schema doc — **done:** trimmed the `rule` DDL in
  [`schema-v0.4.duckdb.sql`](schema-v0.4.duckdb.sql), dropping
  `created_by_labeler_id` / `last_edited_by_labeler_id` to match prod and
  the no-provenance Add-Rule decision (kept `last_edited_at`). RUNBOOK's
  "Notes flash back" entry was also reconciled — its ~2 s revert is now
  framed as the (since-removed) poll.
- A4 / C3 — decide intent for `reject` and `confidence`; reflect in docs/UI.

**Phase 2 — harden for non-demo use (before any wider exposure).**
- A1 — SSO in front + scoped token; ideally a server-side query proxy.
- Dep1 — vendor runtime deps locally.
- T2 — minimal CI (docs link-check + lint); automate Vercel promote.

**Backlog / accepted.**
- A3 — add `evalPrepared` timeout if the wedge class recurs.
- T1 — unit-test extracted pure helpers if the surface grows.
- A2 — intrinsic; keep DATA-LAYER guidance current.
