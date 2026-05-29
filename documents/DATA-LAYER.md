# Labeling Platform — Data Layer

How the browser app talks to MotherDuck, what shape values take on each
side of the wire, and which SQL patterns work vs which silently fail.
Read this before adding a new query or column to
[`labeling-platform.html`](../labeling-platform.html).

For symptom-driven debugging when something breaks, see
[RUNBOOK.md](RUNBOOK.md). For the overall stack and config, see
[LABELING-STACK.md](LABELING-STACK.md).

## Two schemas

There are two definitions of the label tables, and they don't match.

### 1. The DDL in `labeling-platform.html`

Runs as `CREATE TABLE IF NOT EXISTS` on every connect. It uses
"portable" types — `VARCHAR` for IDs, `JSON` for list columns, plain
`VARCHAR` for enum-like fields:

```sql
CREATE TABLE IF NOT EXISTS rule_classification_label (
    rule_id                          VARCHAR NOT NULL,
    labeler_id                       VARCHAR NOT NULL,
    predicted_decision_id            VARCHAR,
    predicted_snapshot_hash          VARCHAR,
    decision                         VARCHAR NOT NULL DEFAULT 'skip',
    predicted_prerequisites          JSON,
    predicted_enforcement_mechanisms JSON,
    ...
);
```

### 2. The actual prod schema in MotherDuck (`md:rules_in_the_wild`)

Was created earlier by the pipeline's `schema-v0.4.duckdb.sql` and uses
stricter types — `UUID` for IDs, `VARCHAR[]` for lists, `ENUM` for
decisions, `BLOB` for the snapshot hash, with several NOT NULL
constraints the DDL doesn't have:

```sql
-- from information_schema.columns on prod
rule_id                          UUID                                 NOT NULL
labeler_id                       UUID                                 NOT NULL
predicted_decision_id            UUID                                          -- nullable in v0.4 (FK; NULL when no LLM prediction)
predicted_snapshot_hash          BLOB                                          -- nullable in v0.4 (NULL when no LLM prediction)
decision                         ENUM('accept', 'reject', 'skip')     NOT NULL
predicted_prerequisites          VARCHAR[]
predicted_enforcement_mechanisms VARCHAR[]
predicted_triggers               VARCHAR[]
predicted_ambiguity_level        ENUM('none', 'low', 'medium', 'high')
predicted_ambiguity_notes        VARCHAR
corrected_prerequisites          VARCHAR[]
corrected_enforcement_mechanisms VARCHAR[]
corrected_triggers               VARCHAR[]
corrected_ambiguity_level        ENUM('none', 'low', 'medium', 'high')
corrected_ambiguity_notes        VARCHAR
created_at                       TIMESTAMP WITH TIME ZONE             NOT NULL
updated_at                       TIMESTAMP WITH TIME ZONE             NOT NULL
PRIMARY KEY (rule_id, labeler_id)
```

`CREATE TABLE IF NOT EXISTS` is a no-op when the table already exists,
so the DDL never actually creates these tables in prod — it's a fallback
for a fresh MotherDuck database (or a local `*.duckdb` file). **All
read/write code in v0.4 has to work against the prod types**, not the
DDL types.

### Why this matters

DuckDB does a lot of implicit casting that hides the drift most of the
time. The places it doesn't, and where the app broke:

| Operation | DDL type | Prod type | Behavior |
|---|---|---|---|
| `SELECT id FROM labeler` | VARCHAR | UUID | Prod returns `{ bytes: [16 ints] }` instead of a string |
| `SELECT corrected_prerequisites` | JSON | VARCHAR[] | Prod returns an Arrow ListVector wrapper `{ values: [...] }` with `.toJson()` |
| `SELECT decision` | VARCHAR | ENUM | Prod returns the ENUM as a non-string (integer ordinal or wrapper) |
| `INSERT INTO ... predicted_decision_id` with a fabricated/nil UUID | n/a | nullable UUID **FK** | FK violation → prepared statement HANGS (never throws). Bind `NULL` when there's no prediction |
| `WHERE rule_id = ?` with bound string | works | works (implicit VARCHAR → UUID) | OK |
| `WHERE rule_id = ?` with bound UUID-wrapper object | n/a | `Invalid column type encountered for argument N` and the prepared statement HANGS the promise (never throws to JS) | Save button stuck on "Saving…" |
| `INSERT ... rule_text_sha256 = sha256(?)` (bound param) | n/a | `sha256()` is VARCHAR → NOT NULL BLOB | Prepared statement HANGS and wedges the connection. Literal `sha256('x')` works; only the bound-param form hangs. Hash in JS + `unhex(?)` instead |

