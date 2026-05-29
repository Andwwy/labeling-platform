-- =============================================================================
-- Rules-in-the-Wild — DuckDB / MotherDuck schema (v0.4, 2026-05-27)
--
-- v0.4 is a clean-slate redesign of v0.3 in three dimensions:
--   1. Schema sprawl: drops 9 legacy/aspirational tables (extracted_rules,
--      extraction_runs, classification_runs, classified_rules,
--      source_documents, crawl_settings, app_users, plus a `rule_human_label`
--      that the actual app never wrote to).
--   2. Labeling shape: two per-(rule, labeler) label tables matching the PDF
--      spec — rule_extraction_label and rule_classification_label. Internal
--      tool, so reads aren't filtered by labeler_id; everyone sees everyone's
--      labels in the UI. Each labeler still owns their own row per rule.
--   3. Real-time-write model: rule text/line edits on the extraction page
--      update the `rule` row directly (not stored as a label override). The
--      label table only carries the {accept,reject,skip} decision. The
--      original extractor output is preserved on `rule.original_*` columns
--      so extractor edit-distance metrics stay computable.
--
-- Pipeline:
--   Crawler → rules_file → source_block (segmented spans)
--                                        ↓
--                          rule (.original_* + editable rule_text/lines,
--                                source_block_id, extraction_reason)
--                                        ↓
--                                rule_llm_decision (4 axes)
--                                        ↓
--                            rule_extraction_label   (decision only)
--                                        ↓
--                            rule_classification_label  (predicted + edited 4 axes)
--
--   Human annotation (orthogonal to the pipeline):
--     rule_comment / source_block_comment — free-text notes a labeler attaches
--     to a rule or a source block; each comment is joined to its labeler.
--
-- ADDENDUM (2026-05-28): re-extraction redesign.
--   The single-rules-per-file set is being dropped and re-extracted by the
--   crawler from rules_file.raw_content. Four changes support the new flow:
--     1. rule.extraction_reason — the extractor now emits a short reason for
--        WHY a span is a rule (shown on the extraction page).
--     2. source_block — the markdown segmentation (previously derived only in
--        the browser) is now a first-class table, so a block has stable
--        identity, an EDITABLE line range (original_* frozen), and a 1-to-many
--        link to the rules extracted from it (rule.source_block_id).
--     3. rule_comment / source_block_comment — labelers can comment on a rule
--        OR a source block; the comment ties back to the labeler (joint).
--     4. rule.rule_type ('rule' vs 'context') + rule.execution_guidance — the
--        extractor now tags whether a span is a directive or project/action
--        context, and keeps the "how" (execution guidance) beside the directive.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. Enums (taxonomy + workflow)
-- -----------------------------------------------------------------------------

