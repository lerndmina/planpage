/* planpage interactive widgets — inlined by planpage.sh when a page uses
   widget markup and PLANPAGE_RENDER_URL is set (JS mode).

   Declarative: agents author class conventions only, this runtime adds all
   behavior. Widgets: ul.check (checklist + progress), ol.steps.track (step
   status), table.decide (pick an option row), div.notes (per-section notes),
   div.tabs > section[title], table.sortable, details[id] (sticky open state).

   State lives in localStorage keyed by page path. Items are keyed by
   index + first 40 chars of text so republishing with small edits keeps
   ticks. The "Copy state" button serializes every stateful widget into one
   markdown blob for pasting back to an agent. */
(function () {
  "use strict";
  var $ = function (s, r) { return (r || document).querySelector(s); };
  var $$ = function (s, r) { return Array.prototype.slice.call((r || document).querySelectorAll(s)); };
  var main = $("main");
  if (!main) return;

  var KEY = "planpage:state:" + (location.pathname.replace(/\/+$/, "") || "/");
  var state = {};
  try { state = JSON.parse(localStorage.getItem(KEY) || "{}") || {}; } catch (e) {}
  function save() { try { localStorage.setItem(KEY, JSON.stringify(state)); } catch (e) {} }
  function bucket(n) { return state[n] || (state[n] = {}); }
  function norm(t) { return t.replace(/\s+/g, " ").trim(); }
  function itemKey(i, text) { return i + ":" + norm(text).slice(0, 40); }
  function cleanText(el, drop) { // textContent minus injected chrome
    var c = el.cloneNode(true);
    $$(drop || ".count, .note-btn, .step-btn, .note-box", c).forEach(function (x) { x.remove(); });
    return norm(c.textContent);
  }
  function headingFor(el) { // nearest h2/h3 above el
    var n = el;
    while (n && n !== main) {
      var p = n.previousElementSibling;
      while (p) {
        if (/^H[23]$/.test(p.tagName)) return cleanText(p);
        p = p.previousElementSibling;
      }
      n = n.parentElement;
    }
    return "";
  }

  var updaters = []; // bars + counters, re-run after every state change
  function refresh() { updaters.forEach(function (f) { f(); }); }

  /* ---- checklists: ul.check ------------------------------------------ */
  var checks = $$("ul.check", main);
  checks.forEach(function (ul, u) {
    ul.classList.add("js");
    var lid = ul.id || "#" + u;
    var saved = bucket("check")[lid] || (bucket("check")[lid] = {});
    $$(":scope > li", ul).forEach(function (li, i) {
      var k = itemKey(i, li.textContent);
      var box = li.querySelector('input[type="checkbox"]');
      if (!box) { // plain <li> — upgrade to label + checkbox
        var label = document.createElement("label");
        box = document.createElement("input");
        box.type = "checkbox";
        var span = document.createElement("span");
        while (li.firstChild) span.appendChild(li.firstChild);
        label.appendChild(box);
        label.appendChild(span);
        li.appendChild(label);
      }
      box.checked = k in saved ? !!saved[k] : li.hasAttribute("data-checked");
      box.addEventListener("change", function () {
        saved[k] = box.checked ? 1 : 0;
        save();
        refresh();
      });
    });
  });

  // live per-section counters: <span class="count" data-count="<ul id>">
  $$(".count[data-count]", main).forEach(function (c) {
    var target = document.getElementById(c.getAttribute("data-count"));
    if (!target) return;
    updaters.push(function () {
      var boxes = $$('input[type="checkbox"]', target);
      var d = boxes.filter(function (b) { return b.checked; }).length;
      c.textContent = d + "/" + boxes.length;
    });
  });

  /* ---- step tracker: ol.steps.track ---------------------------------- */
  var STATUSES = ["pending", "doing", "done", "blocked"];
  var tracks = $$("ol.steps.track", main);
  tracks.forEach(function (ol, o) {
    ol.classList.add("js");
    var lid = ol.id || "#" + o;
    var saved = bucket("steps")[lid] || (bucket("steps")[lid] = {});
    $$(":scope > li", ol).forEach(function (li, i) {
      var k = itemKey(i, li.textContent);
      var btn = document.createElement("button");
      btn.type = "button";
      btn.className = "step-btn";
      li.insertBefore(btn, li.firstChild);
      function apply() {
        var s = saved[k] || "pending";
        li.dataset.status = s;
        btn.textContent = s === "done" ? "✓" : s === "blocked" ? "✕" : String(i + 1);
        btn.title = "Status: " + s + " — click to change";
      }
      btn.addEventListener("click", function () {
        saved[k] = STATUSES[(STATUSES.indexOf(saved[k] || "pending") + 1) % STATUSES.length];
        save();
        apply();
        refresh();
      });
      apply();
    });
  });

  /* ---- decision picker: table.decide --------------------------------- */
  var decides = $$("table.decide", main);
  decides.forEach(function (tb, d) {
    tb.classList.add("js");
    tb._ppName = tb.getAttribute("data-name") ||
      (tb.caption && norm(tb.caption.textContent)) ||
      headingFor(tb) || "Decision " + (d + 1);
    var saved = bucket("decide");
    var hr = tb.querySelector("thead tr");
    if (hr) hr.insertBefore(document.createElement("th"), hr.firstChild);
    var rows = $$("tbody tr", tb);
    var paints = [];
    rows.forEach(function (tr, i) {
      var k = itemKey(i, tr.cells[0] ? tr.cells[0].textContent : tr.textContent);
      var cell = tr.insertCell(0);
      cell.className = "pick";
      function paint() {
        var on = saved[tb._ppName] === k;
        tr.classList.toggle("picked", on);
        cell.textContent = on ? "●" : "○";
      }
      tr.addEventListener("click", function () {
        if (saved[tb._ppName] === k) delete saved[tb._ppName]; // click again to unpick
        else saved[tb._ppName] = k;
        save();
        paints.forEach(function (p) { p(); });
        refresh();
      });
      paints.push(paint);
      paint();
    });
  });

  /* ---- notes: opt in with one <div class="notes"> -------------------- */
  var noteHosts = $$("div.notes", main);
  if (noteHosts.length) {
    var notes = bucket("notes");
    var makeArea = function (key, placeholder) {
      var ta = document.createElement("textarea");
      ta.className = "note-box";
      ta.placeholder = placeholder;
      ta.value = notes[key] || "";
      var t;
      ta.addEventListener("input", function () {
        clearTimeout(t);
        t = setTimeout(function () {
          if (ta.value.trim()) notes[key] = ta.value;
          else delete notes[key];
          save();
        }, 250);
      });
      return ta;
    };
    noteHosts.forEach(function (div, i) {
      div.appendChild(makeArea(div.getAttribute("data-name") || (i ? "Notes " + (i + 1) : "General notes"),
        "Notes for the agent — saved in this browser; use Copy state to send"));
    });
    // a notes block on the page also enables an ✎ affordance on every h2
    $$("h2", main).forEach(function (h2) {
      if (h2.closest("nav.toc")) return;
      var key = "§ " + cleanText(h2);
      var btn = document.createElement("button");
      btn.type = "button";
      btn.className = "note-btn";
      btn.textContent = "✎ note";
      var ta = null;
      function ensure(show) {
        if (!ta) {
          ta = makeArea(key, "Note on “" + key.slice(2) + "” — saved in this browser");
          h2.insertAdjacentElement("afterend", ta);
        }
        ta.style.display = show ? "" : "none";
      }
      btn.addEventListener("click", function () {
        var show = !ta || ta.style.display === "none";
        ensure(show);
        if (show) ta.focus();
      });
      h2.appendChild(btn);
      if (notes[key]) ensure(true);
    });
  }

  /* ---- tabs: div.tabs > section[title] ------------------------------- */
  $$("div.tabs", main).forEach(function (tabs, ti) {
    var secs = $$(":scope > section", tabs);
    if (!secs.length) return;
    tabs.classList.add("js");
    var tkey = "tab:" + (tabs.id || "#" + ti);
    var view = bucket("view");
    var nav = document.createElement("nav");
    var btns = secs.map(function (sec, i) {
      var b = document.createElement("button");
      b.type = "button";
      b.textContent = sec.getAttribute("title") || "Tab " + (i + 1);
      b.addEventListener("click", function () { pick(i); });
      nav.appendChild(b);
      return b;
    });
    function pick(i) {
      secs.forEach(function (s, j) { s.classList.toggle("active", j === i); });
      btns.forEach(function (b, j) { b.classList.toggle("active", j === i); });
      view[tkey] = i;
      save();
    }
    tabs.insertBefore(nav, tabs.firstChild);
    pick(Math.min(view[tkey] || 0, secs.length - 1));
  });

  /* ---- sortable tables: table.sortable ------------------------------- */
  $$("table.sortable", main).forEach(function (tb) {
    var tbody = tb.tBodies[0];
    if (!tbody) return;
    var ths = $$("thead th", tb);
    ths.forEach(function (th, ci) {
      th.addEventListener("click", function () {
        var dir = th.classList.contains("asc") ? -1 : 1;
        ths.forEach(function (h) { h.classList.remove("asc", "desc"); });
        th.classList.add(dir === 1 ? "asc" : "desc");
        var rows = $$(":scope > tr", tbody);
        rows.sort(function (a, b) {
          var x = norm(a.cells[ci] ? a.cells[ci].textContent : "");
          var y = norm(b.cells[ci] ? b.cells[ci].textContent : "");
          var nx = parseFloat(x.replace(/,/g, ""));
          var ny = parseFloat(y.replace(/,/g, ""));
          if (!isNaN(nx) && !isNaN(ny) && /^[-+]?[\d.,]/.test(x) && /^[-+]?[\d.,]/.test(y)) {
            return dir * (nx - ny);
          }
          return dir * x.localeCompare(y);
        });
        rows.forEach(function (r) { tbody.appendChild(r); });
      });
    });
    if ($$(":scope > tr", tbody).length >= 10) { // filter box for big tables
      var box = document.createElement("input");
      box.type = "search";
      box.className = "pp-filter";
      box.placeholder = "Filter rows…";
      box.addEventListener("input", function () {
        var q = box.value.toLowerCase();
        $$(":scope > tr", tbody).forEach(function (tr) {
          tr.style.display = tr.textContent.toLowerCase().indexOf(q) === -1 ? "none" : "";
        });
      });
      tb.insertAdjacentElement("beforebegin", box);
    }
  });

  /* ---- sticky collapsibles: details[id] ------------------------------ */
  $$("details[id]", main).forEach(function (d) {
    var view = bucket("view");
    var k = "det:" + d.id;
    if (k in view) d.open = !!view[k];
    d.addEventListener("toggle", function () {
      view[k] = d.open ? 1 : 0;
      save();
    });
  });

  /* ---- progress strip + whole-page copy state ------------------------ */
  function totals() {
    var t = 0, d = 0;
    checks.forEach(function (ul) {
      $$('input[type="checkbox"]', ul).forEach(function (b) { t++; if (b.checked) d++; });
    });
    tracks.forEach(function (ol) {
      $$(":scope > li", ol).forEach(function (li) { t++; if (li.dataset.status === "done") d++; });
    });
    return { t: t, d: d };
  }

  function serialize() {
    var lines = [], tot = totals();
    lines.push("Page state — " + document.title);
    var head = location.href + " · copied " + new Date().toISOString().slice(0, 10);
    if (tot.t) head += " · " + tot.d + "/" + tot.t + " done";
    lines.push(head, "");
    $$("ul.check, ol.steps.track", main).forEach(function (el) {
      var sec = headingFor(el) || el.id || "Checklist";
      if (el.matches("ul.check")) {
        var boxes = $$('input[type="checkbox"]', el);
        var dd = boxes.filter(function (b) { return b.checked; }).length;
        lines.push("## " + sec + " (" + dd + "/" + boxes.length + ")");
        $$(":scope > li", el).forEach(function (li) {
          var b = li.querySelector('input[type="checkbox"]');
          lines.push("- [" + (b && b.checked ? "x" : " ") + "] " + cleanText(li));
        });
      } else {
        lines.push("## " + sec);
        $$(":scope > li", el).forEach(function (li, i) {
          var t = li.querySelector("strong");
          var title = (t ? norm(t.textContent) : cleanText(li)).slice(0, 100);
          lines.push((i + 1) + ". [" + (li.dataset.status || "pending") + "] " + title);
        });
      }
      lines.push("");
    });
    var dl = [];
    decides.forEach(function (tb) {
      var picked = $("tbody tr.picked", tb);
      if (picked) {
        dl.push("- " + tb._ppName + ": " +
          norm(picked.cells[1] ? picked.cells[1].textContent : picked.textContent));
      }
    });
    if (dl.length) {
      lines.push("## Decisions");
      lines.push.apply(lines, dl);
      lines.push("");
    }
    var notes = state.notes || {};
    var nl = [];
    Object.keys(notes).forEach(function (k) {
      var label = k.indexOf("§ ") === 0 ? k.slice(2) : k;
      String(notes[k]).split("\n").forEach(function (ln, i) {
        nl.push(i === 0 ? "> (" + label + ") " + ln : "> " + ln);
      });
    });
    if (nl.length) {
      lines.push("## Notes");
      lines.push.apply(lines, nl);
      lines.push("");
    }
    return lines.join("\n").trim() + "\n";
  }

  var stateful = checks.length || tracks.length || decides.length || noteHosts.length;
  if (stateful) {
    var strip = document.createElement("div");
    strip.className = "pp-progress";
    var bar = null;
    if (checks.length || tracks.length) {
      var barWrap = document.createElement("div");
      barWrap.className = "bar";
      bar = document.createElement("div");
      barWrap.appendChild(bar);
      strip.appendChild(barWrap);
    }
    var row = document.createElement("div");
    row.className = "row";
    var label = document.createElement("span");
    label.className = "label";
    var copyBtn = document.createElement("button");
    copyBtn.type = "button";
    copyBtn.textContent = "Copy state";
    copyBtn.title = "Copy every checkbox, status, decision, and note as markdown to paste back to your agent";
    copyBtn.addEventListener("click", function () {
      navigator.clipboard.writeText(serialize()).then(function () {
        copyBtn.textContent = "Copied ✓";
        setTimeout(function () { copyBtn.textContent = "Copy state"; }, 1500);
      });
    });
    var resetBtn = document.createElement("button");
    resetBtn.type = "button";
    resetBtn.textContent = "Reset";
    resetBtn.addEventListener("click", function () {
      if (!confirm("Clear saved checks, statuses, decisions, and notes for this page?")) return;
      delete state.check;
      delete state.steps;
      delete state.decide;
      delete state.notes;
      save();
      location.reload();
    });
    row.appendChild(label);
    row.appendChild(copyBtn);
    row.appendChild(resetBtn);
    strip.appendChild(row);
    var anchor = $(".meta", main) || $("h1", main);
    if (anchor) anchor.insertAdjacentElement("afterend", strip);
    else main.insertBefore(strip, main.firstChild);
    updaters.push(function () {
      var tot = totals();
      if (bar) bar.style.width = (tot.t ? (100 * tot.d / tot.t) : 0) + "%";
      label.textContent = tot.t
        ? tot.d + " of " + tot.t + " done — saves in this browser"
        : "Interactive page — state saves in this browser";
    });
  }

  refresh();
})();
