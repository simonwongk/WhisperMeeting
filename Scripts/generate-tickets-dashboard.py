#!/usr/bin/env python3
"""Generate docs/tickets-dashboard.html as a plain, static HTML page from the board files.

Parses docs/TICKETS.md (open board), docs/NEEDS_HUMAN.md (human-blocked work), and the
newest closed entries in docs/TICKET_LOG.md, and writes a self-contained, JS-free HTML
table. No server and no client-side scripting — the rows are rendered here. To refresh
after any board change, just run it again:

    python3 Scripts/generate-tickets-dashboard.py

It aborts rather than emit an empty board.
"""
from __future__ import annotations

import datetime
import html
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DOCS = ROOT / "docs"
DASHBOARD = DOCS / "tickets-dashboard.html"

TICKET_HEADER = re.compile(r"^### (F\d+) — (.+?)\s*$")
LOG_HEADER = re.compile(r"^## (F\d+) — (.+?)\s*$")
SECTION_HEADER = re.compile(r"^## ")
FIELD = re.compile(r"^- \*\*([^:*]+?):\*\*\s*(.*)$")
OUTCOME = re.compile(r"^- \*\*Outcome:\*\*\s*(\w+)")

SEVERITY_RANK = {"high": 0, "medium": 1, "low": 2}
STATUS_RANK = {"open": 0, "in-progress": 1, "blocked": 2, "needs-human": 3}


def clean_md(text: str) -> str:
    text = re.sub(r"\[([^\]]+)\]\([^)]*\)", r"\1", text)
    text = text.replace("**", "").replace("`", "").replace("*", "")
    return re.sub(r"\s+", " ", text).strip()


def first_sentence(text: str, limit: int = 200) -> str:
    text = clean_md(text)
    match = re.search(r"(.+?[.。!?！？])(\s|$)", text)
    sentence = match.group(1) if match else text
    return sentence[:limit].rstrip() + "…" if len(sentence) > limit else sentence


def iter_ticket_blocks(md: str):
    lines = md.splitlines()
    i, n = 0, len(lines)
    while i < n:
        header = TICKET_HEADER.match(lines[i])
        if not header:
            i += 1
            continue
        ticket_id, title = header.group(1), header.group(2)
        i += 1
        body: list[str] = []
        while i < n and not TICKET_HEADER.match(lines[i]) and not SECTION_HEADER.match(lines[i]):
            body.append(lines[i])
            i += 1
        yield ticket_id, title, body


def field_map(body: list[str]) -> dict[str, str]:
    fields: dict[str, str] = {}
    for line in body:
        match = FIELD.match(line)
        if match:
            fields[match.group(1).strip().lower()] = match.group(2).strip()
    return fields


def named_section(body: list[str], name: str) -> str:
    head = re.compile(r"^\*\*" + re.escape(name) + r"[.:]?\*\*\s*(.*)$")
    lead = re.compile(r"^\*\*[A-Za-z][^*]*[.:]\*\*")
    out: list[str] = []
    capturing = False
    for line in body:
        match = head.match(line)
        if match:
            capturing = True
            if match.group(1):
                out.append(match.group(1))
            continue
        if capturing:
            if lead.match(line) or line.startswith("#"):
                break
            out.append(line)
    return " ".join(out).strip()


def strip_title(title: str) -> str:
    return re.sub(r"\s*\((?:delivers|subordinate to)[^)]*\)\s*$", "", title, flags=re.I).strip()


def owner_label(owner: str, status: str) -> str:
    owner = clean_md(owner)
    if owner in ("—", "-", "–", ""):
        return "Needs a human" if status == "needs-human" else "Unowned"
    return owner


def dependency_hint(title: str, fields: dict[str, str]) -> str:
    for key, value in fields.items():
        if key.startswith("blocked by"):
            match = re.search(r"F\d+", value)
            return f"Blocked by {match.group(0)}" if match else "Blocked"
        if key.startswith("dependency"):
            match = re.search(r"F\d+", value)
            return f"{match.group(0)} resolved" if match else clean_md(value)[:40]
    match = re.search(r"\((delivers|subordinate to)\s+(F\d+)[^)]*\)", title, re.I)
    if match:
        return f"{match.group(1).title()} {match.group(2)}"
    return "—"


