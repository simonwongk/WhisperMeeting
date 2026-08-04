#!/usr/bin/env python3
"""Render and validate the static, action-first WhisperMeet ticket dashboard.

The Markdown board files are authoritative. This script projects them into a self-contained HTML
dashboard for people and gives agents two fast checks:

    python3 Scripts/generate-tickets-dashboard.py          # regenerate the checked-in snapshot
    python3 Scripts/generate-tickets-dashboard.py --check  # validate sources + fail if stale
    python3 Scripts/generate-tickets-dashboard.py --brief  # concise validated handoff summary

It intentionally has no server and no client-side JavaScript. A deterministic source fingerprint
makes ``--check`` meaningful on any day.
"""
from __future__ import annotations

import argparse
import hashlib
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
# Ticket-log metadata is intentionally anchored to a metadata bullet, so an example in evidence
# cannot satisfy the required fields by accident. Older entries may put Outcome and Closed on one
# bullet separated by a middle dot; both supported forms remain valid.
OUTCOME = re.compile(r"^- \*\*Outcome:\*\*\s*([^\s·]+)", re.MULTILINE)
CLOSED = re.compile(
    r"^(?:- \*\*Closed:\*\*|-\s+.*?·\s+\*\*Closed:\*\*)\s*([^·\n]+)",
    re.MULTILINE,
)
NEXT_FREE_ID = re.compile(r"^\*\*Next free ID:\s*`(F\d+)`\.\*\*$", re.MULTILINE)
TICKET_SECTION = re.compile(
    r"\*\*(?:Problem|Impact|Proposed fix|Verification|What I need from you|Root cause|Fix|Evidence|Gaps)(?:[.:])?\*\*",
    re.IGNORECASE,
)

SEVERITY_RANK = {"high": 0, "medium": 1, "low": 2}
STATUS_RANK = {"needs-human": 0, "in-progress": 1, "open": 2, "blocked": 3}
ALLOWED_AREAS = {
    "dictation", "meetings", "recording", "transcription", "recovery", "ui", "privacy", "build", "docs",
}
ALLOWED_STATUSES = {
    "TICKETS.md": {"open", "in-progress", "blocked"},
    "NEEDS_HUMAN.md": {"needs-human"},
}
ALLOWED_OUTCOMES = {"fixed", "partial", "wontfix", "invalid", "duplicate"}
def clean_md(text: str) -> str:
    """Produce readable plain text from the small Markdown subset used by ticket fields."""
    text = re.sub(r"\[([^\]]+)\]\([^)]*\)", r"\1", text)
    text = text.replace("**", "").replace("`", "").replace("*", "")
    return re.sub(r"\s+", " ", text).strip()


def first_sentence(text: str, limit: int = 220) -> str:
    text = clean_md(text)
    # A period followed by a lowercase word is commonly an abbreviation (`vs.`, `e.g.`), not the
    # end of the preview. Sentence endings with stronger punctuation are unambiguous.
    match = re.search(r"(.+?(?:[。!?！？]|\.(?=\s+[A-Z])))", text)
    sentence = match.group(1) if match else text
    return sentence[:limit].rstrip() + "…" if len(sentence) > limit else sentence


def iter_ticket_blocks(md: str):
    """Yield Markdown ticket heading/body pairs, stopping cleanly at board subsections."""
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


