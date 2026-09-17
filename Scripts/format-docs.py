#!/usr/bin/env python3
"""Reflow WhisperMeet's docs to a consistent 100-column prose width.

Preserved verbatim: fenced code blocks, tables, headings, link-reference definitions,
horizontal rules, and HTML. Blockquote and list prefixes are kept, with continuations
indented to the width of their marker.

Safety: refuses to write a file whose non-code word stream changed. Formatting must never
alter content, so any drift is a bug, not an acceptable edit.
"""
import glob
import os
import re
import sys

WIDTH = 100
FENCE = re.compile(r"^\s*(```|~~~)")
HEADING = re.compile(r"^\s*#{1,6}\s")
RULE = re.compile(r"^\s*([-*_])(\s*\1){2,}\s*$")
LINKDEF = re.compile(r"^\s*\[[^\]]+\]:\s")
TABLE = re.compile(r"^\s*\|")
HTML = re.compile(r"^\s*<")
# "- ", "* ", "1. ", "1) ", optionally indented
BULLET = re.compile(r"^(\s*)([-*+]|\d{1,3}[.)])(\s+)")
QUOTE = re.compile(r"^(\s*>\s?)")
# A bare `>` — a paragraph break INSIDE a quotation. It is a boundary, not a line to reflow (F163).
QUOTE_ONLY = re.compile(r"^\s*>+\s*$")


def tokenize(text):
    """Split on whitespace, but treat a `backtick span` as one token.

    Wrapping inside an inline code span produces things like "`codesign --verify --deep" /
    "--strict`", which reads as broken even though Markdown still renders it. Spaces inside an
    open span therefore do not end a token.
    """
    tokens, i, n = [], 0, len(text)
    while i < n:
        while i < n and text[i].isspace():
            i += 1
        if i >= n:
            break
        start, in_code = i, False
        while i < n and (in_code or not text[i].isspace()):
            if text[i] == "`":
                in_code = not in_code
            i += 1
        tokens.append(text[start:i])
    return tokens


def wrap(text, width, first_prefix, later_prefix):
    """Greedy wrap. Never splits a token, so URLs and code spans stay intact."""
    words = tokenize(text)
    if not words:
        return []
    lines, current = [], first_prefix + words[0]
    for word in words[1:]:
        if len(current) + 1 + len(word) <= width:
            current += " " + word
        else:
            lines.append(current)
            current = later_prefix + word
    lines.append(current)
    return lines


def flush(buffer, out):
    """Emit one accumulated paragraph, re-wrapped."""
    if not buffer:
        return
    first = buffer[0]
    quote = QUOTE.match(first)
    qprefix = quote.group(1) if quote else ""
    body = [line[len(qprefix):] if line.startswith(qprefix) else line.lstrip() for line in buffer] \
        if qprefix else list(buffer)

    bullet = BULLET.match(body[0])
    if bullet:
        indent, marker, gap = bullet.groups()
        first_prefix = qprefix + indent + marker + gap
        later_prefix = qprefix + " " * len(indent + marker + gap)
        text = body[0][bullet.end():] + " " + " ".join(l.strip() for l in body[1:])
    else:
        indent = re.match(r"^\s*", body[0]).group(0)
        first_prefix = qprefix + indent
        later_prefix = qprefix + indent
        text = " ".join(l.strip() for l in body)

    out.extend(wrap(text, WIDTH, first_prefix, later_prefix))
    buffer.clear()


