#!/usr/bin/env python3
import re
import argparse
from pathlib import Path

KOREAN = r"[\u1100-\u11FF\u3130-\u318F\uAC00-\uD7AF]"


def fix_spacing(text: str) -> str:
    patterns = [
        r"\*\*[^*\n]+?\*\*",  # **bold**
        r"\*[^*\n]+?\*",      # *italic*
        r"`[^`\n]+?`",        # `code`
    ]

    for p in patterns:
        # 한국어 바로 뒤에 inline markup이 오면, markup 앞에 space
        text = re.sub(rf"({KOREAN})({p})", r"\1 \2", text)

        # inline markup 바로 뒤에 한국어가 오면, markup 뒤에 space
        text = re.sub(rf"({p})({KOREAN})", r"\1 \2", text)

    return text


def main():
    parser = argparse.ArgumentParser(
        description="Ensure spaces around inline markdown spans next to Korean text"
    )
    parser.add_argument("-i", "--input", required=True, help="Input markdown file")
    parser.add_argument("-o", "--output", required=True, help="Output markdown file")
    args = parser.parse_args()

    input_path = Path(args.input)
    output_path = Path(args.output)

    text = input_path.read_text(encoding="utf-8")
    fixed = fix_spacing(text)
    output_path.write_text(fixed, encoding="utf-8")


if __name__ == "__main__":
    main()
