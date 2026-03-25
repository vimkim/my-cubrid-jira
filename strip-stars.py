#!/usr/bin/env python3
"""Strip *italic* and **bold** markdown markers from text, preserving content.

Does NOT touch:
- List bullets (* item)
- Horizontal rules (*** or * * *)
- Escaped asterisks (\\*)
"""

import re
import argparse
from pathlib import Path

# **bold** — greedy-safe: content must not start/end with space
BOLD_RE = re.compile(r"\*\*([^\n*]+?)\*\*")
# *italic* — must not be a list bullet (preceded by newline/start + optional spaces)
ITALIC_RE = re.compile(r"(?<!^)(?<!\n)\*([^\n*]+?)\*", re.MULTILINE)


def strip_stars(text: str) -> str:
    # Bold first (longer match), then italic
    text = BOLD_RE.sub(r"\1", text)
    text = ITALIC_RE.sub(r"\1", text)
    return text


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Strip *//** bold/italic markers from markdown"
    )
    parser.add_argument("-i", "--input", required=True, help="Input markdown file")
    parser.add_argument(
        "-o",
        "--output",
        help="Output markdown file (defaults to overwriting input)",
    )
    args = parser.parse_args()

    src = Path(args.input).read_text(encoding="utf-8")
    dst = strip_stars(src)
    out = Path(args.output) if args.output else Path(args.input)
    out.write_text(dst, encoding="utf-8")


if __name__ == "__main__":
    main()
