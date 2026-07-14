#!/usr/bin/env bash
# planpage — publish single-page HTML to a Zipline instance
#
# Required env:
#   ZIPLINE_URL     e.g. https://shrt.zip (no trailing slash)
#   ZIPLINE_TOKEN   a Zipline API token (Settings -> copy token)
# Optional env:
#   PLANPAGE_RENDER_URL      cookie-isolated unsandboxed origin, e.g. https://plans.wild.rip
#                            (see README: Caddy/nginx strip the CSP sandbox there; enables JS)
#   PLANPAGE_DEFAULT_EXPIRY  default deletes-at for pages, e.g. 7d (default: never)
#   PLANPAGE_REGISTRY        registry file (default: ~/.planpage/registry.tsv)
#   PLANPAGE_INDEX_SLUG      slug of the auto-generated index page (default: plans)
#
# Usage:
#   planpage.sh publish <file.html> [--slug my-plan] [--title "My plan"]
#                       [--expires 7d|never] [--password pw] [--no-open] [--no-index]
#   planpage.sh list
#   planpage.sh unpublish <slug>
#   planpage.sh index          # regenerate + republish the index page only
set -euo pipefail

ZIPLINE_URL="${ZIPLINE_URL:-}"
ZIPLINE_TOKEN="${ZIPLINE_TOKEN:-}"
RENDER_URL="${PLANPAGE_RENDER_URL:-}"
DEFAULT_EXPIRY="${PLANPAGE_DEFAULT_EXPIRY:-}"
REGISTRY="${PLANPAGE_REGISTRY:-$HOME/.planpage/registry.tsv}"
INDEX_SLUG="${PLANPAGE_INDEX_SLUG:-plans}"

die() { echo "planpage: $*" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

[ -n "$ZIPLINE_URL" ] || die "ZIPLINE_URL is not set"
[ -n "$ZIPLINE_TOKEN" ] || die "ZIPLINE_TOKEN is not set"
ZIPLINE_URL="${ZIPLINE_URL%/}"
[ -n "$RENDER_URL" ] && RENDER_URL="${RENDER_URL%/}"

mkdir -p "$(dirname "$REGISTRY")"
touch "$REGISTRY"

# ---------- helpers ----------

json_get() { # json_get <key> — first string value of "key" from stdin
  local key="$1"
  if command -v jq >/dev/null 2>&1; then
    jq -r ".files[0].$key // empty" 2>/dev/null || true
  else
    sed -n "s/.*\"$key\":\"\([^\"]*\)\".*/\1/p" | head -1
  fi
}

page_url() { # page_url <name> — public rendered URL for a stored filename
  if [ -n "$RENDER_URL" ]; then
    echo "$RENDER_URL/$1"
  else
    echo "$ZIPLINE_URL/raw/$1"
  fi
}

registry_lookup() { # registry_lookup <slug> — prints full row or nothing
  awk -F'\t' -v s="$1" '$1 == s' "$REGISTRY" | head -1
}

registry_remove() { # registry_remove <slug>
  local tmp="$REGISTRY.tmp.$$"
  awk -F'\t' -v s="$1" '$1 != s' "$REGISTRY" > "$tmp" && mv "$tmp" "$REGISTRY"
}

api_delete_file() { # api_delete_file <file-id>
  curl -fsS -X DELETE -H "authorization: $ZIPLINE_TOKEN" \
    "$ZIPLINE_URL/api/user/files/$1" >/dev/null 2>&1 || true
}

open_url() {
  case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*) cmd.exe /c start "" "$1" >/dev/null 2>&1 || true ;;
    Darwin) open "$1" >/dev/null 2>&1 || true ;;
    *) xdg-open "$1" >/dev/null 2>&1 || true ;;
  esac
}

html_title() { # html_title <file> — contents of <title>, or basename
  local t
  t="$(tr -d '\n' < "$1" | sed -n 's:.*<title>\(.*\)</title>.*:\1:p' | head -1)"
  [ -n "$t" ] && echo "$t" || basename "$1" .html
}