The runbook entries each name the specific symptom these produce. This
doc is about the *patterns* that work.

## Reading rows

### Cast everything across the wire

Every UUID and ENUM column needs an explicit `::VARCHAR` in the SELECT,
or the JS-side value is a wrapper object that doesn't compare with
`===` to a plain string and can't be re-bound as a prepared-statement
parameter.

```sql
SELECT
  l.rule_id::VARCHAR              AS rule_id,
  l.labeler_id::VARCHAR           AS labeler_id,
  l.decision::VARCHAR             AS decision,
  l.predicted_decision_id::VARCHAR AS predicted_decision_id,
  l.predicted_ambiguity_level::VARCHAR AS predicted_ambiguity_level,
  l.corrected_ambiguity_level::VARCHAR AS corrected_ambiguity_level,
  l.predicted_prerequisites,
  l.corrected_prerequisites,
  ...
FROM rule_classification_label l
```

`VARCHAR[]` columns can be left untyped in the SELECT (they come back as
ListVectors, which `parseJsonField` unwraps below). `TIMESTAMP` columns
are also fine untyped — they come back as `Date` objects, which is
usually what you want.

### Unwrap list/JSON returns

`VARCHAR[]` and `JSON` columns return an Apache Arrow wrapper, not a
plain JS array. Use `parseJsonField` (or `toList` for predictions),
which handles every shape we've seen:

```js
function parseJsonField(value) {
  if (value === null || value === undefined) return null;
  if (typeof value === "string") {                      // local DDL JSON column
    try { return JSON.parse(value); } catch { return null; }
  }
  if (Array.isArray(value)) return value.map(String);   // already-plain array
  if (typeof value.toJson  === "function") return value.toJson().map(String);   // ListVector
  if (typeof value.toArray === "function") return Array.from(value.toArray()).map(String);
  if (Array.isArray(value.values)) return value.values.map(String);  // fallback
  return null;
}
```

