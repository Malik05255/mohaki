#!/usr/bin/env python3
import argparse
import json
from pathlib import Path

CATEGORIES = {
    "webview": ("webview", "trichrome"),
    "media": ("codec", "media", "stagefright", "ffmpeg"),
    "fonts_locales": ("/fonts/", "/locale", "/icu", "/hyph"),
    "graphics": ("egl", "gles", "vulkan", "mesa", "virgl", "minigbm", "drm"),
    "framework": ("framework.jar", "/framework/", "services.jar", "boot-"),
    "apps": ("/app/", "/priv-app/"),
    "native_libs": ("/lib64/", "/lib/"),
    "firmware": ("/firmware/", "/vendor/firmware/"),
}


def mib(value: int) -> float:
    return round(value / 1024 / 1024, 2)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("product_files")
    parser.add_argument("--output", default="dist/android/size-analysis.json")
    parser.add_argument("--markdown", default="dist/android/size-analysis.md")
    parser.add_argument("--top", type=int, default=80)
    args = parser.parse_args()

    rows = []
    for raw in Path(args.product_files).read_text(encoding="utf-8", errors="replace").splitlines():
        if not raw.strip():
            continue
        size_text, path = raw.split("\t", 1)
        rows.append((int(size_text), path))
    rows.sort(reverse=True)

    category_bytes = {name: 0 for name in CATEGORIES}
    category_bytes["other"] = 0
    for size, path in rows:
        lower = path.lower().replace("\\", "/")
        matched = False
        for name, tokens in CATEGORIES.items():
            if any(token in lower for token in tokens):
                category_bytes[name] += size
                matched = True
                break
        if not matched:
            category_bytes["other"] += size

    top = [
        {"sizeMiB": mib(size), "bytes": size, "path": path}
        for size, path in rows[: args.top]
    ]
    categories = [
        {"category": name, "sizeMiB": mib(size), "bytes": size}
        for name, size in sorted(category_bytes.items(), key=lambda item: item[1], reverse=True)
    ]

    removable_hints = []
    hint_tokens = (
        "wallpaper", "ringtone", "notification", "alarm", "sample", "demo", "test",
        "dictionary", "tts", "emoji", "trace", "debug", "benchmark", "recovery"
    )
    for size, path in rows:
        lower = path.lower()
        if any(token in lower for token in hint_tokens):
            removable_hints.append({"sizeMiB": mib(size), "bytes": size, "path": path})
        if len(removable_hints) >= 60:
            break

    result = {
        "totalProductFilesMiB": mib(sum(size for size, _ in rows)),
        "fileCount": len(rows),
        "categories": categories,
        "largestFiles": top,
        "reviewCandidates": removable_hints,
        "note": "Review candidates are hints only. Compatibility-critical files must not be removed without boot/app-matrix evidence.",
    }

    output = Path(args.output)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(result, indent=2, ensure_ascii=False), encoding="utf-8")

    md = Path(args.markdown)
    lines = [
        "# JawalOS size analysis",
        "",
        f"Total product files: **{result['totalProductFilesMiB']} MiB** across **{len(rows)} files**.",
        "",
        "## Largest categories",
        "",
        "| Category | MiB |",
        "|---|---:|",
    ]
    lines.extend(f"| {item['category']} | {item['sizeMiB']} |" for item in categories)
    lines += ["", "## Largest files", "", "| MiB | Path |", "|---:|---|"]
    lines.extend(f"| {item['sizeMiB']} | `{item['path']}` |" for item in top[:40])
    lines += ["", "## Review candidates", "", "These are not automatic deletions; they require compatibility evidence.", "", "| MiB | Path |", "|---:|---|"]
    lines.extend(f"| {item['sizeMiB']} | `{item['path']}` |" for item in removable_hints[:40])
    md.write_text("\n".join(lines) + "\n", encoding="utf-8")

    print(f"JawalOS size analysis: {result['totalProductFilesMiB']} MiB, {len(rows)} files")
    print(f"JSON: {output}")
    print(f"Markdown: {md}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
