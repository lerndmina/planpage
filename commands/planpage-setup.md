---
description: Interactive setup for planpage — connect your Zipline instance, verify publishing, and optionally configure a JS-enabled render origin
---

Walk the user through setting up planpage end to end. Be conversational and do one phase at a time — validate each phase before moving to the next. Use AskUserQuestion where a choice has fixed options; use plain questions for free-text answers like URLs. Never print the token back to the user or into logs; it is only ever sent to their own Zipline instance.

## Phase 0 — current state

Check whether `ZIPLINE_URL`, `ZIPLINE_TOKEN`, and `PLANPAGE_RENDER_URL` are already set in the environment. If URL + token are present, verify them (Phase 2's check) and tell the user what's already working — then offer to reconfigure, add the render origin, or stop.

## Phase 1 — collect credentials

1. Ask for their Zipline instance URL (e.g. `https://files.example.com`).
2. Tell them where the API token lives: Zipline dashboard → click their avatar (bottom-left) → **Manage Account** → **Copy Token**. Ask them to paste it.

## Phase 2 — validate

```bash
curl -fsS -H "authorization: <token>" <url>/api/user
```

- 200 with a JSON user object → good; greet them by their Zipline username.
- 401/403 → token is wrong; re-ask.
- Connection failure → URL is wrong or unreachable; re-ask.

Also confirm the instance is Zipline **v4** (`curl -fsS <url>/api/version` or the presence of `/api/user/folders`); v3 is not supported.

## Phase 3 — persist config

Write both values into the `env` block of `~/.claude/settings.json` (create the block if missing, merge with existing keys, never clobber other settings; validate the JSON parses afterwards). Remind the user the file is local and the token grants full access to their Zipline account.

## Phase 4 — verify publishing

Publish a small hello-world fragment with `--expires 1d --no-open` via the planpage script (`${CLAUDE_PLUGIN_ROOT}/skills/planpage/scripts/planpage.sh`), passing the env inline for this session since settings.json only applies to new sessions. Then:

```bash
curl -sI <zipline-url>/raw/<name>.html
```

- `Content-Type: text/html` → rendering works; give them the link and note it expires tomorrow.
- Check for `Content-Security-Policy: sandbox` in those headers and tell them what it means: pages render but JavaScript is disabled — that's the safe stock behavior, and pure-CSS pages still look great.

## Phase 5 — optional render origin (JS-enabled pages)

Explain the trade-off in one short paragraph: a separate cookie-isolated (sub)domain can serve the same files with the sandbox stripped — full JS (mermaid diagrams, theme toggle, copy buttons) with no session-theft risk because that origin never carries their Zipline cookies. It requires controlling the reverse proxy in front of Zipline.

Ask if they want it. If yes:

1. Ask which proxy they run (Caddy / nginx / Traefik / other) and what domain they want to use (e.g. `plans.example.com`). Remind them the DNS record must point at the same box (a wildcard works).
2. For **Caddy**, give them this block with their domain and Zipline upstream filled in (upstream is whatever their Caddy already proxies Zipline to — ask or infer from their existing config if they share it):

   ```caddy
   plans.example.com {
   	encode gzip zstd
   	@app path /login /login/* /register /register/* /auth/* /invite/* /dashboard /dashboard/* /api /api/* /u/* /view/* /folder/* /files/*
   	redir @app https://your.zipline.host{uri} 302
   	@notget not method GET HEAD
   	respond @notget 405
   	@txt path_regexp txt ^(.+)\.txt$
   	rewrite @txt /raw{http.regexp.txt.1}.html
   	header @txt >Content-Type "text/plain; charset=utf-8"
   	redir / /plans.html
   	rewrite * /raw{uri}
   	reverse_proxy zipline:3000 {
   		header_up -Cookie
   		header_up -Authorization
   		header_down -Content-Security-Policy
   	}
   }
   ```

   Explain what it does in two sentences: everything is forced into Zipline's `/raw/` with the sandbox CSP stripped, and the block also hardens the origin (app routes bounce to the main domain, GET/HEAD only, credentials stripped upstream, `.txt` shows page source). For nginx/Traefik, translate the same rules.
3. Offer both paths: they apply it themselves and tell you when done, **or** — if they offer SSH/config access — you apply it, validate the proxy config, and reload gracefully. Never restart shared infrastructure without their explicit go-ahead.
4. Verify: `curl -sI https://<domain>/<name>.html` for the Phase 4 test page → expect `200`, `text/html`, and **no** `Content-Security-Policy` header. Only after that passes, add `PLANPAGE_RENDER_URL=https://<domain>` to the same settings.json env block.

## Phase 6 — optional preferences

Offer (AskUserQuestion, multiSelect) the optional env vars, with the default noted: `PLANPAGE_DEFAULT_EXPIRY` (e.g. `7d`; default never), `PLANPAGE_SITE_NAME` (header brand; default `planpage`), `PLANPAGE_FAVICON` (emoji; default 📋), `PLANPAGE_FOLDER` (Zipline folder; default `planpage`), `PLANPAGE_INDEX_SLUG` (default `plans`). Write any chosen values into the env block.

## Phase 7 — wrap up

Summarize what's configured (URL, render origin or not, extras), remind them env changes apply to **new** sessions, and point them at usage: just ask for a plan, or `/planpage`, `/planpage list`. Clean up: unpublish the hello page or mention it self-expires.

$ARGUMENTS