def words_outside_code(lines):
    """Word stream ignoring fenced code, used to prove content did not change.

    A blockquote's leading `>` is **markup, not a word** (F163). Counting it as content made the
    check refuse the formatter's own output: rewrapping a quote changes how many LINES it has, so
    two quoted lines joining into one went from two `>` tokens to one and read as a content drift.
    Nine of the twenty-two tracked documents were refused for this single reason.

    **Stripping the marker alone would weaken the guarantee**, so each word carries its quote depth
    instead. Turning a quotation into ordinary prose — or the reverse — changes who is speaking,
    which is content, and it is still caught. The invariant that makes the depth stable under
    rewrapping is `flush`'s: it derives one `qprefix` from a block's first line and applies it to
    every line it emits, and `format_text` starts a new block at a quote boundary. So a block is
    entirely quoted or entirely not, and a word cannot change depth by being moved within one.
    ``>`` is matched by `QUOTE`, which anchors at the line start, so `a > b` in a sentence is a word
    and stays one.
    """
    fence, kept = False, []
    for line in lines:
        if FENCE.match(line):
            fence = not fence
            kept.append(line.strip())
            continue
        if fence:
            # Verbatim, including whitespace: inside a fence every byte is content.
            kept.append(line)
            continue
        quote = QUOTE.match(line)
        if quote:
            # Tagged rather than bare, so a word that leaves the quote is a drift. The same single
            # level `flush` strips, so a nested `> >` leaves its inner marker in the body — where
            # both passes see it identically.
            kept.extend(("quoted", word) for word in line[quote.end():].split())
        else:
            kept.extend(line.split())
    return kept


def format_text(source):
    lines = source.split("\n")
    out, buffer, fence = [], [], False

    for line in lines:
        if FENCE.match(line):
            flush(buffer, out)
            fence = not fence
            out.append(line.rstrip())
            continue
        if fence:
            out.append(line.rstrip())
            continue

        stripped = line.strip()
        verbatim = (
            not stripped
            # A bare `>` ends the quoted paragraph the way a blank line ends an ordinary one
            # (F163). Two reasons it must be a boundary rather than a line in the buffer. It
            # carried the block's marker but not its trailing space, so `flush`'s literal-prefix
            # strip left the `>` in the body and re-wrapped it as a WORD — the stream gained a
            # token and the file was refused. And dropping it instead would merge two quoted
            # paragraphs into one, which changes what the document says; a formatter that silently
            # rewrites structure is worse than one that refuses to run.
            or QUOTE_ONLY.match(line)
            or HEADING.match(line)
            or RULE.match(line)
            or TABLE.match(line)
            or LINKDEF.match(line)
            or HTML.match(line)
        )
        if verbatim:
            flush(buffer, out)
            out.append(line.rstrip())
            continue

        # A new bullet, or a blockquote boundary, starts a new block.
        if buffer and (BULLET.match(line) or bool(QUOTE.match(line)) != bool(QUOTE.match(buffer[0]))):
            flush(buffer, out)
        buffer.append(line.rstrip())

    flush(buffer, out)

    text = "\n".join(out)
    text = re.sub(r"\n{3,}", "\n\n", text)
    return text.rstrip("\n") + "\n"


def targets():
    """Every editable Markdown guide: docs/ except the append-only ticket evidence log."""
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    paths = sorted(
        path for path in glob.glob(os.path.join(root, "docs", "*.md"))
        if os.path.basename(path) != "TICKET_LOG.md"
    )
    paths += [os.path.join(root, name) for name in ("README.md", "AGENTS.md")]
    return [p for p in paths if os.path.exists(p)]


def main():
    changed = failed = 0
    for path in targets():
        original = open(path, encoding="utf-8").read()
        formatted = format_text(original)

        before = words_outside_code(original.split("\n"))
        after = words_outside_code(formatted.split("\n"))
        name = os.path.basename(path)
        if before != after:
            for i, (a, b) in enumerate(zip(before, after)):
                if a != b:
                    print(f"  REFUSED {name}: content drift at token {i}: {a!r} -> {b!r}")
                    break
            else:
                print(f"  REFUSED {name}: token count {len(before)} -> {len(after)}")
            failed += 1
            continue

        if formatted != original:
            open(path, "w", encoding="utf-8").write(formatted)
            over = sum(1 for l in formatted.split("\n") if len(l) > WIDTH)
            print(f"  formatted {name:44} (still >{WIDTH}: {over})")
            changed += 1
        else:
            print(f"  unchanged {name}")

    print(f"\n{changed} formatted, {failed} refused")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
