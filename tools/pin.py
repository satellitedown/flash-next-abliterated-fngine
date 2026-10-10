#!/usr/bin/env python3
"""Maintainer tool: pin the fngine commit and the model revision in runtime-manifest.json.

    .venv/bin/python tools/pin.py                                   # both repositories' main
    .venv/bin/python tools/pin.py --runtime COMMIT --model REVISION

Each pinned model file's SHA-256 and size come from the Hub at that revision: the Git LFS
metadata of large files, a download and hash of the small ones. Commit the result as a
"chore: pin ..." change; users receive it through bash setup.sh --update.
"""
import argparse
import hashlib
import json
import re
import tempfile
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
MANIFEST = ROOT / "runtime-manifest.json"
# Published but not needed to serve: the BF16 validation copies of the dense weights (8.7 GB)
# and an archived placement-statistics file.
EXCLUDE = {"pack/dense_bf16.bin", "pack/routing-stats.prefill-era.bin"}
ROOT_FILES = ("LICENSE", "NOTICE", "README.md")


def runtime_commit(repo_id, ref):
    """Full commit hash of `ref` (a branch or commit) in the GitHub repository."""
    request = urllib.request.Request(
        f"https://api.github.com/repos/{repo_id}/commits/{ref}",
        headers={"Accept": "application/vnd.github.sha"},
    )
    with urllib.request.urlopen(request, timeout=60) as response:
        commit = response.read().decode().strip()
    if not re.fullmatch(r"[0-9a-f]{40}", commit):
        raise SystemExit(f"Unexpected commit for {repo_id}@{ref}: {commit!r}")
    return commit


def model_files(repo_id, revision, pack):
    from huggingface_hub import HfApi, hf_hub_download
    from huggingface_hub.hf_api import RepoFile

    api = HfApi()
    revision = api.model_info(repo_id, revision=revision).sha
    files, small = {}, []
    for entry in api.list_repo_tree(repo_id, revision=revision, recursive=True, expand=True):
        if not isinstance(entry, RepoFile):
            continue
        wanted = entry.path in ROOT_FILES or (entry.path.startswith(f"{pack}/") and entry.path not in EXCLUDE)
        if not wanted:
            continue
        if entry.lfs:
            files[entry.path] = {"sha256": entry.lfs.sha256, "size": entry.lfs.size}
        else:
            small.append(entry.path)
    with tempfile.TemporaryDirectory() as scratch:
        for name in small:
            path = Path(hf_hub_download(repo_id, name, revision=revision, local_dir=scratch))
            files[name] = {"sha256": hashlib.sha256(path.read_bytes()).hexdigest(), "size": path.stat().st_size}
    return revision, dict(sorted(files.items()))


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--runtime", default="main", help="fngine branch or commit (default main)")
    parser.add_argument("--model", default="main", help="model branch or revision (default main)")
    args = parser.parse_args()
    manifest = json.loads(MANIFEST.read_text(encoding="utf-8"))
    runtime, model = manifest["runtime"], manifest["model"]

    runtime["revision"] = runtime_commit(runtime["repo_id"], args.runtime)
    model["revision"], model["files"] = model_files(model["repo_id"], args.model, model["pack"])
    required = {*ROOT_FILES, f"{model['pack']}/manifest.json", *model["seed_files"]}
    if not required <= set(model["files"]):
        raise SystemExit(f"The model revision lacks {sorted(required - set(model['files']))}")

    MANIFEST.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    total = sum(pin["size"] for pin in model["files"].values())
    print(f"runtime {runtime['repo_id']} @ {runtime['revision']}")
    print(f"model   {model['repo_id']} @ {model['revision']}: {len(model['files'])} files, {total / 1e9:.1f} GB")


if __name__ == "__main__":
    main()
