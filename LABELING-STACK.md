# Labeling Platform — Stack & Cautions (v0.4)

A maintenance reference for [`labeling-platform.html`](labeling-platform.html),
the single-file browser app that lets reviewers label rules-in-the-wild
output directly against MotherDuck. If you need to change how it works —
or you're trying to figure out why it broke — read this first.

For end-user run instructions, see the comment block at the top of
[`labeling-platform.html`](labeling-platform.html) itself. For the
functional contract (what each page does, what gets written when),
read [`LABELING.md`](LABELING.md).

## What it is

A self-contained static HTML page (~1.1k lines) that:

- Renders a two-tab labeling UI (Extraction, Classification) with master-detail layouts
- Connects directly to MotherDuck from the browser via `@motherduck/wasm-client`
- Reads from the pipeline tables (`rules_file`, `rule`, `source_project`, `rule_llm_decision`)
- **Writes directly to `rule`** for live rule body edits
- Writes labels to its own tables (`labeler`, `rule_extraction_label`, `rule_classification_label`)
  plus side tables (`rule_original_snapshot`, `rule_edit_pointer`)
- Loads the MotherDuck token from a sibling `.env` file (gitignored)
- Polls every 2 seconds while a page is open so every labeler sees every
  other labeler's edits live

## The stack

```
browser (any modern Chromium/Firefox/Safari)
 │
 ├── React 18                          ── esm.sh
 ├── HTM (tagged template literals)    ── esm.sh
 │      (used in place of JSX so there's no build step)
 │
 └── @motherduck/wasm-client@1.5.2-r.3 ── cdn.jsdelivr.net/+esm
        │
        └── DuckDB-WASM (bundled)
              │  HTTPS, mdToken auth
              ▼
           MotherDuck (md:rules_in_the_wild by default)

config:
  ./.env  (gitignored)  →  fetched by the HTML on boot
  ↳ MOTHERDUCK_TOKEN=…
  ↳ MOTHERDUCK_DATABASE=…
```

| Concern | Choice | Why |
|---|---|---|
| Build step | None | Single file users can serve and edit |
| UI framework | React 18 via ES module CDN | Familiar API; no build needed via importmap |
| Templating | HTM (Hyperscript Tagged Markup) | JSX-without-Babel — runtime parses `html\`...\`` template literals |
| DB client | `@motherduck/wasm-client` | The only supported way to talk to MotherDuck from the browser. The standard `@duckdb/duckdb-wasm` does not ship the `motherduck` extension; this fork does, statically linked |
| CDN | esm.sh (React/HTM), jsdelivr `/+esm` (wasm-client) | esm.sh is fine for small packages; for `@motherduck/wasm-client` it intermittently 503s — jsdelivr's `/+esm` is more stable |
| Crypto | Web Crypto `subtle.digest` | SHA-256 for `predicted_snapshot_hash` — stable hash of the frozen prediction axes |
| Identity persistence | `localStorage` | Stores the picked labeler's UUID; the labeler roster lives in MotherDuck |
| Config | `./.env` fetched at boot | Token never lives in the HTML; one `.env` file is shared via your password manager |

## Config loading — three sources, tried in order

On first DB call, the HTML's `loadConfig()` does:

1. **`window.__LABELING_CONFIG`** — set synchronously by `config.js` (an
   ordinary `<script src="./config.js">` tag that runs before the module
   script). This is the Vercel path: `scripts/build-vercel-config.js`
   reads `MOTHERDUCK_TOKEN` / `MOTHERDUCK_DATABASE` from project env
   vars and writes `config.js` at build time. The file is gitignored.
2. **`fetch('./.env', { cache: 'no-store' })`** — for local serving via
   `python3 -m http.server`. Parses `KEY=value` lines.
3. **`localStorage['labeling.motherduckToken']`** — paste via DevTools
   for browsers where the server can't or won't serve dotfiles.
4. If all three are empty, the boot splash shows an error pointing at
   `.env.example`.

For local dev `config.js` doesn't exist; the `<script src="./config.js">`
tag silently 404s and the fallback runs. No extra steps.

A minimal `.env`:

```
MOTHERDUCK_TOKEN=eyJhbG...
MOTHERDUCK_DATABASE=rules_in_the_wild
```

`.env`, `.env.local`, `*.duckdb`, and `config.js` are all in
[`.gitignore`](.gitignore). `.env.example` is the shared template — keep
that in version control with `MOTHERDUCK_TOKEN=` blank.

