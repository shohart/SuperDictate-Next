"""The ONNX speech-model catalog, and installing a model from it.

Port of ``OnnxModelDownload.swift``. Both platforms read the same pinned
catalog, ``native/asr-runtime/catalog/onnx-models.json``: one entry per
model, every file with its URL at a fixed revision, its size and its
SHA-256. Nothing is resolved at run time — no "latest", no hub API — so a
model that downloads is byte-for-byte the model the parity tests ran on.

An install is a directory ``Models\\onnx\\<model_id>\\`` holding the files
and a ``manifest.json``. The manifest is written last, after every file has
been verified, and ``SuperDictateOnnxHost`` refuses a directory without one,
so a download interrupted at any point leaves nothing the host will load.
"""

from __future__ import annotations

import hashlib
import json
import os
import shutil
import sys
import threading
import urllib.request
from dataclasses import dataclass
from pathlib import Path
from typing import Callable, Optional

from . import paths
from .logging_setup import get as get_logger

log = get_logger("onnx_models")

PARAKEET_ULTRA_MODEL_ID = "parakeet-ultra-int8"
GIGAAM_V3_MODEL_ID = "gigaam-v3-e2e-rnnt-int8"

#: Keys the manifest leaves out: ``url`` belongs to the downloader, the rest
#: are presentation. Same split as ``tools/make_manifest.py``.
_DOWNLOADER_ONLY_KEYS = {"url"}
_CATALOG_ONLY_KEYS = {"display_name", "source", "base_model", "attribution"}

_CHUNK = 1 << 20
#: Free space to keep beyond the download itself, so a model install never
#: fills the disk the settings and history live on.
_DISK_HEADROOM_BYTES = 512 * 1024 * 1024


class ModelInstallError(RuntimeError):
    pass


@dataclass(frozen=True)
class ModelFile:
    role: str
    path: str
    url: str
    size: int
    sha256: str


@dataclass(frozen=True)
class CatalogModel:
    model_id: str
    display_name: str
    license: str
    attribution: str
    files: tuple[ModelFile, ...]
    entry: dict

    @property
    def total_bytes(self) -> int:
        return sum(item.size for item in self.files)


# -- bundled resources ------------------------------------------------------

def _source_tree_root() -> Path:
    """The repository root when running from a checkout (``windows/..``)."""
    return Path(__file__).resolve().parent.parent.parent


def runtime_directory() -> Path:
    """Where the packaged build keeps the catalog, assets and the host."""
    return paths.resource_path("onnx-asr")


# The staged layout is flat, as in the macOS bundle's Resources/onnx-asr/:
# host, onnxruntime.dll, the catalog and the bundled feature graphs side by
# side (tools/build-onnx-host.ps1). A checkout without a staged tree falls
# back to the sources.

def catalog_path() -> Path:
    packaged = runtime_directory() / "onnx-models.json"
    if packaged.exists():
        return packaged
    return _source_tree_root() / "native" / "asr-runtime" / "catalog" / "onnx-models.json"


def assets_directory() -> Path:
    packaged = runtime_directory()
    if (packaged / "nemo128.onnx").is_file():
        return packaged
    return _source_tree_root() / "native" / "asr-runtime" / "assets"


def host_executable() -> Optional[Path]:
    """``SuperDictateOnnxHost.exe``: packaged first, then the CMake build tree."""
    name = "SuperDictateOnnxHost.exe" if sys.platform == "win32" else "SuperDictateOnnxHost"
    candidates = [runtime_directory() / name]
    override = os.environ.get("SUPERDICTATE_ONNX_HOST")
    if override:
        # Absolute: the host is spawned with its own directory as cwd.
        candidates.insert(0, Path(override).resolve())
    build = _source_tree_root() / "native" / "asr-runtime" / "build"
    candidates += [build / name, build / "Release" / name]
    for candidate in candidates:
        if candidate.is_file():
            return candidate
    return None


# -- catalog ----------------------------------------------------------------

_catalog_cache: Optional[dict[str, CatalogModel]] = None
_catalog_lock = threading.Lock()


def catalog() -> dict[str, CatalogModel]:
    global _catalog_cache
    with _catalog_lock:
        if _catalog_cache is None:
            _catalog_cache = _read_catalog(catalog_path())
        return _catalog_cache


def _read_catalog(path: Path) -> dict[str, CatalogModel]:
    with open(path, encoding="utf-8") as handle:
        raw = json.load(handle)
    if raw.get("schema") != 1:
        raise ModelInstallError(f"unsupported catalog schema in {path}")
    models: dict[str, CatalogModel] = {}
    for entry in raw["models"]:
        files = tuple(
            ModelFile(role=role, path=spec["path"], url=spec["url"],
                      size=int(spec["size"]), sha256=spec["sha256"].lower())
            for role, spec in entry["files"].items()
            if "path" in spec  # bundled preprocessors have no download
        )
        for item in files:
            _check_relative(item.path)
        models[entry["model_id"]] = CatalogModel(
            model_id=entry["model_id"],
            display_name=entry.get("display_name", entry["model_id"]),
            license=entry.get("license", ""),
            attribution=entry.get("attribution", ""),
            files=files,
            entry=entry,
        )
    return models


