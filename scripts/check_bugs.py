#!/usr/bin/env python3
"""Check the bug tracker format in docs/ai-workflow/bugs.md (rules: .claude/skills/bug/SKILL.md).

- `## Open` lists exactly the Open bugs: `- B-NNN (M<n>, <Sev>) <title>`, in ID order.
- Then one `## M<n> — <name>` section per milestone, in milestone order; each holds that milestone's bugs in ID order.
- Each bug: `### B-NNN · <title>` (≤ MAX_TITLE chars), a meta line
  `Sev: <Sev> · State: <Open|Solved> · Found: <date>[ · Solved: <date>][ · Fix: <hash|uncommitted|[stuck rN]>]`,
  then at most MAX_BULLETS one-line bullets of at most MAX_LINE chars.
- IDs are B-001..B-NNN with no gaps or duplicates; Solved needs a Solved date and a commit hash or `uncommitted`.
Exit 1 with one line per problem.
"""
import re
import sys

MAX_TITLE = 100
MAX_BULLETS = 4
MAX_LINE = 220
SEVS = ("Critical", "High", "Medium", "Low", "—")
DATE = r"\d{4}-\d{2}-\d{2}"
META = re.compile(
    rf"Sev: (?P<sev>\S+) · State: (?P<state>\S+) · Found: (?P<found>{DATE})"
    rf"(?: · Solved: (?P<solved>{DATE}))?(?: · Fix: (?P<fix>.+))?$"
)

path = sys.argv[1] if len(sys.argv) > 1 else "docs/ai-workflow/bugs.md"
lines = open(path, encoding="utf-8").read().splitlines()
problems = []
bugs = {}          # id -> dict
open_list = []     # (id, ms, sev, title) from ## Open
section = None     # "Open" or "M<n>"
ms_order = []
cur = None

for n, line in enumerate(lines, 1):
    if line.startswith("## "):
        cur = None
        if line == "## Open":
            section = "Open"
            continue
        m = re.fullmatch(r"## (M\d+) — .+", line)
        if not m:
            problems.append(f"line {n}: section must be '## Open' or '## M<n> — <name>': {line}")
            section = None
            continue
        section = m.group(1)
        ms_order.append(int(section[1:]))
        continue
    if section == "Open" and line.startswith("- "):
        m = re.fullmatch(r"- (B-\d{3}) \((M\d+), (\S+)\) (.+)", line)
        if m:
            open_list.append(m.groups())
        else:
            problems.append(f"line {n}: Open entry must be '- B-NNN (M<n>, <Sev>) <title>'")
        continue
    if line.startswith("### "):
        m = re.fullmatch(r"### (B-\d{3}) · (.+)", line)
        if not m or section in (None, "Open"):
            problems.append(f"line {n}: bug heading must be '### B-NNN · <title>' inside a '## M<n>' section")
            cur = None
            continue
        bid, title = m.groups()
        if bid in bugs:
            problems.append(f"{bid}: listed twice")
        cur = bugs[bid] = {"title": title, "ms": section, "meta": None, "bullets": 0, "line": n}
        if len(title) > MAX_TITLE:
            problems.append(f"{bid}: title is {len(title)} chars (max {MAX_TITLE}); move detail to a bullet")
        if re.search(r"<[A-Za-z/!]", re.sub(r"`[^`]*`", "", title)):
            problems.append(f"{bid}: HTML-like text in title (wrap it in backticks)")
        continue
    if cur is None or not line.strip():
        continue
    if cur["meta"] is None:
        m = META.fullmatch(line)
        if not m:
            problems.append(f"line {n}: meta line must be 'Sev: … · State: … · Found: …[ · Solved: …][ · Fix: …]'")
            cur["meta"] = {}
        else:
            cur["meta"] = m.groupdict()
        continue
    if not line.startswith("- "):
        problems.append(f"line {n}: only one-line '- ' bullets after the meta line")
        continue
    cur["bullets"] += 1
    if len(line) > MAX_LINE:
        problems.append(f"line {n}: bullet is {len(line)} chars (max {MAX_LINE})")

if ms_order != sorted(ms_order) or len(ms_order) != len(set(ms_order)):
    problems.append("milestone sections must appear once each, in order (M0, M1, … M10)")

for bid, b in bugs.items():
    meta = b["meta"]
    if meta is None:
        problems.append(f"{bid}: missing meta line")
        continue
    if not meta:
        continue
    sev, state, solved, fix = meta["sev"], meta["state"], meta["solved"], meta["fix"] or ""
    if sev not in SEVS:
        problems.append(f"{bid}: Sev must be Critical, High, Medium, Low or —, got '{sev}'")
    if state not in ("Open", "Solved"):
        problems.append(f"{bid}: State must be Open or Solved, got '{state}'")
    if state == "Solved" and (not solved or not re.search(r"uncommitted|\b[0-9a-f]{7,}\b", fix)):
        problems.append(f"{bid}: Solved needs a Solved date and a commit hash or `uncommitted` in Fix")
    if state == "Open" and solved:
        problems.append(f"{bid}: Open bug has a Solved date")
    if state == "Open" and fix and not re.fullmatch(r"\[stuck r\d+\]", fix):
        problems.append(f"{bid}: an Open bug's Fix may only be the marker [stuck rN]")
    if b["bullets"] > MAX_BULLETS:
        problems.append(f"{bid}: {b['bullets']} bullets (max {MAX_BULLETS})")

ids = sorted(bugs)
for i, bid in enumerate(ids, 1):
    if bid != "B-%03d" % i:
        problems.append(f"IDs must run B-001..B-{len(ids):03d} with no gaps (missing B-{i:03d}?)")
        break
for ms in {b["ms"] for b in bugs.values()}:
    in_ms = [b["line"] for b in bugs.values() if b["ms"] == ms]
    by_id = [bugs[k]["line"] for k in ids if bugs[k]["ms"] == ms]
    if sorted(in_ms) != by_id:
        problems.append(f"{ms}: bugs must be in ID order")

expected = [(k, bugs[k]["ms"], (bugs[k]["meta"] or {}).get("sev"), bugs[k]["title"])
            for k in ids if (bugs[k]["meta"] or {}).get("state") == "Open"]
if open_list != expected:
    want = ", ".join(e[0] for e in expected) or "none"
    problems.append(f"'## Open' must list exactly the Open bugs in ID order with milestone, Sev and title (expected: {want})")

for p in problems:
    print(f"{path}: {p}")
if problems:
    sys.exit(1)
print(f"{path}: bug tracker OK ({len(bugs)} bugs, {len(expected)} open)")
