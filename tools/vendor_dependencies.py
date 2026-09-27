#!/usr/bin/env python3
"""Refresh the pinned source snapshots. Optional; ordinary builds never need network."""

import fnmatch
import hashlib
import io
import json
from pathlib import Path, PurePosixPath
import tarfile
import urllib.request


ROOT = Path(__file__).resolve().parents[1]


def selected(path, dependency):
    parts = path.parts
    if not parts or path.is_absolute() or ".." in parts:
        return False
    if any(p in {".git", ".github", "node_modules"} or p.startswith(".env") for p in parts):
        return False
    if any(str(path) == p or str(path).startswith(p + "/") for p in dependency["excluded"]):
        return False
    return any(fnmatch.fnmatch(parts[0], pattern) for pattern in dependency["included"])


def main():
    dependencies = json.loads((ROOT / "lib/dependencies.json").read_text())
    for dependency in dependencies:
        blob = urllib.request.urlopen(dependency["archive"], timeout=60).read()
        if hashlib.sha256(blob).hexdigest() != dependency["sha256"]:
            raise ValueError(f"Archive checksum mismatch: {dependency['name']}")
        destination = ROOT / "lib" / dependency["name"]
        count = 0
        with tarfile.open(fileobj=io.BytesIO(blob), mode="r:gz") as archive:
            for member in archive:
                relative = PurePosixPath(*PurePosixPath(member.name).parts[1:])
                if not member.isfile() or not selected(relative, dependency):
                    continue
                target = destination / relative
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes(archive.extractfile(member).read())
                count += 1
        print(f"{dependency['name']}: {count} ordinary files at {dependency['commit']}")


if __name__ == "__main__":
    main()
