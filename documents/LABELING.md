# Labeling Platform — Functionality (v0.4)

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
| Decision states | `accept` · `correct` · `reject` · `skip` | `accept` · `reject` · `skip` (correct is implicit — see below) |
| Extraction edits | Stored as `corrected_rule_text` / `corrected_start_line` / `corrected_end_line` on the label row | **UPDATE `rule.rule_text` / `line_start` / `line_end` directly** — real-time DB write |
| Original extractor output | Lost on edit | Preserved in `rule_original_snapshot` (lazy-backfilled side table) |
| Label identity | `target_key = sha256(document\|lines\|text)` | `(rule_id, labeler_id)` compound PK |
| View | Per-labeler isolation; "my labels" only | **Shared multi-labeler view** — every labeler sees every other labeler's decisions on the same rule |
| Classification taxonomy | 7 enums (specificity, cognitive_load, …) | **4 fields per PDF spec** — prerequisites, enforcement_mechanisms, triggers, ambiguity (level + notes) |
| Free-form notes | `notes` column on both tables | Removed — only `corrected_ambiguity_notes` survives (concrete by construction) |
| Save model | "Save" button per item | **Real-time field-level upserts**, debounced 400 ms |
| Add missing rule | Separate panel below decision buttons | **Text-select on the `.md` viewer** → "Add as rule" banner appears |
| Source link | None | **GitHub blob link** in detail header |
| Rule body on classification | Editable | Read-only (edit it on the Extraction page) |
| Cross-labeler refresh | Manual reload | **Polling every 2 s** while a page is open |

The "correct" decision disappears because edits are now direct writes: when
a labeler edits `rule.rule_text` or a `corrected_*` axis, the change is
immediately persisted. "Did anyone change anything?" is recoverable by
comparing `rule.rule_text` to `rule.original_rule_text`, or by checking
whether any `corrected_*` column is non-null.

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
- **Writes** to `rule` (direct edits + add-missing-rule), `labeler`,
  `rule_extraction_label`, `rule_classification_label`,
  `rule_original_snapshot`, `rule_edit_pointer`

## The two pages

The UI has two top tabs — **Extraction** and **Classification** — that
correspond to the two questions a labeler is asked. Both share the same
top-bar identity picker (your labeler handle), document filter, and
status filter.

### Extraction page

**The question:** is this the right rule, with the right text and line range,
extracted from this source file?

Layout: master-detail. Left = a queue of rules in the selected document,
filterable by `Unlabeled by me` / `All` / `Labeled by me`. Right = the
selected rule, with:

- A header with the document name, **`View on GitHub`** link
  (`canonical_url/blob/{commit_sha}/{path}`), line range, and an `edited`
  pill if the rule body has been changed from the extractor's original
- The source `.md` rendered with line numbers, with the rule's current
  lines highlighted (plus four lines of context)
- **Editable rule text** + start/end line — every blur/keystroke
  (debounced 400 ms) issues `UPDATE rule …`. The change shows up on
  every other labeler's screen on the next 2-second poll
- Three decision buttons: **Accept · Reject · Skip**
- A row of "labeler badges" showing every labeler who has decided on
  this rule, color-coded by their verdict (your own badge is outlined)

**Add missing rule.** No dedicated panel. Select text inside the rendered
source view → a small green banner appears with the selected text and
line range → click `+ Add as rule`. That inserts a new row into the
pipeline's `rule` table (`extractor_version = 'human:add_missing_rule'`),
snapshots its body into `rule_original_snapshot`, and auto-accepts on
your behalf. The new rule shows up in everyone's queue on the next poll.

### Classification page

**The question:** are the LLM judge's four axis values right for this rule?

Same master-detail shell, with the **rule body shown as read-only** — if
boundaries or text need editing, that's the Extraction page's job. The
four axes are pre-filled from the latest `parse_ok=TRUE` row in
`rule_llm_decision` and are independently editable:

- **Prerequisites** — multi-line list ("what info is needed to enforce")
- **Enforcement mechanisms** — multi-line list ("linter", "regex", "LLM", "bash"…)
- **Triggers** — multi-line list ("session_init", "verify_gate", "post_exec"…)
- **Ambiguity** — level dropdown `{none, low, medium, high}` + a free-text
  "what specifically is ambiguous?" note

Every edit fires a debounced field-level `UPDATE rule_classification_label
SET corrected_<field> = ?` — no per-row Save button. The decision row
below the fields has the same `Accept · Reject · Skip` buttons + the
labeler badges showing everyone's classification verdicts.

## Decision model

The three values of the `Decision` literal map to the same write contract
on both pages:

| Decision | Meaning |
|---|---|
| `accept` | The current state (including any edits I made) is right |
| `reject` | This isn't a real rule (extraction) / can't be classified on these axes (classification) |
| `skip` | Defer — I'm not deciding now |

"Did this labeler change anything?" is computed from data, not stored as
a label state:

- **Extraction**: `rule.rule_text != rule.original_rule_text` or
  `rule.line_start != rule.original_line_start` or `rule.line_end != rule.original_line_end`.
  Plus `rule_edit_pointer` says who touched it most recently.
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

The labeling app owns five tables:

- **`labeler`** — `(id UUID PK, handle UNIQUE, display_name, created_at)`.
  Created when someone picks "Add new…" in the labeler dropdown.
- **`rule_extraction_label`** — `(rule_id, labeler_id) PK`, `decision`,
  timestamps. That's it — edits to the rule live on `rule`.
- **`rule_classification_label`** — `(rule_id, labeler_id) PK`,
  `decision`, `predicted_decision_id`, `predicted_snapshot_hash`, six
  `predicted_*` columns (frozen at row creation), five `corrected_*`
  columns (real-time editable; NULL = "unchanged from prediction"),
  timestamps.
- **`rule_original_snapshot`** — `(rule_id PK, original_rule_text,
  original_line_start, original_line_end, snapshotted_at)`. Mirrors what
  the pipeline's `rule` row looked like the first time we saw it.
  Lazy-backfilled on every read.
- **`rule_edit_pointer`** — `(rule_id PK, labeler_id, last_edited_at)`.
  The most recent editor of a rule's body, kept as a single row per rule
  so reads don't need a window function across an event log.

The full v0.4 DDL is in [`schema-v0.4.duckdb.sql`](schema-v0.4.duckdb.sql).

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
  produce last-write-wins. The 2 s polling will surface the loser's stale
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
