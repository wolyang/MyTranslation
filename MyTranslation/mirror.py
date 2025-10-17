#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
mirror.py — Merge/split project files for ChatGPT Canvas collaboration.

Usage examples
--------------
# 1) Export: 여러 Swift 파일을 하나의 번들 텍스트로 병합 (캔버스로 붙여넣기 용)
python3 mirror.py export \
  --root /path/to/project \
  --src Features/Browser --src Services/Router \
  --ext .swift .swiftui .h .m \
  --out /path/to/browser_bundle.txt

# 2) Dry-run diff: 번들 파일과 로컬 파일 차이를 미리 확인
python3 mirror.py apply \
  --root /path/to/project \
  --dst /path/to/project \
  --in /path/to/browser_bundle.txt \
  --check

# 3) Apply: 번들 내용을 실제 파일로 분할/적용 (백업 .bak 생성)
python3 mirror.py apply \
  --root /path/to/project \
  --dst /path/to/project \
  --in /path/to/browser_bundle.txt \
  --backup

Design notes
------------
- 파일 경계는 명확한 마커 한 줄로 구분됩니다:
  >>>>> MIRROR FILE BEGIN: relative/path/to/File.swift
  <<<<< MIRROR FILE END
- export 시 Git(있으면) 순서 → 알파벳 순으로 정렬.
- apply 시 각 섹션을 상대경로로 해석하여 --dst 아래에 씁니다.
- --check는 실제 파일은 건드리지 않고 차이만 출력합니다.
- --backup은 덮어쓰기 전에 기존 파일을 *.bak 으로 보존합니다.
- --exclude, --include-glob 으로 세밀 제어 가능.

