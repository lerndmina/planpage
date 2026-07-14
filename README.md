# planpage

A [Claude Code](https://claude.com/claude-code) plugin that publishes plans, reports, and docs as **styled single-page HTML links** on your own [Zipline](https://github.com/diced/zipline) instance — instead of leaving markdown files scattered around your repo.

Ask Claude to "publish this plan" and get back something like:

```
https://shrt.zip/raw/auth-refactor-plan.html
```

- **Vanity slugs** with **update-in-place** — re-publishing the same slug keeps the same URL while Claude iterates
- **Expiring links** (`7d`, `2w`, …) so old plans clean themselves up
- **Password protection** for sensitive pages
- **Markdown mode** — publish an existing `.md` file and it's converted to a styled page automatically
- **Auto-generated index page** listing everything you've published
- **Auto-opens** the published page in your browser
- Works against any Zipline v4 instance; no server changes required

## Install

```
claude plugin marketplace add lerndmina/planpage
claude plugin install planpage@planpage
```

## Setup

1. In your Zipline dashboard, copy your API token (avatar → *Manage Account* → *Copy Token*).
2. Make these available in Claude Code's environment — e.g. in `~/.claude/settings.json`:

```json
{
  "env": {
    "ZIPLINE_URL": "https://your.zipline.host",
    "ZIPLINE_TOKEN": "your-token"
  }
}
```

Optional:

| Env var | Effect |
|---|---|
| `PLANPAGE_RENDER_URL` | Serve links from a CSP-stripped origin (enables JavaScript — see below) |
| `PLANPAGE_DEFAULT_EXPIRY` | Default expiry for new pages, e.g. `7d` (default: never) |
| `PLANPAGE_INDEX_SLUG` | Slug of the auto-generated index page (default: `plans`) |
| `PLANPAGE_REGISTRY` | Registry file location (default: `~/.planpage/registry.tsv`) |

## Use

- Just ask for a plan: *"plan out the auth refactor"* — the plan arrives as a published page instead of a markdown file
- `/planpage` — publish the plan from the current conversation
- `/planpage path/to/file.html` — publish an existing file
- `/planpage path/to/notes.md` — convert a markdown file to a styled page and publish it
- `/planpage list` / `/planpage unpublish <slug>` — manage published pages
- Or: *"publish this as a page"*, *"planpage this research"*

## How it works (and the JavaScript question)

Zipline serves uploaded files at `/raw/<name>` with their real content type, so HTML renders as a page. It also sends `Content-Security-Policy: sandbox` on that route, which is what makes this **safe**: published pages run in a unique origin and can't touch your Zipline session cookies. The trade-off is that the sandbox also disables JavaScript.

Out of the box, planpage embraces that: Claude authors pure HTML+CSS pages (native `<details>` collapsibles, CSS-only dark mode, inline SVG diagrams). They look great and work on any stock Zipline.

### Optional: enable JavaScript with a render subdomain

If you control the reverse proxy in front of Zipline, you can serve raw files from a **separate, cookie-isolated origin** with the sandbox stripped — full JS with none of the session-theft risk (the reason Zipline sandboxes raw files in the first place). Don't strip the CSP on your main Zipline domain itself.

Caddy example (`plans.example.com` must point at the same box; a wildcard record works):

```caddy
plans.example.com {
	encode gzip zstd
	redir / /plans.html
	rewrite * /raw{uri}
	reverse_proxy zipline:3000 {
		header_down -Content-Security-Policy
	}
}
```

Then set:

```json
"PLANPAGE_RENDER_URL": "https://plans.example.com"
```

Links now come back as `https://plans.example.com/auth-refactor-plan.html`, and Claude is allowed to use JavaScript when a page benefits from it.

### Security notes

- Published pages are **public-by-obscurity** (or public-by-slug if you use vanity slugs). Use `--password` / ask for a password for anything sensitive; the skill also warns before publishing secrets.
- Your Zipline token stays local — it's only ever sent to your own `ZIPLINE_URL`.

## License

MIT
