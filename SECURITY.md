# Security policy

## Reporting a vulnerability

Please do not open a public issue for security problems. Report them privately through GitHub instead:

1. Go to the [Security tab](https://github.com/ramirobuisan/MLXRunner/security) of this repository.
2. Press **Report a vulnerability** and describe the problem and how to reproduce it.

You should get an answer within 7 days. Fixes are released as soon as possible, and you will be credited unless you prefer not to be.

## Supported versions

Only the latest release gets security fixes.

## How MLXRunner handles risk

MLXRunner installs and runs third-party software, so it is worth knowing what it does:

- **Engines** are installed from PyPI, GitHub and Homebrew using the recipes in [`engines.json`](MLXRunner/Resources/engines.json). Each Python engine gets its own virtual environment under `~/Library/Application Support/MLXRunner/Engines/`. MLXRunner does not check engine code; you trust each engine's authors when you install it.
- **Custom engines** added from the Discover tab run whatever command you enter. Only add engines you trust.
- **Servers** listen on `127.0.0.1` unless you turn on **Allow other devices on my network** in the Serve tab. The engines have no authentication, so anyone on your network can then use the model.
- **The app is not sandboxed**, because it has to run Python, Homebrew and the engines' servers. Release builds are signed ad hoc, not notarized.
- **Hugging Face token**: the optional token is stored in the app's preferences (`~/Library/Preferences/com.ramirobuisan.MLXRunner.plist`), like the `hf` command line tool keeps it in a plain file. Use a read-only token.

Reports about any of these, or about an engine recipe that installs something unexpected, are welcome.
