#!/usr/bin/env python3
"""Regenerate docs/tickets-dashboard.html from the authoritative ticket files.

Parses docs/TICKETS.md (the open board), docs/NEEDS_HUMAN.md (human-blocked work),
and the newest closed entries in docs/TICKET_LOG.md, then rewrites the marked data
regions of the dashboard. The page stays a self-contained file:// document — the data
is baked in as JSON, so it needs no server. Re-run this after any board change:

    python3 Scripts/generate-tickets-dashboard.py

The dashboard's counts, filters, sorting, and detail view are computed in-page from
the `tickets` array, so this script only refreshes the data between the gen: markers;
it never touches the presentation. It aborts rather than emit an empty board.
"""
from __future__ import annotations

import datetime
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DOCS = ROOT / "docs"
DASHBOARD = DOCS / "tickets-dashboard.html"

TICKET_HEADER = re.compile(r"^### (F\d+) — (.+?)\s*$")
LOG_HEADER = re.compile(r"^## (F\d+) — (.+?)\s*$")
SECTION_HEADER = re.compile(r"^## ")  # batch headings that sit between tickets
FIELD = re.compile(r"^- \*\*([^:*]+?):\*\*\s*(.*)$")
OUTCOME = re.compile(r"^- \*\*Outcome:\*\*\s*(\w+)")


def clean_md(text: str) -> str:
    """Markdown span → single-spaced plain text."""
    text = re.sub(r"\[([^\]]+)\]\([^)]*\)", r"\1", text)  # [label](url) -> label
    text = text.replace("**", "").replace("`", "").replace("*", "")
    return re.sub(r"\s+", " ", text).strip()


def first_sentence(text: str, limit: int = 220) -> str:
    text = clean_md(text)
    match = re.search(r"(.+?[.。!?！？])(\s|$)", text)
    sentence = match.group(1) if match else text
    if len(sentence) > limit:
        sentence = sentence[:limit].rstrip() + "…"
    return sentence


def iter_ticket_blocks(md: str):
    """Yield (id, title, body_lines) for each '### F<n> — title' block."""
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
    """Text of a '**Name.**'/'**Name:**' lead-in paragraph, up to the next lead-in."""
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
    for filename, source in (("TICKETS.md", "TICKETS.md"), ("NEEDS_HUMAN.md", "NEEDS_HUMAN.md")):
        path = DOCS / filename
        if not path.exists():
            continue
        for ticket_id, title, body in iter_ticket_blocks(path.read_text(encoding="utf-8")):
            fields = field_map(body)
            status = fields.get("status", "open").lower()
            problem = named_section(body, "Problem") or named_section(body, "What I need from you") \
                or named_section(body, "Impact")
            verification = named_section(body, "Verification")
            tickets.append({
                "id": ticket_id,
                "title": strip_title(clean_md(title)),
                "status": status,
                "severity": fields.get("severity", "low").lower(),
                "area": fields.get("area", "docs").lower(),
                "owner": owner_label(fields.get("owner", "—"), status),
                "dependency": dependency_hint(title, fields),
                "summary": first_sentence(problem) if problem else "(see source)",
                "verification": first_sentence(verification, 260) if verification else "(see source)",
                "source": source,
            })
    return tickets


def load_recent_closed(limit: int = 6) -> list[tuple[str, str, str]]:
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
        if len(title) > 58:
            title = title[:58].rstrip() + "…"
        closed.append((header.group(1), title, outcome))
        if len(closed) >= limit:
            break
    return closed


def esc(text: str) -> str:
    return text.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


def replace_region(html: str, start: str, end: str, inner: str) -> str:
    try:
        a = html.index(start) + len(start)
        b = html.index(end, a)
    except ValueError:
        sys.exit(f"Marker not found in {DASHBOARD.name}: {start!r} .. {end!r}. Aborting so nothing is wiped.")
    return html[:a] + inner + html[b:]


def main() -> None:
    active = load_active()
    if not active:
        sys.exit("Parsed zero active tickets — aborting rather than emit an empty dashboard.")
    ids = [t["id"] for t in active]
    if len(ids) != len(set(ids)):
        dupes = sorted({i for i in ids if ids.count(i) > 1})
        sys.exit(f"Duplicate ticket IDs parsed ({', '.join(dupes)}) — fix the board first.")

    recent = load_recent_closed()
    today = datetime.date.today().strftime("%B %-d, %Y")

    # `tickets` array — JSON is valid JS; neutralize any '</' so a summary can't close <script>.
    ticket_lines = [json.dumps(t, ensure_ascii=False) for t in active]
    tickets_js = "const tickets = [\n" + ",\n".join("  " + line for line in ticket_lines) + "\n];"
    tickets_js = tickets_js.replace("</", "<\\/")
    tickets_block = "\n".join("    " + line for line in tickets_js.splitlines())

    by_status: dict[str, list[str]] = {}
    for t in active:
        by_status.setdefault(t["status"], []).append(t["id"])
    focus = []
    for status, heading in (("in-progress", "In progress"), ("blocked", "Blocked"), ("needs-human", "Needs a human")):
        if by_status.get(status):
            focus.append(f"{heading}: {', '.join(by_status[status])}")
    review = " · ".join(focus) if focus else f"{len(active)} active tickets — all open and unassigned."

    recent_html = "\n".join(
        f'        <div class="recent-item"><strong>{esc(cid)} · {esc(title)}</strong>'
        f'<span>Closed{(" " + esc(outcome)) if outcome else ""}.</span></div>'
        for cid, title, outcome in recent
    ) or '        <div class="recent-item"><span>No closed tickets recorded yet.</span></div>'

    subtitle = (
        "Offline snapshot of active engineering work — the Markdown files remain authoritative. "
        f"Generated {today} from TICKETS.md, NEEDS_HUMAN.md, and TICKET_LOG.md by "
        "Scripts/generate-tickets-dashboard.py."
    )

    html = DASHBOARD.read_text(encoding="utf-8")
    html = replace_region(html, "// gen:tickets:start\n", "    // gen:tickets:end", tickets_block + "\n")
    html = replace_region(html, "<!-- gen:subtitle:start -->", "<!-- gen:subtitle:end -->", esc(subtitle))
    html = replace_region(html, "<!-- gen:review:start -->", "<!-- gen:review:end -->", esc(review))
    html = replace_region(html, "<!-- gen:recent:start -->", "<!-- gen:recent:end -->", "\n" + recent_html + "\n      ")
    DASHBOARD.write_text(html, encoding="utf-8")

    summary = ", ".join(f"{status}={len(v)}" for status, v in sorted(by_status.items()))
    print(f"Refreshed {DASHBOARD.relative_to(ROOT)}: {len(active)} active tickets ({summary}); "
          f"{len(recent)} recent closes; generated {today}.")


if __name__ == "__main__":
    main()