def load_active() -> list[dict]:
    tickets: list[dict] = []
    for filename in ("TICKETS.md", "NEEDS_HUMAN.md"):
        path = DOCS / filename
        if not path.exists():
            continue
        for ticket_id, title, body in iter_ticket_blocks(path.read_text(encoding="utf-8")):
            fields = field_map(body)
            status = fields.get("status", "open").lower()
            problem = (named_section(body, "Problem") or named_section(body, "What I need from you")
                       or named_section(body, "Impact"))
            tickets.append({
                "id": ticket_id,
                "num": int(ticket_id[1:]),
                "title": strip_title(clean_md(title)),
                "status": status,
                "severity": fields.get("severity", "low").lower(),
                "area": fields.get("area", "docs").lower(),
                "owner": owner_label(fields.get("owner", "—"), status),
                "dependency": dependency_hint(title, fields),
                "summary": first_sentence(problem) if problem else "",
                "source": filename,
            })
    tickets.sort(key=lambda t: (SEVERITY_RANK.get(t["severity"], 9),
                                STATUS_RANK.get(t["status"], 9), t["num"]))
    return tickets


def load_recent_closed(limit: int = 8) -> list[tuple[str, str, str]]:
    path = DOCS / "TICKET_LOG.md"
    if not path.exists():
        return []
    lines = path.read_text(encoding="utf-8").splitlines()
    closed: list[tuple[str, str, str]] = []
    for i, line in enumerate(lines):
        header = LOG_HEADER.match(line)
        if not header:
            continue
        outcome = ""
        for probe in lines[i + 1:i + 6]:
            match = OUTCOME.match(probe)
            if match:
                outcome = match.group(1)
                break
        title = strip_title(clean_md(header.group(2)))
        if len(title) > 66:
            title = title[:66].rstrip() + "…"
        closed.append((header.group(1), title, outcome))
        if len(closed) >= limit:
            break
    return closed


def e(text: str) -> str:
    return html.escape(text, quote=False)


PAGE = """<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="color-scheme" content="light dark">
<title>WhisperMeet Ticket Board</title>
<style>
  :root {{ --bg:#f6f7f9; --panel:#fff; --text:#1f2430; --muted:#6b7280; --line:#e2e5ea;
           --open:#2559d8; --open-bg:#e7edfd; --prog:#166534; --prog-bg:#e5f5ea;
           --wait:#8a5800; --wait-bg:#fff2d4; --med:#b42318; --med-bg:#fdecea; --low:#6b7280; --low-bg:#eef0f3;
           font-family:-apple-system,BlinkMacSystemFont,"Segoe UI","Helvetica Neue",sans-serif; }}
  @media (prefers-color-scheme: dark) {{
    :root {{ --bg:#111318; --panel:#1a1d23; --text:#eceef2; --muted:#9aa0ac; --line:#2c313a;
             --open:#8fb0ff; --open-bg:#1e2a4d; --prog:#8bdca6; --prog-bg:#183a27; --wait:#ffce74; --wait-bg:#3d2f18;
             --med:#ff9d93; --med-bg:#412220; --low:#9aa0ac; --low-bg:#262a31; }} }}
  * {{ box-sizing:border-box; }}
  body {{ margin:0; background:var(--bg); color:var(--text); }}
  main {{ max-width:1080px; margin:0 auto; padding:28px 20px 56px; }}
  h1 {{ margin:0 0 4px; font-size:1.7rem; letter-spacing:-0.02em; }}
  h2 {{ margin:32px 0 10px; font-size:1.05rem; }}
  .sub {{ margin:2px 0; color:var(--muted); font-size:0.88rem; }}
  .sub a {{ color:var(--open); }}
  table {{ width:100%; border-collapse:collapse; margin-top:16px; }}
  th, td {{ text-align:left; padding:10px 10px; border-bottom:1px solid var(--line); vertical-align:top; }}
  th {{ color:var(--muted); font-size:0.74rem; font-weight:600; text-transform:uppercase; letter-spacing:0.03em; }}
  tr:hover td {{ background:color-mix(in srgb, var(--line) 30%, transparent); }}
  .id {{ font-weight:700; color:var(--open); white-space:nowrap; font-variant-numeric:tabular-nums; }}
  .title {{ font-weight:600; }}
  .summary {{ color:var(--muted); font-size:0.85rem; margin-top:2px; }}
  .muted {{ color:var(--muted); font-size:0.85rem; white-space:nowrap; }}
  .badge {{ display:inline-block; padding:2px 8px; border-radius:999px; font-size:0.75rem; white-space:nowrap; }}
  .st-open {{ background:var(--open-bg); color:var(--open); }}
  .st-in-progress {{ background:var(--prog-bg); color:var(--prog); }}
  .st-blocked, .st-needs-human {{ background:var(--wait-bg); color:var(--wait); }}
  .sev-high, .sev-medium {{ background:var(--med-bg); color:var(--med); }}
  .sev-low {{ background:var(--low-bg); color:var(--low); }}
  ul.recent {{ margin:8px 0 0; padding:0; list-style:none; }}
  ul.recent li {{ padding:7px 0; border-bottom:1px solid var(--line); font-size:0.9rem; }}
  ul.recent .id {{ margin-right:6px; }}
  ul.recent em {{ color:var(--muted); font-style:normal; }}
  @media (max-width:640px) {{ .hide-sm {{ display:none; }} main {{ padding:20px 12px 40px; }} }}
</style>
</head>
<body>
<main>
<h1>WhisperMeet Ticket Board</h1>
<p class="sub">{count_line}</p>
<p class="sub">Generated {date} from <a href="TICKETS.md">TICKETS.md</a>, <a href="NEEDS_HUMAN.md">NEEDS_HUMAN.md</a>, and <a href="TICKET_LOG.md">TICKET_LOG.md</a> · refresh with <code>Scripts/generate-tickets-dashboard.py</code></p>
<table>
<thead><tr><th>ID</th><th>Ticket</th><th>Status</th><th>Sev</th><th class="hide-sm">Area</th><th class="hide-sm">Owner / dependency</th></tr></thead>
<tbody>
{rows}
</tbody>
</table>
<h2>Recently closed</h2>
<ul class="recent">
{recent}
</ul>
</main>
</body>
</html>
"""