def named_section_lines(body: list[str], name: str) -> list[str]:
    """Read a bold ticket section, accepting the optional human-action time hint."""
    head = re.compile(
        r"^\*\*" + re.escape(name) + r"(?:[.:])?\*\*(?:\s*\([^)]*\))?(?:\s*[:.])?\s*(.*)$",
        re.IGNORECASE,
    )
    lines: list[str] = []
    capturing = False
    for raw_line in body:
        fragments = [fragment for fragment in TICKET_SECTION.split(raw_line) if fragment]
        markers = TICKET_SECTION.findall(raw_line)
        expanded: list[str] = []
        if markers and not raw_line.startswith("**"):
            expanded.append(fragments.pop(0))
        for marker, fragment in zip(markers, fragments):
            expanded.append(marker + fragment)
        if not expanded:
            expanded = [raw_line]
        for line in expanded:
            match = head.match(line)
            if match:
                capturing = True
                if match.group(1):
                    lines.append(match.group(1))
                continue
            if capturing:
                if TICKET_SECTION.match(line) or line.startswith("#"):
                    return lines
                if line.strip():
                    lines.append(line.rstrip())
                elif lines:
                    # Action cards need this boundary to keep a closing response instruction out
                    # of the preceding numbered step. Other named sections safely collapse it.
                    lines.append("")
    return lines


def named_section(body: list[str], name: str) -> str:
    return " ".join(named_section_lines(body, name)).strip()


def strip_title(title: str) -> str:
    return re.sub(r"\s*\((?:delivers|subordinate to)[^)]*\)\s*$", "", title, flags=re.IGNORECASE).strip()


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
            return f"Depends on {match.group(0)}" if match else f"Dependency: {clean_md(value)[:48]}"
    match = re.search(r"\((delivers|subordinate to)\s+(F\d+)[^)]*\)", title, re.IGNORECASE)
    if match:
        return f"{match.group(1).title()} {match.group(2)}"
    return "—"


def ticket_link(source: str) -> str:
    """Link to the authoritative local Markdown file, which has no browser anchor IDs."""
    return source


def parse_active_file(filename: str) -> tuple[list[dict], list[str]]:
    path = DOCS / filename
    if not path.exists():
        return [], [f"{filename} is missing"]

    markdown = path.read_text(encoding="utf-8")
    errors: list[str] = []
    if filename == "TICKETS.md" and "# Open tickets" not in markdown:
        errors.append("TICKETS.md is missing its # Open tickets marker")
    for line_number, line in enumerate(markdown.splitlines(), start=1):
        if line.startswith("### F") and not TICKET_HEADER.match(line):
            errors.append(f"{filename}:{line_number} has a malformed ticket heading")

    tickets: list[dict] = []
    for ticket_id, raw_title, body in iter_ticket_blocks(markdown):
        title = strip_title(clean_md(raw_title))
        fields = field_map(body)
        status = fields.get("status", "").lower()
        severity = fields.get("severity", "").lower()
        area = fields.get("area", "").lower()
        owner = fields.get("owner", "")
        prefix = f"{filename} {ticket_id}"

        for required in ("status", "owner", "severity", "area", "filed"):
            if not fields.get(required, "").strip():
                errors.append(f"{prefix} is missing required **{required.title()}:** metadata")
        if status not in ALLOWED_STATUSES[filename]:
            allowed = ", ".join(sorted(ALLOWED_STATUSES[filename]))
            errors.append(f"{prefix} has status {status or 'missing'!r}; {filename} allows: {allowed}")
        if severity not in SEVERITY_RANK:
            errors.append(f"{prefix} has severity {severity or 'missing'!r}; use high, medium, or low")
        if area not in ALLOWED_AREAS:
            errors.append(f"{prefix} has area {area or 'missing'!r}; use a documented ticket area")
        if status == "in-progress" and owner_label(owner, status) == "Unowned":
            errors.append(f"{prefix} is in-progress but has no owner")
        if status == "open" and clean_md(owner) != "—":
            errors.append(f"{prefix} is open but its owner is not —")
        if status == "blocked" and not fields.get("blocked by", "").strip():
            errors.append(f"{prefix} is blocked but has no **Blocked by:** field")

        action_lines = named_section_lines(body, "What I need from you")
        if status == "needs-human" and not action_lines:
            errors.append(f"{prefix} needs a **What I need from you:** action")

        problem = named_section(body, "Problem")
        impact = named_section(body, "Impact")
        proposed_fix = named_section(body, "Proposed fix")
        verification = named_section(body, "Verification")
        for label, value in (("Problem", problem), ("Impact", impact), ("Verification", verification)):
            if not value:
                errors.append(f"{prefix} is missing a **{label}.** section")
        tickets.append({
            "id": ticket_id,
            "num": int(ticket_id[1:]),
            "title": title,
            "status": status,
            "severity": severity,
            "area": area,
            "owner": owner_label(owner, status),
            "dependency": dependency_hint(raw_title, fields),
            "summary": first_sentence(problem or impact),
            "problem": problem,
            "impact": impact,
            "proposed_fix": proposed_fix,
            "verification": verification,
            "action_lines": action_lines,
            "source": filename,
            "link": ticket_link(filename),
        })
    return tickets, errors


