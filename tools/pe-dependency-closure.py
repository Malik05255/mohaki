#!/usr/bin/env python3
"""Compute the local PE DLL dependency closure for Jawal's Windows runtime.

The scanner has no third-party Python dependencies. It reads PE import and
DelayLoad tables, recursively follows DLLs present beside the supplied binaries,
and can distinguish real Windows system DLLs from missing redistributable/runtime
DLLs. In strict mode, an unresolved non-system dependency is a packaging error.
"""
from __future__ import annotations

import argparse
import json
import struct
from pathlib import Path


def u16(data: bytes, off: int) -> int:
    return struct.unpack_from("<H", data, off)[0]


def u32(data: bytes, off: int) -> int:
    return struct.unpack_from("<I", data, off)[0]


def read_cstr(data: bytes, off: int) -> str:
    end = data.find(b"\0", off)
    if end < 0:
        end = len(data)
    return data[off:end].decode("ascii", errors="ignore")


class PE:
    def __init__(self, path: Path):
        self.path = path
        self.data = path.read_bytes()
        if self.data[:2] != b"MZ":
            raise ValueError(f"not PE/MZ: {path}")
        peoff = u32(self.data, 0x3C)
        if self.data[peoff:peoff + 4] != b"PE\0\0":
            raise ValueError(f"bad PE signature: {path}")

        coff = peoff + 4
        section_count = u16(self.data, coff + 2)
        optional_size = u16(self.data, coff + 16)
        optional = coff + 20
        magic = u16(self.data, optional)
        if magic == 0x20B:  # PE32+
            data_dir = optional + 112
        elif magic == 0x10B:  # PE32
            data_dir = optional + 96
        else:
            raise ValueError(f"unsupported PE optional header: {path}")

        self.import_rva = u32(self.data, data_dir + 8)
        self.import_size = u32(self.data, data_dir + 12)
        self.delay_rva = u32(self.data, data_dir + 13 * 8)
        self.delay_size = u32(self.data, data_dir + 13 * 8 + 4)

        sec = optional + optional_size
        self.sections: list[tuple[int, int, int, int]] = []
        for i in range(section_count):
            o = sec + i * 40
            virtual_size = u32(self.data, o + 8)
            virtual_addr = u32(self.data, o + 12)
            raw_size = u32(self.data, o + 16)
            raw_ptr = u32(self.data, o + 20)
            self.sections.append((virtual_addr, max(virtual_size, raw_size), raw_ptr, raw_size))

    def rva_to_offset(self, rva: int) -> int:
        if rva == 0:
            return 0
        for va, span, raw, _ in self.sections:
            if va <= rva < va + span:
                return raw + (rva - va)
        if rva < len(self.data):
            return rva
        raise ValueError(f"RVA 0x{rva:x} outside sections in {self.path}")

    def imports(self) -> set[str]:
        names: set[str] = set()
        if self.import_rva:
            off = self.rva_to_offset(self.import_rva)
            limit = off + (self.import_size or 1 << 20)
            while off + 20 <= len(self.data) and off < limit:
                fields = struct.unpack_from("<IIIII", self.data, off)
                if not any(fields):
                    break
                name_rva = fields[3]
                if name_rva:
                    names.add(read_cstr(self.data, self.rva_to_offset(name_rva)).lower())
                off += 20

        if self.delay_rva:
            off = self.rva_to_offset(self.delay_rva)
            limit = off + (self.delay_size or 1 << 20)
            while off + 32 <= len(self.data) and off < limit:
                fields = struct.unpack_from("<IIIIIIII", self.data, off)
                if not any(fields):
                    break
                attrs, name_field = fields[0], fields[1]
                if name_field and attrs & 1:
                    names.add(read_cstr(self.data, self.rva_to_offset(name_field)).lower())
                off += 32
        return {n for n in names if n.endswith(".dll")}


def is_api_set(name: str) -> bool:
    return name.startswith("api-ms-win-") or name.startswith("ext-ms-win-")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("runtime_dir", type=Path)
    ap.add_argument("roots", nargs="+")
    ap.add_argument("--json", dest="json_path", type=Path)
    ap.add_argument("--system-dir", dest="system_dirs", action="append", default=[])
    ap.add_argument("--strict-local", action="store_true",
                    help="fail if an imported DLL is neither local nor present in a system directory")
    args = ap.parse_args()

    root = args.runtime_dir.resolve()
    local = {p.name.lower(): p for p in root.glob("*.dll")}
    roots = [root / name for name in args.roots]
    for p in roots:
        if not p.is_file():
            raise SystemExit(f"root PE missing: {p}")

    system_names: set[str] = set()
    for raw in args.system_dirs:
        system_dir = Path(raw)
        if system_dir.is_dir():
            system_names.update(p.name.lower() for p in system_dir.glob("*.dll"))

    queue = roots[:]
    visited: set[Path] = set()
    required: dict[str, Path] = {}
    system_imports: dict[str, list[str]] = {}
    unresolved: dict[str, list[str]] = {}

    while queue:
        current = queue.pop(0).resolve()
        if current in visited:
            continue
        visited.add(current)
        try:
            imports = PE(current).imports()
        except Exception as exc:
            raise SystemExit(f"failed to parse {current.name}: {exc}")

        os_here: list[str] = []
        missing_here: list[str] = []
        for name in sorted(imports):
            dep = local.get(name)
            if dep is not None:
                if name not in required:
                    required[name] = dep
                    queue.append(dep)
            elif name in system_names or is_api_set(name):
                os_here.append(name)
            else:
                missing_here.append(name)
        if os_here:
            system_imports[current.name] = os_here
        if missing_here:
            unresolved[current.name] = missing_here

    ordered = [required[k] for k in sorted(required)]
    for p in ordered:
        print(p.name)

    result = {
        "roots": [p.name for p in roots],
        "localDllCount": len(ordered),
        "localDlls": [p.name for p in ordered],
        "systemImports": system_imports,
        "unresolvedNonSystemImports": unresolved,
        "strictLocal": args.strict_local,
    }
    if args.json_path:
        args.json_path.parent.mkdir(parents=True, exist_ok=True)
        args.json_path.write_text(json.dumps(result, indent=2), encoding="utf-8")

    if args.strict_local and unresolved:
        for owner, names in unresolved.items():
            print(f"unresolved non-system imports for {owner}: {', '.join(names)}", file=__import__('sys').stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
