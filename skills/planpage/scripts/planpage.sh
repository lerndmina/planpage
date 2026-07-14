#!/usr/bin/env bash
# planpage — publish single-page HTML to a Zipline instance
#
# Zipline is the source of truth: every page lives in a dedicated Zipline
# folder, and find/list/index/update-in-place all query the API. No local
# state, so any machine with the same ZIPLINE_TOKEN sees the same pages.
#
# Requires: bash, curl, perl (JSON parsing + markdown mode).
#
# Required env:
#   ZIPLINE_URL     e.g. https://shrt.zip (no trailing slash)
#   ZIPLINE_TOKEN   a Zipline API token (Settings -> copy token)
# Optional env:
#   PLANPAGE_RENDER_URL      cookie-isolated unsandboxed origin, e.g. https://plans.wild.rip
#                            (see README: Caddy/nginx strip the CSP sandbox there; enables JS)
#   PLANPAGE_DEFAULT_EXPIRY  default deletes-at for pages, e.g. 7d (default: never)
#   PLANPAGE_FOLDER          Zipline folder that holds the pages (default: planpage)
#   PLANPAGE_INDEX_SLUG      slug of the auto-generated index page (default: plans)
#
# Usage:
#   planpage.sh publish <file.html|file.md> [--slug my-plan] [--title "My plan"]
#                       [--expires 7d|never] [--password pw] [--no-open] [--no-index]
#   planpage.sh find <query>       # search pages by slug/title, prints matches only
#   planpage.sh list               # full table of pages
#   planpage.sh unpublish <slug>
#   planpage.sh index              # regenerate + republish the index page only
set -euo pipefail

ZIPLINE_URL="${ZIPLINE_URL:-}"
ZIPLINE_TOKEN="${ZIPLINE_TOKEN:-}"
RENDER_URL="${PLANPAGE_RENDER_URL:-}"
DEFAULT_EXPIRY="${PLANPAGE_DEFAULT_EXPIRY:-}"
FOLDER_NAME="${PLANPAGE_FOLDER:-planpage}"
INDEX_SLUG="${PLANPAGE_INDEX_SLUG:-plans}"

die() { echo "planpage: $*" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

[ -n "$ZIPLINE_URL" ] || die "ZIPLINE_URL is not set"
[ -n "$ZIPLINE_TOKEN" ] || die "ZIPLINE_TOKEN is not set"
command -v perl >/dev/null 2>&1 || die "perl is required"
ZIPLINE_URL="${ZIPLINE_URL%/}"
[ -n "$RENDER_URL" ] && RENDER_URL="${RENDER_URL%/}"

# ---------- API helpers ----------

api_get() { curl -fsS -H "authorization: $ZIPLINE_TOKEN" "$ZIPLINE_URL/api/$1"; }

api_delete_file() { # api_delete_file <file-id>
  curl -fsS -X DELETE -H "authorization: $ZIPLINE_TOKEN" \
    "$ZIPLINE_URL/api/user/files/$1" >/dev/null 2>&1 || true
}

ensure_folder() { # prints the planpage folder id, creating the folder if needed
  local fid
  fid="$(api_get user/folders | PP_FOLDER="$FOLDER_NAME" perl -MJSON::PP -0777 -e '
    my $d = decode_json(<STDIN>);
    my ($f) = grep { $_->{name} eq $ENV{PP_FOLDER} } @$d;
    print $f->{id} if $f;')"
  if [ -z "$fid" ]; then
    fid="$(curl -fsS -X POST -H "authorization: $ZIPLINE_TOKEN" \
      -H "content-type: application/json" \
      -d "{\"name\":\"$FOLDER_NAME\",\"isPublic\":false}" \
      "$ZIPLINE_URL/api/user/folders" | perl -MJSON::PP -0777 -e '
        print decode_json(<STDIN>)->{id};')"
  fi
  [ -n "$fid" ] || die "could not find or create Zipline folder '$FOLDER_NAME'"
  echo "$fid"
}

folder_files() { # TSV: name, id, title, published(YYYY-MM-DD), expires(YYYY-MM-DD|never)
  api_get user/folders | PP_FOLDER="$FOLDER_NAME" perl -MJSON::PP -0777 -e '
    my $d = decode_json(<STDIN>);
    my ($f) = grep { $_->{name} eq $ENV{PP_FOLDER} } @$d;
    exit 0 unless $f;
    for my $x (@{ $f->{files} || [] }) {
      my $title = $x->{originalName} // $x->{name};
      $title =~ s/\.html$//;
      $title =~ s/[\t\r\n]/ /g;
      printf "%s\t%s\t%s\t%s\t%s\n",
        $x->{name}, $x->{id}, $title,
        substr($x->{createdAt} // "", 0, 10),
        $x->{deletesAt} ? substr($x->{deletesAt}, 0, 10) : "never";
    }'
}

resolve_id() { # resolve_id <slug> — file id for slug.html in the folder, or empty
  folder_files | awk -F'\t' -v n="$1.html" '$1 == n { print $2; exit }'
}

# ---------- misc helpers ----------

json_get() { # json_get <key> — first string value of "key" from stdin
  perl -MJSON::PP -0777 -e '
    my $d = decode_json(<STDIN>);
    print $d->{files}[0]{$ARGV[0]} // "";' "$1"
}

page_url() { # page_url <name> — public rendered URL for a stored filename
  if [ -n "$RENDER_URL" ]; then
    echo "$RENDER_URL/$1"
  else
    echo "$ZIPLINE_URL/raw/$1"
  fi
}

open_url() {
  case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*) cmd.exe /c start "" "$1" >/dev/null 2>&1 || true ;;
    Darwin) open "$1" >/dev/null 2>&1 || true ;;
    *) xdg-open "$1" >/dev/null 2>&1 || true ;;
  esac
}