def main() -> None:
    active = load_active()
    if not active:
        sys.exit("Parsed zero active tickets — aborting rather than emit an empty dashboard.")
    ids = [t["id"] for t in active]
    if len(ids) != len(set(ids)):
        dupes = sorted({i for i in ids if ids.count(i) > 1})
        sys.exit(f"Duplicate ticket IDs parsed ({', '.join(dupes)}) — fix the board first.")

    counts: dict[str, int] = {}
    for t in active:
        counts[t["status"]] = counts.get(t["status"], 0) + 1
    order = ["open", "in-progress", "blocked", "needs-human"]
    parts = [f"{counts[s]} {s.replace('-', ' ')}" for s in order if counts.get(s)]
    count_line = f"{len(active)} active — " + " · ".join(parts)

    rows = "\n".join(
        "<tr>"
        f'<td class="id">{e(t["id"])}</td>'
        f'<td><div class="title">{e(t["title"])}</div>'
        + (f'<div class="summary">{e(t["summary"])}</div>' if t["summary"] else "")
        + "</td>"
        f'<td><span class="badge st-{e(t["status"])}">{e(t["status"])}</span></td>'
        f'<td><span class="badge sev-{e(t["severity"])}">{e(t["severity"])}</span></td>'
        f'<td class="hide-sm">{e(t["area"])}</td>'
        f'<td class="hide-sm muted">{e(t["owner"])} · {e(t["dependency"])}</td>'
        "</tr>"
        for t in active
    )

    recent = load_recent_closed()
    recent_html = "\n".join(
        f'<li><span class="id">{e(cid)}</span>{e(title)}'
        + (f' <em>— {e(outcome)}</em>' if outcome else "")
        + "</li>"
        for cid, title, outcome in recent
    ) or "<li><em>No closed tickets recorded yet.</em></li>"

    page = PAGE.format(
        count_line=e(count_line),
        date=datetime.date.today().strftime("%B %-d, %Y"),
        rows=rows,
        recent=recent_html,
    )
    DASHBOARD.write_text(page, encoding="utf-8")

    summary = ", ".join(f"{s}={counts[s]}" for s in order if counts.get(s))
    print(f"Wrote {DASHBOARD.relative_to(ROOT)}: {len(active)} active tickets ({summary}); "
          f"{len(recent)} recent closes.")


if __name__ == "__main__":
    main()
