#!/usr/bin/env python3
import re
import argparse
from pathlib import Path

KOREAN_RE = r"[\u1100-\u11FF\u3130-\u318F\uAC00-\uD7AF]"


def fix_markdown_korean_spacing(text: str) -> str:
    # *, ** handling
    text = re.sub(rf"(\*\*|\*)(?={KOREAN_RE})", r"\1 ", text)
    text = re.sub(rf"(?<={KOREAN_RE})(\*\*|\*)", r" \1", text)

    # ` handling (inline code)
    text = re.sub(rf"`(?={KOREAN_RE})", "` ", text)
    text = re.sub(rf"(?<={KOREAN_RE})`", " `", text)

    return text


def main():
    parser = argparse.ArgumentParser(
        description="Ensure spaces between Markdown markers (*, **, `) and Korean text."
    )
    parser.add_argument("-i", "--input", required=True, help="Input markdown file")
    parser.add_argument("-o", "--output", required=True, help="Output markdown file")

    args = parser.parse_args()

    input_path = Path(args.input)
    output_path = Path(args.output)

    text = input_path.read_text(encoding="utf-8")
    fixed = fix_markdown_korean_spacing(text)
    output_path.write_text(fixed, encoding="utf-8")


if __name__ == "__main__":
    main()
