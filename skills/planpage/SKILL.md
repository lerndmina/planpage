---
name: planpage
description: Create and publish plans, reports, and docs as styled single-page HTML links on the user's Zipline instance — the replacement for markdown plan files. Use whenever the user asks for a plan, design doc, proposal, review write-up, or research summary (deliver it as a published page, not a .md file), and whenever they ask to publish or share existing content as a page/link. Requires ZIPLINE_URL and ZIPLINE_TOKEN in the environment.
---

# planpage

Publish self-contained HTML pages to the user's Zipline instance and return a shareable link. This **replaces markdown plan files entirely**: when the user asks you to plan something, write up a design, or produce a report, the deliverable is a published planpage URL — do not write a `plan.md` into the repo unless the user explicitly asks for a file on disk. The same applies to research summaries, reviews, and one-off docs.

## Prerequisites

`ZIPLINE_URL` and `ZIPLINE_TOKEN` must be set in the environment. If they aren't, stop and tell the user to set them (see the plugin README for how to create a token). Never echo the token.

## Workflow

1. **Author the page** — write a complete, self-contained HTML file (see Authoring rules below). Write it to a temp/scratch location, not the user's repo.
2. **Publish it**:

   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/skills/planpage/scripts/planpage.sh" publish <file.html> \
     --slug <kebab-case-slug> [--expires 7d] [--password <pw>] [--no-open]
   ```

3. **Return the link** — the script prints the final URL on its last line. Give that URL to the user as the deliverable.

### Options

- `--slug` — vanity slug; the page lives at `<origin>/<slug>.html`. Always pass one derived from the page title (e.g. `auth-refactor-plan`) unless the user wants a random unguessable link, in which case omit it.
- Re-publishing with the same slug **updates in place**: the old file is deleted and the URL stays stable. This is the normal way to iterate on a plan.
- `--expires` — relative expiry like `12h`, `7d`, `2w`; `never` disables. Defaults to `PLANPAGE_DEFAULT_EXPIRY` if set, otherwise never.
- `--password` — protect sensitive pages (Zipline prompts viewers for it).
- `--no-open` — skip auto-opening the page in the user's browser after publishing.

### Markdown mode

`publish` also accepts a `.md`/`.markdown` file directly — it is converted to a styled HTML page automatically (requires `perl`, present on Git Bash/macOS/Linux). The page title comes from the first `# ` heading unless `--title` is given.

```bash
bash "${CLAUDE_PLUGIN_ROOT}/skills/planpage/scripts/planpage.sh" publish notes.md --slug my-notes
```

Use markdown mode to publish an *existing* markdown file as-is (e.g. a plan the user already has on disk). The converter covers standard markdown: headings, lists, fenced code, tables, blockquotes, links, images, bold/italic. When you are authoring new content yourself, write HTML directly instead — you get the richer template (badges, step lists, collapsibles) and full layout control.

### Other commands

```bash
planpage.sh list               # table of published pages
planpage.sh unpublish <slug>   # delete a page (and refresh the index)
planpage.sh index              # regenerate + republish the index page
```

Every publish also regenerates an **index page** (slug `plans` by default) listing all live pages — mention its URL when the user asks what's published.

## Authoring rules

**JavaScript depends on the deployment.** Check `PLANPAGE_RENDER_URL`:

- **Not set** (stock Zipline): pages are served with `Content-Security-Policy: sandbox` — **no JavaScript executes**. Author pure HTML+CSS only. Use native `<details>/<summary>` for collapsible sections, CSS counters for step lists, and inline SVG for diagrams. Do not include `<script>` tags — they will silently do nothing.
- **Set** (a cookie-isolated origin that strips the sandbox, per the README): links are served from that origin, scripts run, and you may use JS and interactivity when the page genuinely benefits.

**Always, regardless of mode:**

- One fully self-contained file: inline all CSS; no external stylesheets, fonts, or trackers. External images only if the user supplied the URL.
- Start from `assets/template.html` (same directory tree as this file) — replace the `{{...}}` placeholders and cut sections that don't apply. Deviate freely for non-plan content, but keep its conventions: light/dark via `prefers-color-scheme`, system font stack, ~46rem measure, `<meta name="robots" content="noindex">`.
- Set a real `<title>` — the registry and index page use it.
- These pages are public-by-obscurity links unless password-protected. Don't put secrets (tokens, internal hostnames, credentials) in a page; warn the user and use `--password` if the content is sensitive.

## Content guidance for plans

A good published plan reads top-to-bottom in under two minutes: a one-paragraph summary first, then numbered implementation steps (what + why, with file paths), a decisions table for anything with alternatives, and risks/open questions in collapsibles. Prefer prose over walls of code — include code only where the exact diff is the point.
