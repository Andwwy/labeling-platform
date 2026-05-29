# Labeling Platform — Runbook

A symptom-driven debugging guide for the labeling app. When something
breaks, find the symptom in [Quick lookup](#quick-lookup) and follow the
link.

This complements [LABELING-STACK.md § Cautions](LABELING-STACK.md#cautions)
and [LABELING-STACK.md § Where to look when…](LABELING-STACK.md#where-to-look-when):
the cautions list known traps before you hit them, the lookup table maps
boot-time symptoms to fixes, and this doc walks through the **save-path**
bugs we hit in v0.4 — which all fail silently or hang rather than
throw, so they don't show up in the boot symptom table.

For the underlying design (prod schema, why these patterns matter), see
[DATA-LAYER.md](DATA-LAYER.md).

## Quick lookup

| Symptom | Section |
|---|---|
| Save Classification button stuck on "Saving…" forever, no toast | [§ Save hangs forever](#save-hangs-forever) |
| Edits "save" with no error but DB row is unchanged or has nulls | [§ Save silently no-ops](#save-silently-no-ops) |
| Sidebar always shows "unlabeled" even after a successful save | [§ "Labeled by me" never works](#labeled-by-me-never-works) |
| Switching labeler in the dropdown falls back to Charlie + empty page | [§ Labeler switch falls back](#labeler-switch-falls-back) |
| Typing in a note field reverts shortly after you type | [§ Notes flash back](#notes-flash-back) |
| Note field pre-filled with the LLM prediction text | [§ Notes pre-fill with LLM](#notes-pre-fill-with-llm) |
| Add Rule / Change Rule "Confirm" sticks, no toast, then whole app hangs | [§ Add/Change Rule hangs](#addchange-rule-hangs) |
| Hand-added rules never show up in the Classification phase | [§ Hand-added rules missing from labeling](#hand-added-rules-missing-from-labeling) |
| Vercel shows the old code after a git push | [§ Vercel shows old code](#vercel-shows-old-code) |
| Vercel asks every visitor to log in to Vercel | [§ Vercel SSO blocks all access](#vercel-sso-blocks-all-access) |

## Save hangs forever

**Symptom.** Click Save Classification, button shows "Saving…", and stays
there indefinitely. No error toast, no DB row written. Reloading the page
doesn't help.

**Root cause.** DuckDB-WASM's `evaluatePreparedStatement` **hangs the
promise** (instead of throwing) when a write violates a constraint — a
NOT NULL *or* a FOREIGN KEY violation both hang rather than reject. The
same statement run via `evaluateQuery` (a literal, no bound params)
correctly throws a `Constraint Error`.

The trap in the classification INSERT is `predicted_decision_id`, a
**nullable FK** to `rule_llm_decision(id)`. Rules with no LLM prediction
(hand-added, or accept-only rules the judge never scored) have no
decision row to point at. Binding a fabricated/nil UUID
(`'00000000-…'::UUID`) there *violates* the FK and hangs the promise; the
Save button's chain never resolves → stuck on "Saving…". The fix is to
bind `NULL` (a NULL FK value is exempt from the constraint) — which is
what `saveClassificationLabel` / `skipClassificationLabel` now do.

> This first surfaced as a NOT NULL omission: `predicted_snapshot_hash`
> was once `BLOB NOT NULL` in prod and the INSERT left it out (fixed in
> `8069f4b` by including it). The columns were later made **nullable**
> (see [DATA-LAYER.md § Two schemas](DATA-LAYER.md#two-schemas) and
> `schema-v0.4.duckdb.sql` §7), so the live hang risk is now the FK case
> above, not the missing column.

**Fix.** When there's no prediction, bind `NULL` for every `predicted_*`
column. When there *is* one, freeze the snapshot hash as a hex string and
cast it in SQL with `decode(?, 'hex')`:

```sql
INSERT INTO rule_classification_label (
    rule_id, labeler_id,
    predicted_decision_id, predicted_snapshot_hash,
    ...
) VALUES (
    ?::UUID, ?::UUID,
    ?::UUID, decode(?, 'hex'),   -- both bound NULL when the rule has no prediction
    ...
)
```

```js
const hasPred = !!(pred && pred.decision_id);
const snapHash = hasPred ? await sha256Hex(stableStringify({...pred fields...})) : null;
await evalPrepared(sql, [ruleId, labelerId, hasPred ? pred.decision_id : null, snapHash, ...]);
```

See `saveClassificationLabel` / `skipClassificationLabel` in
[labeling-platform.html](../labeling-platform.html).

**How to diagnose this class of bug.** Add temporary logging in
`evalPrepared`:

```js
async function evalPrepared(sql, params) {
  const conn = await getConnection();
  try {
    const r = await conn.evaluatePreparedStatement(sql, params);
    return r.data ? r.data.toRows() : [];
  } catch (e) {
    console.error("evalPrepared failed:", JSON.stringify({ sql: sql.slice(0, 120), params, err: e?.message || String(e) }));
    throw e;
  }
}
```

But this won't catch the hang — the promise never rejects. Faster path:
in DevTools console, copy the exact SQL + params and run via
`window.__evalQuery` (no prepared statement) — that one throws, and the
error names the column or type at fault.

## Add/Change Rule hangs

**Symptom.** In the Extraction page, click Add Rule → Confirm (or Change
Rule → Save). The banner/button sticks, no toast, the rule never appears.
Worse than a one-off: every subsequent action hangs too and the whole app
goes unresponsive until you reload. The `rule` row may actually be written
— the hang is *after* the first INSERT.

**Root cause.** `rule.rule_text_sha256` is `BLOB NOT NULL` in prod.
`addRule`/`updateRule` computed it in SQL with `sha256(?)`, but DuckDB's
`sha256()` returns **VARCHAR**. Routing a *bound parameter* through
`sha256()` into a BLOB column makes `evaluatePreparedStatement` hang the
promise — the same silent-failure class as
[§ Save hangs forever](#save-hangs-forever), but a type mismatch rather
than a NOT NULL violation. Because the MotherDuck WASM client serializes
all queries on one connection, the hung statement **wedges the entire
connection**: every later read/write (even `SELECT 1`) queues behind it
forever, so the app looks frozen.

The *literal* form `sha256('text')` works (constant-folded, implicit
VARCHAR→BLOB cast) — only the bound-param prepared form hangs, which is
why it's easy to miss.

**Fix.** Don't compute the hash in SQL. Hash in JS with the existing
`sha256Hex` helper, bind the hex string, and convert with `unhex(?)` —
which yields the 32-byte digest prod stores:

```sql
-- addRule INSERT / updateRule UPDATE
rule_text_sha256 = unhex(?)      -- NOT sha256(?)
```

```js
const ruleHashHex = await sha256Hex(ruleText);
await evalPrepared(sql, [..., ruleHashHex, ...]);
```

Beware `decode(sha256(?), 'hex')` as a "fix": DuckDB's `decode` is
BLOB→VARCHAR (the wrong direction) and throws a clean binder error.
`unhex()` is the VARCHAR-hex→BLOB direction you want. Fixed in `addRule`
and `updateRule` in [labeling-platform.html](../labeling-platform.html).

**How to diagnose.** A wedged connection (every query hangs, even
`SELECT 1`) means a prior prepared statement hung — reload for a fresh
connection, then reproduce the offending INSERT as a *literal* via
`window.__evalQuery`, which throws instead of hanging. See
[DATA-LAYER § BLOB columns](DATA-LAYER.md#blob-columns-bind-hex-cast-with-decode).

## Hand-added rules missing from labeling

**Symptom.** You add a rule by hand in Extraction (Add Rule → Confirm). It
shows in the Extraction list, but never appears in the Classification
phase to be labeled.

**Root cause.** `getAllClassificationItems` gated on
`EXISTS (rule_llm_decision … parse_ok = TRUE)` only. Hand-added rules have
no LLM decision, so they were filtered out — even though
`saveClassificationLabel` already has a "no prediction" branch built to
label exactly these (binds NULL for the nullable `predicted_*` columns).

**Fix.** Mirror the Extraction gate — also include rules a human accepted:

```sql
WHERE EXISTS (SELECT 1 FROM rule_llm_decision d WHERE d.rule_id = r.id AND d.parse_ok = TRUE)
   OR EXISTS (SELECT 1 FROM rule_extraction_label l WHERE l.rule_id = r.id::VARCHAR AND l.decision = 'accept')
```

The Classification form already renders with a null prediction (empty
"LLM Judge" box). Fixed in `getAllClassificationItems` in
[labeling-platform.html](../labeling-platform.html).

## Save silently no-ops

**Symptom.** Save Classification briefly shows "Saved ✓", form advances
to next rule, but the DB row's `corrected_*` columns are still null,
or the read-back shows the LLM prediction instead of what you typed.

**Two distinct causes** — fix both:

1. **Bound parameter has the wrong type.** `labeler.id` came back from
   `SELECT id FROM labeler` as a UUID `{ bytes: [...] }` wrapper object,
   not a string. Binding the wrapper to a parameter throws `Invalid
   column type encountered for argument N` deep in the WASM client. The
   surface symptom: save reports success then nothing is in the DB,
   because the WRITE failed but a prior SELECT also failed first,
   short-circuiting through the catch.

   **Fix.** Cast every UUID to VARCHAR on read:

   ```sql
   SELECT id::VARCHAR AS id, handle, display_name FROM labeler
   ```

   Apply the same to `rule_id`, `labeler_id`, `predicted_decision_id`,
   and every other UUID column anywhere it crosses the JS boundary.

2. **VARCHAR[] columns round-trip as Arrow ListVector wrappers.**
   DuckDB-WASM returns `corrected_prerequisites` etc. as a
   `{ values: [...] }` wrapper with a `.toJson()` method, not as a plain
   JS array. The old `parseJsonField` only handled `typeof === 'string'`
   and `Array.isArray()` — the wrapper failed both checks and parsed as
   `null`. The form then fell back to the LLM prediction, so saved
   labels read back as if they were unsaved.

   **Fix.** Unwrap every shape:

   ```js
   function parseJsonField(value) {
     if (value === null || value === undefined) return null;
     if (typeof value === "string") { try { return JSON.parse(value); } catch { return null; } }
     if (Array.isArray(value)) return value.map(String);
     if (typeof value.toJson  === "function") return value.toJson().map(String);
     if (typeof value.toArray === "function") return Array.from(value.toArray()).map(String);
     if (Array.isArray(value.values)) return value.values.map(String);
     return null;
   }
   ```

Both landed in commit `0507daf` (your `Fixed user switch`). See
[DATA-LAYER.md § Reading rows](DATA-LAYER.md#reading-rows) for the full
list of wrapper shapes and which DuckDB types produce which.

## "Labeled by me" never works

**Symptom.** You saved a rule, the DB row exists with `decision='accept'`,
but the sidebar still shows the `unlabeled` badge and the "Labeled by me"
filter is empty.

**Root cause.** Same family as above. The check is
`myLabel?.decision === "accept"`, but `decision` is an `ENUM('accept',
'reject', 'skip')` in prod. DuckDB-WASM returns ENUM values as a
non-string wrapper (or sometimes the integer ordinal — 2 for `'skip'`).
The strict `=== "accept"` comparison always evaluates false.

**Fix.** Cast to VARCHAR in the SELECT. Same fix as UUIDs and ambiguity
ENUMs:

```sql
SELECT
  l.decision::VARCHAR AS decision,
  l.corrected_ambiguity_level::VARCHAR AS corrected_ambiguity_level,
  l.predicted_ambiguity_level::VARCHAR AS predicted_ambiguity_level,
  ...
FROM rule_classification_label l
```

Landed in `0507daf`.

## Labeler switch falls back

**Symptom.** You change the Labeler dropdown from Charlie to Wenyu (or
any other user). The page goes blank ("Pick a labeler in the top bar to
start.") for a moment, then the dropdown snaps back to Charlie.

**Root cause.** Identity flowed through React state as `current` from
`IdentityProvider`. The labeler list is fetched once on mount via
`listLabelers()`. If the labeler IDs returned from that fetch are UUID
wrapper objects (see above), then `next.find(l => l.id === stored)` from
the `localStorage` ID — a string — always misses. `setCurrent` then
defaults to `next[0]`, which alphabetically is Charlie.

The dropdown change handler fires `setCurrentById(e.target.value)`. The
handler does `labelers.find(l => l.id === id)`, but again `l.id` is a
wrapper object and `id` from the `<select>` is a string — `===` is
always false, so `setCurrent(null)` is called, the empty-state UI
renders, and the dropdown re-derives from the now-null current →
fallback to first labeler (Charlie).

**Fix.** Same root fix as [§ Save silently no-ops](#save-silently-no-ops):
cast `id::VARCHAR` in `listLabelers`. Once every labeler ID is a real
string, the `===` comparisons in `find` work and the dropdown sticks.

Landed in `0507daf`.

## Notes flash back

**Symptom.** You type into a "Your notes" textarea on the Classification
page. Moments later your text reverts to whatever was there before —
usually the LLM prediction or your last-saved value. Effectively the
textarea behaves as if it's read-only with a sticky default.

**Root cause.** `ClassificationForm` used to have:

```js
const initial = useMemo(() => ({
  PREREQUISITE: formatList(myLabel?.corrected_prerequisites ?? ... ?? []),
  ...
}), [item.rule_id, myLabel?.updated_at]);
const [draft, setDraft] = useState(initial);
useEffect(() => { setDraft(initial); }, [initial]);   // ← the bug
```

The reset effect is meant to handle "rule changed → re-init draft", but
the form already remounts when the rule changes (`key=${selected.rule_id}`
in the parent). So the effect only ever fires when `initial` is a new
reference but the rule is the same — which happens on every re-fetch for
any rule the labeler has already touched: `myLabel?.updated_at` is a
`Date` object that comes back as a fresh reference each fetch, busting
`useMemo`'s `Object.is` dep check. (At the time, a background poll
re-fetched every ~2 s, so the revert looked timer-driven; that poll has
since been removed, but the effect would have mis-fired on any refresh.)

**Fix.** Delete the reset effect entirely. Rely on `key=rule_id`
remounting the form (and `useState`'s lazy initializer) to set up the
initial draft.

Landed in `5e42121`. See `ClassificationForm` in
[labeling-platform.html](../labeling-platform.html).

## Notes pre-fill with LLM

**Behavior (intentional).** Open an unsaved rule on the Classification
page and the "Your notes" textareas are already filled with the latest
`parse_ok=TRUE` LLM prediction (e.g. ENFORCEMENT shows "regex, bash").
This is by design: the labeler reviews the model's answer and edits it
down instead of typing from scratch. The raw prediction still shows in
its own read-only "LLM Judge" box.

**Precedence.** A labeler's previously-saved correction wins; the draft
only falls back to the prediction when an axis has no saved `corrected_*`.
`??` stops at null/undefined, so an explicitly-saved empty correction
(`[]` or `""`) is preserved and is NOT re-filled from the LLM:

```js
PREREQUISITE: formatList(myLabel?.corrected_prerequisites ?? item.prediction?.prerequisites ?? []),
```

**History.** This fallback was briefly dropped in `5e42121` (it was felt
to force labelers to clear the field), then restored by request so
labelers start from the LLM answer. To go back to blank fields, remove
the `item.prediction?.…` term from the `initial` useMemo in
`ClassificationForm`.

## Vercel shows old code

**Symptom.** You pushed a fix to `main` on GitHub. The Vercel deployment
shows as "success" in the Vercel dashboard, but visiting your URL still
serves the old code.

**Two causes** to check, in this order:

1. **Per-deployment URL vs production alias.** Every Vercel build gets
   a unique frozen URL like
   `labeling-platform-<hash>-andwwys-projects.vercel.app`. That URL
   **always serves the commit it was built from** — it never updates.
   If you bookmarked an older deployment URL, you'll keep seeing the
   old build forever.

   Fix: use the production alias (`<project>.vercel.app` or your custom
   domain). Verify in **Vercel → Settings → Domains** which deployment
   the alias points to.

2. **Build succeeded but was "never promoted".** Some Vercel project
   configurations (manual-promote mode, or a one-off where auto-promote
   didn't fire) build the deployment but don't switch the production
   alias to it. The Vercel dashboard shows it labeled "Previous" with
   "Deployed Nm ago, never promoted".

   Fix: **Vercel → Deployments → find the row with your commit SHA →
   ⋯ → Promote to Production**.

To check which commit a per-deployment URL is serving:

```bash
gh api "/repos/<owner>/<repo>/deployments?per_page=30" \
  --jq '.[] | {id, sha: .sha[:7], created_at}'
gh api "/repos/<owner>/<repo>/deployments/<id>/statuses" \
  --jq '.[] | {state, env_url: .environment_url}'
```

The `env_url` is the per-deployment URL; the `sha` is the commit it's
serving.

## Vercel SSO blocks all access

**Symptom.** Anyone visiting the Vercel URL — even with the right
Basic Auth password from `middleware.js` — gets a 401 with a
`_vercel_sso_nonce` cookie. The Basic Auth prompt never appears.

**Root cause.** Vercel has its own "Deployment Protection" feature
(Vercel Authentication / Password Protection) that wraps deployments
**before** your `middleware.js` runs. It requires visitors to be logged
into a Vercel account that has access to your project. This is separate
from your repo's `middleware.js` Basic Auth and supersedes it.

**Fix.** **Vercel → Project → Settings → Deployment Protection → Vercel
Authentication → Disabled** (or "Only Preview Deployments" if you want
to keep PR previews private).

After saving, hit the URL in incognito. You'll see the Basic Auth
browser prompt asking for username/password — that's `middleware.js`
working as intended; password defaults to `ritw` (override with the
`LABELING_PASSWORD` env var).

**Security note.** Once Vercel SSO is off, Basic Auth over HTTPS is the
only gate. That's fine for casual access control among a small team, but
a leaked password = `view-source` of `config.js` = a working MotherDuck
token. For anything resembling production, layer Cloudflare Access in
front (see [LABELING-STACK.md § Vercel deploys are public by default —
token gets exposed](LABELING-STACK.md#-vercel-deploys-are-public-by-default--token-gets-exposed)).

## How to add a runbook entry

When you debug a non-obvious failure, add to this doc before closing
the loop:

1. **Symptom** — what the user *sees*, not what the code does. The
   reader is grepping this file for the string they're staring at.
2. **Root cause** — one paragraph, with the actual mechanism (not just
   "X was wrong"). Link to the relevant file and function.
3. **Fix** — the diff intent, with the commit SHA once landed.
4. Add the symptom phrase to [Quick lookup](#quick-lookup).

If the bug is a class of failure rather than a one-off, also add to
[DATA-LAYER.md](DATA-LAYER.md) so the next person designing a similar
query avoids it from the start.
