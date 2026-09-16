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

# Never recommend deleting these merely for size. They directly affect app
# compatibility, rendering/media quality, security, networking, storage or input.
PROTECTED_TOKENS = (
    "webview", "trichrome", "framework.jar", "services.jar", "app_process",
    "surfaceflinger", "systemui", "permissioncontroller", "packageinstaller",
    "documentsui", "downloadprovider", "audioserver", "audioflinger",
    "mediacodec", "media.swcodec", "stagefright", "codec2", "ffmpeg",
    "vulkan", "egl", "gles", "mesa", "virgl", "minigbm", "libdrm",
    "netd", "networkstack", "tethering", "dnsresolver", "keystore", "keymint",
    "gatekeeper", "vold", "storagemanager", "latinime", "inputmethod",
    "e2fsck", "fsck.ext4", "selinux", "sepolicy", "zygote", "libart",
    "libbinder", "libc.so", "libdl.so", "libm.so", "liblog.so",
    "jawalsystembridge", "jawalstore", "handheld_core_hardware",
)

# Strong candidates: content, diagnostics and physical-hardware helpers Jawal
# deliberately does not expose. These still require validator/boot evidence.
SAFE_HINT_TOKENS = (
    "wallpaper", "ringtone", "notification", "alarm", "sample", "demo",
    "benchmark", "trace", "debug", "test", "recovery", "setupwizard",
    "updater", "print", "nfc", "uwb", "satellite", "camera.provider",
    "emulatedcamera", "fastboot", "simpleperf", "strace", "heapprofd",
    "microdroid", "virtualizationservice", "/vm_shell", "/vm",
)

# Potentially removable but more likely to have indirect app dependencies.
REVIEW_HINT_TOKENS = (
    "dictionary", "tts", "emoji", "fonts", "locale", "hyph", "firmware",
    "bluetooth", "location", "sensor", "backup", "companion", "provision",
)


def mib(value: int) -> float:
    return round(value / 1024 / 1024, 2)


def classify(path: str) -> str:
    lower = path.lower().replace("\\", "/")
    if any(token in lower for token in PROTECTED_TOKENS):
        return "protected"
    if any(token in lower for token in SAFE_HINT_TOKENS):
        return "safe_candidate"
    if any(token in lower for token in REVIEW_HINT_TOKENS):
        return "review_candidate"
    return "unknown"


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("product_files")
    parser.add_argument("--output", default="dist/android/size-analysis.json")
    parser.add_argument("--markdown", default="dist/android/size-analysis.md")
    parser.add_argument("--plan", default="dist/android/pruning-plan.md")
    parser.add_argument("--top", type=int, default=100)
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
    risk_bytes = {"protected": 0, "safe_candidate": 0, "review_candidate": 0, "unknown": 0}

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
        risk_bytes[classify(path)] += size

    top = [
        {"sizeMiB": mib(size), "bytes": size, "path": path, "risk": classify(path)}
        for size, path in rows[: args.top]
    ]
    categories = [
        {"category": name, "sizeMiB": mib(size), "bytes": size}
        for name, size in sorted(category_bytes.items(), key=lambda item: item[1], reverse=True)
    ]
    risks = [
        {"class": name, "sizeMiB": mib(size), "bytes": size}
        for name, size in sorted(risk_bytes.items(), key=lambda item: item[1], reverse=True)
    ]

    safe = []
    review = []
    protected = []
    for size, path in rows:
        item = {"sizeMiB": mib(size), "bytes": size, "path": path}
        risk = classify(path)
        if risk == "safe_candidate" and len(safe) < 100:
            safe.append(item)
        elif risk == "review_candidate" and len(review) < 100:
            review.append(item)
        elif risk == "protected" and len(protected) < 100:
            protected.append(item)

    result = {
        "totalProductFilesMiB": mib(sum(size for size, _ in rows)),
        "fileCount": len(rows),
        "categories": categories,
        "riskClasses": risks,
        "largestFiles": top,
        "safeReviewCandidates": safe,
        "dependencyReviewCandidates": review,
        "protectedLargeFiles": protected,
        "policy": {
            "safe_candidate": "Review first; removable only if product validator and boot/app matrix stay green.",
            "review_candidate": "Do not remove without explicit dependency/app evidence.",
            "protected": "Do not remove for size optimization.",
        },
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
    lines += ["", "## Size by pruning risk", "", "| Class | MiB |", "|---|---:|"]
    lines.extend(f"| {item['class']} | {item['sizeMiB']} |" for item in risks)
    lines += ["", "## Largest files", "", "| MiB | Risk | Path |", "|---:|---|---|"]
    lines.extend(f"| {item['sizeMiB']} | {item['risk']} | `{item['path']}` |" for item in top[:50])
    md.write_text("\n".join(lines) + "\n", encoding="utf-8")

    plan = Path(args.plan)
    plan_lines = [
        "# JawalOS measured pruning plan",
        "",
        "Generated after a real Android build. Never delete protected entries for size.",
        "",
        "## Tier A — safest high-value review candidates",
        "",
        "| MiB | Path |",
        "|---:|---|",
    ]
    plan_lines.extend(f"| {item['sizeMiB']} | `{item['path']}` |" for item in safe[:60])
    plan_lines += [
        "",
        "## Tier B — dependency review required",
        "",
        "| MiB | Path |",
        "|---:|---|",
    ]
    plan_lines.extend(f"| {item['sizeMiB']} | `{item['path']}` |" for item in review[:60])
    plan_lines += [
        "",
        "## Protected large files — do not prune for size",
        "",
        "| MiB | Path |",
        "|---:|---|",
    ]
    plan_lines.extend(f"| {item['sizeMiB']} | `{item['path']}` |" for item in protected[:60])
    plan.write_text("\n".join(plan_lines) + "\n", encoding="utf-8")

    print(f"JawalOS size analysis: {result['totalProductFilesMiB']} MiB, {len(rows)} files")
    print(f"JSON: {output}")
    print(f"Markdown: {md}")
    print(f"Pruning plan: {plan}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
