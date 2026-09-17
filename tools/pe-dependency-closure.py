#!/usr/bin/env python3
"""Compute the local PE DLL dependency closure for Jawal's QEMU runtime.

This intentionally has no third-party Python dependencies. It reads the PE import
and delay-import tables, resolves only DLLs present in the supplied runtime
directory, and treats Windows system DLLs as external dependencies.
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

        # Import directory index 1; delay-import directory index 13.
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
        # Header RVA fallback.
        if rva < len(self.data):
            return rva
        raise ValueError(f"RVA 0x{rva:x} outside sections in {self.path}")

    def imports(self) -> set[str]:
        names: set[str] = set()
        if self.import_rva:
            off = self.rva_to_offset(self.import_rva)
            # IMAGE_IMPORT_DESCRIPTOR: 20 bytes, Name RVA at +12.
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
            # IMAGE_DELAYLOAD_DESCRIPTOR: 32 bytes; DLLNameRVA at +4.
            while off + 32 <= len(self.data) and off < limit:
                fields = struct.unpack_from("<IIIIIIII", self.data, off)
                if not any(fields):
                    break
                attrs, name_field = fields[0], fields[1]
                if name_field:
                    # Modern images use RVA when dlattrRva bit is set. For old
                    # VA-style descriptors, translating reliably needs image base;
                    # QEMU Windows builds in scope use RVA-style delay imports.
                    if attrs & 1:
                        names.add(read_cstr(self.data, self.rva_to_offset(name_field)).lower())
                off += 32
        return {n for n in names if n.endswith(".dll")}


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("runtime_dir", type=Path)
    ap.add_argument("roots", nargs="+")
    ap.add_argument("--json", dest="json_path", type=Path)
    args = ap.parse_args()

    root = args.runtime_dir.resolve()
    local = {p.name.lower(): p for p in root.glob("*.dll")}
    roots = [root / name for name in args.roots]
    for p in roots:
        if not p.is_file():
            raise SystemExit(f"root PE missing: {p}")

    queue = roots[:]
    visited: set[Path] = set()
    required: dict[str, Path] = {}
    unresolved: dict[str, list[str]] = {}

    # DLLs not present beside QEMU are expected to be Windows/system runtime
    # dependencies. Record them for evidence, but do not copy or fail on them.
    while queue:
        current = queue.pop(0).resolve()
        if current in visited:
            continue
        visited.add(current)
        try:
            imports = PE(current).imports()
        except Exception as exc:
            raise SystemExit(f"failed to parse {current.name}: {exc}")
        missing_here: list[str] = []
        for name in sorted(imports):
            dep = local.get(name)
            if dep is not None:
                if name not in required:
                    required[name] = dep
                    queue.append(dep)
            else:
                missing_here.append(name)
        if missing_here:
            unresolved[current.name] = missing_here

    ordered = [required[k] for k in sorted(required)]
    for p in ordered:
        print(p.name)

    if args.json_path:
        args.json_path.parent.mkdir(parents=True, exist_ok=True)
        args.json_path.write_text(json.dumps({
            "roots": [p.name for p in roots],
            "localDllCount": len(ordered),
            "localDlls": [p.name for p in ordered],
            "externalImports": unresolved,
        }, indent=2), encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