-- Provenance of a rules_file: which agent-instruction convention it is.
CREATE TYPE rules_file_kind AS ENUM (
    'claude_md',                   -- CLAUDE.md, .claude/*.md
    'agents_md',                   -- AGENTS.md
    'cursor_rules',                -- .cursorrules, .cursor/rules/*.mdc
    'windsurf_rules',              -- .windsurfrules
    'aider_conventions',           -- CONVENTIONS.md, .aider.conf.yml
    'cline_rules',                 -- .clinerules
    'copilot_instructions',        -- .github/copilot-instructions.md
    'continue_rules',              -- .continue/rules
    'llms_txt',                    -- llms.txt
    'system_prompt_repo',
    'awesome_list',
    'vendor_doc',
    'claude_marketplace_manifest',
    'claude_plugin_manifest',
    'claude_plugin_command',
    'claude_plugin_agent',
    'claude_plugin_skill',
    'claude_plugin_hook_config',
    'other'
);

-- Three labeling decisions on both phases. Drops 'correct' from the v0.3
-- prototype's four-state literal: with real-time direct edits, "correct" is
-- implicit (= the labeler edited something). Decisions are now just
-- {accept, reject, skip}; the "did the labeler change anything" signal is
-- recoverable by comparing `rule.rule_text` vs `rule.original_rule_text`
-- (extraction) or checking `corrected_*` IS NOT NULL (classification).
CREATE TYPE label_decision AS ENUM ('accept','reject','skip');

-- Ambiguity is the 4th classification axis. Level is the structured signal
-- (used in metrics + filtering); ambiguity_notes (TEXT, in the label table)
-- carries the "what specifically is ambiguous" the PDF asks for.
CREATE TYPE ambiguity_level AS ENUM ('none','low','medium','high');

-- Whether an extracted span is a normative RULE the agent must follow, or
-- project/action CONTEXT that informs behavior without itself being a directive.
-- Context is extracted + tagged (not dropped) so labelers see the distinction.
CREATE TYPE rule_type AS ENUM ('rule','context');

-- Append-only history for the judge — same shape as v0.3.
CREATE TYPE judge_decision_trigger AS ENUM (
    'initial',
    'prompt_revised',
    'human_disagreed',
    'manual_rerun'
);

CREATE TYPE ingestion_status AS ENUM ('queued','running','succeeded','failed','partial');

-- -----------------------------------------------------------------------------
-- 2. Source provenance
-- -----------------------------------------------------------------------------

CREATE TABLE source_project (
    id              UUID PRIMARY KEY DEFAULT uuid(),
    host            TEXT NOT NULL,
    owner           TEXT NOT NULL,
    name            TEXT NOT NULL,
    canonical_url   TEXT NOT NULL UNIQUE,
    first_seen_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    last_crawled_at TIMESTAMPTZ
);

CREATE TABLE rules_file (
    id              UUID PRIMARY KEY DEFAULT uuid(),
    project_id      UUID NOT NULL REFERENCES source_project(id),
    path            TEXT NOT NULL,
    kind            rules_file_kind NOT NULL,
    commit_sha      TEXT,
    raw_content     TEXT NOT NULL,
    content_sha256  BLOB NOT NULL,
    byte_size       INTEGER NOT NULL,
    fetched_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    -- Appended log of rules the extractor MISSED. The labeling UI's "Add
    -- Rule" flow lets a human flag a rule the agent failed to extract; each
    -- such addition appends a one-line "[skipped_rule] …" record here (the
    -- app ALTERs this column in on boot, so it may be absent on older DBs).
    missed_rules    TEXT,
    UNIQUE (project_id, path, commit_sha)
);
CREATE INDEX rules_file_project_idx ON rules_file (project_id);
CREATE INDEX rules_file_sha_idx     ON rules_file (content_sha256);

-- A source_block is one segmented span of a rules_file (a heading, a list
-- item, a paragraph, a fenced code block). The crawler emits these alongside
-- the rules it extracts; each rule points at the block it came from
-- (rule.source_block_id), giving an explicit block→rule (1-to-many) relation
-- instead of the browser-only line-containment heuristic.
--
-- line_start / line_end are LIVE editable (a labeler can widen/narrow a block
-- on the extraction page); original_line_* freeze the segmenter's output and
-- double as the natural anchor for re-matching a block across re-segmentation.
--
-- WHY NON-UNIQUE (rules_file_id, original_line_start, original_line_end):
--   The extraction guide (§3.2, §6.2) splits a compound single line into
--   multiple rules — and their blocks — that can share ONE line range. A UNIQUE
--   constraint would reject the second one. It's also a DuckDB-WASM foot-gun:
--   WASM HANGS the connection on a constraint violation instead of throwing, so
--   the platform pre-checks in JS rather than relying on the constraint. A plain
--   index gives the lookup speed without the collision.
CREATE TABLE source_block (
    id                  UUID PRIMARY KEY DEFAULT uuid(),
    rules_file_id       UUID NOT NULL REFERENCES rules_file(id),
    kind                TEXT,            -- heading | list_item | paragraph | code
    line_start          INTEGER NOT NULL,   -- LIVE editable
    line_end            INTEGER NOT NULL,   -- LIVE editable
    original_line_start INTEGER NOT NULL,   -- frozen segmenter output (natural anchor)
    original_line_end   INTEGER NOT NULL,
    snippet             TEXT,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    last_edited_at      TIMESTAMPTZ         -- NULL until a labeler edits the range
);
CREATE INDEX source_block_file_idx      ON source_block (rules_file_id);
CREATE INDEX source_block_origlines_idx ON source_block (rules_file_id, original_line_start, original_line_end);

-- -----------------------------------------------------------------------------
-- 3. Labeler identity (replaces app_users + the deferred labeler table)
-- -----------------------------------------------------------------------------

CREATE TABLE labeler (
    id            UUID PRIMARY KEY DEFAULT uuid(),
    handle        TEXT NOT NULL UNIQUE,        -- 'alice@example.com', shown in the dropdown
    display_name  TEXT,
    created_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- -----------------------------------------------------------------------------
-- 4. Extracted rule
--    rule_text / line_start / line_end are LIVE state — labelers can update
--    rule_text directly from the extraction page (Change Rule). The original
--    extractor output is frozen into original_rule_text / original_line_*
--    so extractor accuracy is still computable from data.
--
--    "Add missing rule" inserts an ordinary rule row: it reuses the file's
--    existing extractor_version (no separate human-vs-LLM provenance), and
--    original_* equals rule_text/line_* at insert time. The LLM judge runs
--    on these the same way it does on every other rule.
--
--    last_edited_at records when a labeler last edited the rule body (NULL
--    until first edit). Used to surface "this rule changed since you labeled
--    it" against rule_extraction_label.updated_at.
-- -----------------------------------------------------------------------------

CREATE TABLE rule (
    id                          UUID PRIMARY KEY DEFAULT uuid(),
    rules_file_id               UUID NOT NULL REFERENCES rules_file(id),
    -- The segmented source span this rule was extracted from (1 block → N
    -- rules). NULLABLE: hand-added rules and rules from pre-source_block
    -- extractions may not be linked; the UI falls back to line containment.
    source_block_id             UUID REFERENCES source_block(id),
    -- LIVE editable state
    rule_text                   TEXT NOT NULL,
    line_start                  INTEGER NOT NULL,
    line_end                    INTEGER NOT NULL,
    -- Frozen extractor output (set at insert, never updated)
    original_rule_text          TEXT NOT NULL,
    original_line_start         INTEGER NOT NULL,
    original_line_end           INTEGER NOT NULL,
    rule_text_norm              TEXT NOT NULL,
    rule_text_sha256            BLOB NOT NULL,
    section_anchor              TEXT,
    embedding                   FLOAT[1024],
    extracted_at                TIMESTAMPTZ NOT NULL DEFAULT now(),
    extractor_version           TEXT NOT NULL,
    -- The extractor's short justification for WHY this span is a rule. Set at
    -- extraction; frozen (not a labeler-editable field). NULL for hand-added
    -- rules (no model reason) and for pre-addendum extractions.
    extraction_reason           TEXT,
    -- Extractor classification: 'rule' (a normative directive the agent must
    -- follow) vs 'context' (project/action info that informs behavior but is
    -- not itself a directive). Frozen at extraction; 'rule' for hand-added rows.
    rule_type                   rule_type NOT NULL DEFAULT 'rule',
    -- The "how": execution guidance the source pairs with this rule (commands,
    -- steps, caveats), kept beside the normalized directive. Frozen; NULL if none.
    execution_guidance          TEXT,
    -- NULL until a labeler edits rule_text from the extraction page.
    last_edited_at              TIMESTAMPTZ
    -- NON-UNIQUE on (rules_file_id, original_line_start, original_line_end):
    -- a compound single line splits into several rules sharing one line range
    -- (extraction guide §3.2/§6.2), and DuckDB-WASM hangs on a UNIQUE violation.
    -- See "WHY NON-UNIQUE" on source_block above — same reasoning.
);
CREATE INDEX rule_sha_idx        ON rule (rule_text_sha256);
CREATE INDEX rule_rules_file_idx ON rule (rules_file_id);
CREATE INDEX rule_origlines_idx  ON rule (rules_file_id, original_line_start, original_line_end);

-- -----------------------------------------------------------------------------
-- 5. LLM judge decision — APPEND-ONLY HISTORY
--    Shrinks from v0.3's seven-axis taxonomy to the four fields the labeling
--    UI actually uses (per the PDF spec):
--      prerequisites        — TEXT[], free-form items per "what info is
--                             needed to enforce" (e.g. ['No information',
--                             'Bash', 'Repo'])
--      enforcement_mechanisms TEXT[], items like 'linter','regex','llm','bash'
--      triggers             — TEXT[], items like 'session_init',
--                             'settings.json','verify_gate','post_exec'
--      ambiguity_level      — enum  + ambiguity_notes (rationale, optional)
--    These are TEXT[] not enum[] because the PDF's examples are open-ended
--    free-form items — the labeling UI is a multi-line list, no enum lock-in.
--
-- FUTURE (deferred 2026-05-28): deterministic regex pre-classification. A regex
-- schema would match rule_text against patterns for rules that are
-- deterministically enforceable, auto-tag them 'enforced'/'solved' (rendered in
-- red in the UI), and short-circuit the LLM judge for that subset. Decision for
-- now: detect-and-ignore — do NOT act on a match yet; revisit when the
-- enforcement_mechanisms taxonomy stabilizes.
-- -----------------------------------------------------------------------------

CREATE TABLE rule_llm_decision (
    id                      UUID PRIMARY KEY DEFAULT uuid(),
    rule_id                 UUID NOT NULL REFERENCES rule(id),
    judge_model             TEXT NOT NULL,
    judge_prompt_version    TEXT NOT NULL,
    triggered_by            judge_decision_trigger NOT NULL,
    prompt_messages         JSON NOT NULL,
    raw_response            TEXT NOT NULL,
    parse_ok                BOOLEAN NOT NULL,
    parse_error             TEXT,
    -- Parsed classification (NULL when parse_ok = false)
    prerequisites           TEXT[],
    enforcement_mechanisms  TEXT[],
    triggers                TEXT[],
    ambiguity_level         ambiguity_level,
    ambiguity_notes         TEXT,
    confidence              REAL CHECK (confidence BETWEEN 0 AND 1),
    rationale               TEXT,
    -- Ops metadata
    latency_ms              INTEGER,
    input_tokens            INTEGER,
    output_tokens           INTEGER,
    created_at              TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX rule_llm_decision_rule_idx   ON rule_llm_decision (rule_id, created_at DESC);
CREATE INDEX rule_llm_decision_prompt_idx ON rule_llm_decision (judge_prompt_version);

-- -----------------------------------------------------------------------------
-- 6. EXTRACTION LABEL — phase 1 of labeling
--    Question: "Did the extractor correctly identify this text as a rule?"
--
--    Schema is tiny on purpose: the labeler edits rule.rule_text/line_*
--    directly (real-time writes), so the label only records the verdict.
--    The "was this corrected?" signal is computed from
--    `rule.rule_text != rule.original_rule_text` etc.
--
--    PK (rule_id, labeler_id): each labeler keeps their own decision per
--    rule. Reads aren't filtered by labeler — everyone can see everyone's
--    decisions in the UI (internal tool).
-- -----------------------------------------------------------------------------

CREATE TABLE rule_extraction_label (
    rule_id     UUID NOT NULL REFERENCES rule(id),
    labeler_id  UUID NOT NULL REFERENCES labeler(id),
    decision    label_decision NOT NULL,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (rule_id, labeler_id)
);
CREATE INDEX rule_extraction_label_labeler_idx ON rule_extraction_label (labeler_id, updated_at DESC);

-- -----------------------------------------------------------------------------
-- 7. CLASSIFICATION LABEL — phase 2 of labeling
--    Question: "Are the LLM judge's 4 axis values right for this rule?"
--
--    Real-time writes: as the labeler edits a field on the UI, the
--    corresponding corrected_* column updates immediately (debounced blur,
--    not per-keystroke). predicted_* is a frozen snapshot taken when the
--    row is first inserted, never touched again.
--
--    corrected_* IS NULL means "labeler hasn't touched this axis — use the
--    prediction." Non-null = labeler's explicit value.
--
--    Anchored to a specific rule_llm_decision (predicted_decision_id) so
--    prompt-iteration tooling can compute "which labels were made against
--    which prompt version." predicted_snapshot_hash flags drift when a
--    fresher rule_llm_decision exists with different axis values.
--
--    predicted_decision_id / predicted_snapshot_hash are NULLABLE: a rule can
--    be labeled even when it has NO LLM prediction (e.g. rules added by hand on
--    the extraction page, or accept-only rules the judge never scored). In that
--    case every predicted_* column is NULL and the labeler fills the axes from
--    scratch. They must stay nullable — a non-null fabricated/placeholder
--    predicted_decision_id would violate the FK to rule_llm_decision, and a
--    NULL FK value is exempt from the constraint. (DuckDB-WASM hangs the
--    prepared statement on such an FK violation rather than raising.)
-- -----------------------------------------------------------------------------

CREATE TABLE rule_classification_label (
    rule_id                  UUID NOT NULL REFERENCES rule(id),
    labeler_id               UUID NOT NULL REFERENCES labeler(id),
    predicted_decision_id    UUID REFERENCES rule_llm_decision(id),  -- NULL when the rule had no LLM prediction
    predicted_snapshot_hash  BLOB,                                   -- NULL when the rule had no LLM prediction
    decision                 label_decision NOT NULL DEFAULT 'skip',
    -- Frozen snapshot of the LLM prediction at row creation.
    predicted_prerequisites           TEXT[],
    predicted_enforcement_mechanisms  TEXT[],
    predicted_triggers                TEXT[],
    predicted_ambiguity_level         ambiguity_level,
    predicted_ambiguity_notes         TEXT,
    -- Labeler edits, real-time. NULL = unchanged from prediction.
    corrected_prerequisites           TEXT[],
    corrected_enforcement_mechanisms  TEXT[],
    corrected_triggers                TEXT[],
    corrected_ambiguity_level         ambiguity_level,
    corrected_ambiguity_notes         TEXT,
    created_at               TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at               TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (rule_id, labeler_id)
);
CREATE INDEX rule_classification_label_labeler_idx  ON rule_classification_label (labeler_id, updated_at DESC);
CREATE INDEX rule_classification_label_decision_idx ON rule_classification_label (predicted_decision_id);

-- -----------------------------------------------------------------------------
-- 8. Human annotations — free-text comments (rule & source block)
--    A labeler can leave one or more comments on a rule OR on a source block.
--    Each comment is a JOINT row tying the annotated entity to its labeler, so
--    "who said what about which rule/block" is queryable. Reads aren't filtered
--    by labeler (internal tool) — everyone sees everyone's comments, attributed.
--
--    These are append-style threads (own UUID PK, many per (entity, labeler)),
--    NOT a single decision row like the label tables. A labeler may edit/delete
--    their own comments (updated_at stamps edits).
-- -----------------------------------------------------------------------------

CREATE TABLE rule_comment (
    id          UUID PRIMARY KEY DEFAULT uuid(),
    rule_id     UUID NOT NULL REFERENCES rule(id),
    labeler_id  UUID NOT NULL REFERENCES labeler(id),
    body        TEXT NOT NULL,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX rule_comment_rule_idx    ON rule_comment (rule_id, created_at);
CREATE INDEX rule_comment_labeler_idx ON rule_comment (labeler_id);

CREATE TABLE source_block_comment (
    id          UUID PRIMARY KEY DEFAULT uuid(),
    block_id    UUID NOT NULL REFERENCES source_block(id),
    labeler_id  UUID NOT NULL REFERENCES labeler(id),
    body        TEXT NOT NULL,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX source_block_comment_block_idx   ON source_block_comment (block_id, created_at);
CREATE INDEX source_block_comment_labeler_idx ON source_block_comment (labeler_id);

-- -----------------------------------------------------------------------------
-- 9. Ops / observability — unchanged from v0.3
-- -----------------------------------------------------------------------------

CREATE TABLE ingestion_run (
    id              UUID PRIMARY KEY DEFAULT uuid(),
    started_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    finished_at     TIMESTAMPTZ,
    status          ingestion_status NOT NULL DEFAULT 'running',
    source_query    TEXT NOT NULL,
    projects_seen   INTEGER NOT NULL DEFAULT 0,
    files_fetched   INTEGER NOT NULL DEFAULT 0,
    rules_extracted INTEGER NOT NULL DEFAULT 0,
    rules_new       INTEGER NOT NULL DEFAULT 0,
    error_message   TEXT,
    crawler_version TEXT NOT NULL
);

CREATE SEQUENCE ingestion_event_id_seq START 1;
CREATE TABLE ingestion_event (
    id              BIGINT PRIMARY KEY DEFAULT nextval('ingestion_event_id_seq'),
    run_id          UUID NOT NULL REFERENCES ingestion_run(id),
    event_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
    level           TEXT NOT NULL CHECK (level IN ('debug','info','warn','error')),
    message         TEXT NOT NULL,
    payload         JSON
);

-- -----------------------------------------------------------------------------
-- DROPPED IN v0.4 (vs v0.3) — for reviewer reference:
--   Tables:
--     • extracted_rules, extraction_runs, classification_runs,
--       classified_rules, source_documents, crawl_settings, app_users
--       — unused legacy from prior pipeline iterations
--     • rule_human_label — never written to; replaced by rule_extraction_label
--       and rule_classification_label
--     • rule_semantic_cluster, rule_semantic_cluster_member — DEFERRED, not
--       deleted. PDF says dedup is "fixed by ???"; keep tables out of the
--       v0.4 file so they aren't part of the labeling contract. Restore from
--       v0.3 when dedup is back on the roadmap.
--   Views:
--     • rule_classification_current, rule_pending_review — no longer make
--       sense once labels are edited live and the UI is multi-labeler-shared.
--       Read endpoints query the label tables directly with the filters
--       they need.
--   Enums:
--     • rule_specificity, rule_cognitive_load, rule_constraint_level,
--       enforcement_scope, rule_kind, artifact_required — outside the
--       4-axis taxonomy
--     • enforcement_mechanism, enforcement_trigger (single-valued) — replaced
--       by enforcement_mechanisms TEXT[] / triggers TEXT[] (multi-valued)
--     • human_label_disposition, semantic_cluster_method
--     • The 'correct' value on label_decision — implicit now (= labeler
--       edited rule_text or any corrected_* axis)
-- -----------------------------------------------------------------------------
