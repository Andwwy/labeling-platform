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
--   Crawler → rules_file → rule (.original_* + editable rule_text/lines)
--                                        ↓
--                                rule_llm_decision (4 axes)
--                                        ↓
--                            rule_extraction_label   (decision only)
--                                        ↓
--                            rule_classification_label  (predicted + edited 4 axes)
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
    UNIQUE (project_id, path, commit_sha)
);
CREATE INDEX rules_file_project_idx ON rules_file (project_id);
CREATE INDEX rules_file_sha_idx     ON rules_file (content_sha256);

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
--    them directly from the extraction page (real-time writes). The original
--    extractor output is frozen into original_rule_text / original_line_*
--    so extractor accuracy is still computable from data.
--
--    `created_by_labeler_id` flags rules that came from "add missing rule"
--    (labeler selects text in the .md viewer). For those, original_* equals
--    rule_text/line_* at insert time. The LLM judge runs on these the same
--    way it does on extractor-produced rules.
--
--    last_edited_at + last_edited_by_labeler_id audit who touched the rule
--    last. Used to surface "this rule changed since you labeled it" on
--    other labelers' existing extraction labels (compare against
--    rule_extraction_label.updated_at).
-- -----------------------------------------------------------------------------

CREATE TABLE rule (
    id                          UUID PRIMARY KEY DEFAULT uuid(),
    rules_file_id               UUID NOT NULL REFERENCES rules_file(id),
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
    -- "Add missing rule" provenance. NULL = extractor-produced.
    created_by_labeler_id       UUID REFERENCES labeler(id),
    -- NULL until a labeler edits rule_text / line_start / line_end.
    last_edited_at              TIMESTAMPTZ,
    last_edited_by_labeler_id   UUID REFERENCES labeler(id),
    UNIQUE (rules_file_id, original_line_start, original_line_end)
);
CREATE INDEX rule_sha_idx        ON rule (rule_text_sha256);
CREATE INDEX rule_rules_file_idx ON rule (rules_file_id);

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
-- -----------------------------------------------------------------------------

CREATE TABLE rule_classification_label (
    rule_id                  UUID NOT NULL REFERENCES rule(id),
    labeler_id               UUID NOT NULL REFERENCES labeler(id),
    predicted_decision_id    UUID NOT NULL REFERENCES rule_llm_decision(id),
    predicted_snapshot_hash  BLOB NOT NULL,
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
-- 8. Ops / observability — unchanged from v0.3
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