def parse_closed() -> tuple[list[dict], list[str]]:
    path = DOCS / "TICKET_LOG.md"
    if not path.exists():
        return [], ["TICKET_LOG.md is missing"]
    lines = path.read_text(encoding="utf-8").splitlines()
    errors: list[str] = []
    closed: list[dict] = []
    for index, line in enumerate(lines):
        header = LOG_HEADER.match(line)
        if not header:
            continue
        ticket_id, raw_title = header.groups()
        body: list[str] = []
        probe = index + 1
        while probe < len(lines) and not LOG_HEADER.match(lines[probe]):
            body.append(lines[probe])
            probe += 1
        joined = "\n".join(body)
        outcome_match = OUTCOME.search(joined)
        if not outcome_match:
            errors.append(f"TICKET_LOG.md {ticket_id} has no **Outcome:**")
        closed_match = CLOSED.search(joined)
        if not closed_match:
            errors.append(f"TICKET_LOG.md {ticket_id} has no **Closed:**")
        outcome = clean_md(outcome_match.group(1)).lower() if outcome_match else ""
        if outcome and outcome not in ALLOWED_OUTCOMES:
            errors.append(
                f"TICKET_LOG.md {ticket_id} has invalid outcome {outcome!r}; "
                f"use: {', '.join(sorted(ALLOWED_OUTCOMES))}"
            )
        title = strip_title(clean_md(raw_title))
        closed.append({
            "id": ticket_id,
            "num": int(ticket_id[1:]),
            "title": title,
            "outcome": outcome,
            "closed": clean_md(closed_match.group(1)) if closed_match else "",
            "source": "TICKET_LOG.md",
            "link": ticket_link("TICKET_LOG.md"),
        })
    return closed, errors


def next_free_id() -> tuple[int | None, list[str]]:
    path = DOCS / "TICKETS.md"
    if not path.exists():
        return None, ["TICKETS.md is missing"]
    match = NEXT_FREE_ID.search(path.read_text(encoding="utf-8"))
    if not match:
        return None, ["TICKETS.md is missing a valid **Next free ID: `F<n>`.** line"]
    return int(match.group(1)[1:]), []


def load_validated() -> tuple[list[dict], list[dict], int]:
    """Return active/closed tickets only after enforcing the documented board contract."""
    active: list[dict] = []
    errors: list[str] = []
    for filename in ("TICKETS.md", "NEEDS_HUMAN.md"):
        tickets, source_errors = parse_active_file(filename)
        active.extend(tickets)
        errors.extend(source_errors)
    human_count = sum(ticket["status"] == "needs-human" for ticket in active)
    if human_count > 5:
        errors.append(f"NEEDS_HUMAN.md has {human_count} tickets; keep at most 5")
    closed, log_errors = parse_closed()
    errors.extend(log_errors)
    next_id, next_id_errors = next_free_id()
    errors.extend(next_id_errors)

    all_tickets = active + closed
    ids = [ticket["id"] for ticket in all_tickets]
    duplicates = sorted({ticket_id for ticket_id in ids if ids.count(ticket_id) > 1}, key=lambda value: int(value[1:]))
    if duplicates:
        errors.append(f"duplicate ticket IDs: {', '.join(duplicates)}")
    if all_tickets and next_id is not None:
        expected = max(ticket["num"] for ticket in all_tickets) + 1
        if next_id != expected:
            errors.append(f"Next free ID is F{next_id}; expected F{expected} after the highest recorded ticket")

    if errors:
        message = "Ticket board validation failed:\n" + "\n".join(f"- {error}" for error in errors)
        raise ValueError(message)

    active.sort(key=lambda ticket: (STATUS_RANK[ticket["status"]], SEVERITY_RANK[ticket["severity"]], ticket["num"]))
    return active, closed, next_id or 1


