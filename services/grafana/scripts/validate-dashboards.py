#!/usr/bin/env python3
"""Validate dashboard JSON against project conventions and (optionally) JSON Schema.

Used by:
  - pre-commit hook (local; fast feedback before committing)
  - GH Actions `validate-dashboards` job (canonical check on PR/push)

Checks per dashboard JSON file:
  1. Parses as JSON.
  2. `uid` starts with `<project_slug>-`.
  3. `title` starts with `<display_name>`.
  4. `schemaVersion` >= 39.
  5. (Optional) Matches the JSON Schema at schemas/grafana-dashboard-5.x.json.

Vars come from (in priority order):
  - --slug / --display-name CLI flags
  - PROJECT_SLUG / DISPLAY_NAME env vars
  - .template-vars file walked up from each dashboard
"""

from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path


def load_template_vars(start: Path) -> dict[str, str]:
    """Walk upward from `start` looking for `.template-vars` (KEY=value lines)."""
    for d in [start, *start.parents]:
        candidate = d / ".template-vars"
        if candidate.is_file():
            out: dict[str, str] = {}
            for line in candidate.read_text().splitlines():
                line = line.strip()
                if not line or line.startswith("#"):
                    continue
                if "=" not in line:
                    continue
                k, v = line.split("=", 1)
                out[k.strip()] = v.strip().strip('"').strip("'")
            return out
    return {}


def resolve_vars(args: argparse.Namespace, paths: list[Path]) -> tuple[str, str]:
    """Resolve project_slug + display_name from CLI > env > .template-vars."""
    slug = args.slug or os.environ.get("PROJECT_SLUG")
    display = args.display_name or os.environ.get("DISPLAY_NAME")
    if (not slug or not display) and paths:
        vars_ = load_template_vars(paths[0].resolve().parent)
        slug = slug or vars_.get("PROJECT_SLUG")
        display = display or vars_.get("DISPLAY_NAME")
    if not slug or not display:
        sys.stderr.write(
            "ERROR: PROJECT_SLUG / DISPLAY_NAME unresolved. Set them via "
            "--slug/--display-name, env vars, or .template-vars.\n"
        )
        sys.exit(2)
    return slug, display


def check_conventions(dashboard: dict, slug: str, display: str) -> list[str]:
    errors: list[str] = []
    uid = dashboard.get("uid", "")
    if not uid.startswith(f"{slug}-"):
        errors.append(f"uid must start with {slug + '-'!r} (got {uid!r})")
    title = dashboard.get("title", "")
    if not title.startswith(display):
        errors.append(f"title must start with {display!r} (got {title!r})")
    schema_version = dashboard.get("schemaVersion", 0)
    if schema_version < 39:
        errors.append(f"schemaVersion must be >= 39 (got {schema_version!r})")
    return errors


def check_schema(dashboard: dict, schema_path: Path) -> list[str]:
    try:
        import jsonschema  # type: ignore[import-not-found]
    except ImportError:
        return []
    schema = json.loads(schema_path.read_text())
    dashboard_schema = schema.get("properties", {}).get("dashboard", {})
    try:
        jsonschema.validate(instance=dashboard, schema=dashboard_schema)
    except jsonschema.ValidationError as exc:
        path = " -> ".join(str(p) for p in exc.path)
        return [f"schema: {exc.message} (at {path})"]
    return []


def emit_error(path: Path, msg: str, gh_actions: bool) -> None:
    if gh_actions:
        print(f"::error file={path}::{msg}")
    else:
        print(f"{path}: {msg}", file=sys.stderr)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("paths", nargs="*", type=Path, help="Dashboard JSON files (default: all dashboards/*.json)")
    parser.add_argument("--slug", help="Project slug; overrides env + .template-vars")
    parser.add_argument("--display-name", help="Display name; overrides env + .template-vars")
    parser.add_argument("--schema", type=Path, help="Path to grafana-dashboard-5.x.json JSON Schema (optional)")
    parser.add_argument(
        "--gh-actions",
        action="store_true",
        default=bool(os.environ.get("GITHUB_ACTIONS")),
        help="Emit errors in `::error file=...::` format",
    )
    args = parser.parse_args()

    paths: list[Path] = list(args.paths)
    if not paths:
        cwd = Path.cwd()
        candidates = [cwd / "dashboards", cwd / "services/grafana/dashboards"]
        for c in candidates:
            if c.is_dir():
                paths = sorted(c.glob("*.json"))
                break
        if not paths:
            print("No dashboard files supplied and none auto-discovered.", file=sys.stderr)
            return 2

    slug, display = resolve_vars(args, paths)

    schema_path: Path | None = args.schema
    if schema_path is None:
        for guess in [
            paths[0].resolve().parent.parent / "schemas" / "grafana-dashboard-5.x.json",
            Path.cwd() / "schemas" / "grafana-dashboard-5.x.json",
            Path.cwd() / "tests/schemas/grafana-dashboard-5.x.json",
        ]:
            if guess.is_file():
                schema_path = guess
                break

    failed = 0
    for p in paths:
        if not p.is_file():
            emit_error(p, "file not found", args.gh_actions)
            failed += 1
            continue
        try:
            dashboard = json.loads(p.read_text())
        except json.JSONDecodeError as exc:
            emit_error(p, f"invalid JSON: {exc}", args.gh_actions)
            failed += 1
            continue

        errors = check_conventions(dashboard, slug, display)
        if schema_path is not None:
            errors.extend(check_schema(dashboard, schema_path))
        if errors:
            for e in errors:
                emit_error(p, e, args.gh_actions)
            failed += 1
        else:
            print(f"ok  {p}")

    if failed:
        print(f"\n{failed} dashboard(s) failed validation", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
