#!/usr/bin/env python3
"""Download and verify the pinned abliterated Qwen3.8-Flash-Next fngine pack and its licenses."""
import argparse
import fcntl
import hashlib
import json
import os
import re
import shutil
import stat
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
# Free space required beyond the files themselves: metadata and filesystem overhead.
SPACE_MARGIN = 1 << 30


def require_file(path):
    if path.is_symlink() or not path.is_file():
        raise ValueError(f"Expected a regular, non-symlink file: {path}")


def file_digest(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def digests(paths):
    """SHA-256 of several large files at once (hashing releases the GIL)."""
    with ThreadPoolExecutor(max_workers=min(8, os.cpu_count() or 1)) as pool:
        return list(pool.map(file_digest, paths))


def matches(path, pin, digest):
    return not path.is_symlink() and path.is_file() and path.stat().st_size == pin["size"] and digest == pin["sha256"]


def mismatch_error(path, pin, digest):
    return ValueError(
        f"Size or SHA-256 mismatch: {path}\nExpected {pin['size']} bytes, SHA-256 {pin['sha256']}; "
        f"got {path.stat().st_size} bytes, SHA-256 {digest}.\n"
        "Move the damaged, outdated, or unrelated file aside and retry (bash setup.sh --update "
        "moves such files aside for you); it was not overwritten."
    )


def previous_directory(destination):
    """Create a new sibling folder for files that no longer match the pin."""
    stem = f"{destination.name}.previous-{time.strftime('%Y%m%d-%H%M%S')}"
    for attempt in range(1, 100):
        candidate = destination.with_name(stem if attempt == 1 else f"{stem}-{attempt}")
        try:
            candidate.mkdir()
        except FileExistsError:
            continue
        return candidate
    raise ValueError(f"Could not create a folder for the previous files next to {destination}.")


def set_aside(path, target):
    ensure_directory(target.parent)
    try:
        path.rename(target)
    except OSError as error:
        raise ValueError(
            f"Could not move {path} to {target}: {error}.\n"
            "Move it out of the model folder yourself and retry."
        ) from error


def require_space(destination, needed, previous):
    free = shutil.disk_usage(destination).free
    if free < needed + SPACE_MARGIN:
        kept = (
            f"\nThe files it replaces were moved to {previous}. Delete that folder if you no longer "
            "need it, then run the update again."
            if previous
            else "\nFree some space (or choose another --models-dir) and retry."
        )
        raise ValueError(
            f"The remaining model files need {needed / 1e9:.1f} GB of free space; "
            f"{free / 1e9:.1f} GB is free.{kept}"
        )


def ensure_directory(path):
    if path.is_symlink() or (path.exists() and not path.is_dir()):
        raise ValueError(f"Refusing a symlink or non-directory at {path}")
    path.mkdir(parents=True, exist_ok=True)


def load_model(manifest_path):
    require_file(manifest_path)
    model = json.loads(manifest_path.read_text(encoding="utf-8"))["model"]
    if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", model["repo_id"]):
        raise ValueError("Invalid model repo_id in runtime-manifest.json")
    if not re.fullmatch(r"[0-9a-f]{40}", model["revision"]):
        raise ValueError("The model revision must be a full commit hash in runtime-manifest.json")
    if f"{model['pack']}/manifest.json" not in model["files"]:
        raise ValueError("The manifest must pin the pack's manifest.json.")
    if not set(model["seed_files"]) <= set(model["files"]):
        raise ValueError("Every seed file must also be pinned.")
    for name in (model["directory"], model["pack"], *model["files"]):
        relative = Path(name)
        if relative.is_absolute() or ".." in relative.parts or not relative.name:
            raise ValueError(f"Expected a relative manifest path: {name}")
    for name, pin in model["files"].items():
        if not (re.fullmatch(r"[0-9a-f]{64}", pin["sha256"]) and isinstance(pin["size"], int)):
            raise ValueError(f"Invalid pin for {name}")
    return model


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--models-dir", type=Path, default=ROOT / "models")
    parser.add_argument(
        "--set-aside-mismatched",
        action="store_true",
        help="move existing files that do not match the pinned checksums to "
        "<model folder>.previous-<time>/ and download the pinned files instead of stopping; "
        "nothing is deleted (bash setup.sh --update uses this)",
    )
    args = parser.parse_args()
    model = load_model(ROOT / "runtime-manifest.json")
    files, seeds = model["files"], set(model["seed_files"])
    ensure_directory(args.models_dir)
    destination = args.models_dir
    for part in Path(model["directory"]).parts:
        destination /= part
        ensure_directory(destination)
    fd = os.open(destination / ".fngine-download.lock", os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, "r+") as lock:
        if not stat.S_ISREG(os.fstat(lock.fileno()).st_mode):
            raise ValueError("The download lock must be a regular file.")
        print("Waiting for exclusive download access...", flush=True)
        fcntl.flock(lock, fcntl.LOCK_EX)
        print(f"Model: {model['repo_id']} @ {model['revision']}", flush=True)
        for name in files:
            parent = destination
            for part in Path(name).parent.parts:
                parent /= part
                ensure_directory(parent)
        present = [name for name in files if (destination / name).exists() or (destination / name).is_symlink()]
        missing = [name for name in files if name not in present]
        # Seed files (the learned expert-placement statistics) are rewritten by the server, so
        # an existing copy is kept as it is; only a fresh download is checked against the pin.
        checked = [name for name in present if name not in seeds]
        if checked:
            print(f"Verifying {len(checked)} existing model files...", flush=True)
        for name in present:
            if name in seeds or not args.set_aside_mismatched:
                require_file(destination / name)
        regular = [name for name in checked if not (destination / name).is_symlink() and (destination / name).is_file()]
        found = dict(zip(regular, digests([destination / name for name in regular])))
        previous = None
        for name in present:
            path = destination / name
            if name in seeds:
                print(f"Kept (updated by the server): {name}", flush=True)
            elif matches(path, files[name], found.get(name)):
                print(f"Verified: {name}", flush=True)
            elif args.set_aside_mismatched:
                previous = previous or previous_directory(destination)
                set_aside(path, previous / name)
                print(f"Moved aside (does not match this pin): {name}", flush=True)
                missing.append(name)
            else:
                raise mismatch_error(path, files[name], found.get(name))
        if missing:
            require_space(destination, sum(files[name]["size"] for name in missing), previous)
            from huggingface_hub import snapshot_download

            # The local cache retains partial downloads. Existing files are
            # verified above and excluded so unrelated data is not overwritten.
            for directory in (destination / ".cache", destination / ".cache/huggingface"):
                ensure_directory(directory)
            size = sum(files[name]["size"] for name in missing)
            amount = (f"{size / 1e9:.1f} GB" if size >= 1e8 else f"{size / 1e6:.1f} MB" if size >= 1e6
                      else f"{size / 1e3:.0f} kB")
            print(f"Downloading {len(missing)} file{'s' if len(missing) != 1 else ''} ({amount})...", flush=True)
            snapshot_download(
                repo_id=model["repo_id"],
                revision=model["revision"],
                local_dir=destination,
                allow_patterns=missing,
            )
            for name in missing:
                require_file(destination / name)
            for name, digest in zip(missing, digests([destination / name for name in missing])):
                if not matches(destination / name, files[name], digest):
                    raise mismatch_error(destination / name, files[name], digest)
                print(f"Verified: {name}", flush=True)
    print(f"Ready: {destination / model['pack']}", flush=True)
    for kept in sorted(destination.parent.glob(f"{destination.name}.previous-*")):
        print(f"Earlier model files are kept in {kept}; delete it once the new model works.", flush=True)
    print("Download complete.", flush=True)


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, KeyError) as error:
        raise SystemExit(f"Download failed: {error}") from error
