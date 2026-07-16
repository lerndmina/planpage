---
name: planpage
description: Create and publish plans, reports, and docs as styled single-page HTML links on the user's Zipline instance — the replacement for markdown plan files. Use whenever the user asks for a plan, design doc, proposal, review write-up, or research summary (deliver it as a published page, not a .md file), and whenever they ask to publish or share existing content as a page/link. Requires ZIPLINE_URL and ZIPLINE_TOKEN in the environment.
---

# planpage

Publish self-contained HTML pages to the user's Zipline instance and return a shareable link. This **replaces markdown plan files entirely**: when the user asks you to plan something, write up a design, or produce a report, the deliverable is a published planpage URL — do not write a `plan.md` into the repo unless the user explicitly asks for a file on disk. The same applies to research summaries, reviews, and one-off docs.

## Prerequisites

`ZIPLINE_URL` and `ZIPLINE_TOKEN` must be set in the environment. If they aren't, stop and tell the user to set them (see the plugin README for how to create a token). Never echo the token.

## Workflow

1. **Author a content fragment** — inner HTML only, no doctype/head/body/styles (see Authoring rules below). The script wraps it in shared chrome: base stylesheet, a site header with navigation back to the index, and a footer carrying the sources you pass and the publish date. Write the fragment to a temp/scratch location, not the user's repo.
2. **Publish it**:

   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/skills/planpage/scripts/planpage.sh" publish <fragment.html> \
     [--title "Page title"] [--source "Label|https://url"]... \
     [--slug <name>] [--expires 7d] [--password <pw>] [--no-open]
   ```

3. **Return the link** — the script prints the final URL on its last line. Give that URL to the user as the deliverable. If `PLANPAGE_RENDER_URL` is set and the proxy uses the README's config, swapping the link's `.html` for `.txt` serves the page source as plain text — worth mentioning when the user wants to inspect or copy the markup.

### Options

- `--title` — page title (stored server-side, shown on the index). Defaults to the fragment's first `<h1>`.
- `--description "One-line summary"` — feeds the link-preview card (og:description) and shows under the title on the index page. Always pass one; keep it under ~120 chars.
- `--source "Label|https://url"` — repeatable; each becomes a link in the footer's Sources section. Pass one per source you drew on (docs, issues, discussions) so readers can verify claims.

- `--slug` — custom slug; the page lives at `<origin>/<slug>.html`. **Omit it by default** so pages get random unguessable names — the index page already shows titles, and random names avoid collisions. Pass a slug only when the user explicitly asks for a memorable URL.
- Re-publishing with `--slug` set to a page's existing name **updates in place**: the old file is deleted and the URL stays stable. This works for random names too — when iterating on an already-published page whose URL isn't in context, run `planpage.sh find "<title words>"` (matches slug + title, prints only the matching slug/title/URL) and pass the returned slug as `--slug`. Don't use `list` for lookups; it dumps every page.
- `--expires` — relative expiry like `12h`, `7d`, `2w`; `never` disables. Defaults to `PLANPAGE_DEFAULT_EXPIRY` if set, otherwise never.
- `--password` — protects the file, but protected files can't be served by the raw route at all: the returned link goes to Zipline's viewer (`/view/`), which prompts for the password and shows the page as source, not rendered. For sensitive content, prefer a random unguessable link with a short `--expires` instead; use `--password` only when the user insists.
- `--no-open` — skip auto-opening the page in the user's browser after publishing.
- `--no-check` — skip mermaid validation. Publish normally parses every `<pre class="mermaid">` block with the real mermaid parser **before uploading** and aborts with the per-block parse errors if any block is invalid — read the error, fix the diagram source in the fragment, and re-run publish. Only pass `--no-check` if the validator itself is broken (e.g. npm install fails offline), never to push through a syntax error.

### Markdown mode

`publish` also accepts a `.md`/`.markdown` file directly — it is converted to a styled HTML page automatically (requires `perl`, present on Git Bash/macOS/Linux). The page title comes from the first `# ` heading unless `--title` is given.

```bash
bash "${CLAUDE_PLUGIN_ROOT}/skills/planpage/scripts/planpage.sh" publish notes.md --slug my-notes
```

