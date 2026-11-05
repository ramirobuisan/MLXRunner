# Changelog

All notable changes to MLXRunner are listed here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and versions follow [Semantic Versioning](https://semver.org/).

## [Unreleased]

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

[Unreleased]: https://github.com/ramirobuisan/mlxrunner/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/ramirobuisan/mlxrunner/releases/tag/v0.1.0
