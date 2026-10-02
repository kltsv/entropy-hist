#!/usr/bin/env python3
"""Compile the Entropy app: validate spec → implementation linkage.

This is the project-level compile entry point. It is distinct from
`.agents/setup.py`, which compiles the agent harness (vendor configs and
skill mirrors).

Specs live under /app/ and are identified by their `name:` frontmatter.
Each implementation directory declares which spec it realises via a SPEC.md
sidecar containing `implements: <name>`.

Agnostic test-specs live alongside behaviour specs as `app/<module>.tests.md`
with frontmatter `tests: <name>` (the module spec they exercise). Test
directories declare which test-spec they realise via a SPEC.md sidecar
containing `implements-tests: <name>`.

This script verifies:
  - Every SPEC.md has an `implements:` or `implements-tests:` field
  - Every `implements:` references a real spec name from /app/
  - Every `tests:` in a `*.tests.md` references a real spec name
  - Every `implements-tests:` references a spec that has an agnostic test-spec
  - Specs without any implementation are reported as info, not errors
    (a draft spec may legitimately have no impl yet)

Exit code 0 if links are valid, 1 otherwise.

Requires Python 3.11+. No external dependencies.
"""

import hashlib
import json
import os
import re
import sys
from pathlib import Path

REPO_ROOT = Path.cwd().resolve()
APP_DIR = REPO_ROOT / "app"

SKIP_DIRS = {
    ".git", ".dart_tool", "build", "node_modules", ".venv", "__pycache__",
    ".claude", ".codex", ".opencode", ".deps", ".artifacts", "dist", "demo-vault",
}

FRONTMATTER_RE = re.compile(r"^---\s*\n(.*?)\n---\s*\n", re.DOTALL)

RESERVED_MD_NAMES = {"AGENTS.md", "CLAUDE.md", "README.md", "SPEC.md"}


def sha256_file(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def extract_frontmatter(text: str) -> dict[str, str]:
    """Pull simple key:value pairs from a leading YAML frontmatter block.

    Not a full YAML parser — sufficient for our flat single-line frontmatter.
    """
    m = FRONTMATTER_RE.match(text)
    if not m:
        return {}
    out: dict[str, str] = {}
    for line in m.group(1).splitlines():
        line = line.rstrip()
        if not line or line.startswith("#") or ":" not in line:
            continue
        key, _, value = line.partition(":")
        out[key.strip()] = value.strip()
    return out


def spec_roots(root: Path, seen=None) -> list[Path]:
    seen = set() if seen is None else seen
    root = root.resolve()
    if root in seen:
        return []
    seen.add(root)
    if not (root / "app").is_dir():
        raise ValueError(f"Missing spec provider {root}; prepare workspace/dependencies first")
    config = root / "spec_sources_overrides.json"
    if not config.exists():
        config = root / "spec_sources.json"
    sources = json.loads(config.read_text(encoding="utf-8"))["sources"] if config.exists() else []
    if not isinstance(sources, list) or any(not isinstance(s, str) for s in sources):
        raise ValueError(f"{config}: sources must be a list of paths")
    result = [root]
    for source in sources:
        result.extend(spec_roots(root / source, seen))
    return result


def load_catalog(roots: list[Path], field: str, glob: str) -> dict[str, Path]:
    result = {}
    for root in roots:
        for path in sorted((root / "app").rglob(glob)):
            if path.name in RESERVED_MD_NAMES:
                continue
            name = extract_frontmatter(path.read_text(encoding="utf-8")).get(field)
            if name:
                if name in result and sha256_file(path) != sha256_file(result[name]):
                    raise ValueError(f"Conflicting spec {name}: {result[name]} and {path}")
                result[name] = path
    return result


def display(path: Path) -> str:
    return str(path.relative_to(REPO_ROOT)) if path.is_relative_to(REPO_ROOT) else str(path)


def find_spec_md_files() -> list[Path]:
    results = []
    for directory, dirs, files in os.walk(REPO_ROOT):
        base = Path(directory)
        dirs[:] = [d for d in dirs if d not in SKIP_DIRS and not (base / d / ".git").exists()]
        if "SPEC.md" in files:
            results.append(base / "SPEC.md")
    return sorted(results)


def main() -> None:
    try:
        roots = spec_roots(REPO_ROOT)
        spec_names = load_catalog(roots, "name", "*.md")
        test_specs = load_catalog(roots, "tests", "*.tests.md")
    except (ValueError, OSError, KeyError) as error:
        print(f"spec catalog error: {error}", file=sys.stderr)
        sys.exit(1)
    spec_md_files = find_spec_md_files()

    errors: list[str] = []
    info: list[str] = []
    used_specs: set[str] = set()

    known_specs = ", ".join(sorted(spec_names)) or "(none)"

    # Agnostic test-specs must point at a real behaviour spec, and (if stamped)
    # not be stale relative to it.
    for tested, path in sorted(test_specs.items()):
        rel = display(path)
        if tested not in spec_names:
            errors.append(f"{rel}: tests unknown spec `{tested}` (known: {known_specs})")
            continue
        digest = extract_frontmatter(path.read_text(encoding="utf-8")).get("spec-digest")
        if digest and digest != sha256_file(spec_names[tested]):
            errors.append(
                f"{rel}: stale — spec-digest does not match `app/{tested}.md` "
                f"(behaviour spec changed since this test-spec was generated; regenerate)"
            )

    for p in spec_md_files:
        rel = p.relative_to(REPO_ROOT)
        fm = extract_frontmatter(p.read_text(encoding="utf-8"))
        impl = fm.get("implements")
        impl_tests = fm.get("implements-tests")

        if not impl and not impl_tests:
            errors.append(f"{rel}: missing `implements:` or `implements-tests:` field")
            continue

        if impl:
            if impl not in spec_names:
                errors.append(f"{rel}: implements unknown spec `{impl}` (known: {known_specs})")
            else:
                used_specs.add(impl)
                digest = fm.get("spec-digest")
                if digest and digest != sha256_file(spec_names[impl]):
                    errors.append(
                        f"{rel}: stale — spec-digest does not match `app/{impl}.md` "
                        f"(behaviour spec changed since this implementation was generated; regenerate)"
                    )

        if impl_tests:
            if impl_tests not in spec_names:
                errors.append(
                    f"{rel}: implements-tests unknown spec `{impl_tests}` (known: {known_specs})"
                )
            elif impl_tests not in test_specs:
                errors.append(
                    f"{rel}: implements-tests `{impl_tests}` but no agnostic test-spec "
                    f"`app/{impl_tests}.tests.md` exists"
                )
            else:
                digest = fm.get("testspec-digest")
                if digest and digest != sha256_file(test_specs[impl_tests]):
                    errors.append(
                        f"{rel}: stale — testspec-digest does not match `app/{impl_tests}.tests.md` "
                        f"(test-spec changed since these tests were generated; regenerate)"
                    )

    for name, path in sorted(spec_names.items()):
        if name not in used_specs and path.is_relative_to(APP_DIR):
            info.append(f"{display(path)}: spec `{name}` has no implementations")

    for msg in info:
        print(f"info: {msg}")

    if errors:
        if info:
            print("", file=sys.stderr)
        print("spec link errors:", file=sys.stderr)
        for e in errors:
            print(f"  {e}", file=sys.stderr)
        sys.exit(1)

    print(
        f"checked {len(spec_md_files)} SPEC.md and {len(test_specs)} test-spec(s) "
        f"against {len(spec_names)} specs — links valid"
    )


if __name__ == "__main__":
    main()
