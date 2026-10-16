# cross-model

> **About this fork.** Forked from [nimaloo/cross-model](https://github.com/nimaloo/cross-model). It adds:
> - **Windows support (Git Bash):** fixes a runner hang on stdin, a lost-signal hang in the timeout watchdog, and a `mktemp` incompatibility that mislabelled timeouts.
> - **Grok as an optional reviewer** for `/crossreview`: pick Codex, Grok, or both with `--with`. See [Grok reviewer](#grok-reviewer-optional).

Claude Code skills that bring in OpenAI Codex as an independent second opinion.

- **`/crossarch`**: architecture review of a whole codebase or site. Both models review blind, then every finding is checked against the code and sorted into found-by-both, Codex-only, Claude-only and rejected.
- **`/crossplan`**: planning. Both models plan blind, then the plans are reconciled into agreed, disputed and unique-to-one.
- **`/crossreview`**: diff review. Codex reviews uncommitted changes, a branch or a commit, and Claude checks each finding before you see it.

A second model only helps if it stays independent. If Codex sees Claude's plan or findings first, it tends to agree with them. So each skill hands Codex a neutral brief, runs it in the background, and has Claude finish its own work before reading anything Codex produced.

## Guarantees

- **Codex can't write to your repo.** Every call runs in a read-only sandbox (`-s read-only`, or `-c sandbox_mode="read-only"` on `codex exec review`, which rejects `-s`). It also runs with `--ephemeral`, so no session files are kept.
- **A failed cross-check is never shown as a pass.** If Codex is missing, logged out, times out, refuses or returns nothing useful, the reply opens by saying so and shows Claude's work alone, without the two-model layout.
- **Findings are checked, not just forwarded.** Claude opens the cited code for every Codex finding. A finding with no concrete failure path is rejected, and rejected findings stay visible in the report.

## Requirements

- [Claude Code](https://claude.com/claude-code)
- [Codex CLI](https://github.com/openai/codex) on `PATH` and signed in (`codex login`). A ChatGPT plan works; no API key is needed.
- bash 3.2 or later (the version macOS ships works; on Windows, Git Bash)

## Install

```bash
git clone https://github.com/nimaloo/cross-model.git
cd cross-model
./install.sh
```

This copies `codex-run.sh` to `~/.claude/cross-model/` and the three skills to `~/.claude/skills/`. Restart Claude Code, then type `/crossarch`, `/crossplan` or `/crossreview`. Run `git pull && ./install.sh` to update.

If you're working on the skills, use `./install.sh --link` instead. It symlinks the install to your checkout, so your edits take effect without reinstalling.

Codex uses whatever model and reasoning effort are set in `~/.codex/config.toml`.

## Usage

```
/crossarch                       # review the architecture of the current directory
/crossarch path/to/app           # or another path
/crossarch https://example.com   # public site only (delivery layer, not the backend)
/crossarch --write               # also save docs/architecture-review-<date>.md
/crossplan add rate limiting to the API
/crossreview                     # uncommitted changes
/crossreview against main        # branch diff
/crossreview --fix               # apply confirmed findings (never commits)
/crossreview --with grok         # Grok instead of Codex
/crossreview --with codex,grok   # both, blind to each other
```

## Grok reviewer (optional)

`/crossreview --with grok` (or `--with codex,grok`) adds xAI's Grok as a reviewer.

- **How it stays read-only:** Grok is called through xAI's API with the diff as plain text (15 lines of context) and no tools or file access, so it cannot write anything. xAI's own CLI has no sandbox on Windows, which is why this backend does not use it.
- **Setup:** Node.js 18+ on `PATH`, and an API key from [console.x.ai](https://console.x.ai) in the `XAI_API_KEY` environment variable.
- **Cost:** unlike Codex on a ChatGPT plan, Grok is billed per token. Every report ends with the run's token count and an approximate price. Diffs over 200 KB are refused rather than sent.
- **Settings:** `CROSS_MODEL_GROK_MODEL` (default `grok-4.7`), `CROSS_MODEL_GROK_MAX_BYTES` (default `200000`), `CROSS_MODEL_GROK_PRICE_IN` / `_OUT` (USD per 1M tokens, defaults `2` / `6`, used only for the estimate).

Grok uses the same exit codes as the Codex runner: 10 Node.js or the script is missing, 11 `XAI_API_KEY` is missing or rejected, 12 timeout, 13 API error or diff over the cap, 14 no output.

## Runner exit codes

The skills read these exit codes from `codex-run.sh {preflight|plan|arch|review|grok-review}`:

| Code | Meaning |
|---|---|
| 0 | Output written. The skill then checks it is a real result, not a refusal or quota message. |
| 10 | `codex` is not on `PATH` |
| 11 | `codex` is not logged in |
| 12 | Timed out |
| 13 | `codex` exited non-zero |
| 14 | `codex` produced no output |
| 64 | Bad arguments (a bug in the calling skill) |

## Tests

```bash
tests/run-tests.sh
```

The suite runs against a fake `codex` (`tests/fixtures/codex`) that copies the real CLI's flag parsing, so it never uses your rate limits. Results from a live run against the real CLI are in [`tests/smoke.md`](tests/smoke.md).

## Limitations

- Interactive Claude Code sessions only, not CI or git hooks.
- Codex's half uses your ChatGPT plan's rate limits.
- A whole-repo pass can take 5 to 20 minutes. It runs in the background while Claude works.

See [`DESIGN.md`](DESIGN.md) for the design decisions and the Codex CLI quirks behind them.

## License

MIT
