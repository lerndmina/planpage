#!/usr/bin/env bash
# planpage — publish single-page HTML to a Zipline instance
#
# Zipline is the source of truth: every page lives in a dedicated Zipline
# folder, and find/list/index/update-in-place all query the API. No local
# state, so any machine with the same ZIPLINE_TOKEN sees the same pages.
#
# Pages are authored as CONTENT FRAGMENTS (inner HTML only). The script wraps
# them in shared chrome: base stylesheet, a header with navigation back to the
# index page, an auto table of contents, and a footer with optional sources.
# A file that already starts with <!doctype or <html is published as-is with
# no chrome (escape hatch).
#
# Requires: bash, curl, perl (JSON parsing, TOC, markdown mode).
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
#   PLANPAGE_SITE_NAME       brand shown in the page header (default: planpage)
#   PLANPAGE_FAVICON         emoji used as the pages' favicon (default: 📋)
#   PLANPAGE_CACHE_DIR       cache for the mermaid validator (default: ~/.cache/planpage)
#
# Usage:
#   planpage.sh publish <fragment.html|page.html|file.md>
#                       [--slug my-plan] [--title "My plan"]
#                       [--description "One-line summary"]
#                       [--source "Label|https://url"]...
#                       [--expires 7d|never] [--password pw] [--no-open] [--no-index]
#                       [--no-check]   # skip pre-upload mermaid validation
#   planpage.sh find <query>       # search pages by slug/title/description
#   planpage.sh url <slug>         # print a page's URL
#   planpage.sh open <slug>        # open a page in the browser
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
SITE_NAME="${PLANPAGE_SITE_NAME:-planpage}"
FAVICON="${PLANPAGE_FAVICON:-📋}"
CACHE_DIR="${PLANPAGE_CACHE_DIR:-$HOME/.cache/planpage}"

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

