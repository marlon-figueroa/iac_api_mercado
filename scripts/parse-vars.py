#!/usr/bin/env python3
"""Parse project vars.yaml without external dependencies."""
from __future__ import annotations

import json
import os
import re
import sys
from pathlib import Path


def parse_vars(path: Path) -> dict:
    data: dict = {}
    current_key: str | None = None

    for raw in path.read_text(encoding="utf-8").splitlines():
        line = raw.split("#", 1)[0].rstrip()
        if not line.strip():
            continue

        list_match = re.match(r"^\s+-\s+(.+)$", line)
        if list_match and current_key is not None:
            item = list_match.group(1).strip().strip('"').strip("'")
            bucket = data.setdefault(current_key, [])
            if isinstance(bucket, list):
                bucket.append(item)
            continue

        top_match = re.match(r"^([A-Za-z0-9_]+):\s*(.*)$", line)
        if not top_match:
            continue

        key, value = top_match.group(1), top_match.group(2).strip()
        current_key = key
        if value == "":
            data[key] = []
        else:
            data[key] = value.strip('"').strip("'")

    return data


def emit_exports(data: dict) -> None:
    for key, val in data.items():
        if val is None:
            val = ""
        elif isinstance(val, list):
            val = ",".join(str(x) for x in val)
        else:
            val = str(val)
        val = val.replace("\\", "\\\\").replace('"', '\\"')
        print(f'export {key}="{val}"')


def update_keys(path: Path, updates: dict) -> None:
    lines = path.read_text(encoding="utf-8").splitlines(keepends=True)
    seen = set()
    out: list[str] = []

    for line in lines:
        matched = False
        for key, new_val in updates.items():
            if re.match(rf"^{re.escape(key)}:\s*", line):
                out.append(f"{key}: {new_val}\n")
                seen.add(key)
                matched = True
                break
        if not matched:
            out.append(line)

    for key, new_val in updates.items():
        if key not in seen:
            if out and not out[-1].endswith("\n"):
                out[-1] = out[-1] + "\n"
            out.append(f"{key}: {new_val}\n")

    path.write_text("".join(out), encoding="utf-8")


def main() -> int:
    if len(sys.argv) < 2:
        print("usage: parse-vars.py export|update-json PATH [JSON]", file=sys.stderr)
        return 1

    cmd = sys.argv[1]
    path = Path(sys.argv[2])
    data = parse_vars(path)

    if cmd == "export":
        emit_exports(data)
        return 0
    if cmd == "update-json":
        updates = json.loads(sys.argv[3])
        update_keys(path, updates)
        return 0

    print(f"unknown command: {cmd}", file=sys.stderr)
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