def source_fingerprint() -> str:
    digest = hashlib.sha256()
    for filename in ("TICKETS.md", "NEEDS_HUMAN.md", "TICKET_LOG.md"):
        path = DOCS / filename
        digest.update(filename.encode("utf-8"))
        digest.update(b"\0")
        digest.update(path.read_bytes())
        digest.update(b"\0")
    return digest.hexdigest()[:12]


def e(text: str) -> str:
    return html.escape(text, quote=True)


def action_html(lines: list[str]) -> str:
    """Keep a human-action checklist readable without pretending to implement Markdown fully."""
    blocks: list[tuple[str, list[str] | str]] = []
    current_items: list[str] | None = None
    blank_boundary = False
    for raw_line in lines:
        if not raw_line.strip():
            blank_boundary = True
            continue
        line = clean_md(raw_line)
        match = re.match(r"^\d+[.)]\s+(.+)$", line)
        if match:
            if current_items is None or blank_boundary:
                current_items = []
                blocks.append(("list", current_items))
            current_items.append(e(match.group(1)))
            blank_boundary = False
        elif current_items and not blank_boundary and raw_line[:1].isspace():
            current_items[-1] += " " + e(line)
        else:
            if blocks and blocks[-1][0] == "paragraph" and not blank_boundary:
                blocks[-1] = ("paragraph", f"{blocks[-1][1]} {e(line)}")
            else:
                blocks.append(("paragraph", e(line)))
            current_items = None
            blank_boundary = False
    rendered = "".join(
        f"<p>{content}</p>" if kind == "paragraph"
        else "<ol>" + "".join(f"<li>{item}</li>" for item in content) + "</ol>"
        for kind, content in blocks
    )
    return rendered or "<p>See the authoritative source for the requested action.</p>"


def details_html(ticket: dict) -> str:
    sections = [
        ("Problem", ticket["problem"]),
        ("Impact", ticket["impact"]),
        ("Proposed fix", ticket["proposed_fix"]),
        ("Verification", ticket["verification"]),
    ]
    visible = [(label, text) for label, text in sections if text]
    if not visible:
        return ""
    body = "".join(f"<dt>{e(label)}</dt><dd>{e(clean_md(text))}</dd>" for label, text in visible)
    return f"<details><summary>Ticket details</summary><dl>{body}</dl></details>"


def ticket_card(ticket: dict, *, action: bool = False) -> str:
    source_instruction = f"Open {ticket['source']}; find {ticket['id']} →"
    source_title = f"Open {ticket['source']} and find {ticket['id']}"
    action_block = ""
    if action:
        action_block = (
            '<div class="human-action"><h4>What I need from you</h4>'
            + action_html(ticket["action_lines"])
            + "</div>"
        )
    summary = f'<p class="summary">{e(ticket["summary"])}</p>' if ticket["summary"] else ""
    return (
        f'<article class="ticket-card sev-{e(ticket["severity"])}">'
        '<div class="ticket-top">'
        f'<a class="id" href="{e(ticket["link"])}" title="{e(source_title)}">{e(ticket["id"])}</a>'
        f'<span class="badge st-{e(ticket["status"])}">{e(ticket["status"])}</span>'
        f'<span class="badge sev-badge-{e(ticket["severity"])}">{e(ticket["severity"])}</span>'
        "</div>"
        f'<h3>{e(ticket["title"])}</h3>'
        f'<p class="meta">{e(ticket["area"])} · owner: {e(ticket["owner"])} · {e(ticket["dependency"])}</p>'
        + action_block
        + summary
        + details_html(ticket)
        + f'<a class="source-link" href="{e(ticket["link"])}" title="{e(source_title)}">{e(source_instruction)}</a>'
        + "</article>"
    )