# The page title (and optional description, separated by ||) travels as the
# upload's originalName, so all metadata lives on the server.
# Description is the LAST column because it is the only one that can be empty:
# bash `read` with a tab IFS collapses consecutive tabs, so an empty field
# anywhere else would shift every column after it.
folder_files() { # TSV: name, id, title, published(YYYY-MM-DD), expires(YYYY-MM-DD|never), description
  api_get user/folders | PP_FOLDER="$FOLDER_NAME" perl -MJSON::PP -0777 -e '
    binmode STDOUT, ":utf8";
    my $d = decode_json(<STDIN>);
    my ($f) = grep { $_->{name} eq $ENV{PP_FOLDER} } @$d;
    exit 0 unless $f;
    for my $x (@{ $f->{files} || [] }) {
      my $meta = $x->{originalName} // $x->{name};
      $meta =~ s/\.html$//;
      $meta =~ s/[\t\r\n]/ /g;
      my ($title, $desc) = split /\|\|/, $meta, 2;
      printf "%s\t%s\t%s\t%s\t%s\t%s\n",
        $x->{name}, $x->{id}, $title,
        substr($x->{createdAt} // "", 0, 10),
        $x->{deletesAt} ? substr($x->{deletesAt}, 0, 10) : "never",
        $desc // "";
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

html_escape() { echo "$1" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g; s/"/\&quot;/g'; }

ascii_meta() { # ascii_meta <text> — ASCII-safe metadata for the multipart filename
  echo "$1" | perl -CSD -pe '
    s/[\x{2014}\x{2013}\x{2212}]/-/g;      # em dash, en dash, minus
    s/[\x{2018}\x{2019}]/\x27/g;           # curly single quotes
    s/[\x{201C}\x{201D}]//g;               # curly double quotes (quotes are stripped anyway)
    s/\x{2026}/.../g;                      # ellipsis
    s/\x{00D7}/x/g;                        # multiplication sign
    s/[\x{2192}\x{2794}]/->/g;             # arrows
    s/[^\x00-\x7F]//g;                     # drop any other non-ASCII
  ' | tr -d '\t\r\n";\\|'
}

html_unescape() { echo "$1" | sed 's/&lt;/</g; s/&gt;/>/g; s/&quot;/"/g; s/&amp;/\&/g'; }

is_full_page() { head -c 512 "$1" | grep -qi '<!doctype\|<html'; }

html_title() { # html_title <file> — <title> of a full page as plain text, or basename
  local t
  t="$(tr -d '\n' < "$1" | sed -n 's:.*<title>\(.*\)</title>.*:\1:p' | head -1)"
  if [ -n "$t" ]; then html_unescape "$t"; else basename "$1" .html; fi
}

fragment_title() { # fragment_title <file> — first <h1> as plain text, or basename
  local t
  t="$(tr -d '\n' < "$1" | sed -n 's:.*<h1[^>]*>\(.*\)</h1>.*:\1:p' | head -1 | sed 's/<[^>]*>//g')"
  if [ -n "$t" ]; then html_unescape "$t"; else basename "$1" | sed 's/\.[^.]*$//'; fi
}

# ---------- mermaid validation ----------

# check_mermaid <html-file>
# Parses every <pre class="mermaid"> block with the real mermaid parser
# (node + mermaid@11 in a cache dir, installed on first use) and dies with
# the parse errors if any block is invalid — so bad diagrams are caught
# before upload, not by readers. Infrastructure problems (no node, install
# failure) only warn: publishing must not depend on npm being healthy.
check_mermaid() {
  grep -q 'class="[^"]*mermaid' "$1" || return 0
  if ! command -v node >/dev/null 2>&1 || ! command -v npm >/dev/null 2>&1; then
    echo "planpage: warning: mermaid blocks not validated (node/npm not found)" >&2
    return 0
  fi
  local vdir="$CACHE_DIR/mermaid-check"
  if [ ! -d "$vdir/node_modules/mermaid" ] || [ ! -d "$vdir/node_modules/happy-dom" ]; then
    echo "planpage: installing mermaid validator (one-time)..." >&2
    mkdir -p "$vdir"
    if ! npm install --prefix "$vdir" --no-audit --no-fund --loglevel=error \
        mermaid@11 happy-dom >/dev/null 2>&1; then
      echo "planpage: warning: mermaid validator install failed; skipping check" >&2
      return 0
    fi
  fi
  # run the checker from the cache dir so bare imports resolve against
  # the node_modules installed there
  cp "$SCRIPT_DIR/check-mermaid.mjs" "$vdir/check-mermaid.mjs"
  local out rc=0
  out="$(node "$vdir/check-mermaid.mjs" "$1" 2>&1)" || rc=$?
  case "$rc" in
    0) ;;
    1) die "page has invalid mermaid — fix the diagram source and re-publish (--no-check to override):
$out" ;;
    *) echo "planpage: warning: mermaid check skipped ($out)" >&2 ;;
  esac
}

# ---------- page chrome ----------

# inject_toc <fragment-file>
# Gives every <h2> an id and, when there are 3 or more, inserts an
# "On this page" TOC after the .meta block (or the <h1>). In-place.
inject_toc() {
  perl -0777 -e '
    binmode STDOUT, ":utf8";
    local $/; open my $fh, "<:utf8", $ARGV[0] or exit 1; my $f = <$fh>; close $fh;
    my (@items, %seen);
    $f =~ s{<h2([^>]*)>(.*?)</h2>}{
      my ($attrs, $inner) = ($1, $2);
      (my $txt = $inner) =~ s/<[^>]*>//g;
      my $id;
      if ($attrs =~ /id="([^"]+)"/) { $id = $1 }
      else {
        ($id = lc $txt) =~ s/&[#a-z0-9]+;/ /g;
        $id =~ s/[^a-z0-9]+/-/g; $id =~ s/^-+|-+$//g;
        $id = "section" unless length $id;
        $id .= "-" . $seen{$id} if $seen{$id}++;
        $attrs = " id=\"$id\"$attrs";
      }
      push @items, [$id, $txt];
      "<h2$attrs>$inner</h2>";
    }gse;
    if (@items >= 3) {
      my $toc = "<nav class=\"toc\"><details open><summary>On this page</summary><ol>"
        . join("", map { "<li><a href=\"#$$_[0]\">$$_[1]</a></li>" } @items)
        . "</ol></details></nav>";
      $f =~ s{(<div class="meta".*?</div>)}{$1\n$toc}s
        or $f =~ s{(</h1>)}{$1\n$toc}s
        or $f = "$toc\n$f";
    }
    open my $out, ">:utf8", $ARGV[0] or exit 1; print $out $f;
  ' "$1"
}

# wrap_page <fragment-file> <title>
# Emits the full page: stylesheet, site header with index nav, TOC, the
# fragment inside <main>, and a footer with sources (from $SOURCES_HTML),
# description meta (from $DESCRIPTION), reading time, and publish date.
wrap_page() {
  local title_esc index_url now words read_html="" desc_meta="" mermaid_js="" page_js=""
  title_esc="$(html_escape "$2")"
  index_url="$(page_url "$INDEX_SLUG.html")"
  now="$(date +%Y-%m-%d)"

  inject_toc "$1"

  words="$(sed 's/<[^>]*>//g' "$1" | wc -w)"
  [ "$words" -ge 150 ] && read_html=" &middot; ~$(( (words + 219) / 220 )) min read"

  if [ -n "${DESCRIPTION:-}" ]; then
    desc_meta="<meta name=\"description\" content=\"$(html_escape "$DESCRIPTION")\">
<meta property=\"og:description\" content=\"$(html_escape "$DESCRIPTION")\">"
  fi

  if [ -n "$RENDER_URL" ] && grep -q 'class="mermaid"' "$1"; then
    mermaid_js='<script type="module">
import mermaid from "https://cdn.jsdelivr.net/npm/mermaid@11/dist/mermaid.esm.min.mjs";
const dark = document.documentElement.dataset.theme
  ? document.documentElement.dataset.theme === "dark"
  : matchMedia("(prefers-color-scheme: dark)").matches;
mermaid.initialize({ startOnLoad: false, theme: dark ? "dark" : "neutral" });
// parse each block first: an invalid one degrades to its source + the parse
// error instead of mermaid'"'"'s "Syntax error in text" bomb
const nodes = [];
for (const el of document.querySelectorAll(".mermaid")) {
  const src = el.textContent;
  try { await mermaid.parse(src); nodes.push(el); }
  catch (e) {
    const box = document.createElement("div");
    box.className = "mermaid-error";
    const msg = document.createElement("p");
    msg.textContent = "Diagram failed to render: " + String(e.message ?? e).split("\n")[0];
    const pre = document.createElement("pre");
    pre.textContent = src.trim();
    box.append(msg, pre);
    el.replaceWith(box);
  }
}
if (nodes.length) await mermaid.run({ nodes });
</script>'
  fi

  if [ -n "$RENDER_URL" ]; then
    page_js='<script>
(function () {
  var KEY = "planpage-theme", root = document.documentElement;
  function eff() {
    return root.dataset.theme ||
      (matchMedia("(prefers-color-scheme: dark)").matches ? "dark" : "light");
  }
  var btn = document.createElement("button");
  btn.className = "theme-toggle";
  btn.setAttribute("aria-label", "Toggle color theme");
  function paint() { btn.textContent = eff() === "dark" ? "☀" : "☾"; }
  btn.onclick = function () {
    root.dataset.theme = eff() === "dark" ? "light" : "dark";
    try { localStorage.setItem(KEY, root.dataset.theme); } catch (e) {}
    paint();
  };
  paint();
  var shell = document.querySelector("header.site .shell");
  if (shell) shell.appendChild(btn);

  // never touch mermaid blocks: this classic script runs before the mermaid
  // module, and injected button text would corrupt the diagram source
  document.querySelectorAll("main pre:not(.mermaid)").forEach(function (pre) {
    var txt = pre.innerText;
    var b = document.createElement("button");
    b.className = "copy-btn";
    b.textContent = "copy";
    b.onclick = function () {
      navigator.clipboard.writeText(txt).then(function () {
        b.textContent = "copied";
        setTimeout(function () { b.textContent = "copy"; }, 1200);
      });
    };
    pre.appendChild(b);
  });
})();
</script>'
  fi

  cat <<EOF
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="robots" content="noindex">
<title>$title_esc</title>
<meta property="og:title" content="$title_esc">
<meta property="og:site_name" content="$(html_escape "$SITE_NAME")">
<meta property="og:type" content="article">
$desc_meta
<link rel="icon" href="data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 100 100'%3E%3Ctext y='.9em' font-size='90'%3E$FAVICON%3C/text%3E%3C/svg%3E">
<script>try{var t=localStorage.getItem("planpage-theme");if(t)document.documentElement.dataset.theme=t}catch(e){}</script>
<style>
  :root {
    --bg: #fafafa; --surface: #ffffff; --fg: #1a1a1a; --muted: #666a73;
    --line: #e4e4e8; --accent: #4756e6; --accent-soft: #eef0ff;
    --ok: #1a7f4b; --ok-soft: #e4f5ec; --warn: #955d00; --warn-soft: #fdf2dd;
    --risk: #b3261e; --risk-soft: #fdecea; --code-bg: #f1f1f4;
  }
  @media (prefers-color-scheme: dark) {
    :root:not([data-theme="light"]) {
      --bg: #101014; --surface: #17171c; --fg: #e8e8ea; --muted: #9a9aa2;
      --line: #2a2a31; --accent: #8b96ff; --accent-soft: #23244a;
      --ok: #58c48c; --ok-soft: #143526; --warn: #e2b45c; --warn-soft: #3a2d12;
      --risk: #f2827a; --risk-soft: #3d1a17; --code-bg: #202027;
    }
  }
  :root[data-theme="dark"] {
    --bg: #101014; --surface: #17171c; --fg: #e8e8ea; --muted: #9a9aa2;
    --line: #2a2a31; --accent: #8b96ff; --accent-soft: #23244a;
    --ok: #58c48c; --ok-soft: #143526; --warn: #e2b45c; --warn-soft: #3a2d12;
    --risk: #f2827a; --risk-soft: #3d1a17; --code-bg: #202027;
  }
  * { box-sizing: border-box; }
  body { margin: 0; background: var(--bg); color: var(--fg); min-height: 100vh;
         display: flex; flex-direction: column;
         font: 16px/1.65 ui-sans-serif, system-ui, -apple-system, "Segoe UI", sans-serif; }

  header.site { border-bottom: 1px solid var(--line); }
  header.site .shell { max-width: 46rem; margin: 0 auto; padding: .7rem 1.25rem;
    display: flex; align-items: center; gap: .6rem; }
  header.site .brand { font-weight: 700; font-size: .9rem; letter-spacing: .02em;
    color: var(--muted); text-decoration: none; margin-right: auto; }
  header.site .nav-index { font-size: .85rem; font-weight: 600; color: var(--accent);
    background: var(--accent-soft); padding: .3rem .8rem; border-radius: 99px;
    text-decoration: none; }
  header.site .nav-index:hover { text-decoration: underline; }
  .theme-toggle { background: none; border: 1px solid var(--line); border-radius: 99px;
    color: var(--muted); width: 2rem; height: 2rem; cursor: pointer; font-size: .9rem;
    line-height: 1; }

  main { flex: 1; width: 100%; max-width: 46rem; margin: 0 auto; padding: 2.5rem 1.25rem 4rem; }
  main > h1:first-child { margin-top: 0; }

  nav.toc { margin: 0 0 2rem; }
  nav.toc details { border: 1px solid var(--line); border-radius: 10px;
    background: var(--surface); }
  nav.toc summary { cursor: pointer; padding: .6rem 1rem; font-weight: 600;
    font-size: .85rem; color: var(--muted); user-select: none; }
  nav.toc ol { margin: 0; padding: .25rem 1rem .75rem 2.4rem; font-size: .9rem; }
  nav.toc li { margin: .2rem 0; }
  nav.toc a { text-decoration: none; }
  nav.toc a:hover { text-decoration: underline; }

  footer.site { border-top: 1px solid var(--line); }
  footer.site .shell { max-width: 46rem; margin: 0 auto; padding: 1.5rem 1.25rem 2rem; }
  footer.site .sources h2 { font-size: .8rem; text-transform: uppercase;
    letter-spacing: .06em; color: var(--muted); margin: 0 0 .5rem; }
  footer.site .sources ul { margin: 0 0 1.25rem; padding-left: 1.25rem; font-size: .9rem; }
  footer.site .sources li { margin: .25rem 0; }
  footer.site .colophon { color: var(--muted); font-size: .8rem; margin: 0; }
  footer.site .colophon a { color: var(--muted); }

  h1 { font-size: 1.9rem; line-height: 1.25; margin: 0 0 .5rem; letter-spacing: -.02em; }
  h2 { font-size: 1.25rem; margin: 2.5rem 0 .75rem; letter-spacing: -.01em; }
  h3 { font-size: 1rem; margin: 1.75rem 0 .5rem; }
  p { margin: .75rem 0; }
  a { color: var(--accent); }
  .meta { color: var(--muted); font-size: .875rem; display: flex; gap: 1rem;
          flex-wrap: wrap; margin-bottom: 2rem; }

  .badge { display: inline-block; font-size: .75rem; font-weight: 600; padding: .1rem .55rem;
           border-radius: 99px; vertical-align: 2px; }
  .badge.ok { color: var(--ok); background: var(--ok-soft); }
  .badge.warn { color: var(--warn); background: var(--warn-soft); }
  .badge.risk { color: var(--risk); background: var(--risk-soft); }
  .badge.info { color: var(--accent); background: var(--accent-soft); }

  details { border: 1px solid var(--line); border-radius: 10px; background: var(--surface);
            margin: .75rem 0; }
  details summary { cursor: pointer; padding: .8rem 1rem; font-weight: 600; user-select: none; }
  details[open] summary { border-bottom: 1px solid var(--line); }
  details .body { padding: .25rem 1rem .9rem; }
  nav.toc details[open] summary { border-bottom: 0; }

  code { font: .85em ui-monospace, "Cascadia Code", Consolas, monospace;
         background: var(--code-bg); padding: .12em .35em; border-radius: 5px; }
  pre { background: var(--code-bg); border: 1px solid var(--line); border-radius: 10px;
        padding: 1rem; overflow-x: auto; position: relative; }
  pre code { background: none; padding: 0; }
  .copy-btn { position: absolute; top: .5rem; right: .5rem; font-size: .7rem;
    background: var(--surface); color: var(--muted); border: 1px solid var(--line);
    border-radius: 6px; padding: .15rem .5rem; cursor: pointer; }

  table { width: 100%; border-collapse: collapse; margin: 1rem 0; font-size: .925rem; }
  th { text-align: left; font-size: .72rem; text-transform: uppercase; letter-spacing: .06em;
       color: var(--muted); padding: .45rem .7rem; border-bottom: 2px solid var(--line); }
  td { padding: .55rem .7rem; border-bottom: 1px solid var(--line); vertical-align: top; }

  ol.steps { padding-left: 0; counter-reset: step; list-style: none; }
  ol.steps > li { counter-increment: step; position: relative; padding: 0 0 1.1rem 2.6rem; }
  ol.steps > li::before { content: counter(step); position: absolute; left: 0; top: .05rem;
    width: 1.7rem; height: 1.7rem; border-radius: 50%; background: var(--accent-soft);
    color: var(--accent); font-weight: 700; font-size: .85rem;
    display: flex; align-items: center; justify-content: center; }
  ol.steps > li:not(:last-child)::after { content: ""; position: absolute; left: .82rem;
    top: 1.95rem; bottom: .15rem; width: 2px; background: var(--line); }

  .mermaid-error { border: 1px solid var(--risk); border-radius: 10px;
    background: var(--risk-soft); padding: .75rem 1rem; margin: 1rem 0; }
  .mermaid-error > p { color: var(--risk); font-size: .85rem; font-weight: 600;
    margin: 0 0 .5rem; }
  .mermaid-error > pre { margin: 0; }

  blockquote { margin: 1rem 0; padding: .6rem 1rem; border-left: 3px solid var(--accent);
               background: var(--surface); border-radius: 0 8px 8px 0; color: var(--muted); }
  hr { border: 0; border-top: 1px solid var(--line); margin: 2.5rem 0; }
  ul, ol { padding-left: 1.4rem; }
  li { margin: .3rem 0; }
  img { max-width: 100%; }

  @media (max-width: 640px) {
    main { padding: 1.75rem 1rem 3rem; }
    h1 { font-size: 1.5rem; }
    header.site .shell, footer.site .shell { padding-left: 1rem; padding-right: 1rem; }
    table { display: block; overflow-x: auto; }
    .meta { gap: .6rem; }
  }

  @media print {
    header.site, footer.site .colophon, nav.toc, .copy-btn, .theme-toggle { display: none; }
    body { background: #fff; color: #000; }
    main { max-width: 100%; padding: 0; }
    a { color: inherit; }
    pre, details { border-color: #bbb; }
  }
</style>
</head>
<body>
<header class="site">
  <div class="shell">
    <a class="brand" href="$index_url">$(html_escape "$SITE_NAME")</a>
    <a class="nav-index" href="$index_url">All pages</a>
  </div>
</header>
<main>
$(cat "$1")
</main>
<footer class="site">
  <div class="shell">
$SOURCES_HTML
    <p class="colophon">Published $now$read_html &middot; <a href="$index_url">All pages</a> &middot; $(html_escape "$SITE_NAME")</p>
  </div>
</footer>
$mermaid_js
$page_js
</body>
</html>
EOF
}

build_sources_html() { # build_sources_html "Label|url" ... -> sets SOURCES_HTML
  SOURCES_HTML=""
  [ $# -gt 0 ] || return 0
  local s label url items=""
  for s in "$@"; do
    case "$s" in
      *"|"*) label="${s%%|*}"; url="${s#*|}" ;;
      *) label="$s"; url="$s" ;;
    esac
    label="$(echo "$label" | sed 's/^ *//; s/ *$//')"
    url="$(echo "$url" | sed 's/^ *//; s/ *$//')"
    items="$items<li><a href=\"$(html_escape "$url")\">$(html_escape "$label")</a></li>"
  done
  SOURCES_HTML="    <section class=\"sources\"><h2>Sources</h2><ul>$items</ul></section>"
}

# ---------- index page ----------

month_name() { # month_name <YYYY-MM> -> "July 2026"
  local y="${1%%-*}" m="${1##*-}" n=""
  case "$m" in
    01) n=January ;; 02) n=February ;; 03) n=March ;; 04) n=April ;;
    05) n=May ;; 06) n=June ;; 07) n=July ;; 08) n=August ;;
    09) n=September ;; 10) n=October ;; 11) n=November ;; 12) n=December ;;
    *) n="$1"; y="" ;;
  esac
  echo "$n $y"
}