If you skip the unwrap, the value reads as `null` and the UI falls back
to whatever default — typically the LLM prediction — making saves look
like silent no-ops. See [RUNBOOK § Save silently no-ops](RUNBOOK.md#save-silently-no-ops).

### Don't expose untyped UUIDs to JS

`r.rule_id` straight off the wire is the wrapper. If you put that into
a `Map` key, a React `key` prop, or a `===` comparison, it'll silently
break:

```js
//  WRONG: keys are object refs, no two are ever equal
const byId = new Map(rows.map(r => [r.rule_id, r]));

//  RIGHT: cast in SQL, key is a real string
//  SELECT id::VARCHAR AS id ...
const byId = new Map(rows.map(r => [r.id, r]));
```

## Writing rows

### Bind UUIDs as strings, cast in SQL

Every UUID parameter is bound as a JS string, and the SQL casts it with
`?::UUID`:

```sql
UPDATE rule_classification_label
SET decision = ?, updated_at = now()
WHERE rule_id = ?::UUID AND labeler_id = ?::UUID
```

```js
await evalPrepared(sql, [decision, ruleId, labelerId]);
```

The WASM client's binder does not have a representation for UUID
parameters. Binding the `{bytes: ...}` wrapper directly fails with
`Invalid column type encountered for argument N` — and in
`evaluatePreparedStatement`, **that failure hangs the promise instead
of throwing**. The button is stuck on "Saving…" and there is nothing in
the catch block to fire.

> If you've SELECT'd UUID columns without `::VARCHAR AS id`, you'll
> never know — the next prepared statement that uses the value will hang.
> Cast at the source.

### Bind VARCHAR[] as a JSON string, cast with from_json

The WASM binder also has no native VARCHAR[] parameter type. Build the
array as a JSON string and unpack with `from_json`:

```sql
UPDATE rule_classification_label
SET corrected_prerequisites = from_json(?, '["VARCHAR"]'),
    updated_at = now()
WHERE rule_id = ?::UUID AND labeler_id = ?::UUID
```

```js
await evalPrepared(sql, [
  JSON.stringify(["regex", "bash"]),  // ['"regex","bash"]' string
  ruleId, labelerId,
]);
```

The `'["VARCHAR"]'` argument to `from_json` is the **type spec** — a JSON
string that says "the input is a JSON array of strings". DuckDB parses
the bound string against that spec and produces a typed list.

There are two other patterns that *appear* to work but have failure
modes:

| Pattern | When it works | When it breaks |
|---|---|---|
| Bind a JS array directly | Never | WASM binder has no array parameter type |
| Bind a JSON string to a JSON column without cast | Local DDL (JSON columns) | Prod (VARCHAR[]) — the string gets stored as the literal text, reads back wrong shape |
| Inline `'[...]'::JSON` literal (escape quotes) | Both DDL and prod (implicit JSON → VARCHAR[] cast) | Hard to read, brittle if values contain quotes |
| `from_json(?, '["VARCHAR"]')` ← **canonical** | Both DDL and prod | — |

### BLOB columns: bind hex, cast with decode

`predicted_snapshot_hash` is BLOB. There's no BLOB parameter type for
hex/byte arrays. Use a hex string + `decode`:

```sql
INSERT INTO rule_classification_label (
    rule_id, labeler_id,
    predicted_decision_id, predicted_snapshot_hash,
    ...
) VALUES (
    ?::UUID, ?::UUID,
    ?::UUID, decode(?, 'hex'),
    ...
)
```

```js
const snapHash = await sha256Hex(stableStringify({
  prerequisites: pred.prerequisites,
  enforcement_mechanisms: pred.enforcement_mechanisms,
  triggers: pred.triggers,
  ambiguity_level: pred.ambiguity_level,
  ambiguity_notes: pred.ambiguity_notes,
}));
await evalPrepared(sql, [ruleId, labelerId, pred.decision_id, snapHash, ...]);
```

The hash is **not optional** — `predicted_snapshot_hash` is NOT NULL in
prod. Omitting it triggers the constraint-violation hang described
above. See [RUNBOOK § Save hangs forever](RUNBOOK.md#save-hangs-forever).

**Computing a hash for a BLOB column.** Don't compute it in SQL with
`sha256(?)`. `sha256()` returns VARCHAR, and routing a *bound parameter*
through it into a BLOB column hangs the prepared statement (and wedges the
connection) — the literal `sha256('x')` works, so this is easy to miss.
Hash in JS with `sha256Hex`, bind the hex string, and convert with
`unhex(?)`, which produces the same 32-byte digest prod stores
(`rule_text_sha256`):

```sql
rule_text_sha256 = unhex(?)        -- NOT sha256(?)
```

```js
await evalPrepared(sql, [..., await sha256Hex(ruleText), ...]);
```

`decode(sha256(?), 'hex')` does **not** work — DuckDB's `decode` is
BLOB→VARCHAR (the wrong direction) and throws a binder error. See
[RUNBOOK § Add/Change Rule hangs](RUNBOOK.md#addchange-rule-hangs).

### Include every NOT NULL column; bind NULL (never a placeholder) for the optional FK

The prod schema's NOT NULL columns:

- `rule_id`, `labeler_id` — UUID
- `decision` — ENUM (defaults to `'skip'` if omitted)
- `created_at`, `updated_at` — auto-default to `now()`

`predicted_decision_id` (UUID) and `predicted_snapshot_hash` (BLOB) are
**nullable** in v0.4 — `predicted_decision_id` is a FOREIGN KEY to
`rule_llm_decision(id)`, and hand-added or accept-only rules have no
decision row to point at (see the rationale in
[`schema-v0.4.duckdb.sql`](schema-v0.4.duckdb.sql) §7).

The "no prediction" branch in `saveClassificationLabel` /
`skipClassificationLabel` binds **`NULL`** to both — a NULL FK value is
exempt from the constraint. Do **not** substitute a fabricated/nil UUID
(`'00000000-...'::UUID`): that *violates* the FK, and DuckDB-WASM **hangs
the prepared statement** instead of throwing (the "stuck on Saving…" bug).
When `pred.decision_id` is falsy, every `predicted_*` value is bound NULL.

## The WASM client's silent-failure modes

Three failure modes don't throw to JS, in increasing order of
debuggability:

| Failure mode | Surface symptom | How to diagnose |
|---|---|---|
| Constraint violation in `evaluatePreparedStatement` | Promise hangs forever | Copy the SQL and run as a literal via `__evalQuery`, which throws normally |
| Bad parameter type binding | Promise hangs forever | Same — `__evalQuery` throws "Invalid column type encountered for argument N" |
| Implicit cast silently stores the wrong shape | Save succeeds, read-back returns null/wrong | Read the row back via `__evalQuery` in DevTools and inspect the wrapper |

Helpful DevTools snippets (both `__evalQuery` and `__evalPrepared` are
exposed on `window` in dev):

```js
// Show the actual columns + types on prod
await window.__evalQuery(`
  SELECT column_name, data_type, is_nullable
  FROM information_schema.columns
  WHERE table_name = 'rule_classification_label'
  ORDER BY ordinal_position
`);

// Show what a row actually looks like (wrappers and all)
const r = await window.__evalQuery(`
  SELECT corrected_prerequisites FROM rule_classification_label LIMIT 1
`);
console.log(r[0].corrected_prerequisites);
// e.g. ns { values: ['regex', 'bash'] }  — Arrow ListVector

// Force-throw a hanging prepared statement. The live hang is a fabricated
// predicted_decision_id with no matching rule_llm_decision row (FK violation):
await window.__evalQuery(`
  INSERT INTO rule_classification_label (rule_id, labeler_id, predicted_decision_id, decision)
  VALUES ('<rid>'::UUID, '<lid>'::UUID, '00000000-0000-0000-0000-000000000000'::UUID, 'skip')
`);
// → Constraint Error: Violates foreign key constraint — key (predicted_decision_id)
//   is not present in table "rule_llm_decision". Bind NULL instead of a placeholder.
```

## Schema drift: what to do when prod and DDL diverge again

The DDL in the HTML is documentation of intent, not the source of
truth. When you change a column type (or the pipeline migrates a column
in prod):

1. Update `documents/schema-v0.4.duckdb.sql` to match prod (this file
   IS the source of truth for the table shape).
2. Update the `CREATE TABLE IF NOT EXISTS` blocks in
   `labeling-platform.html` so a fresh local DuckDB matches prod — the
   IF NOT EXISTS makes it a one-way migration aid, not a strict mirror.
3. Update every SELECT that touches the changed columns to cast back to
   the JS-friendly shape (`::VARCHAR` for UUIDs/ENUMs, leave VARCHAR[]
   alone and let `parseJsonField` unwrap).
4. Update every prepared statement that binds the changed columns to
   use the right SQL-side cast (`?::UUID`, `from_json(?, '["VARCHAR"]')`,
   `decode(?, 'hex')`).
5. Add a row to the [Two schemas § Why this matters](#why-this-matters)
   table if the new column type also lands in a silent-failure mode.

## Decision log

Why some of the non-obvious choices got made:

- **Read everything as VARCHAR strings rather than working with
  UUID/ENUM wrappers in JS.** Wrappers compare by reference, can't be
  `Map` keys, can't go into React `key`, can't be re-bound. Casting at
  the SQL boundary makes the entire JS layer work in plain strings.
- **`from_json(?, '["VARCHAR"]')` instead of `?::JSON` for list writes.**
  `?::JSON` works against a JSON column (local DDL) but stores the bound
  string as a literal JSON string in a VARCHAR[] column (prod), reading
  back wrong. `from_json` is the only pattern that works for both.
- **No `useEffect(setDraft(initial), [initial])` in `ClassificationForm`.**
  The form already remounts on `key=rule_id` from the parent, which is
  the only time the draft *should* re-initialize. The effect existed to
  handle "rule changes mid-render" but only ever fired on polls, which
  reset whatever the labeler had just typed. See [RUNBOOK § Notes flash
  back](RUNBOOK.md#notes-flash-back).
- **Initial note-field value does NOT fall back to the LLM
  prediction.** The LLM output already shows in its own "LLM Judge" box
  next to the field. Pre-filling the editable area forced labelers to
  clear before typing. See [RUNBOOK § Notes pre-fill with LLM](RUNBOOK.md#notes-pre-fill-with-llm).
- **Snapshot hash is computed at INSERT, never updated.** The hash
  freezes the prediction the labeler is reviewing, so a future audit
  can flag a label made against a since-changed judge prediction.
  Updating it on every save would defeat the purpose.