html_escape() { echo "$1" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g'; }

md_wrap() { # md_wrap <file.md> <title> — full styled HTML page on stdout
  local title_esc
  title_esc="$(html_escape "$2")"
  cat <<EOF
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="robots" content="noindex">
<title>$title_esc</title>
<style>
  :root {
    --bg: #fafafa; --surface: #ffffff; --fg: #1a1a1a; --muted: #666a73;
    --line: #e4e4e8; --accent: #4756e6; --accent-soft: #eef0ff; --code-bg: #f1f1f4;
  }
  @media (prefers-color-scheme: dark) {
    :root {
      --bg: #101014; --surface: #17171c; --fg: #e8e8ea; --muted: #9a9aa2;
      --line: #2a2a31; --accent: #8b96ff; --accent-soft: #23244a; --code-bg: #202027;
    }
  }
  * { box-sizing: border-box; }
  body { margin: 0; background: var(--bg); color: var(--fg);
         font: 16px/1.65 ui-sans-serif, system-ui, -apple-system, "Segoe UI", sans-serif; }
  main { max-width: 46rem; margin: 0 auto; padding: 3rem 1.25rem 5rem; }
  h1 { font-size: 1.9rem; line-height: 1.25; letter-spacing: -.02em; }
  h2 { font-size: 1.25rem; margin: 2.5rem 0 .75rem; letter-spacing: -.01em; }
  h3 { font-size: 1rem; margin: 1.75rem 0 .5rem; }
  p { margin: .75rem 0; }
  a { color: var(--accent); }
  code { font: .85em ui-monospace, "Cascadia Code", Consolas, monospace;
         background: var(--code-bg); padding: .12em .35em; border-radius: 5px; }
  pre { background: var(--code-bg); border: 1px solid var(--line); border-radius: 10px;
        padding: 1rem; overflow-x: auto; }
  pre code { background: none; padding: 0; }
  table { width: 100%; border-collapse: collapse; margin: 1rem 0; font-size: .925rem; }
  th { text-align: left; font-size: .72rem; text-transform: uppercase; letter-spacing: .06em;
       color: var(--muted); padding: .45rem .7rem; border-bottom: 2px solid var(--line); }
  td { padding: .55rem .7rem; border-bottom: 1px solid var(--line); vertical-align: top; }
  blockquote { margin: 1rem 0; padding: .6rem 1rem; border-left: 3px solid var(--accent);
               background: var(--surface); border-radius: 0 8px 8px 0; color: var(--muted); }
  hr { border: 0; border-top: 1px solid var(--line); margin: 2.5rem 0; }
  ul, ol { padding-left: 1.4rem; }
  li { margin: .3rem 0; }
</style>
</head>
<body>
<main>
$(perl "$SCRIPT_DIR/md2html.pl" < "$1")
</main>
</body>
</html>
EOF
}

# ---------- index page ----------

regen_index() {
  local tmp="${TMPDIR:-/tmp}/planpage-index.$$.html"
  # locals matter: bash scopes dynamically, and without these the read loop
  # would clobber the caller do_publish's title/url before it echoes them
  local now rows="" slug id title published expires url
  now="$(date +%Y-%m-%d)"
  # prune expired rows (best effort: relative expiries were resolved to dates at publish)
  while IFS=$'\t' read -r slug id title published expires url; do
    [ -n "$slug" ] || continue
    [ "$slug" = "$INDEX_SLUG" ] && continue
    if [ -n "$expires" ] && [ "$expires" != "never" ] && [[ "$expires" < "$now" ]]; then
      registry_remove "$slug"
      continue
    fi
    rows="$rows<tr><td><a href=\"$url\">$title</a></td><td><code>$slug</code></td><td>$published</td><td>${expires:-never}</td></tr>"
  done < "$REGISTRY"

  cat > "$tmp" <<EOF
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="robots" content="noindex">
<title>Published pages</title>
<style>
  :root { --bg:#fafafa; --fg:#1a1a1a; --muted:#666; --line:#e2e2e2; --accent:#4756e6; }
  @media (prefers-color-scheme: dark) {
    :root { --bg:#111114; --fg:#e8e8ea; --muted:#9a9aa2; --line:#2a2a30; --accent:#8b96ff; }
  }
  * { box-sizing: border-box; }
  body { margin:0; background:var(--bg); color:var(--fg);
         font:16px/1.6 ui-sans-serif,system-ui,-apple-system,"Segoe UI",sans-serif; }
  main { max-width:56rem; margin:0 auto; padding:3rem 1.25rem; }
  h1 { font-size:1.6rem; margin:0 0 .25rem; }
  p.sub { color:var(--muted); margin:0 0 2rem; }
  table { width:100%; border-collapse:collapse; }
  th { text-align:left; font-size:.75rem; text-transform:uppercase; letter-spacing:.06em;
       color:var(--muted); padding:.5rem .75rem; border-bottom:2px solid var(--line); }
  td { padding:.65rem .75rem; border-bottom:1px solid var(--line); }
  a { color:var(--accent); text-decoration:none; }
  a:hover { text-decoration:underline; }
  code { font:0.85em ui-monospace,Consolas,monospace; color:var(--muted); }
</style>
</head>
<body>
<main>
<h1>Published pages</h1>
<p class="sub">Generated by planpage on $now</p>
<table>
<thead><tr><th>Page</th><th>Slug</th><th>Published</th><th>Expires</th></tr></thead>
<tbody>$rows</tbody>
</table>
</main>
</body>
</html>
EOF
  do_publish "$tmp" --slug "$INDEX_SLUG" --title "Published pages" --expires never --no-open --no-index --quiet
  rm -f "$tmp"
}

# ---------- publish ----------

do_publish() {
  local file="" slug="" title="" expires="$DEFAULT_EXPIRY" password="" do_open=1 do_index=1 quiet=0
  file="$1"; shift
  while [ $# -gt 0 ]; do
    case "$1" in
      --slug) slug="$2"; shift 2 ;;
      --title) title="$2"; shift 2 ;;
      --expires) expires="$2"; shift 2 ;;
      --password) password="$2"; shift 2 ;;
      --no-open) do_open=0; shift ;;
      --no-index) do_index=0; shift ;;
      --quiet) quiet=1; shift ;;
      *) die "unknown option: $1" ;;
    esac
  done
  [ -f "$file" ] || die "file not found: $file"
  [ "$expires" = "never" ] && expires=""

  # markdown mode: convert to a styled HTML page first
  local md_tmp=""
  case "$file" in
    *.md|*.markdown)
      command -v perl >/dev/null 2>&1 || die "markdown mode requires perl"
      if [ -z "$title" ]; then
        title="$(sed -n 's/^#[[:space:]]\{1,\}\(.*\)$/\1/p' "$file" | head -1)"
        [ -n "$title" ] || title="$(basename "$file" | sed 's/\.[^.]*$//')"
      fi
      md_tmp="${TMPDIR:-/tmp}/planpage-md.$$.html"
      md_wrap "$file" "$title" > "$md_tmp" || die "markdown conversion failed"
      file="$md_tmp"
      ;;
  esac

  [ -n "$title" ] || title="$(html_title "$file")"

  # update-in-place: delete the previous file behind this slug first
  if [ -n "$slug" ]; then
    local existing old_id
    existing="$(registry_lookup "$slug")"
    if [ -n "$existing" ]; then
      old_id="$(echo "$existing" | cut -f2)"
      [ -n "$old_id" ] && api_delete_file "$old_id"
      registry_remove "$slug"
    fi
  fi

  local -a hdrs=(-H "authorization: $ZIPLINE_TOKEN")
  # Zipline appends the extension itself — pass the bare slug
  [ -n "$slug" ] && hdrs+=(-H "x-zipline-filename: $slug")
  [ -n "$expires" ] && hdrs+=(-H "x-zipline-deletes-at: $expires")
  [ -n "$password" ] && hdrs+=(-H "x-zipline-password: $password")

  # upload with a relative path: on Windows (Git Bash), MSYS path conversion
  # can't rewrite a Unix path embedded in curl's -F argument
  local resp
  resp="$(cd "$(dirname "$file")" && \
    curl -fsS "${hdrs[@]}" -F "file=@$(basename "$file");type=text/html" "$ZIPLINE_URL/api/upload")" \
    || die "upload failed (check ZIPLINE_URL/ZIPLINE_TOKEN)"

  local name id url
  name="$(echo "$resp" | json_get name)"
  id="$(echo "$resp" | json_get id)"
  [ -n "$name" ] || die "could not parse upload response: $resp"
  url="$(page_url "$name")"
  [ -n "$slug" ] || slug="${name%.html}"

  # resolve relative expiry (7d, 12h, 30m) to a date for the registry/index
  local expires_date="never"
  if [ -n "$expires" ]; then
    local n unit secs=0
    if [[ "$expires" =~ ^([0-9]+)([mhdw])$ ]]; then
      n="${BASH_REMATCH[1]}"; unit="${BASH_REMATCH[2]}"
      case "$unit" in m) secs=$((n*60));; h) secs=$((n*3600));; d) secs=$((n*86400));; w) secs=$((n*604800));; esac
      expires_date="$(date -d "@$(( $(date +%s) + secs ))" +%Y-%m-%d 2>/dev/null \
        || date -r "$(( $(date +%s) + secs ))" +%Y-%m-%d)"
    else
      expires_date="$expires"
    fi
  fi

  printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$slug" "$id" "$title" "$(date +%Y-%m-%d)" "$expires_date" "$url" >> "$REGISTRY"

  [ -n "$md_tmp" ] && rm -f "$md_tmp"
  [ "$do_index" = 1 ] && regen_index
  [ "$do_open" = 1 ] && open_url "$url"
  if [ "$quiet" = 0 ]; then
    echo "published: $title"
    echo "$url"
  fi
}