regen_index() {
  local frag="${TMPDIR:-/tmp}/planpage-index-frag.$$.html"
  local page="${TMPDIR:-/tmp}/planpage-index.$$.html"
  # locals matter: bash scopes dynamically, and without these the read loop
  # would clobber the caller do_publish's title/url before it echoes them
  local rows="" name id title desc published expires month prev_month="" desc_html search_html=""
  while IFS=$'\t' read -r name id title published expires desc; do
    [ -n "$name" ] || continue
    [ "$name" = "$INDEX_SLUG.html" ] && continue
    month="${published%-*}"
    if [ "$month" != "$prev_month" ]; then
      rows="$rows<tr class=\"month\"><td colspan=\"4\">$(month_name "$month")</td></tr>"
      prev_month="$month"
    fi
    desc_html=""
    [ -n "$desc" ] && desc_html="<div class=\"desc\">$(html_escape "$desc")</div>"
    rows="$rows<tr class=\"page\"><td><a href=\"$(page_url "$name")\">$(html_escape "$title")</a>$desc_html</td><td><code>${name%.html}</code></td><td>$published</td><td>$expires</td></tr>"
  done < <(folder_files | sort -t"$(printf '\t')" -k4,4r -k1,1)

  if [ -n "$RENDER_URL" ]; then
    search_html='<input id="pp-search" type="search" placeholder="Filter pages&hellip;" aria-label="Filter pages">
<script>
document.addEventListener("DOMContentLoaded", function () {
  var box = document.getElementById("pp-search");
  box.addEventListener("input", function () {
    var q = box.value.toLowerCase();
    document.querySelectorAll("tr.page").forEach(function (tr) {
      tr.style.display = tr.textContent.toLowerCase().indexOf(q) === -1 ? "none" : "";
    });
    document.querySelectorAll("tr.month").forEach(function (m) {
      var el = m.nextElementSibling, any = false;
      while (el && !el.classList.contains("month")) {
        if (el.style.display !== "none") { any = true; break; }
        el = el.nextElementSibling;
      }
      m.style.display = any ? "" : "none";
    });
  });
});
</script>
<style>
#pp-search { width: 100%; margin: 0 0 1rem; padding: .55rem .9rem; font: inherit;
  color: var(--fg); background: var(--surface); border: 1px solid var(--line);
  border-radius: 10px; }
