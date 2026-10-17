#!/usr/bin/env python3
"""Write <model_dir>/manifest.json for one catalog entry (development tool).

The app's downloader does the same thing natively after verifying every
file; this script exists so tests and benchmarks can install a model by
hand. It never downloads: fetch the files listed in the catalog yourself.

    make_manifest.py <catalog.json> <model_id> <model_dir> [--verify]
"""
import hashlib
import json
import os
import sys

DOWNLOADER_ONLY_KEYS = {"url"}
CATALOG_ONLY_KEYS = {"display_name", "source", "base_model", "attribution"}


def sha256(path):
    digest = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def main():
    args = [a for a in sys.argv[1:] if a != "--verify"]
    verify = "--verify" in sys.argv
    if len(args) != 3:
        sys.exit(__doc__)
    catalog_path, model_id, model_dir = args
    with open(catalog_path, encoding="utf-8") as f:
        catalog = json.load(f)
    entry = next((m for m in catalog["models"] if m["model_id"] == model_id), None)
    if entry is None:
        sys.exit(f"model {model_id!r} not in catalog")

    manifest = {"schema": 1}
    for key, value in entry.items():
        if key in CATALOG_ONLY_KEYS:
            continue
        if key == "files":
            value = {role: {k: v for k, v in spec.items() if k not in DOWNLOADER_ONLY_KEYS}
                     for role, spec in value.items()}
        manifest[key] = value

    for role, spec in manifest["files"].items():
        if "path" not in spec:
            continue
        path = os.path.join(model_dir, spec["path"])
        if os.path.islink(path) or not os.path.isfile(path):
            sys.exit(f"{role}: {path} missing or not a regular file")
        if os.path.getsize(path) != spec["size"]:
            sys.exit(f"{role}: size mismatch")
        if verify and sha256(path) != spec["sha256"]:
            sys.exit(f"{role}: sha256 mismatch")

    tmp = os.path.join(model_dir, "manifest.json.tmp")
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(manifest, f, ensure_ascii=False, indent=2)
        f.write("\n")
    os.replace(tmp, os.path.join(model_dir, "manifest.json"))
    print(os.path.join(model_dir, "manifest.json"))


if __name__ == "__main__":
    main()
