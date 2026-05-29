# Rules Labeling Platform

A single-file static HTML app for human-in-the-loop review of rules-in-the-wild
extraction + classification output. Talks directly to MotherDuck from the
browser via `@motherduck/wasm-client`.

- **App**: [`labeling-platform.html`](labeling-platform.html) — single file, no build step
- **Functional contract**: [`documents/LABELING.md`](documents/LABELING.md)
- **Stack & gotchas**: [`documents/LABELING-STACK.md`](documents/LABELING-STACK.md)
- **Data layer & SQL patterns**: [`documents/DATA-LAYER.md`](documents/DATA-LAYER.md)
- **Debugging runbook**: [`documents/RUNBOOK.md`](documents/RUNBOOK.md)
- **Schema reference**: [`documents/schema-v0.4.duckdb.sql`](documents/schema-v0.4.duckdb.sql)
- **Tech-debt register**: [`documents/TECH-DEBT.md`](documents/TECH-DEBT.md)

## Deploy to Vercel

Three steps: push to GitHub → import on Vercel → paste the MotherDuck token.

### 1. Push this repo to GitHub

```bash
# from this folder
git init -b main
git add -A
git commit -m "Initial labeling platform"

# create the empty repo first on github.com, then:
git remote add origin git@github.com:<you>/<repo>.git
git push -u origin main
```

Confirm `.env`, `config.js`, and `*.duckdb` are **not** in the push —
[`.gitignore`](.gitignore) keeps them out, but `git status` before the push
is the final check. The MotherDuck token must never land in git history.

### 2. Import the repo into Vercel

1. Go to <https://vercel.com/new> and select your GitHub repo.
2. Framework preset: **Other** (Vercel auto-detects [`vercel.json`](vercel.json)).
3. Leave the build command and output dir alone — they come from `vercel.json`.
4. Don't deploy yet. Click **Environment Variables** first.

### 3. Add the MotherDuck token + DB name

In **Project Settings → Environment Variables**, add:

| Name                  | Value                                   | Scope                 |
|-----------------------|-----------------------------------------|-----------------------|
| `MOTHERDUCK_TOKEN`    | your token (mark **Sensitive**)         | Production + Preview  |
| `MOTHERDUCK_DATABASE` | `rules_in_the_wild` (or your DB name)   | Production + Preview  |
| `LABELING_PASSWORD`   | password for the Basic Auth gate        | Production + Preview  |

Get a token at <https://app.motherduck.com/settings/tokens>. Use a scoped
**read-write** token — `UPDATE rule` is required by v0.4. Don't use a global
PAT; mint one limited to the `rules_in_the_wild` database.

Then click **Deploy**. The build runs [`scripts/build-vercel-config.js`](scripts/build-vercel-config.js),
which reads those env vars and emits `config.js` next to the HTML.
[`middleware.js`](middleware.js) gates the deployment with HTTP Basic Auth
using `LABELING_PASSWORD` (default `ritw` if unset — change it).

When the deploy is green, open the assigned URL, authenticate, and the
labeling app boots.

### ⚠️ Token exposure on a public Vercel URL

`config.js` ships to every visitor. The Basic Auth in [`middleware.js`](middleware.js)
is the floor — anyone with the password can view-source the token. For
anything beyond a personal demo:

- **Gate with SSO** (Cloudflare Access in front of Vercel — free up to 50 users;
  or Vercel's built-in Password Protection / Vercel Authentication on Pro).
- **Use a narrowly-scoped token** — read-write, limited to the
  `rules_in_the_wild` database only.

Treat a public-URL labeling deploy as world-writable MotherDuck unless one of
those is in place.

## Local development

```bash
cp .env.example .env
# paste your MotherDuck token into .env

python3 -m http.server 8765
# open http://localhost:8765/labeling-platform.html
```

The HTML fetches `./.env` on boot. ES modules don't load over `file://`, so
double-clicking the HTML won't work — it must be served over HTTP.

See [`documents/LABELING-STACK.md`](documents/LABELING-STACK.md) for the full
config-loading flow (three fallbacks: `window.__LABELING_CONFIG` → `.env` → `localStorage`).

## What's in this repo

| Path                                | Role                                              |
|-------------------------------------|---------------------------------------------------|
| [`labeling-platform.html`](labeling-platform.html) | The app (React + HTM via CDN, no build) |
| [`vercel.json`](vercel.json)        | Vercel config — emits `config.js` + rewrites `/` |
| [`middleware.js`](middleware.js)    | Vercel Edge middleware — HTTP Basic Auth gate     |
| [`scripts/build-vercel-config.js`](scripts/build-vercel-config.js) | Reads env vars → writes `config.js` at build |
| [`package.json`](package.json)      | Declares `@vercel/edge` for the middleware        |
| [`.env.example`](.env.example)      | Local-dev token template (`.env` is gitignored)   |
| [`documents/LABELING.md`](documents/LABELING.md)        | Functional contract (pages, decisions, schema)    |
| [`documents/LABELING-STACK.md`](documents/LABELING-STACK.md) | Stack details, gotchas, troubleshooting       |
| [`documents/DATA-LAYER.md`](documents/DATA-LAYER.md) | Browser↔MotherDuck wire shapes & SQL patterns |
| [`documents/RUNBOOK.md`](documents/RUNBOOK.md) | Symptom-driven debugging guide |
| [`documents/schema-v0.4.duckdb.sql`](documents/schema-v0.4.duckdb.sql) | DDL reference for the label tables       |
| [`documents/TECH-DEBT.md`](documents/TECH-DEBT.md) | Prioritized tech-debt register |
| [`documents/UI-design.pen`](documents/UI-design.pen)    | Pencil design file (artifact, not used at runtime)|