html_escape() { echo "$1" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g'; }

html_title() { # html_title <file> — contents of <title>, or basename
  local t
  t="$(tr -d '\n' < "$1" | sed -n 's:.*<title>\(.*\)</title>.*:\1:p' | head -1)"
  [ -n "$t" ] && echo "$t" || basename "$1" .html
}

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
  local now rows="" name id title published expires
  now="$(date +%Y-%m-%d)"
  while IFS=$'\t' read -r name id title published expires; do
    [ -n "$name" ] || continue
    [ "$name" = "$INDEX_SLUG.html" ] && continue
    rows="$rows<tr><td><a href=\"$(page_url "$name")\">$(html_escape "$title")</a></td><td><code>${name%.html}</code></td><td>$published</td><td>$expires</td></tr>"
  done < <(folder_files | sort -t"$(printf '\t')" -k4,4r)

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
  # title travels as the multipart filename -> Zipline originalName;
  # strip characters that break curl -F syntax or the TSV listing
  local safe_title
  safe_title="$(echo "$title" | tr -d '\t\r\n";\\')"

  local fid
  fid="$(ensure_folder)"

  # update-in-place: delete the previous file behind this slug first
  if [ -n "$slug" ]; then
    local old_id
    old_id="$(resolve_id "$slug")"
    [ -n "$old_id" ] && api_delete_file "$old_id"
  fi

  local -a hdrs=(-H "authorization: $ZIPLINE_TOKEN")
  # Zipline appends the extension itself — pass the bare slug
  [ -n "$slug" ] && hdrs+=(-H "x-zipline-filename: $slug")
  [ -n "$expires" ] && hdrs+=(-H "x-zipline-deletes-at: $expires")
  [ -n "$password" ] && hdrs+=(-H "x-zipline-password: $password")
  hdrs+=(-H "x-zipline-folder: $fid" -H "x-zipline-original-name: true")

  # upload with a relative path: on Windows (Git Bash), MSYS path conversion
  # can't rewrite a Unix path embedded in curl's -F argument
  local resp
  resp="$(cd "$(dirname "$file")" && \
    curl -fsS "${hdrs[@]}" \
      -F "file=@$(basename "$file");type=text/html;filename=$safe_title.html" \
      "$ZIPLINE_URL/api/upload")" \
    || die "upload failed (check ZIPLINE_URL/ZIPLINE_TOKEN)"

  local name url
  name="$(echo "$resp" | json_get name)"
  [ -n "$name" ] || die "could not parse upload response: $resp"
  url="$(page_url "$name")"

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
    [ $# -ge 1 ] || die "usage: planpage.sh publish <file.html|file.md> [options]"
    do_publish "$@"
    ;;
  list)
    rows="$(folder_files)"
    [ -n "$rows" ] || { echo "nothing published yet"; exit 0; }
    printf '%-24s %-12s %-12s %s\n' "SLUG" "PUBLISHED" "EXPIRES" "URL"
    while IFS=$'\t' read -r name id title published expires; do
      [ -n "$name" ] && printf '%-24s %-12s %-12s %s\n' \
        "${name%.html}" "$published" "$expires" "$(page_url "$name")"
    done <<< "$rows"
    ;;
  find|search)
    [ $# -ge 1 ] || die "usage: planpage.sh find <query>"
    q="$(echo "$*" | tr '[:upper:]' '[:lower:]')"
    found=0
    while IFS=$'\t' read -r name id title published expires; do
      [ -n "$name" ] || continue
      hay="$(echo "${name%.html}	$title" | tr '[:upper:]' '[:lower:]')"
      case "$hay" in *"$q"*)
        printf '%s\t%s\t%s\n' "${name%.html}" "$title" "$(page_url "$name")"
        found=1 ;;
      esac
    done < <(folder_files)
    [ "$found" = 1 ] || die "no published page matching: $*"
    ;;
  unpublish)
    [ $# -ge 1 ] || die "usage: planpage.sh unpublish <slug>"
    fid_check="$(resolve_id "$1")"
    [ -n "$fid_check" ] || die "no published page with slug '$1'"
    api_delete_file "$fid_check"
    regen_index
    echo "unpublished: $1"
    ;;
  index)
    regen_index
    echo "$(page_url "$INDEX_SLUG.html")"
    ;;
  *)
    die "usage: planpage.sh {publish|find|list|unpublish|index}"
    ;;
esac
