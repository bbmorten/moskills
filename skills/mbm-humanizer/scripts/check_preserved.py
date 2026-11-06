#!/usr/bin/env python3
"""Check that a rewrite kept every hard fact of the original.

    python3 check_preserved.py ORIGINAL REWRITE

Compares, as multisets: numbers (with their own separators and a trailing %), URLs,
e-mail addresses, Markdown link targets, inline code spans and fenced code blocks; and
the count of Markdown headings. Reports the length change in characters. Prints
"OK" when nothing is missing, otherwise "CHECK" with each missing or added item.
Exit status 0 = nothing missing, 1 = something missing (added items alone do not fail:
they may be legitimate, but read them).
"""
import re
import sys
from collections import Counter

FENCE = re.compile(r"```.*?```", re.S)
INLINE = re.compile(r"`[^`\n]+`")
URL = re.compile(r"https?://[^\s)\]>\"'`]+")
EMAIL = re.compile(r"\b[\w.+-]+@[\w-]+(?:\.[\w-]+)+\b")
LINK = re.compile(r"\]\(([^)\s]+)\)")
NUM = re.compile(r"(?<![\w.,])[+-]?\d+(?:[.,:]\d+)*%?(?![\w])|%\d+(?:[.,]\d+)*")
HEADING = re.compile(r"^#{1,6}\s", re.M)


def facts(text):
    fences = FENCE.findall(text)
    rest = FENCE.sub(" ", text)
    inline = INLINE.findall(rest)
    rest2 = INLINE.sub(" ", rest)
    urls = [u.rstrip(".,;:!?") for u in URL.findall(rest2)]
    rest3 = URL.sub(" ", rest2)
    return {
        "fenced code block": Counter(f.strip() for f in fences),
        "inline code": Counter(inline),
        "URL": Counter(urls),
        "link target": Counter(LINK.findall(text)),
        "e-mail": Counter(EMAIL.findall(rest3)),
        "number": Counter(n.rstrip(".,:") for n in NUM.findall(EMAIL.sub(" ", rest3))),
    }


def main():
    if len(sys.argv) != 3:
        print(__doc__)
        return 2
    a = open(sys.argv[1], encoding="utf-8").read()
    b = open(sys.argv[2], encoding="utf-8").read()
    fa, fb = facts(a), facts(b)
    missing, added = [], []
    for kind in fa:
        for item, n in (fa[kind] - fb[kind]).items():
            missing.append(f"{kind}: {item!r}" + (f" ×{n}" if n > 1 else ""))
        for item, n in (fb[kind] - fa[kind]).items():
            added.append(f"{kind}: {item!r}" + (f" ×{n}" if n > 1 else ""))
    ha, hb = len(HEADING.findall(a)), len(HEADING.findall(b))
    la, lb = len(a.strip()), len(b.strip())
    change = 100.0 * (lb - la) / max(la, 1)
    print(f"length: {la} -> {lb} characters ({change:+.1f}%)")
    print(f"headings: {ha} -> {hb}")
    if missing:
        print("MISSING from the rewrite:")
        for m in missing:
            print("  - " + m)
    if added:
        print("ADDED in the rewrite (check each is not a new claim):")
        for m in added:
            print("  + " + m)
    print("OK" if not missing else "CHECK")
    return 1 if missing else 0


if __name__ == "__main__":
    sys.exit(main())
