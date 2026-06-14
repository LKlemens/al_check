#!/usr/bin/env python3
"""Parse per-module coverage from mix test --cover output and write JSON."""
import re
import json
import sys

raport_path = sys.argv[1] if len(sys.argv) > 1 else "raport"
output_path = sys.argv[2] if len(sys.argv) > 2 else "current_module_coverage.json"

modules = {}
with open(raport_path) as f:
    for line in f:
        m = re.match(r"\|\s*([\d.]+)%\s*\|\s*([\w.]+)\s*\|", line)
        if m:
            pct, name = float(m.group(1)), m.group(2)
            if name != "Total":
                modules[name] = pct

with open(output_path, "w") as f:
    json.dump(modules, f, indent=2)

print(f"Parsed {len(modules)} modules -> {output_path}")
