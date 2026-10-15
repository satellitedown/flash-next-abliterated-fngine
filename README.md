# Qwen3.8-Flash-Next heretic: fngine

A repository-local installer for [Qwen3.8-Flash-Next-heretic-fngine](https://huggingface.co/satellitedown/Qwen3.8-Flash-Next-heretic-fngine), a decensored Qwen3.8-Flash-Next served by [fngine](https://github.com/satellitedown/fngine), a C++20/CUDA engine written for this model. The routed experts keep their ISTA-DASLab GSQ-RCO IQ3_S bytes and are split between the GPU and an AVX-512 CPU tier, the dense weights are FP8, and MTP speculation is lossless. Adapted from the [fafstmobel installer](https://github.com/satellitedown/fafstmobel-cinference).

This repository is the installation for the heretic model. The engine is developed separately in [satellitedown/fngine](https://github.com/satellitedown/fngine), and the model's weights are hosted on Hugging Face (too large for Git); this installer pins one engine commit and one model revision and installs both.

## Run

You need **Linux x86_64, an RTX 5090 (32 GB), an AVX-512 CPU (AMD Zen 4/5, Intel Sapphire Rapids or later), about 60 GB of RAM, and an NVIDIA driver compatible with CUDA 13.3**. The model is too large for VRAM alone: part of every layer's experts runs on the CPU, so CPU and RAM speed matter. This preset builds for Blackwell **sm_120a**; other GPUs are not validated. The installer does not install or change GPU drivers.

Install with one command. It downloads this installer to `~/flash-next-abliterated-fngine` and opens its menu:

```bash
curl -fsSL https://raw.githubusercontent.com/satellitedown/flash-next-abliterated-fngine/main/get.sh | bash
```

Choose **1** to install (it builds fngine and downloads the model), then **3** to start the server. Run the same command again any time to get back to the menu. To install on another disk, set the folder: `curl -fsSL https://raw.githubusercontent.com/satellitedown/flash-next-abliterated-fngine/main/get.sh | FNGINE_DIR=/path/to/folder bash`.

Or do the same by hand:

```bash
git clone https://github.com/satellitedown/flash-next-abliterated-fngine
cd flash-next-abliterated-fngine
bash setup.sh
```

The same menu handles installation, updates, and serving:

1. **Install everything (build + download):** check prerequisites, offer to install missing system build packages with permission, install local tools, build the pinned fngine, and download the model. Allow **~86.8 GB for model files**, plus software, build products, and download working space.
2. **Download / resume model:** download the pinned pack and licenses without compiling the runtime or installing CUDA. Interrupted downloads retain their local cache and can be resumed. Existing files are checksum-verified rather than silently replaced.
3. **Start the server:** run in the foreground. Leave the terminal open while using the API; **Ctrl+C** stops it.
4. **Update:** bring this installer, fngine, and the model to the latest published versions. `bash setup.sh --update` does the same without the menu.

Choose **0** to exit the menu. An interrupted install can be continued with option 1, an interrupted download with option 2, and an interrupted update by running it again. Existing modified runtime source, unexpected CUDA files, or mismatched model files are reported instead of reset or deleted. Review the error and move conflicting files aside yourself before retrying.

Updating pulls this installer from GitHub, rebuilds fngine at its new pin, and checks the model files against the new checksums. Files that no longer match, such as an earlier model revision, are moved to `models/Qwen3.8-Flash-Next-heretic-fngine.previous-<time>/` and the pinned files are downloaded; nothing is deleted. An installation of the earlier abliterated release (`models/Qwen3.8-Flash-Next-abliterated-fngine/`) is renamed to the new folder first: its experts, n-gram table and MTP experts are the same files, so only the changed ones (mainly `dense.bin`, about 6 GB) are downloaded. The update stops before downloading if the replacement files don't fit beside the kept ones. Delete the `previous` folder once the new model works, and restart a running server to use the update.

The server keeps learning which experts your workload uses and stores that in `pack/routing-stats.bin`, which decides what stays on the GPU at the next start. Updates keep this file; delete it to start from the published statistics again (option 2 downloads them).

By default, everything lives inside this checkout: `.tools/`, `.venv/`, `.cuda-toolkit/`, `runtime/fngine/`, and `models/Qwen3.8-Flash-Next-heretic-fngine/`. The isolated CUDA SDK is pinned to **13.3.73** with cuBLAS **13.6.0.2**, the versions fngine is tested with; it does not use a system CUDA toolkit. System compilers, NVIDIA driver libraries and liburing remain prerequisites. CUDA 13.3 accepts GCC up to 15 as its host compiler: on systems whose default GCC is newer, the installer uses `g++-15` (or 14, 13, 12) for CUDA host code (on Arch, option 1 offers to install `gcc15`); `CUDAHOSTCXX` selects another. fngine's CPU code is compiled for the installing machine's CPU.

## Connect an application

Use the OpenAI-compatible API at **`http://127.0.0.1:8002/v1`**, model **`qwen3.8-flash-next`**. No API key is required. Keep the server on loopback: **there is no authentication** unless you pass `--api-key`. Requests run one at a time with a short queue; set agent frameworks to one concurrent request. Thinking output arrives as `reasoning_content`; `enable_thinking` and `reasoning_effort` work as with the Qwen chat template.

The profile in [runtime-manifest.json](runtime-manifest.json) uses a context of **262,144 tokens** with fngine's defaults: K8V8 KV cache, automatic MTP/prompt-lookup speculation, adaptive expert placement and the pack's decensoring edit. The server loads about 50 GB of experts into VRAM and RAM at startup: 14 seconds in testing with the model files already in the page cache, longer from a cold disk.

For direct use after installation:

```bash
bash scripts/serve.sh
```

`PACK_PATH` can select another fngine pack; `HOST` and `PORT` override the bind address. Additional `fngine-serve` arguments follow the manifest profile and take precedence, for example `--ctx 131072` to leave more VRAM to other programs. `--no-ablation` serves without the routed-expert edit, for comparison. `bash scripts/serve.sh --help`, `bash scripts/install.sh --help`, and `bash setup.sh --help` work without an installed runtime. For a different model storage location, the downloader accepts `--models-dir`; set `PACK_PATH` when serving from that location.

## Oh My Pi (OMP)

Merge this provider into `~/.omp/agent/models.yml`, keeping existing providers:

```yaml
providers:
  fngine:
    baseUrl: http://127.0.0.1:8002/v1
    auth: none
    api: openai-completions
    models:
      - id: qwen3.8-flash-next
        name: Qwen 3.8 Flash Next 256K heretic (fngine)
        contextWindow: 262144
        maxTokens: 32768
        reasoning: true
        thinking:
          mode: effort
          efforts: [low, medium, xhigh]
          defaultLevel: medium
          requiresEffort: false
        input: [text]
        cost: {input: 0, output: 0, cacheRead: 0, cacheWrite: 0}
        compat:
          supportsDeveloperRole: true
          supportsStore: false
          supportsStrictMode: false
          supportsToolChoice: false
          supportsReasoningEffort: true
          thinkingFormat: qwen-chat-template
          qwenTemplateReasoningEffort: true
          reasoningContentField: reasoning_content
          maxTokensField: max_tokens
          streamIdleTimeoutMs: 300000
```

Start the server first, then open OMP:

```bash
omp --model fngine/qwen3.8-flash-next
```

Use `--thinking off` for non-thinking requests. The explicit Qwen template setting is necessary because the custom model ID does not identify the upstream architecture to OMP.

## Verification

[results/verification.json](results/verification.json) records the pins, the toolchain, and the checks run from a fresh clone of this installer: build, download and checksum verification, serving, and update. The model's own verification (agreement with the original model, refusal and capability comparisons, engine tests) is in the model repository's `heretic/` folder and summarized on its [model card](https://huggingface.co/satellitedown/Qwen3.8-Flash-Next-heretic-fngine).

## Immutable downloads

[runtime-manifest.json](runtime-manifest.json) pins:

- runtime: `satellitedown/fngine` at a full commit, built with the locked CUDA wheels in [requirements-cuda.lock](requirements-cuda.lock);
- model: `satellitedown/Qwen3.8-Flash-Next-heretic-fngine` at a full revision, with the SHA-256 and size of every file needed to serve plus the repository's `LICENSE`, `NOTICE` and `README.md`. Its `heretic/` folder (how the model was made and verified) and the pack's `dense_bf16.bin` (8.7 GB, used only by fngine's validation mode) are not downloaded.

Maintainers pin new versions with `.venv/bin/python tools/pin.py`, which takes every checksum from the Hub at the pinned revision, and commit the result.

## Model lineage

The pack is Qwen3.8-Flash-Next with ISTA-DASLab's GSQ-RCO IQ3_S routed experts and n-gram table, FP8 dense weights converted from the official BF16 release, and the decensoring of [trohrbaugh/Qwen3.8-Flash-Next-heretic-2](https://huggingface.co/trohrbaugh/Qwen3.8-Flash-Next-heretic-2) (made with [Heretic](https://github.com/p-e-w/heretic)): its 21 edited dense tensors are included, and its routed-expert edit (one refusal direction and weight per layer, in layers 31–35) is applied by fngine to the summed routed-expert output, which is mathematically equivalent and keeps the quantized expert bytes unchanged. No training was done. It stays close to the original model (G2 top-1 agreement 0.899 against 0.911 for the un-edited pack) and answers 31 of 32 prompts the original partly refuses; outputs are unmoderated and not suitable for safety-critical use. It replaces the earlier huihui-ai abliteration, which measurably degraded the model on ordinary text.

## Licensing and credits

The **installer code is Apache-2.0**, under [LICENSE](LICENSE). That license does **not** relicense downloaded weights or software.

The model is a derivative of Qwen3.8-Flash-Next under the **Qwen Community License 1.0**, downloaded with it as `LICENSE`; its conditions apply to your use. fngine is Apache-2.0 and derives in part from Cinference and NInfer. CUDA components retain NVIDIA's license terms.

Credits include Qwen, ISTA-DASLab (GSQ, RCO), trohrbaugh and the Heretic authors, Neroued/NInfer, Cinference and ggml. See [NOTICE](NOTICE) and the downloaded `NOTICE`. This is an unofficial community recipe, not an upstream endorsement.
