#!/usr/bin/env python3
"""
Download remote http(s) images referenced in a Markdown file and rewrite the
references to local, relative paths into a persistent cache.

Why
---
Typst cannot fetch remote URLs, so any `![alt](https://...)` must be backed
by a local file before pandoc runs. This preprocessor downloads each remote
image once into a content-addressed cache and rewrites the reference.

Usage
-----
    preprocess_images.py input.md output.md [--cache-dir DIR] [--timeout N]

The original input.md is never modified. output.md is a derived file with
remote image references replaced by local ones; feed THAT to pandoc.

Behaviour on failure
--------------------
A failed download leaves the original remote reference in the output and
prints a warning to stderr. The build then fails loudly at the typst stage
("file not found") instead of silently dropping the image.

Notes
-----
* Downloads are cached by URL hash, so repeated builds do not re-fetch.
  Delete the cache directory to force a re-download.
* Image links written into the output Markdown are RELATIVE to the output
  file's directory, so the document stays portable across machines.
* Only `![alt](url "title")` Markdown image syntax is handled. Raw HTML
  `<img>` tags are out of scope.
"""

from __future__ import annotations

import argparse
import hashlib
import os
import re
import sys
import urllib.request
from pathlib import Path
from urllib.parse import urlsplit

DOWNLOAD_TIMEOUT_SECONDS = 30

IMAGE_RE = re.compile(
    r"!\[(?P<alt>[^\]]*)\]\(\s*(?P<url>[^)\s]+)(?:\s+(?P<title>\"[^\"]*\"))?\s*\)"
)

# Extensions recognised directly in the URL path.
URL_EXT_RE = re.compile(
    r"\.(png|jpe?g|gif|svg|webp|avif|bmp)$", re.IGNORECASE
)

# Fallback: derive the extension from the HTTP Content-Type header.
CONTENT_TYPE_EXT = {
    "image/png": ".png",
    "image/jpeg": ".jpg",
    "image/gif": ".gif",
    "image/svg+xml": ".svg",
    "image/webp": ".webp",
    "image/avif": ".avif",
    "image/bmp": ".bmp",
}


def is_remote(url: str) -> bool:
    return url.lower().startswith(("http://", "https://"))


def pick_extension(url: str, content_type: str) -> str:
    path = urlsplit(url).path
    m = URL_EXT_RE.search(path)
    if m:
        ext = m.group(1).lower()
        return ".jpg" if ext == "jpeg" else f".{ext}"
    return CONTENT_TYPE_EXT.get(content_type, ".png")


def download(url: str, timeout: int) -> tuple[bytes, str]:
    """Fetch `url`; return (data, content_type). Raises on failure."""
    req = urllib.request.Request(
        url, headers={"User-Agent": "MRKcompile-build/1.0"}
    )
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        data = resp.read()
        ctype = resp.headers.get("Content-Type", "").split(";")[0].strip().lower()
    return data, ctype


def local_path_for(url: str, cache_dir: Path, content_type: str) -> Path:
    digest = hashlib.sha256(url.encode("utf-8")).hexdigest()[:16]
    return cache_dir / f"img-{digest}{pick_extension(url, content_type)}"


def process(
    input_path: Path,
    output_path: Path,
    cache_dir: Path,
    timeout: int,
) -> None:
    text = input_path.read_text(encoding="utf-8")

    matches = list(IMAGE_RE.finditer(text))
    remote = [m for m in matches if is_remote(m.group("url"))]
    if not remote:
        output_path.parent.mkdir(parents=True, exist_ok=True)
        output_path.write_text(text, encoding="utf-8")
        print(f"No remote images in {input_path.name}; copied unchanged.")
        return

    pieces: list[str] = []
    last_end = 0
    fetched = 0
    cached = 0
    failed = 0

    for m in matches:
        pieces.append(text[last_end:m.start()])
        last_end = m.end()
        url = m.group("url")

        if not is_remote(url):
            pieces.append(m.group(0))
            continue

        # Provisional extension before we know the content type; renamed
        # below if the header disagrees.
        target = local_path_for(url, cache_dir, "")
        if target.exists():
            cached += 1
        else:
            try:
                data, ctype = download(url, timeout)
            except Exception as e:  # noqa: BLE001 — any failure is surfaced
                print(f"WARNING: could not download {url}: {e}", file=sys.stderr)
                print(
                    f"         leaving remote reference unchanged in "
                    f"{output_path.name}",
                    file=sys.stderr,
                )
                pieces.append(m.group(0))
                failed += 1
                continue
            target = local_path_for(url, cache_dir, ctype)
            if target != local_path_for(url, cache_dir, "") and target.exists():
                cached += 1  # same URL already cached under another extension
            else:
                cache_dir.mkdir(parents=True, exist_ok=True)
                target.write_bytes(data)
                fetched += 1

        # Relative path from the OUTPUT file's directory to the cached file.
        # os.path.relpath (not Path.relative_to) handles sibling directories
        # and produces a portable, machine-independent link.
        try:
            rel = os.path.relpath(target, start=output_path.parent)
        except ValueError:
            rel = str(target)  # different drives on Windows

        title = m.group("title")
        suffix = f" {title}" if title else ""
        pieces.append(f"![{m.group('alt')}]({Path(rel).as_posix()}{suffix})")

    pieces.append(text[last_end:])
    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text("".join(pieces), encoding="utf-8")

    msg = (
        f"{input_path.name}: {len(remote)} remote image(s) -> "
        f"{output_path.name} ({fetched} downloaded, {cached} cached)"
    )
    if failed:
        msg += f" ({failed} failed, left as remote references)"
    print(msg)


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("input", type=Path)
    ap.add_argument("output", type=Path)
    ap.add_argument(
        "--cache-dir",
        type=Path,
        default=Path(".cache/images"),
        help="directory to cache downloaded images (default: .cache/images)",
    )
    ap.add_argument(
        "--timeout",
        type=int,
        default=DOWNLOAD_TIMEOUT_SECONDS,
        help=f"download timeout in seconds (default: {DOWNLOAD_TIMEOUT_SECONDS})",
    )
    args = ap.parse_args()

    process(args.input, args.output, args.cache_dir, args.timeout)


if __name__ == "__main__":
    main()
