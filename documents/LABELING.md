# Labeling Platform — Functionality (v0.4)

> Current as of commit `5e42121` (2026-05-28). For the data layer and
> debugging see [DATA-LAYER.md](DATA-LAYER.md) and [RUNBOOK.md](RUNBOOK.md);
> for the stack, config, and deployment see
> [LABELING-STACK.md](LABELING-STACK.md).

The labeling platform is the human-in-the-loop review tool for the
rules-in-the-wild pipeline. It sits between two pipeline steps — extraction
(pulling individual rules out of agent rulebooks like `AGENTS.md`, `CLAUDE.md`,
`.cursorrules`) and classification (an LLM judge assigning each rule along a
taxonomy) — and lets reviewers confirm, edit, or correct what the machine
produced.

v0.4 ships as a single-file static [`labeling-platform.html`](../labeling-platform.html)
that talks directly to MotherDuck from the browser via `@motherduck/wasm-client`.
See [LABELING-STACK.md](LABELING-STACK.md) for the stack, config, and Vercel
deployment notes.

## What changed in v0.4

| Area | v0.3 / prototype | v0.4 |
|---|---|---|
| Decision states | `accept` · `correct` · `reject` · `skip` | `accept` · `skip` written by the UI (`reject` reserved in the enum, no control); correct is implicit — see below |
| Extraction edits | Stored as `corrected_rule_text` / `corrected_start_line` / `corrected_end_line` on the label row | **`UPDATE rule.rule_text` directly** (Change Rule); the line range stays as extracted |
| Original extractor output | Lost on edit | Preserved in `rule.original_*` columns (frozen at insert) |
| Label identity | `target_key = sha256(document\|lines\|text)` | `(rule_id, labeler_id)` compound PK |
| View | Per-labeler isolation; "my labels" only | **Shared multi-labeler view** — every labeler sees every other labeler's decisions on the same rule |
| Classification taxonomy | 7 enums (specificity, cognitive_load, …) | **4 fields per PDF spec** — prerequisites, enforcement_mechanisms, triggers, ambiguity (level + notes) |
| Free-form notes | `notes` column on both tables | Removed — only `corrected_ambiguity_notes` survives (concrete by construction) |
| Save model | "Save" button per item | **Explicit Save Classification button** — one `INSERT … ON CONFLICT`; extraction edits persist on change |
| Add missing rule | Separate panel below decision buttons | **`Add Rule` button → centered modal** (rule text + note + 4 axes) |
| Source link | None | **GitHub blob link** in detail header |
| Rule body on classification | Editable | Read-only (edit it on the Extraction page) |
| Cross-labeler refresh | Manual reload | **Refresh on load, document switch, after a mutation, and the top-bar refresh button** (no background poll) |

The "correct" decision disappears because changes are recoverable from data:
compare `rule.rule_text` to `rule.original_rule_text`, or check whether any
`corrected_*` column on the classification label is non-null. No explicit
"correct" state is needed.

## Where it sits in the stack

```
                 GitHub repos
                      │
                      ▼
           ┌──────────────────────┐
           │  crawling-agent      │   discovers + extracts + embeds
           │  (Streamlit, :8501)  │   rules into `rule`, `rules_file`,
           └──────────┬───────────┘   `source_project`, etc.
                      │
                      ▼
           ┌──────────────────────┐
           │  judge-agent         │   LLM-classifies each rule into
           │  (FastAPI, :8503)    │   `rule_llm_decision`
           └──────────┬───────────┘
                      │
                      ▼
           ┌──────────────────────────────────────┐
           │  labeling-platform.html              │
           │   (static, browser → MotherDuck      │
           │    via @motherduck/wasm-client)      │
           └──────────────────────────────────────┘
```

The HTML:
- **Reads** from `rules_file`, `rule`, `source_project`, `rule_llm_decision`
- **Writes** to `rule` (Change Rule edits + add-missing-rule), `rules_file`
  (the `missed_rules` log), `labeler`, `rule_extraction_label`,
  `rule_classification_label`