#pp-search:focus { outline: 2px solid var(--accent-soft); border-color: var(--accent); }
</style>'
  fi

  cat > "$frag" <<EOF
<h1>Published pages</h1>
$search_html
<table>
<thead><tr><th>Page</th><th>Slug</th><th>Published</th><th>Expires</th></tr></thead>
<tbody>$rows</tbody>
</table>
<style>
tr.month td { font-size: .8rem; font-weight: 700; text-transform: uppercase;
  letter-spacing: .06em; color: var(--muted); padding-top: 1.4rem; border-bottom: 0; }
td .desc { color: var(--muted); font-size: .85rem; margin-top: .15rem; }
</style>
EOF
  SOURCES_HTML="" DESCRIPTION="" wrap_page "$frag" "Published pages" > "$page"
  rm -f "$frag"
  do_publish "$page" --slug "$INDEX_SLUG" --title "Published pages" --expires never --no-open --no-index --quiet
  rm -f "$page"
}

# ---------- publish ----------

do_publish() {
  local file="" slug="" title="" expires="$DEFAULT_EXPIRY" password="" do_open=1 do_index=1 quiet=0 do_check=1
  local -a sources=()
  DESCRIPTION=""
  file="$1"; shift
  while [ $# -gt 0 ]; do
    case "$1" in
      --slug) slug="$2"; shift 2 ;;
      --title) title="$2"; shift 2 ;;
      --description) DESCRIPTION="$2"; shift 2 ;;
      --source) sources+=("$2"); shift 2 ;;
      --expires) expires="$2"; shift 2 ;;
      --password) password="$2"; shift 2 ;;
      --no-open) do_open=0; shift ;;
      --no-index) do_index=0; shift ;;
      --no-check) do_check=0; shift ;;
      --quiet) quiet=1; shift ;;
      *) die "unknown option: $1" ;;
    esac
  done
  [ -f "$file" ] || die "file not found: $file"
  [ "$expires" = "never" ] && expires=""

  local tmp=""

  # markdown mode: convert to an HTML fragment first
  case "$file" in
    *.md|*.markdown)
      if [ -z "$title" ]; then
        title="$(sed -n 's/^#[[:space:]]\{1,\}\(.*\)$/\1/p' "$file" | head -1)"
        [ -n "$title" ] || title="$(basename "$file" | sed 's/\.[^.]*$//')"
      fi
      tmp="${TMPDIR:-/tmp}/planpage-md.$$.html"
      perl "$SCRIPT_DIR/md2html.pl" < "$file" > "$tmp" || die "markdown conversion failed"
      file="$tmp"
      ;;
  esac

  # validate mermaid blocks before anything is uploaded (fragments and
  # full pages alike); dies with the parse errors on failure
  [ "$do_check" = 1 ] && check_mermaid "$file"

  # wrap fragments in the shared chrome; full pages pass through untouched
  if is_full_page "$file"; then
    [ -n "$title" ] || title="$(html_title "$file")"
    [ ${#sources[@]} -eq 0 ] || die "--source requires a fragment (full pages own their chrome)"
  else
    [ -n "$title" ] || title="$(fragment_title "$file")"
    build_sources_html ${sources[@]+"${sources[@]}"}
    local workcopy="${TMPDIR:-/tmp}/planpage-frag.$$.html"
    local wrapped="${TMPDIR:-/tmp}/planpage-page.$$.html"
    cp "$file" "$workcopy"   # inject_toc edits in place; never touch the input
    wrap_page "$workcopy" "$title" > "$wrapped"
    rm -f "$workcopy"
    [ -n "$tmp" ] && rm -f "$tmp"
    tmp="$wrapped"
    file="$wrapped"
  fi

  # title (+ optional description after ||) travels as the multipart filename
  # -> Zipline originalName. Multipart header values are latin-1/ASCII by
  # spec: raw UTF-8 arrives server-side as U+FFFD, so transliterate typography
  # to ASCII and drop the rest (the page HTML itself keeps real unicode).
  local safe_meta
  safe_meta="$(ascii_meta "$title")"
  if [ -n "$DESCRIPTION" ]; then
    safe_meta="$safe_meta||$(ascii_meta "$DESCRIPTION")"
  fi

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
      -F "file=@$(basename "$file");type=text/html;filename=\"$safe_meta.html\"" \
      "$ZIPLINE_URL/api/upload")" \
    || die "upload failed (check ZIPLINE_URL/ZIPLINE_TOKEN)"

  local name url
  name="$(echo "$resp" | json_get name)"
  [ -n "$name" ] || die "could not parse upload response: $resp"
  if [ -n "$password" ]; then
    # protected files 403 on the raw route; only Zipline's viewer can unlock them
    url="$ZIPLINE_URL/view/$name"
  else
    url="$(page_url "$name")"
  fi

  [ -n "$tmp" ] && rm -f "$tmp"
  [ "$do_index" = 1 ] && regen_index
  [ "$do_open" = 1 ] && open_url "$url"
  if [ "$quiet" = 0 ]; then
    echo "published: $title"
    [ -n "$password" ] && echo "note: password-protected pages open in Zipline's viewer (source view + password prompt), not as a rendered page — prefer an expiring random link for sensitive content"
    echo "$url"
  fi
}