# ---------- commands ----------

cmd="${1:-}"; shift || true
case "$cmd" in
  publish)
    [ $# -ge 1 ] || die "usage: planpage.sh publish <file.html> [options]"
    do_publish "$@"
    ;;
  list)
    [ -s "$REGISTRY" ] || { echo "nothing published yet"; exit 0; }
    printf '%-24s %-12s %-12s %s\n' "SLUG" "PUBLISHED" "EXPIRES" "URL"
    while IFS=$'\t' read -r slug id title published expires url; do
      [ -n "$slug" ] && printf '%-24s %-12s %-12s %s\n' "$slug" "$published" "$expires" "$url"
    done < "$REGISTRY"
    ;;
  find|search)
    [ $# -ge 1 ] || die "usage: planpage.sh find <query>"
    matches="$(awk -F'\t' -v q="$(echo "$*" | tr '[:upper:]' '[:lower:]')" \
      'index(tolower($1 "\t" $3), q) { printf "%s\t%s\t%s\n", $1, $3, $6 }' "$REGISTRY")"
    [ -n "$matches" ] && echo "$matches" || die "no published page matching: $*"
    ;;
  unpublish)
    [ $# -ge 1 ] || die "usage: planpage.sh unpublish <slug>"
    row="$(registry_lookup "$1")"
    [ -n "$row" ] || die "no published page with slug '$1'"
    api_delete_file "$(echo "$row" | cut -f2)"
    registry_remove "$1"
    regen_index
    echo "unpublished: $1"
    ;;
  index)
    regen_index
    echo "$(page_url "$INDEX_SLUG.html")"
    ;;
  *)
    die "usage: planpage.sh {publish|list|unpublish|index}"
    ;;
esac