def cards(tickets: list[dict], *, action: bool = False, empty: str) -> str:
    if not tickets:
        return f'<p class="empty">{e(empty)}</p>'
    return '<div class="ticket-grid">' + "\n".join(ticket_card(ticket, action=action) for ticket in tickets) + "</div>"


PAGE = """<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="color-scheme" content="light dark">
<title>WhisperMeet Work Board</title>
<style>
  :root {{
    --bg:#f5f7fa; --panel:#fff; --text:#20242c; --muted:#667085; --line:#dfe3ea;
    --accent:#2559d8; --accent-bg:#e9efff; --progress:#14723d; --progress-bg:#e4f5e9;
    --attention:#9a6100; --attention-bg:#fff3d6; --danger:#b42318; --danger-bg:#fdecea;
    --low:#596273; --low-bg:#eef1f5;
    font-family:-apple-system,BlinkMacSystemFont,"Segoe UI","Helvetica Neue",sans-serif;
  }}
  @media (prefers-color-scheme: dark) {{
    :root {{
      --bg:#111318; --panel:#1a1d23; --text:#edf0f5; --muted:#a1a8b5; --line:#2d323b;
      --accent:#97b5ff; --accent-bg:#1c2b4e; --progress:#8de0aa; --progress-bg:#163c28;
      --attention:#ffd279; --attention-bg:#41321a; --danger:#ffaaa2; --danger-bg:#452321;
      --low:#b2bac7; --low-bg:#292e36;
    }}
  }}
  * {{ box-sizing:border-box; }}
  body {{ margin:0; background:var(--bg); color:var(--text); }}
  main {{ max-width:1120px; margin:0 auto; padding:32px 20px 64px; }}
  h1 {{ margin:0; font-size:clamp(1.7rem, 4vw, 2.25rem); letter-spacing:-.035em; }}
  h2 {{ margin:36px 0 12px; font-size:1.15rem; letter-spacing:-.01em; }}
  h3 {{ margin:10px 0 5px; font-size:1rem; line-height:1.3; }}
  h4 {{ margin:0 0 6px; font-size:.83rem; }}
  p {{ line-height:1.45; }}
  a {{ color:var(--accent); }}
  .lede {{ margin:8px 0 0; color:var(--muted); max-width:72ch; }}
  .source {{ margin:8px 0 0; color:var(--muted); font-size:.85rem; }}
  .source code {{ font-size:.9em; }}
  .metrics {{ display:grid; grid-template-columns:repeat(auto-fit, minmax(145px, 1fr)); gap:10px; margin-top:24px; }}
  .metric {{ padding:14px; border:1px solid var(--line); border-radius:12px; background:var(--panel); }}
  .metric strong {{ display:block; font-size:1.45rem; font-variant-numeric:tabular-nums; }}
  .metric span {{ color:var(--muted); font-size:.84rem; }}
  .attention {{ margin-top:28px; padding:18px; border:1px solid color-mix(in srgb, var(--attention) 35%, var(--line)); border-radius:14px; background:var(--attention-bg); }}
  .attention h2 {{ margin:0 0 4px; }}
  .attention > p {{ margin:0 0 14px; color:var(--muted); }}
  .ticket-grid {{ display:grid; grid-template-columns:repeat(auto-fit, minmax(280px, 1fr)); gap:12px; }}
  .ticket-card {{ padding:16px; border:1px solid var(--line); border-radius:13px; background:var(--panel); box-shadow:0 1px 1px color-mix(in srgb, var(--text) 4%, transparent); }}
  .ticket-card.sev-high, .ticket-card.sev-medium {{ border-left:4px solid var(--danger); }}
  .ticket-card.sev-low {{ border-left:4px solid var(--low); }}
  .ticket-top {{ display:flex; align-items:center; gap:7px; flex-wrap:wrap; }}
  .id {{ font-weight:750; text-decoration:none; font-variant-numeric:tabular-nums; }}
  .badge {{ display:inline-block; padding:3px 8px; border-radius:999px; font-size:.72rem; font-weight:650; white-space:nowrap; }}
  .st-open {{ color:var(--accent); background:var(--accent-bg); }}
  .st-in-progress {{ color:var(--progress); background:var(--progress-bg); }}
  .st-blocked, .st-needs-human {{ color:var(--attention); background:var(--attention-bg); }}
  .sev-badge-high, .sev-badge-medium {{ color:var(--danger); background:var(--danger-bg); }}
  .sev-badge-low {{ color:var(--low); background:var(--low-bg); }}
  .meta, .summary {{ margin:4px 0 0; color:var(--muted); font-size:.86rem; }}
  .human-action {{ margin-top:12px; padding:11px 12px; border-radius:9px; background:color-mix(in srgb, var(--attention-bg) 72%, var(--panel)); }}
  .human-action p {{ margin:0 0 7px; font-size:.9rem; }}
  .human-action ol {{ margin:0; padding-left:20px; font-size:.9rem; line-height:1.45; }}
  details {{ margin-top:12px; color:var(--muted); font-size:.86rem; }}
  summary {{ cursor:pointer; color:var(--accent); }}
  dl {{ margin:9px 0 0; }}
  dt {{ margin-top:8px; color:var(--text); font-weight:650; }}
  dd {{ margin:2px 0 0; }}
  .source-link {{ display:inline-block; margin-top:13px; font-size:.86rem; font-weight:600; }}
  .empty {{ margin:0; padding:15px; border:1px dashed var(--line); border-radius:10px; color:var(--muted); }}
  .recent {{ margin:0; padding:0; list-style:none; border-top:1px solid var(--line); }}
  .recent li {{ display:flex; gap:8px; align-items:baseline; padding:10px 0; border-bottom:1px solid var(--line); }}
  .recent .outcome, .recent .closed {{ color:var(--muted); font-size:.86rem; }}
  @media (max-width:700px) {{
    main {{ padding:24px 14px 48px; }}
    .metrics {{ grid-template-columns:repeat(2, minmax(0, 1fr)); }}
    .ticket-grid {{ grid-template-columns:1fr; }}
    .recent li {{ align-items:flex-start; flex-wrap:wrap; }}
  }}
</style>
</head>
<body>
<main>
  <h1>WhisperMeet work board</h1>
  <p class="lede">A scan-first view of the authoritative Markdown ticket system: act on human requests first, then continue owned work or pick up a ready ticket.</p>
  <p class="source">Authoritative sources: <a href="TICKETS.md">ticket board</a> · <a href="NEEDS_HUMAN.md">human-action queue</a> · <a href="TICKET_LOG.md">evidence log</a> · source fingerprint <code>{fingerprint}</code></p>
  <section class="metrics" aria-label="Work totals">
    <div class="metric"><strong>{active_count}</strong><span>active tickets</span></div>
    <div class="metric"><strong>{needs_human_count}</strong><span>need your action</span></div>
    <div class="metric"><strong>{in_progress_count}</strong><span>in progress</span></div>
    <div class="metric"><strong>{open_count}</strong><span>ready to take</span></div>
    <div class="metric"><strong>{blocked_count}</strong><span>blocked tickets</span></div>
  </section>
  <section class="attention" aria-labelledby="needs-action">
    <h2 id="needs-action">Needs your action</h2>
    <p>These are the only tickets blocked on a physical check or decision from a person.</p>
    {needs_human_cards}
  </section>
  <section aria-labelledby="in-progress">
    <h2 id="in-progress">In progress</h2>
    {in_progress_cards}
  </section>
  <section aria-labelledby="ready">
    <h2 id="ready">Ready to take</h2>
    {open_cards}
  </section>
  <section aria-labelledby="blocked">
    <h2 id="blocked">Blocked</h2>
    {blocked_cards}
  </section>
  <section aria-labelledby="recently-closed">
    <h2 id="recently-closed">Recently closed</h2>
    <ul class="recent">{recent}</ul>
  </section>
</main>
</body>
</html>
"""


