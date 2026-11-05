# Changelog

All notable changes to MLXRunner are listed here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and versions follow [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added

- Recommended settings per model, from the model cards and the model's own files: sampling for thinking and non-thinking mode, output length, context, memory, the engines and minimum engine versions it needs, and notes. Bundled for Qwen3, Qwen3.5, Qwen3.6, Qwen3.8, Qwen3.8-Flash-Next, Qwen3-VL, Gemma 4, Ornith 1.5, DeepSeek V4.1 Flash, Bonsai and popular mlx-serve, MTPLX and oMLX packs, and extensible with `model-profiles.json`.
- Models that need their own engine are recognised from their files: mlx-serve packs (`ngram_table.bin`), MTPLX packs (`mtplx_runtime.json`) and 1-bit weights, which need PrismML's MLX fork. Models no installed engine can run (1-bit Bonsai, JANG packs for vMLX) are marked as such and skipped.
- Models tab: a "Recommended settings" column with the details for each model.
- Benchmark: uses each model's recommended sampling by default (switch back to greedy decoding in the settings), skips engines a model can't run, and records the sampling in results and CSV.
- Serve: thinking or no-thinking mode, and the recommended sampling and output length set as the server's defaults on engines that support it.
- Serve with mlx-serve: "Run it like the MLX-Serve app" (on by default) keeps the context, MTP, drafter, KV cache and request defaults you saved in the MLX-Serve app, and shows them. The Models tab and benchmark log show them too.
- Serve preselects the model and engine you started last time.
- mlx-serve's version is detected when it was installed without Homebrew.

## [0.1.0] - 2026-11-05

First public version.

### Added

- Engines tab: one-click install of mlx-lm, mlx-vlm, vllm-mlx, MLX Omni Server, mlx-openai-server, Rapid-MLX, oMLX, MTPLX, mlx-serve and LM Studio, each in its own environment.
- Daily automatic engine updates. The new version installs next to the old one, and the old one is deleted only after the new one works.
- Models tab: finds MLX models on the Mac and downloads models from Hugging Face.
- Benchmark tab: TTFT, prompt speed, generation speed, peak memory and load time for every engine on every model, with cache-proof prompts calibrated to each tokenizer.
- Results tab: ranking per model with adjustable weights, charts and CSV export.
- Serve tab: run any model as an OpenAI-compatible server, with the benchmark winner preselected.
- Discover tab: search GitHub for new MLX engines and add custom engines.
- Copy button on every log.

### Fixed

- LM Studio: the model is found even when LM Studio indexes it under a shorter name, its server port is left unchanged, and its server is stopped afterwards only if MLXRunner started it.
- Cancelled benchmark runs are no longer saved as results, and failures fixed by a later run are hidden.
- Installed engines are preselected in the Benchmark tab once their status has loaded.

[Unreleased]: https://github.com/ramirobuisan/MLXRunner/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/ramirobuisan/MLXRunner/releases/tag/v0.1.0
