# MLXRunner

A native macOS app (SwiftUI, Apple Silicon) that installs the MLX inference engines available on GitHub, benchmarks them against each other on your own models, tells you the fastest engine for each model, and serves any model as an OpenAI-compatible API.

## What it does

- **Engines**: one-click install of each engine into its own isolated Python environment (managed with [uv](https://docs.astral.sh/uv/)), or through Homebrew / an existing app. Engines update automatically once a day; the new version is installed side by side and the old one is deleted only after the new one works.
- **Models**: finds MLX models already on your Mac (MLXRunner folder, Hugging Face cache, LM Studio, mlx-serve) and downloads new ones from Hugging Face (mlx-community, lmstudio-community or any repo), with size in GB and a "fits in RAM" hint.
- **Benchmark**: starts each engine as an OpenAI-compatible server, sends identical streamed chat requests and measures:
  - time to first token (ms)
  - prompt processing speed (tokens/s)
  - generation speed (tokens/s)
  - peak memory (GB, system-wide increase, plus process footprint)
  - load time (launch → first token)

  Each prompt starts with a random nonce so prompt caches can't skew results; one warm-up request, then N measured runs (median).
- **Results**: per model ranking with a weighted score (default 50 % generation, 25 % prompt, 15 % TTFT, 10 % memory; adjustable in Settings), charts, CSV export.
- **Serve**: run any model with any engine (the benchmark winner is pre-selected) on a port of your choice, on localhost or your local network.
- **Discover**: searches GitHub for new MLX engines and lets you add one as a custom engine (pip packages + launch command).

## Supported engines

| Engine | Install | Notes |
|---|---|---|
| [mlx-lm](https://github.com/ml-explore/mlx-lm) | uv | Apple's reference engine, the baseline |
| [mlx-vlm](https://github.com/Blaizzy/mlx-vlm) | uv | vision models only |
| [vllm-mlx](https://github.com/waybarrios/vllm-mlx) | uv | continuous batching |
| [MLX Omni Server](https://github.com/madroidmaq/mlx-omni-server) | uv | beta |
| [mlx-openai-server](https://github.com/cubist38/mlx-openai-server) | uv | |
| [Rapid-MLX](https://github.com/raullenchai/Rapid-MLX) | uv | beta |
| [oMLX](https://github.com/jundot/omlx) | uv (from Git) | beta, updates tracked by commit |
| [MTPLX](https://github.com/youssofal/MTPLX) | uv | multi-token prediction |
| [mlx-serve](https://github.com/ddalcu/mlx-serve) | Homebrew or existing binary | native, no Python |
| [LM Studio](https://lmstudio.ai) (mlx-engine) | LM Studio app | via `lms`; models in `~/.lmstudio/models` |

Engine recipes live in [`MLXRunner/Resources/engines.json`](MLXRunner/Resources/engines.json).

## Build and run

Requirements: Apple Silicon Mac, macOS 15+, Xcode 16+ (with command line tools), Homebrew.

Open **Terminal** and run:

```sh
git clone https://github.com/ramirobuisan/MLXRunner.git ~/Developer/MLXRunner
cd ~/Developer/MLXRunner
./scripts/build.sh --install
open /Applications/MLXRunner.app
```

`build.sh` installs [XcodeGen](https://github.com/yonaskolb/XcodeGen) if needed, generates the Xcode project and builds a Release app. Without `--install` the app is left in `build/MLXRunner.app`.

To work on the code in Xcode: `xcodegen generate && open MLXRunner.xcodeproj`.

## Where things are stored

- Engines: `~/Library/Application Support/MLXRunner/Engines/<engine>/env-<timestamp>/`
- Results: `~/Library/Application Support/MLXRunner/results.json`
- Downloaded models: `~/MLXRunner/Models/<org>/<model>` (change in Settings)

## Tips for fair numbers

- Plug in the charger and close heavy apps.
- Only one engine runs at a time; there is a cool-down between engines.
- Speculative/MTP engines (MTPLX, mlx-serve) can look much faster on models with MTP heads; that's a real advantage, not a measurement error.