def render_dashboard(active: list[dict], closed: list[dict], next_id: int) -> str:
    by_status = {status: [ticket for ticket in active if ticket["status"] == status] for status in STATUS_RANK}
    recent = closed[:8]
    recent_html = "\n".join(
        f'<li><a class="id" href="{e(ticket["link"])}" title="Open TICKET_LOG.md and find {e(ticket["id"])}">{e(ticket["id"])}</a>'
        f'<span>{e(ticket["title"])}</span>'
        + (f'<span class="outcome">— {e(ticket["outcome"])}</span>' if ticket["outcome"] else "")
        + (f'<span class="closed">closed {e(ticket["closed"] )}</span>' if ticket["closed"] else "")
        + "</li>"
        for ticket in recent
    ) or '<li><span class="empty">No closed tickets recorded yet.</span></li>'

    return PAGE.format(
        fingerprint=source_fingerprint(),
        active_count=len(active),
        needs_human_count=len(by_status["needs-human"]),
        in_progress_count=len(by_status["in-progress"]),
        open_count=len(by_status["open"]),
        blocked_count=len(by_status["blocked"]),
        needs_human_cards=cards(
            by_status["needs-human"],
            action=True,
            empty="No human action is waiting right now.",
        ),
        in_progress_cards=cards(
            by_status["in-progress"],
            empty="No ticket is currently claimed.",
        ),
        open_cards=cards(
            by_status["open"],
            empty="No unowned ticket is ready to take.",
        ),
        blocked_cards=cards(
            by_status["blocked"],
            empty="No ticket is blocked on another dependency.",
        ),
        recent=recent_html,
    )