## The two pages

The UI has two top tabs — **Extraction** and **Classification** — that
correspond to the two questions a labeler is asked. Both share the same
top-bar identity picker (your labeler handle); each page keeps its own
filter row (Extraction filters the file list; Classification filters by
your label status).

### Extraction page

**The question:** is this the right rule, with the right text and line range,
extracted from this source file?

Layout: three panes.

- **Left sidebar** — the file picker: a search box, an `All` / `Extracted`
  filter, and one row per source file with a rule-count badge. Selecting a file
  loads its rules.
- **Center viewer** — the source `.md` rendered with line numbers. Lines any
  rule was extracted from are tinted green; the currently selected unit-or-rule
  span is highlighted yellow. The header carries the filename, breadcrumb, and a
  **`View on GitHub`** link (`canonical_url/blob/{commit_sha}/{path}`); a status
  bar shows the line count and, when you drag-select text, the selected line
  range.
- **Right panel — "Extracted Rules"** — the review queue, **grouped into source
  units** (see [Source units](#source-units)).

**The queue is two-level.** Each rule is bucketed into the source block it came
from. A unit row shows a source snippet, its `Lines a–b` range, and an
`n/m labeled` rollup (how many of its rules you hold an extraction label on);
expanding it lists the rule rows. The header meta reads `N rules · M units`, and
a **`Show empty units`** toggle reveals blocks that produced no rules.

**A rule row** shows the normalized `rule_text` and its own line range, and
expands to:

- the rule's UUID,
- **Change Rule** — edits the rule text in place (the line range stays as
  extracted — there are no line-number inputs); the change is written straight
  to `rule` and bumps `last_edited_at`,
- **Delete** — hard-removes the rule and everything that references it: its
  `rule_classification_label`, `rule_extraction_label`, and `rule_llm_decision`
  children first, then the `rule` row itself (children-first so the FK delete
  can't hang the wasm connection).

Selecting or expanding a unit highlights its whole block span; selecting a child
rule highlights only that rule's `line_start`–`line_end` span. Clicking a green
rule-line in the viewer selects the matching rule and opens its unit.

**Add missing rule.** Two entry points open the same centered modal: the
panel-level **`Add Rule`** button (scoped to a drag-selection in the viewer, if
any) and the **`+`** on any unit row (scoped to that unit's line range — the
affordance for the empty units the toggle reveals). The modal collects the rule
text, a free-text *note*, and the four classification axes (filled manually —
there is no LLM call). On confirm it inserts a new row into the pipeline's
`rule` table, **reusing the file's existing `extractor_version`** so a
human-added rule is indistinguishable from an extracted one (no separate
human-vs-LLM provenance), auto-accepts the extraction on your behalf, writes the
axes as your `corrected_*` classification label (`decision='accept'`), and
appends a one-line `[skipped_rule] …` record to the source file's
`rules_file.missed_rules` column.

### Classification page

**The question:** are the LLM judge's four axis values right for this rule?

Same master-detail shell, with the **rule body shown as read-only** — if
boundaries or text need editing, that's the Extraction page's job. The
latest `parse_ok=TRUE` prediction from `rule_llm_decision` is shown
read-only in an **LLM Judge** box; the four editable correction fields
below start blank (no pre-fill):

- **Prerequisites** — multi-line list ("what info is needed to enforce")
- **Enforcement mechanisms** — multi-line list ("linter", "regex", "LLM", "bash"…)
- **Triggers** — multi-line list ("session_init", "verify_gate", "post_exec"…)
- **Ambiguity** — level dropdown `{none, low, medium, high}` + a free-text
  "what specifically is ambiguous?" note

The page commits via an explicit **Save Classification** button: one
`INSERT … ON CONFLICT` that writes every `corrected_*` axis plus
`decision='accept'` in a single round-trip. A **Skip** button writes
`decision='skip'`. There is no Reject control and no labeler-badge row.

## Source units

A *source unit* is the contiguous source block a rule was extracted from — a
single line if the rule came from one line, the whole paragraph if it came from
a paragraph. Units are **derived in the browser**, not stored: `deriveSourceUnits`
segments the file's `rules_file.document_text` into blocks and buckets each rule
into the block that contains its `line_start`.

**Why group.** Extraction *normalizes* each rule into a directive (see
[`../../extraction_guide.md`](../../extraction_guide.md)), so `rule_text` no
longer matches the source verbatim, and a single source line or paragraph can
yield several rules (compound splitting). A flat rule queue hides that
provenance. Grouping the queue by the source span each rule came from lets a
reviewer (a) see every rule a paragraph produced side by side, (b) spot
over-splitting, and (c) spot **missed** rules — a source block with no extracted
rule under it is the signal.

**Segmentation.**

- Split the document into blocks on blank lines.
- A fenced ```` ``` ```` … ```` ``` ```` block is one block.
- A **heading anchors a unit**: a markdown heading (`#…`) or a standalone bold
  label like `**PR Creation Checklist:**` starts a new unit, and everything
  beneath it — paragraphs, list / numbered items, fenced blocks — belongs to that
  unit until the next heading. A heading-delimited list is **one** unit, not
  one-per-item (a 7-item checklist = one unit with 7 child rules).
- In a region with no enclosing heading, split on blank lines into paragraph
  blocks.
- Assign rule → unit by `line_start` containment, falling back to the nearest
  preceding unit. Two rules split from the same line share a unit; rules from the
  same section share a unit even when their per-rule line ranges differ.

**No schema change** — `rules_file.document_text` plus `rule.line_start` /
`rule.line_end` are enough, computed in the browser. The per-rule
`line_start`/`line_end` is the *minimal* span of that one rule, used for the
yellow highlight; the *unit* is the enclosing block. The two coexist — units are
derived for grouping, the per-rule span still drives the highlight.

**The two-level queue** (right panel of the Extraction page):

- Top level: one collapsible row per source unit, in document order — a source
  snippet, the unit's `Lines a–b` range, a `+` to add a rule scoped to the unit,
  and an `n/m labeled` rollup (how many of the unit's rules you hold an
  extraction label on). Empty units show `no rules` instead of a rollup.
- Expanding a unit lists its extracted rules (the normalized `rule_text`s), each
  selectable.
- A **`Show empty units`** toggle reveals source blocks that produced *no* rules
  — the affordance for catching missed rules. Their `+` opens the Add Rule modal
  prefilled with the block's line range and source text.

**Selection / highlighting.**

- Selecting a child rule highlights its own `line_start`–`line_end` span in the
  viewer.
- Selecting or expanding a unit highlights the whole block span.
- Clicking a green rule-line in the viewer selects the matching rule and opens
  its unit. Highlight priority: a pending drag-selection, then the expanded
  rule, then the active unit.

**Notes.**

- A rule whose span crosses a block boundary is assigned by `line_start`.
- Because extraction has no per-rule accept control (only `Add Rule`
  auto-accepts), rollups usually read `0/n` — an honest reflection of the
  workflow.
- Units are derived, not stored, so the view survives pipeline re-runs the same
  way the flat queue does.

**Not in scope:** the Classification page (stays flat — it operates per rule),
reordering rules within a unit, and merging rules across units.

## Decision model

The three values of the `Decision` literal map to the same write contract
on both pages:

| Decision | Meaning |
|---|---|
| `accept` | The current state (including any edits I made) is right |
| `reject` | This isn't a real rule (extraction) / can't be classified on these axes (classification) |
| `skip` | Defer — I'm not deciding now |

Only `accept` and `skip` are reachable from the UI today: extraction
auto-writes `accept` when you add a rule, and classification's Save / Skip
buttons write `accept` / `skip`. `reject` stays in the `label_decision`
enum but has no control yet.

"Did this labeler change anything?" is computed from data, not stored as
a label state:

- **Extraction**: `rule.rule_text != rule.original_rule_text` (line ranges
  are no longer editable, so they always match the extractor's).
  `rule.last_edited_at` records when the body was last changed.
- **Classification**: any of `corrected_prerequisites`,
  `corrected_enforcement_mechanisms`, `corrected_triggers`,
  `corrected_ambiguity_level`, `corrected_ambiguity_notes` is non-null.

## Per-(rule, labeler) compound key

Every label table is keyed by `(rule_id, labeler_id)`:

- `rule_extraction_label (rule_id, labeler_id, decision, …)`
- `rule_classification_label (rule_id, labeler_id, predicted_*, corrected_*, decision, …)`

This survives pipeline re-runs the same way `target_key` did in the v0.3
design — `rule.id` is stable once a rule exists, and crawl re-runs are
upserts against the same row. The compound PK explicitly supports
multiple labelers having their own row per rule. Reads do NOT filter by
labeler, so every labeler sees every other labeler's decisions side by
side.

## `predicted_snapshot_hash` — detecting prediction drift

The classification label row freezes `predicted_decision_id` (the
`rule_llm_decision.id` that was on screen when the row was created) and
`predicted_snapshot_hash` (SHA-256 of the stable-stringified axes). If
the judge later re-classifies the same rule and the new axes hash
differently, an offline tool can flag the existing labels as "made
against stale predictions" — surfacing has not yet shipped in the UI but
the data is there.

## Storage schema

The labeling app owns three tables:

- **`labeler`** — `(id UUID PK, handle UNIQUE, display_name, created_at)`.
  Created when someone picks "Add new…" in the labeler dropdown.
- **`rule_extraction_label`** — `(rule_id, labeler_id) PK`, `decision`,
  timestamps. That's it — edits to the rule live on `rule`.
- **`rule_classification_label`** — `(rule_id, labeler_id) PK`,
  `decision`, `predicted_decision_id`, `predicted_snapshot_hash`, five
  `predicted_*` axis columns (frozen at row creation) mirrored by five
  `corrected_*` columns (NULL = "unchanged from prediction"), timestamps.

The `original_*` extractor output lives directly on the pipeline's `rule`
table (COALESCEd to the live values for older rows), so there is no
snapshot side-table. The full v0.4 DDL is in
[`schema-v0.4.duckdb.sql`](schema-v0.4.duckdb.sql).

## Running

```bash
cp .env.example .env
# paste your MotherDuck token into .env

# any static server works
python3 -m http.server 8765
# open http://localhost:8765/labeling-platform.html
```

The browser fetches `.env` on boot and connects to MotherDuck directly.
See [LABELING-STACK.md](LABELING-STACK.md) for caveats — token in cleartext,
wasm load time, ES modules require HTTP not `file://` — and for the
Vercel deployment story.

## What the labeling platform does *not* do

- **It does not re-run extraction or classification.** Those happen in the
  crawler / judge stacks. The UI only reads what's already in `rule` and
  `rule_llm_decision`. Rules without a `parse_ok=TRUE` decision don't
  appear in the extraction queue unless someone has already labeled them.
- **It does not handle live conflicts between concurrent editors of the
  same rule body.** Two labelers editing `rule.rule_text` simultaneously
  produce last-write-wins. A manual refresh surfaces the loser's stale
  view; there's no CRDT or merge.
- **It does not surface dedup of semantically-equivalent rules.** v0.3's
  `rule_semantic_cluster*` tables are intentionally deferred (PDF marks
  this TODO). When dedup ships, the v0.3 schema can be restored.
- **It does not surface `predicted_snapshot_hash` drift in the UI.** The
  hash is captured on every classification label row; an offline tool
  can flag stale labels but the UI doesn't yet.
- **It does not export labels.** Downstream consumers query the label
  tables directly via SQL.

These are scope boundaries, not bugs — each maps cleanly to a feature
you'd add if/when the workflow grew.
