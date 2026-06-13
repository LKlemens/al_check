#!/usr/bin/env python3
"""Compare per-module coverage for modified modules and print a markdown table."""
import json
import sys

baseline_path = sys.argv[1] if len(sys.argv) > 1 else "/tmp/baseline_module_coverage.json"
current_path = sys.argv[2] if len(sys.argv) > 2 else "current_module_coverage.json"
modified_path = sys.argv[3] if len(sys.argv) > 3 else "modified_modules.txt"

with open(baseline_path) as f:
    baseline = json.load(f)

with open(current_path) as f:
    current = json.load(f)

with open(modified_path) as f:
    modified = [l.strip() for l in f if l.strip()]

rows = []
for mod in sorted(set(modified)):
    if mod not in current:
        continue
    cur = current[mod]
    base = baseline.get(mod)
    if base is None:
        rows.append(f"| `{mod}` | N/A | {cur:.2f}% | 🆕 new |")
    else:
        delta = cur - base
        sign = "+" if delta >= 0 else ""
        icon = "✅" if delta >= 0 else "❌"
        rows.append(f"| `{mod}` | {base:.2f}% | {cur:.2f}% | {sign}{delta:.2f}% {icon} |")

if rows:
    print("| Module | Baseline | Current | Delta |")
    print("|--------|----------|---------|-------|")
    for row in rows:
        print(row)
else:
    print("_No modified modules with coverage data found._")