def render_brief(active: list[dict], next_id: int) -> str:
    lines = [f"Next free ID: F{next_id}"]
    labels = (
        ("needs-human", "Needs human"),
        ("in-progress", "In progress"),
        ("open", "Ready"),
        ("blocked", "Blocked"),
    )
    for status, label in labels:
        tickets = [ticket for ticket in active if ticket["status"] == status]
        if not tickets:
            continue
        lines.append(f"{label}:")
        lines.extend(f"- {ticket['id']} — {ticket['title']} ({ticket['owner']})" for ticket in tickets)
    return "\n".join(lines)


def arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--check", action="store_true", help="fail when the checked-in dashboard is stale")
    mode.add_argument("--brief", action="store_true", help="print a compact validated ticket handoff")
    return parser.parse_args()


def main() -> None:
    args = arguments()
    try:
        active, closed, next_id = load_validated()
    except ValueError as error:
        raise SystemExit(str(error)) from error

    if args.brief:
        print(render_brief(active, next_id))
        return

    page = render_dashboard(active, closed, next_id)
    if args.check:
        if not DASHBOARD.exists():
            raise SystemExit("Ticket dashboard is missing; run Scripts/generate-tickets-dashboard.py")
        if DASHBOARD.read_text(encoding="utf-8") != page:
            raise SystemExit("Ticket dashboard is stale; run Scripts/generate-tickets-dashboard.py and commit the result")
        print("Ticket dashboard is current.")
        return

    DASHBOARD.write_text(page, encoding="utf-8")
    summary = ", ".join(
        f"{status}={sum(ticket['status'] == status for ticket in active)}"
        for status in ("needs-human", "in-progress", "open", "blocked")
        if any(ticket["status"] == status for ticket in active)
    )
    print(
        f"Wrote {DASHBOARD.relative_to(ROOT)}: {len(active)} active tickets ({summary}); "
        f"next free ID F{next_id}."
    )


if __name__ == "__main__":
    main()