"""

from __future__ import annotations
import argparse
import difflib
import fnmatch
import os
import subprocess
import sys
from pathlib import Path
from typing import Iterable, List, Tuple

MARK_BEGIN = ">>>>> MIRROR FILE BEGIN: "  # + relative path
MARK_END = "<<<<< MIRROR FILE END"
ENCODING = "utf-8"

# ------------------------------
# Helpers
# ------------------------------

def is_text_file(p: Path) -> bool:
    try:
        with p.open("rb") as f:
            chunk = f.read(2048)
        chunk.decode(ENCODING)
        return True
    except Exception:
        return False


def list_files(root: Path, src_dirs: List[Path], exts: List[str], include_globs: List[str], exclude_globs: List[str], use_git_order: bool) -> List[Path]:
    # Collect candidates
    candidates: List[Path] = []
    for d in src_dirs:
        base = (root / d).resolve()
        if not base.exists():
            continue
        for path in base.rglob("*"):
            if not path.is_file():
                continue
            if exts and path.suffix not in exts:
                continue
            rel = path.relative_to(root)
            rel_str = str(rel).replace("\\", "/")
            # include filter
            if include_globs:
                if not any(fnmatch.fnmatch(rel_str, g) for g in include_globs):
                    continue
            # exclude filter
            if exclude_globs:
                if any(fnmatch.fnmatch(rel_str, g) for g in exclude_globs):
                    continue
            # Trust by extension; do not drop files by charset check
            candidates.append(path)

    # Sorting: prefer git order if requested and available
    if use_git_order:
        git_files = _git_ls_files(root)
        git_index = {f: i for i, f in enumerate(git_files)}
        def key_func(p: Path):
            rel = str(p.relative_to(root)).replace("\\", "/")
            return (0, git_index[rel]) if rel in git_index else (1, rel.lower())
        return sorted(candidates, key=key_func)
    else:
        return sorted(candidates, key=lambda p: str(p.relative_to(root)).lower())


def _git_ls_files(root: Path) -> List[str]:
    try:
        proc = subprocess.run(["git", "-C", str(root), "ls-files"], capture_output=True, text=True, check=True)
        files = [ln.strip() for ln in proc.stdout.splitlines() if ln.strip()]
        return files
    except Exception:
        return []


# ------------------------------
# Export
# ------------------------------

def export_bundle(root: Path, src_dirs: List[Path], out_file: Path, exts: List[str], include_globs: List[str], exclude_globs: List[str], order: str) -> None:
    use_git_order = (order == "git")
    files = list_files(root, src_dirs, exts, include_globs, exclude_globs, use_git_order)
    if not files:
        print("[mirror] No files found to export.")
        return

    lines: List[str] = []
    header = [
        "# mirror bundle\n",
        f"# root: {root}\n",
        f"# files: {len(files)}\n",
        "# note: Each section is bounded by MARK_BEGIN/MARK_END lines.\n",
        "\n",
    ]
    lines.extend(header)

    for f in files:
        rel = f.relative_to(root)
        rel_str = str(rel).replace("\\", "/")
        lines.append(f"{MARK_BEGIN}{rel_str}\n")
        try:
            content = f.read_text(encoding=ENCODING)
        except Exception as e:
            print(f"[mirror] WARN: failed to read {rel_str}: {e}")
            content = ""
        # Ensure trailing newline before end marker for cleaner diffs
        if content and not content.endswith("\n"):
            content += "\n"
        lines.append(content)
        lines.append(f"{MARK_END}\n\n")

    out_file.parent.mkdir(parents=True, exist_ok=True)
    out_file.write_text("".join(lines), encoding=ENCODING)
    print(f"[mirror] Exported {len(files)} files → {out_file}")


# ------------------------------
# Apply
# ------------------------------

def parse_bundle(bundle_path: Path) -> List[Tuple[Path, str]]:
    text = bundle_path.read_text(encoding=ENCODING)
    parts: List[Tuple[Path, str]] = []

    current_rel: Path | None = None
    current_buf: List[str] = []

    def flush():
        nonlocal current_rel, current_buf
        if current_rel is not None:
            parts.append((current_rel, "".join(current_buf)))
            current_rel = None
            current_buf = []

    for line in text.splitlines(keepends=True):
        if line.startswith(MARK_BEGIN):
            # New section
            flush()
            rel = line[len(MARK_BEGIN):].strip()
            current_rel = Path(rel)
            current_buf = []
        elif line.startswith(MARK_END):
            flush()
        else:
            if current_rel is not None:
                current_buf.append(line)
    # Edge case: trailing content without end marker
    flush()
    return parts


def ensure_parent(path: Path):
    path.parent.mkdir(parents=True, exist_ok=True)


def unified_diff_str(old: str, new: str, fromfile: str = "old", tofile: str = "new") -> str:
    diff = difflib.unified_diff(old.splitlines(keepends=True), new.splitlines(keepends=True), fromfile=fromfile, tofile=tofile)
    return "".join(diff)


def apply_bundle(bundle_path: Path, root: Path, dst: Path, check: bool, backup: bool) -> int:
    sections = parse_bundle(bundle_path)
    if not sections:
        print("[mirror] No sections found in bundle.")
        return 1

    exit_code = 0
    for rel, new_content in sections:
        # Normalize path
        rel_norm = Path(str(rel).replace("\\", "/"))
        target = (dst / rel_norm).resolve()
        display_rel = str(target.relative_to(root)) if target.is_absolute() and root in target.parents else str(rel_norm)

        old_content = ""
        if target.exists():
            try:
                old_content = target.read_text(encoding=ENCODING)
            except Exception as e:
                print(f"[mirror] WARN: cannot read existing {display_rel}: {e}")
        # Always end with newline for consistent diff
        if new_content and not new_content.endswith("\n"):
            new_content += "\n"

        if old_content == new_content:
            print(f"[=] {display_rel} (no changes)")
            continue

        # Show diff
        diff = unified_diff_str(old_content, new_content, fromfile=f"a/{display_rel}", tofile=f"b/{display_rel}")
        if diff:
            print(diff, end="")

        if check:
            exit_code = 2  # indicate differences found
            continue

        # Write
        try:
            ensure_parent(target)
            if backup and target.exists():
                bak = target.with_suffix(target.suffix + ".bak")
                bak.write_text(old_content, encoding=ENCODING)
            target.write_text(new_content, encoding=ENCODING)
            print(f"[✔] wrote {display_rel}")
        except Exception as e:
            print(f"[mirror] ERROR writing {display_rel}: {e}")
            exit_code = 1

    return exit_code


# ------------------------------
# CLI
# ------------------------------

def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(description="Mirror project files to/from a single bundle for ChatGPT Canvas.")
    sub = p.add_subparsers(dest="cmd", required=True)

    # export
    pe = sub.add_parser("export", help="Merge multiple files into a single bundle text file")
    pe.add_argument("--root", required=True, help="Project root path")
    pe.add_argument("--src", action="append", default=[], help="Source directory (relative to root). Can be repeated.")
    pe.add_argument("--ext", nargs="*", default=[".swift"], help="File extensions to include (e.g., .swift .m .h). Default: .swift")
    pe.add_argument("--include-glob", nargs="*", default=[], help="Only include files matching these glob patterns (relative paths)")
    pe.add_argument("--exclude-glob", nargs="*", default=["**/DerivedData/**", "**/.build/**", "**/Pods/**", "**/.git/**"], help="Exclude files by glob patterns")
    pe.add_argument("--order", choices=["git", "alpha"], default="git", help="Export file order. Prefer 'git' if repo.")
    pe.add_argument("--out", required=True, help="Output bundle file path")

    # apply
    pa = sub.add_parser("apply", help="Split bundle back into project files")
    pa.add_argument("--root", required=True, help="Project root path (used for display and git context)")
    pa.add_argument("--dst", required=True, help="Destination base directory to write files into (often same as --root)")
    pa.add_argument("--in", dest="bundle", required=True, help="Input bundle file path")
    pa.add_argument("--check", action="store_true", help="Only show diffs; do not write")
    pa.add_argument("--backup", action="store_true", help="Create .bak before overwriting")

    return p


def main(argv: List[str] | None = None) -> int:
    argv = argv or sys.argv[1:]
    parser = build_parser()
    args = parser.parse_args(argv)

    if args.cmd == "export":
        root = Path(args.root).resolve()
        src_dirs = [Path(s) for s in (args.src or ["."])]
        out_file = Path(args.out).resolve()
        exts = args.ext
        include_globs = args.include_glob
        exclude_globs = args.exclude_glob
        export_bundle(root, src_dirs, out_file, exts, include_globs, exclude_globs, args.order)
        return 0

    elif args.cmd == "apply":
        root = Path(args.root).resolve()
        dst = Path(args.dst).resolve()
        bundle_path = Path(args.bundle).resolve()
        return apply_bundle(bundle_path, root, dst, check=args.check, backup=args.backup)

    else:
        parser.print_help()
        return 2


if __name__ == "__main__":
    sys.exit(main())