> **The static server has to serve `.env`.** `python3 -m http.server`
> happily serves dotfiles. If you front this with Nginx or Caddy and
> they're configured to deny `.*`, the boot will fall through to the
> localStorage path and you'll get the "token not set" banner. Either
> relax the deny rule for that one file, paste the token into
> `localStorage` via DevTools, or use the Vercel-style `config.js`
> approach (see below).

## Deploying to Vercel (free tier)

The high-level steps are in [README.md](README.md). This section covers the
mechanics for engineers touching the build.

[`vercel.json`](vercel.json) wires the repo as a static site with one build
step — emitting `config.js`:

```json
{
  "buildCommand": "node scripts/build-vercel-config.js",
  "outputDirectory": ".",
  "rewrites": [
    { "source": "/", "destination": "/labeling-platform.html" }
  ]
}
```

[`scripts/build-vercel-config.js`](scripts/build-vercel-config.js)
reads `MOTHERDUCK_TOKEN` + `MOTHERDUCK_DATABASE` from `process.env`
(set in Vercel **Project Settings → Environment Variables**) and
writes `config.js` next to the HTML. That file populates
`window.__LABELING_CONFIG` synchronously, so the module script's
`loadConfig()` finds it on the first try without any `fetch('.env')`.

[`middleware.js`](middleware.js) (Vercel Edge) gates every request behind
HTTP Basic Auth using `LABELING_PASSWORD`. The matcher excludes
`_vercel` + `favicon.ico` so platform routes still work. The fallback
password is `ritw` — override it in env vars.

Required env vars in Vercel:

| Name                  | Required | Purpose                                           |
|-----------------------|----------|---------------------------------------------------|
| `MOTHERDUCK_TOKEN`    | yes      | Read by the build script, embedded in `config.js` |
| `MOTHERDUCK_DATABASE` | no       | Defaults to `rules_in_the_wild`                   |
| `LABELING_PASSWORD`   | yes (or change the default) | Basic Auth password in `middleware.js` |

Scope each to Production + Preview (not Development — those are bundled
into the local Vercel CLI, not the deploy). Mark `MOTHERDUCK_TOKEN`
**Sensitive**.

### ⚠️ Vercel deploys are public by default — token gets exposed

`config.js` is served to every visitor. The Basic Auth gate in
`middleware.js` is the floor — anyone with the password can `view-source`
it and read the token. Two non-negotiables before deploying for anything
but a personal demo:

- **Gate access with real SSO.** Vercel's built-in deployment protection
  (Vercel Authentication, Password Protection) is Pro-tier. On Hobby (free):
    - **Cloudflare Access in front of Vercel** — point Cloudflare at the
      Vercel deployment, configure an Access policy (Google / GitHub
      login). Free for up to 50 users.
    - A GitHub OAuth check inside a serverless function — DIY route.
- **Use a scoped token.** Mint a MotherDuck token limited to just the
  `rules_in_the_wild` database with the minimum role you need. Don't
  ship a `read_write` PAT that has access to every database in the
  account. If labelers only need to read, use a read-scaling token —
  but then `UPDATE rule` won't work, so v0.4 requires read-write
  scoped narrowly.

Without one of these, a Vercel URL with only Basic Auth = world-writable
MotherDuck for anyone who learns the password.

### Local dev still uses `.env`

Nothing about the Vercel setup affects local dev — `config.js` isn't
checked in, the `<script src="./config.js">` tag silently 404s, and
the HTML falls through to `fetch('./.env')` which `python3 -m http.server`
serves out of the working directory.

If you want a Vercel-shaped local dev (no `.env`, generate `config.js`
yourself):

```bash
MOTHERDUCK_TOKEN=$(grep ^MOTHERDUCK_TOKEN .env | cut -d= -f2-) \
MOTHERDUCK_DATABASE=$(grep ^MOTHERDUCK_DATABASE .env | cut -d= -f2-) \
node scripts/build-vercel-config.js
python3 -m http.server 8765
```

## Data flow