# ---------- commands ----------

cmd="${1:-}"; shift || true
case "$cmd" in
  publish)
    [ $# -ge 1 ] || die "usage: planpage.sh publish <fragment.html|page.html|file.md> [options]"
    do_publish "$@"
    ;;
  list)
    rows="$(folder_files)"
    [ -n "$rows" ] || { echo "nothing published yet"; exit 0; }
    printf '%-24s %-12s %-12s %s\n' "SLUG" "PUBLISHED" "EXPIRES" "URL"
    # shellcheck disable=SC2034  # id/title/desc are positional, unused here
    while IFS=$'\t' read -r name id title published expires desc; do
      [ -n "$name" ] && printf '%-24s %-12s %-12s %s\n' \
        "${name%.html}" "$published" "$expires" "$(page_url "$name")"
    done <<< "$rows"
    ;;
  find|search)
    [ $# -ge 1 ] || die "usage: planpage.sh find <query>"
    q="$(echo "$*" | tr '[:upper:]' '[:lower:]')"
    found=0
    # shellcheck disable=SC2034  # id/published/expires are positional, unused here
    while IFS=$'\t' read -r name id title published expires desc; do
      [ -n "$name" ] || continue
      hay="$(echo "${name%.html}	$title	$desc" | tr '[:upper:]' '[:lower:]')"
      case "$hay" in *"$q"*)
        printf '%s\t%s\t%s\n' "${name%.html}" "$title" "$(page_url "$name")"
        found=1 ;;
      esac
    done < <(folder_files)
    [ "$found" = 1 ] || die "no published page matching: $*"
    ;;
  url)
    [ $# -ge 1 ] || die "usage: planpage.sh url <slug>"
    [ -n "$(resolve_id "$1")" ] || die "no published page with slug '$1'"
    page_url "$1.html"
    ;;
  open)
    [ $# -ge 1 ] || die "usage: planpage.sh open <slug>"
    [ -n "$(resolve_id "$1")" ] || die "no published page with slug '$1'"
    u="$(page_url "$1.html")"
    open_url "$u"
    echo "$u"
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
    page_url "$INDEX_SLUG.html"
    ;;
  *)
    die "usage: planpage.sh {publish|find|url|open|list|unpublish|index}"
    ;;
esac
