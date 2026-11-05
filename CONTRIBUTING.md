# Contributing to MLXRunner

Thanks for helping. Bug reports, new engines, benchmark results from other Macs and pull requests are all welcome.

## Ways to help

- **Report a bug**: open an issue with the [bug report form](https://github.com/ramirobuisan/MLXRunner/issues/new?template=bug_report.yml). Include your Mac, macOS version and the engine log (Engines tab, select the engine, copy the log).
- **Ask for an engine**: use the [engine request form](https://github.com/ramirobuisan/MLXRunner/issues/new?template=engine_request.yml).
- **Share results**: in Results, press **Export CSV** and attach the file to an issue. Numbers from M1 to M4 Macs are especially useful.
- **Send a pull request**: see below.

## Development setup

You need an Apple Silicon Mac with macOS 15 or newer, Xcode 16 or newer and Homebrew.

```sh
git clone https://github.com/ramirobuisan/MLXRunner.git
cd MLXRunner
brew install xcodegen
xcodegen generate
open MLXRunner.xcodeproj
```

The Xcode project is generated from [`project.yml`](project.yml) and is not committed. Run `xcodegen generate` again after adding or removing files.

To build a Release app from the command line:

```sh
./scripts/build.sh            # app in build/MLXRunner.app
./scripts/build.sh --install  # also copies it to /Applications
```

## Project layout

| Folder | What is in it |
|---|---|
| `MLXRunner/App` | app entry point, sidebar, window |
| `MLXRunner/Engines` | engine recipes, install and update (`EngineManager`), launching servers (`EngineLauncher`) |
| `MLXRunner/Bench` | benchmark client and runner, results and scoring |
| `MLXRunner/Models` | local model scanner and Hugging Face downloader |
| `MLXRunner/Serve` | servers started from the Serve tab |
| `MLXRunner/Support` | shell helpers, paths, memory and system info |
| `MLXRunner/Views` | one SwiftUI view per tab, plus shared components in `Common.swift` |
| `MLXRunner/Resources` | `engines.json` (engine recipes) and `constraints.txt` (pip pins shared by every engine) |

## Adding an engine

Most engines need no Swift code: add an entry to [`MLXRunner/Resources/engines.json`](MLXRunner/Resources/engines.json). The engine must be able to run as an OpenAI-compatible server with streamed `/v1/chat/completions`.

```json
{
  "id": "my-engine",
  "name": "My Engine",
  "repo": "someone/my-engine",
  "summary": "One sentence shown on the Engines tab.",
  "install": { "kind": "uv", "python": "3.12", "packages": ["my-engine"] },
  "versionPackage": "my-engine",
  "command": ["{bin}/my-engine", "serve", "--model", "{model}", "--host", "{host}", "--port", "{port}"],
  "requestModel": "{model}",
  "experimental": true
}
```

| Field | Meaning |
|---|---|
| `id` | short unique id, also the folder name under `Engines/` |
| `name`, `repo`, `summary` | shown on the Engines tab; `repo` is `owner/name` on GitHub |
| `install.kind` | `uv` (Python packages in their own environment), `brew` (Homebrew formula) or `external` (installed by the user, such as LM Studio) |
| `install.packages` | pip requirements for `uv`; a `git+https://…` URL installs from Git and updates are tracked by commit |
| `install.python` | Python version for the environment (3.12 is the safe choice) |
| `install.tap`, `install.formula`, `install.binaries` | for `brew`: the tap, the formula, and binary paths to look for if the engine is already installed some other way |
| `versionPackage` | the package whose version is shown and compared with PyPI |
| `command` | the server command; see the placeholders below |
| `env` | extra environment variables; placeholders work here too |
| `requestModel` | the `model` value sent in API requests (default `{model}`) |
| `visionOnly` | `true` if the engine only runs vision models |
| `experimental` | `true` shows a "beta" label |
| `lifecycle` | leave it out; `lmstudio` is only for LM Studio |

Placeholders in `command`, `env` and `requestModel`:

| Placeholder | Becomes |
|---|---|
| `{bin}` | the engine's environment `bin` folder |
| `{exe}` | the engine's executable (for `brew` and `external`) |
| `{model}` | the full path of the model folder |
| `{modelParent}` | the folder that contains the model folder |
| `{modelName}` | the model folder's name |
| `{repoId}` | the Hugging Face repo id, when known |
| `{modelType}` | `multimodal` for vision models, `lm` otherwise |
| `{mtpFlag}` | empty for models with MTP heads, `--no-mtp` otherwise |
| `{host}`, `{port}` | where the server must listen |

Before opening the pull request:

1. Build the app and press **Install** on your engine.
2. Benchmark it on a small model such as `mlx-community/Qwen3-0.6B-4bit` together with mlx-lm.
3. Put a screenshot of the Results card, or the exported CSV, in the pull request.

You can also try a recipe without rebuilding: in the **Discover** tab, press **Add custom engine**. Custom engines are saved in `~/Library/Application Support/MLXRunner/custom-engines.json`.

If an engine needs a pip pin to work (for example `pillow<13`), add it to [`constraints.txt`](MLXRunner/Resources/constraints.txt) with a comment that explains why.

## Pull requests

- Keep each pull request to one change, and describe what you tested on which Mac.
- Follow the style of the code around you: Swift 5, SwiftUI, 4-space indentation, no third-party Swift packages.
- The app must keep building with `./scripts/build.sh`; GitHub Actions checks this on every pull request.
- Update the README and the CHANGELOG when you change something users see.

## Code of conduct

Be kind and assume good intent. This project follows the [Contributor Covenant](https://www.contributor-covenant.org/version/2/1/code_of_conduct/). Report unacceptable behaviour privately to the maintainer through the contact options on [github.com/ramirobuisan](https://github.com/ramirobuisan).