```
On boot:
  loadConfig()                                  (fetch .env)
  MDConnection.create({ mdToken })
  → conn.isInitialized()
  → USE rules_in_the_wild
  → CREATE TABLE IF NOT EXISTS labeler / rule_extraction_label /
    rule_classification_label / rule_original_snapshot /
    rule_edit_pointer

On Extraction page load:
  listDocuments()                               (fetches per call — cheap join)
  backfillSnapshots()                           (idempotent NOT EXISTS)
  getExtractionItems(documentId)                (rules judged OR labeled)
  getExtractionLabelsByRules(ruleIds)           (every labeler's decision)

On rule body edit (debounced 400ms):
  ensureSnapshotForRule(rule_id)
  UPDATE rule SET rule_text=?, line_start=?, line_end=?, …
  UPSERT rule_edit_pointer (who edited last + when)

On decision click:
  ensureSnapshotForRule(rule_id)
  UPSERT rule_extraction_label (rule_id, labeler_id, decision)

On Classification page load:
  listDocuments()
  backfillSnapshots()
  getClassificationItems(documentId)            (rules with parse_ok decisions)
  getClassificationPredictions(documentId)      (latest per rule)
  getClassificationLabelsByRules(ruleIds)

On classification field edit (debounced 400ms per field):
  ensureClassificationRow(rule_id, labeler_id)  (frozen predicted_* snapshot)
  UPDATE rule_classification_label SET corrected_<field> = …

On decision click:
  ensureClassificationRow(rule_id, labeler_id)
  UPDATE rule_classification_label SET decision = ?

Polling (every 2s, while a page is open):
  loadItems() — same as page load, but in-place state update
```

## Schema (created on first connect)

```sql
CREATE TABLE IF NOT EXISTS labeler (
    id           VARCHAR PRIMARY KEY,
    handle       VARCHAR NOT NULL UNIQUE,
    display_name VARCHAR,
    created_at   TIMESTAMP NOT NULL DEFAULT current_timestamp
);

CREATE TABLE IF NOT EXISTS rule_extraction_label (
    rule_id    VARCHAR NOT NULL,
    labeler_id VARCHAR NOT NULL,
    decision   VARCHAR NOT NULL,
    created_at TIMESTAMP NOT NULL DEFAULT current_timestamp,
    updated_at TIMESTAMP NOT NULL DEFAULT current_timestamp,
    PRIMARY KEY (rule_id, labeler_id)
);

CREATE TABLE IF NOT EXISTS rule_classification_label (
    rule_id                          VARCHAR NOT NULL,
    labeler_id                       VARCHAR NOT NULL,
    predicted_decision_id            VARCHAR,
    predicted_snapshot_hash          VARCHAR,
    decision                         VARCHAR NOT NULL DEFAULT 'skip',
    predicted_prerequisites          JSON,
    predicted_enforcement_mechanisms JSON,
    predicted_triggers               JSON,
    predicted_ambiguity_level        VARCHAR,
    predicted_ambiguity_notes        VARCHAR,
    corrected_prerequisites          JSON,
    corrected_enforcement_mechanisms JSON,
    corrected_triggers               JSON,
    corrected_ambiguity_level        VARCHAR,
    corrected_ambiguity_notes        VARCHAR,
    created_at                       TIMESTAMP NOT NULL DEFAULT current_timestamp,
    updated_at                       TIMESTAMP NOT NULL DEFAULT current_timestamp,
    PRIMARY KEY (rule_id, labeler_id)
);

CREATE TABLE IF NOT EXISTS rule_original_snapshot (
    rule_id             VARCHAR PRIMARY KEY,
    original_rule_text  VARCHAR NOT NULL,
    original_line_start INTEGER NOT NULL,
    original_line_end   INTEGER NOT NULL,
    snapshotted_at      TIMESTAMP NOT NULL DEFAULT current_timestamp
);

CREATE TABLE IF NOT EXISTS rule_edit_pointer (
    rule_id        VARCHAR PRIMARY KEY,
    labeler_id     VARCHAR NOT NULL,
    last_edited_at TIMESTAMP NOT NULL DEFAULT current_timestamp
);
```

`predicted_snapshot_hash = sha256(stableStringify({prerequisites,
enforcement_mechanisms, triggers, ambiguity_level, ambiguity_notes}))`.
Frozen at row creation so a future tool can flag classification labels
made against a now-stale judge prediction.

The earlier `extraction_labels` and `classification_labels` tables (the
v0.3 prototype shape with `target_key`) are not touched by this app —
they can be `DROP TABLE`'d manually when you're confident nothing else
reads from them.

## In-file layout of `labeling-platform.html`

The single `<script type="module">` block at the bottom is divided into
section banners. Top to bottom:

1. **imports** — React, HTM, MDConnection from the importmap
2. **config — .env loader** — `loadConfig()` + `parseEnv()`
3. **lib/hash** — `sha256Hex`, `stableStringify`, `parseJsonField`
4. **duckdb/schema** — the five `CREATE TABLE IF NOT EXISTS` DDLs
5. **duckdb/client** — `getConnection()` singleton, `evalQuery` / `evalPrepared`
6. **duckdb/queries** — `listLabelers`, `listDocuments`,
   `backfillSnapshots`, `getExtractionItems`,
   `getExtractionLabelsByRules`, `getClassificationPredictions`,
   `getClassificationLabelsByRules`, `getClassificationItems`
7. **duckdb/upserts** — `upsertLabeler`, `ensureSnapshotForRule`,
   `updateRule`, `addRule`, `putExtractionDecision`,
   `ensureClassificationRow`, `putClassificationDecision`,
   `putClassificationField`
8. **identity** — `IdentityContext`, `IdentityProvider`, `useIdentity`, `LabelerPicker`
9. **shared components** — `StatusSelect`, `DocumentSelect`, `DecisionButtons`,
   `GithubLink`, `LabelerBadges`, `SourceLines` (with text-selection callback),
   `parseList`/`formatList`
10. **hooks** — `useDebouncedCallback`, `usePolling`
11. **pages** — `ExtractionPage` + `ExtractionDetail`, `ClassificationPage` + `ClassificationDetail`
12. **App** — top-level shell with boot splash + tabs + LabelerPicker
13. **boot** — `createRoot().render(...)`

The CSS lives in an inline `<style>` block in `<head>`.

## Cautions

### ⚠️ `.env` is gitignored — never commit it

Anyone with `.env` has the same MotherDuck access as the token holder.
The deployment model assumes the file is shared via a password manager,
not git. Use `.env.example` (which has `MOTHERDUCK_TOKEN=` blank) as the
template.

If you ever need to deploy this on a real host, pair the deployed URL
with Cloudflare Access SSO and use a MotherDuck **read-scaling token**
with reduced scope. Putting the token in localStorage instead of `.env`
also helps — each user pastes their own.

### ⚠️ ES modules don't work over `file://`

Double-clicking the HTML file in Finder will not work in any modern
browser — the importmap and `import` statements get blocked by
file-CORS. The file must be served over HTTP. `python3 -m http.server`
is the simplest. The "HOW TO RUN" comment at the top of the file calls
this out for users.

### ⚠️ The static server needs to serve `.env`

`python3 -m http.server` serves dotfiles by default. Caddy and Nginx
typically deny `.*`. If your boot splash says "Failed to connect to
MotherDuck" with the "token not set" wording, the most common cause is
the server refusing to serve `/.env`. Fix: relax the deny rule for
exactly `.env`, OR paste the token into `localStorage['labeling.motherduckToken']`
via DevTools, OR use the Vercel-style `config.js` approach so the token
lives in `window.__LABELING_CONFIG` instead of being fetched at boot.

### ⚠️ MotherDuck wasm-client uses pre-release versioning

The package's version on npm is `1.5.2-r.3` (with a `-r.N` pre-release
suffix), not `1.5.2`. esm.sh historically resolved the loose `@1.5.2`
specifier to `1.5.2-r.3` but its cache lapsed and started returning
404/503. **Always pin to the exact `@1.5.2-r.N` published version**.
Check <https://registry.npmjs.org/@motherduck/wasm-client> for the
current list before bumping.

When you bump the wasm-client version, also confirm that the jsdelivr
`/+esm` build of that version exists and loads cleanly. Both CDN
endpoints have flaked on this package in the past; jsdelivr is currently
more reliable.

### ⚠️ Direct `UPDATE rule` requires a read-write MotherDuck token

The v0.4 design has labelers editing the live `rule.rule_text` /
`line_start` / `line_end`. The token in `.env` must have
`tokenType: read_write`. A read-only token will boot fine and let you
load the queue, but every save fails with a permission error. If you
pull a token from MotherDuck's UI and the writes don't land, double-check
its scope.

### ⚠️ `COUNT(*)` returns BigInt — `JSON.stringify` will throw

DuckDB-WASM ships `COUNT(*)` as a JavaScript `BigInt`, and `JSON.stringify`
on any object containing a `BigInt` throws
`TypeError: Do not know how to serialize a BigInt`. The current code
doesn't include any explicit `count(*)` calls, but if you add one, cast
in SQL:

```sql
SELECT COUNT(*)::INTEGER AS n FROM rule_extraction_label
```

### ⚠️ Identity is required for save, not for read

The labeler dropdown writes the picked labeler's UUID into
`localStorage['labeling.identity.labelerId']`. Every save attaches
`labeler_id` to the row. Reads do NOT filter by `labeler_id` — every
labeler sees every other labeler's decisions in the badge row.

If you want a per-labeler-only view, change `filterExtractionByStatus`
/ `filterClassificationByStatus` to also drop rows with `labeler_id !=
me` from the queue. The current behavior is intentional per the v0.4
multi-labeler spec.

### ⚠️ Two labelers editing the same rule body race on writes

DuckDB / MotherDuck serializes writes per catalog, so the second write
wins — there's no merge. The 2-second polling will surface the loser's
stale view; their next edit will overwrite the winner's change. If
labelers are about to actively co-edit the same rule, either coordinate
verbally or bump `POLL_INTERVAL_MS` down so the in-flight edits collide
sooner and one labeler backs off.

### ⚠️ Polling cost

`POLL_INTERVAL_MS = 2000` means each open page makes ~4 queries every
two seconds (rules + labels for extraction; rules + labels +
predictions for classification). With ~5 labelers that's ~10 queries/sec
to MotherDuck. Acceptable for an internal tool; bump the interval if you
notice rate-limit warnings in the console.

### ⚠️ Cold WASM load is ~10 MB

First visit downloads the wasm bundle, sub-dependencies, and the worker
script — typically 2–4 seconds on a fast connection. Subsequent loads
are cached. The boot splash is distinct from the "loading data" state
so users don't mistake a 3-second hang for a broken app.

### ⚠️ JSON columns: bind as text, cast in SQL

DuckDB-WASM has no first-class binding for JS arrays into a `JSON`
column. The proven pattern is `JSON.stringify(arr)` in JS and cast with
`?::JSON` in SQL (see `putClassificationField`). Do **not** try to bind
a JS array directly.

### ⚠️ HTM templating gotchas

- Closing tag is `<//>` (two slashes) for component tags: `html\`<${Foo}>…<//>\``.
- Spread props: `html\`<div ...${obj} />\``.
- Style as object: `style=${{maxWidth: "32rem"}}` — the double `${{` is
  correct (template-literal interpolation of an object literal).
- HTM is parsed at runtime; a missing closer fails at the render call,
  not at parse, so the error often points away from the actual mistake.

### ⚠️ `http.server` port 5173 may be taken

On macs with Docker Desktop, port 5173 is sometimes pre-bound by Docker.
Pick another port — the comment at the top of the HTML suggests 8765.

## Where to look when…

| Symptom | Look at |
|---|---|
| "Loading labeling app…" never goes away | CDN 404/503. DevTools → Network, filter `esm.sh` / `jsdelivr.net` |
| "Failed to connect to MotherDuck — token not set" | `.env` not served by the static server, or `MOTHERDUCK_TOKEN=` blank |
| "Catalog Error: Table with name rule does not exist" | `USE ${MOTHERDUCK_DATABASE}` failed or wrong DB name. `SHOW DATABASES;` to confirm |
| "Permission denied" on a save | Token is read-only. Re-mint with `read_write` scope |
| "TypeError: Do not know how to serialize a BigInt" | A `COUNT(*)` somewhere is missing `::INTEGER` |
| Items load but Save does nothing | Identity not picked — header dropdown is empty |
| Lots of duplicate rows for one rule | Two labelers have their own row by design (compound PK). Their badges appear in the labeler-badges row |
| Edits to one rule don't show on another tab | 2 s polling is normal; refresh the tab if it feels slow, or lower `POLL_INTERVAL_MS` |

## Where the data lives

- **Pipeline tables (READ + WRITE for `rule`)**: `rules_file`, `rule`,
  `source_project`, `rule_llm_decision`. Defined in the crawler's
  `duckdb_schema.sql`. v0.4 specifically lets the labeling app
  `UPDATE rule` and `INSERT INTO rule` — make sure the token scope
  allows that.
- **Label tables (owned by this app)**: `labeler`,
  `rule_extraction_label`, `rule_classification_label`,
  `rule_original_snapshot`, `rule_edit_pointer`. DDL in this file
  and in [`schema-v0.4.duckdb.sql`](schema-v0.4.duckdb.sql).
- **Identity (browser-only)**: `localStorage['labeling.identity.labelerId']`.
