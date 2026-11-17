#!/usr/bin/env python3
"""Check the bug tracker format in TODO.md (rules: .claude/skills/bug/SKILL.md).

- Bugs table: fixed header, 8 columns per row, sequential IDs, valid State/Sev/Milestone, short titles,
  no HTML-like text; Solved rows have a Fix (commit hash or `uncommitted`).
- Bug details: exactly one entry per table row, heading title equals the table title,
  at most 5 lines per entry (heading + up to 4 bullets), each line at most MAX_LINE characters.
Exit 1 with one line per problem.
"""
import re
import sys

MAX_TITLE = 100
MAX_LINES = 5
MAX_LINE = 220
HEADER = "| ID | Title | Sev | State | Milestone | Found | Solved | Fix |"

path = sys.argv[1] if len(sys.argv) > 1 else "TODO.md"
text = open(path, encoding="utf-8").read()
problems = []


def section(name):
    m = re.search(r"^## %s\n(.*?)(?=^## |\Z)" % re.escape(name), text, re.S | re.M)
    if not m:
        problems.append(f"missing section '## {name}'")
        return ""
    return m.group(1)


bugs = section("Bugs")
lines = bugs.splitlines()
if HEADER not in lines:
    problems.append(f"Bugs table header must be exactly: {HEADER}")

rows = {}
for n, line in enumerate(l for l in lines if l.startswith("| B-")):
    cells = [c.strip() for c in line.strip().strip("|").split("|")]
    if len(cells) != 8:
        problems.append(f"{line[:12]}: {len(cells)} columns, expected 8 (a '|' inside a cell?)")
        continue
    bid, title, sev, state, ms, found, solved, fix = cells
    if bid != "B-%03d" % (n + 1):
        problems.append(f"{bid}: IDs must be sequential (expected B-{n + 1:03d})")
    if len(title) > MAX_TITLE:
        problems.append(f"{bid}: title is {len(title)} chars (max {MAX_TITLE}); move detail to Bug details")
    if re.search(r"<[A-Za-z/!]", re.sub(r"`[^`]*`", "", title)):
        problems.append(f"{bid}: HTML-like text in title (wrap it in backticks)")
    if sev not in ("Critical", "High", "Medium", "—"):
        problems.append(f"{bid}: Sev must be Critical, High, Medium or —, got '{sev}'")
    if state not in ("Open", "Solved"):
        problems.append(f"{bid}: State must be Open or Solved, got '{state}'")
    if not re.fullmatch(r"M\d+", ms):
        problems.append(f"{bid}: Milestone must look like M3, got '{ms}'")
    if state == "Solved" and not re.search(r"uncommitted|\b[0-9a-f]{7,}\b", fix):
        problems.append(f"{bid}: Solved needs a commit hash or `uncommitted` in Fix")
    if state == "Open" and solved:
        problems.append(f"{bid}: Open bug has a Solved date")
    rows[bid] = title

details = section("Bug details")
entries = {}
for block in re.split(r"\n(?=### )", details):
    m = re.match(r"### (B-\d{3}): (.*)", block)
    if not m:
        continue
    bid, heading = m.groups()
    body = [l for l in block.strip().splitlines() if l.strip()]
    if bid in entries:
        problems.append(f"{bid}: more than one details entry")
    entries[bid] = heading
    if len(body) > MAX_LINES:
        problems.append(f"{bid}: details entry has {len(body)} lines (max {MAX_LINES}: heading + 4 bullets)")
    for l in body:
        if len(l) > MAX_LINE:
            problems.append(f"{bid}: details line is {len(l)} chars (max {MAX_LINE}): {l[:50]}...")
    if bid in rows and heading.strip() != rows[bid]:
        problems.append(f"{bid}: details heading differs from the table title")

for bid in rows:
    if bid not in entries:
        problems.append(f"{bid}: no details entry")
for bid in entries:
    if bid not in rows:
        problems.append(f"{bid}: details entry without a table row")

for p in problems:
    print(f"{path}: {p}")
if problems:
    sys.exit(1)
print(f"{path}: bug tracker OK ({len(rows)} bugs)")