def model(model_id: str) -> CatalogModel:
    try:
        return catalog()[model_id]
    except KeyError:
        raise ModelInstallError(f"model {model_id!r} is not in the catalog") from None


def _check_relative(relative: str) -> None:
    # The host enforces the same rule; refusing here keeps a forged catalog
    # from writing outside the model directory in the first place.
    pure = Path(relative)
    if pure.is_absolute() or ".." in pure.parts or len(pure.parts) != 1:
        raise ModelInstallError(f"catalog path {relative!r} is not a plain file name")


# -- installs ---------------------------------------------------------------

def model_directory(model_id: str) -> Path:
    return paths.MODELS_DIR / "onnx" / model_id


def is_installed(model_id: str) -> bool:
    """Manifest present and every file the right size.

    Sizes only: hashing 600 MB on every launch would cost seconds. The host
    re-checks sizes and the downloader is the only writer, so a verified
    install stays verified unless somebody edits the files by hand.
    """
    try:
        entry = model(model_id)
    except (ModelInstallError, OSError, ValueError):
        return False
    directory = model_directory(model_id)
    if not (directory / "manifest.json").is_file():
        return False
    for item in entry.files:
        target = directory / item.path
        try:
            if target.is_symlink() or target.stat().st_size != item.size:
                return False
        except OSError:
            return False
    return True


def installed_bytes(model_id: str) -> int:
    directory = model_directory(model_id)
    if not directory.exists():
        return 0
    total = 0
    for item in directory.iterdir():
        try:
            if item.is_file():
                total += item.stat().st_size
        except OSError:
            continue
    return total


def delete(model_id: Optional[str] = None) -> None:
    targets = [model_id] if model_id else list(catalog())
    for name in targets:
        directory = model_directory(name)
        if directory.exists():
            shutil.rmtree(directory, ignore_errors=True)


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(_CHUNK), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _manifest_for(entry: dict) -> dict:
    manifest: dict = {"schema": 1}
    for key, value in entry.items():
        if key in _CATALOG_ONLY_KEYS:
            continue
        if key == "files":
            value = {role: {k: v for k, v in spec.items() if k not in _DOWNLOADER_ONLY_KEYS}
                     for role, spec in value.items()}
        manifest[key] = value
    return manifest


ProgressCallback = Callable[[int, int], None]


def install(model_id: str, on_progress: Optional[ProgressCallback] = None,
            cancelled: Optional[threading.Event] = None) -> Path:
    """Download and verify every missing file, then write the manifest.

    Each file goes to a ``.part`` beside its final name (same volume, so the
    rename is atomic), is checked for size and SHA-256, and only then takes
    its real name. A file already in place with the right size and digest is
    kept, so an interrupted install resumes at file granularity.
    """
    entry = model(model_id)
    directory = model_directory(model_id)
    directory.mkdir(parents=True, exist_ok=True)
    manifest_path = directory / "manifest.json"
    # The manifest is the "complete" marker; it goes first so that a
    # partially rewritten install can never look finished.
    manifest_path.unlink(missing_ok=True)

    total = entry.total_bytes
    done = 0

    def report(extra: int = 0) -> None:
        if on_progress is not None:
            try:
                on_progress(done + extra, total)
            except Exception:
                pass

    pending = []
    for item in entry.files:
        target = directory / item.path
        if (target.is_file() and not target.is_symlink()
                and target.stat().st_size == item.size and _sha256(target) == item.sha256):
            done += item.size
            continue
        pending.append(item)
    report()

    needed = sum(item.size for item in pending)
    if needed:
        free = shutil.disk_usage(directory).free
        if free < needed + _DISK_HEADROOM_BYTES:
            raise ModelInstallError(
                f"not enough disk space: {needed / 2**20:.0f} MB needed, "
                f"{free / 2**20:.0f} MB free")

    for item in pending:
        target = directory / item.path
        partial = directory / (item.path + ".part")
        log.info("Downloading %s (%d bytes)", item.url, item.size)
        digest = hashlib.sha256()
        received = 0
        request = urllib.request.Request(item.url, headers={"User-Agent": "SuperDictate"})
        try:
            with urllib.request.urlopen(request, timeout=60) as response, \
                    open(partial, "wb") as handle:
                while True:
                    if cancelled is not None and cancelled.is_set():
                        raise ModelInstallError("download cancelled")
                    chunk = response.read(_CHUNK)
                    if not chunk:
                        break
                    received += len(chunk)
                    if received > item.size:
                        raise ModelInstallError(f"{item.path}: more data than the catalog size")
                    digest.update(chunk)
                    handle.write(chunk)
                    report(received)
            if received != item.size:
                raise ModelInstallError(
                    f"{item.path}: got {received} bytes, expected {item.size}")
            if digest.hexdigest() != item.sha256:
                raise ModelInstallError(f"{item.path}: SHA-256 mismatch")
            os.replace(partial, target)
        except BaseException:
            partial.unlink(missing_ok=True)
            raise
        done += item.size
        report()

    temporary = directory / "manifest.json.tmp"
    with open(temporary, "w", encoding="utf-8", newline="\n") as handle:
        json.dump(_manifest_for(entry.entry), handle, ensure_ascii=False, indent=2)
        handle.write("\n")
    os.replace(temporary, manifest_path)
    log.info("Installed %s into %s", model_id, directory)
    return directory
