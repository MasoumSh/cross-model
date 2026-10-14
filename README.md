# cross-model

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
- bash 3.2 or later (the version macOS ships works)

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
```

## Runner exit codes

The skills read these exit codes from `codex-run.sh {preflight|plan|arch|review}`:

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