Use markdown mode to publish an *existing* markdown file as-is (e.g. a plan the user already has on disk). The converter covers standard markdown: headings, lists, fenced code, tables, blockquotes, links, images, bold/italic. When you are authoring new content yourself, write HTML directly instead — you get the richer template (badges, step lists, collapsibles) and full layout control.

### Other commands

```bash
planpage.sh find <query>       # search pages by slug/title/description, prints matches only
planpage.sh url <slug>         # print a page's URL (cheapest way to re-share a link)
planpage.sh open <slug>        # open a page in the user's browser
planpage.sh list               # full table of published pages (only when the user asks)
planpage.sh unpublish <slug>   # delete a page (and refresh the index)
planpage.sh index              # regenerate + republish the index page
```

Every publish also regenerates an **index page** (slug `plans` by default) listing all live pages — mention its URL when the user asks what's published. All state lives on the Zipline server (pages sit in a dedicated folder; titles are stored as file metadata), so `find`/`list`/update-in-place give the same answers from any machine with the same token.

## Authoring rules

**JavaScript depends on the deployment.** Check `PLANPAGE_RENDER_URL`:

- **Not set** (stock Zipline): pages are served with `Content-Security-Policy: sandbox` — **no JavaScript executes**. Author pure HTML+CSS only. Use native `<details>/<summary>` for collapsible sections, CSS counters for step lists, and inline SVG for diagrams. Do not include `<script>` tags — they will silently do nothing.
- **Set** (a cookie-isolated origin that strips the sandbox, per the README): links are served from that origin, scripts run, and you may use JS and interactivity when the page genuinely benefits. **Mermaid is first-class**: write a `<pre class="mermaid">` block with the diagram text and the chrome auto-loads the renderer, theme-matched — prefer this over hand-drawn SVG. Publish validates every mermaid block before uploading and fails with the exact parse errors if a diagram is invalid; fix the block it names and re-publish. Common causes: unquoted `(){}[]|` or `"` inside node labels (wrap the label in double quotes: `A["label (with parens)"]`), and HTML entities — the block is decoded like browser textContent, so write `-->` literally, not `--&gt;`. The chrome also adds a theme toggle and copy buttons on code blocks automatically.

**Always, regardless of mode:**

- **Write a fragment, not a document**: inner HTML only — no `<!doctype>`, `<html>`, `<head>`, `<body>`, and no `<style>` boilerplate. The chrome (stylesheet, header nav, footer) is the script's job. Start from `assets/template.html` (same directory tree as this file): replace the `{{...}}` placeholders, cut sections that don't apply, deviate freely for non-plan content.
- Styled building blocks the chrome provides: `.meta` (info row under the h1), `.badge ok|warn|risk|info`, `ol.steps` (numbered step list with connectors), `details > summary` + `div.body` (collapsibles), tables, `blockquote`, `pre/code`. Small page-specific `<style>` or inline SVG inside the fragment is fine when the content needs something extra; external stylesheets/fonts/trackers are not.
- Start the fragment with an `<h1>` — it becomes the page title (or pass `--title`), stored server-side and shown on the index.
- Don't hand-write a table of contents — the chrome injects an "On this page" TOC automatically when the fragment has 3+ `<h2>`s (and adds reading time, OpenGraph tags, favicon, print styles, and mobile layout on its own).
- Pass the sources you drew on via repeated `--source "Label|url"` flags rather than writing your own sources section — the footer renders them.
- These pages are public-by-obscurity links unless password-protected. Don't put secrets (tokens, internal hostnames, credentials) in a page; warn the user and use `--password` if the content is sensitive.
- **Full-page escape hatch**: a file starting with `<!doctype` or `<html` is published exactly as-is — no chrome, no `--source` support. Use only when a page genuinely can't live inside the standard shell (custom app-like demos); you then own all styling and should include the header/footer conventions yourself if appropriate.

## Content guidance for plans

A good published plan reads top-to-bottom in under two minutes: a one-paragraph summary first, then numbered implementation steps (what + why, with file paths), a decisions table for anything with alternatives, and risks/open questions in collapsibles. Prefer prose over walls of code — include code only where the exact diff is the point.
