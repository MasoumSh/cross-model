# Cross-Model Consensus — Design

- **Date:** 2026-09-26
- **Status:** Implemented and live-verified. Deviations from the original
  specification are recorded in **Live-verified constraints** below.
- **Author:** Nima Eslamloo (with Claude)

## Problem

Planning and reviewing with a single model means a single set of blind spots.
A second frontier model from a different lab disagrees in useful places — but
only if it is consulted in a way that preserves its independence. Naive
"ask the other model what it thinks of my plan" produces agreement theatre:
the second model anchors on the first model's framing and confirms it.

## Goal

Two commands, usable in any repo, that bring OpenAI's Codex in as a genuine
second opinion at the two points where it pays for itself — planning and
code review — without slowing down implementation.

A third command, `/crossarch`, was added later. It applies the `/crossplan`
pattern (blind, then reconcile) to a whole-codebase architecture review, and
it runs on the plan path of the runner, because `codex exec review` can only
review a diff.

## Non-goals

- Cross-model checking during implementation. The plan already encodes the
  agreement; re-litigating each edit causes thrash.
- CI / headless operation. See Limitations.
- Replacing the existing planning systems (superpowers, gsd). This composes
  with whichever one is in use.

## Decisions

| # | Decision | Rationale |
|---|---|---|
| 1 | **Planning = independent-then-reconcile.** Both models plan blind, then diff. | Only independent generation catches a *shared* blind spot, which is the entire reason to add a second model. |
| 2 | **Review = advisory, single pass.** Codex critiques, Claude verifies and decides. | Highest signal per unit of latency. A consensus loop on review stalls on style nitpicks. |
| 3 | **Implementation = single model.** No cross-check. | Avoids thrash; agreement is already captured in the plan. |
| 4 | **Standalone commands, not plugin edits.** | superpowers and gsd are vendored under `plugins/cache/...`; edits there are clobbered on upgrade. Standalone also lets review run on any diff, including hand-written code and client PRs. |
| 5 | **Split persistence.** Raw blind plans → scratchpad. Reconciled plan → repo's existing spec convention. Review findings → chat. | Raw plans are working material whose value expires at the moment of comparison. Keeping them creates a directory of stale forks and, in client repos, a git-history transcript of AI disagreement. |
| 6 | **Codex runs in background.** | A `high`-effort planning pass takes minutes; blocking the session for it is wasteful when Claude has its own plan to write meanwhile. |

## Environment (verified 2026-09-26)

- `codex-cli 0.154.0` on `PATH`
- `codex login status` → **Logged in using ChatGPT** (subscription auth)
- No `OPENAI_API_KEY` present; none required
- `~/.codex/config.toml` pins `model = "gpt-5.6-sol"`,
  `model_reasoning_effort = "high"`

**Cost model:** no per-token billing on either side. The Claude half is this
session; the GPT half spends ChatGPT plan rate limits. The binding constraint
is rate limits, not dollars.

## Live-verified constraints

Facts about `codex-cli 0.154.0`, each established by running the real binary
(2026-09-26), each contradicting what this document originally specified. They
are recorded here because every one of them was invisible to a fully green
stubbed test suite: the fixture accepted any flag, so the suite proved only
that the runner *sent* what the design said, never that codex accepts it.

| # | Constraint | Consequence for this design |
|---|---|---|
| 1 | `codex exec review` **rejects `-s` / `--sandbox`** — `error: unexpected argument '-s' found`, exit 2. Only plain `codex exec` takes it. | The review path uses `-c sandbox_mode="read-only"` instead, which this subcommand *does* honour (live header printed `sandbox: read-only`). The Global Constraint "every invocation uses `-s read-only`" is unsatisfiable as literally written; the guarantee, not the flag, is what is universal. |
| 2 | `codex exec review` **rejects `-C` / `--cd`** — same failure shape, exit 2. It has no working-directory flag at all. | `cmd_review` runs the invocation from inside `$repo` in a subshell. Not `env -C`: that is a GNU coreutils extension and is unavailable on macOS. |
| 3 | `codex exec review` **silently ignores `--output-schema`**. The flag parses; output returns in review's own fixed prose format regardless. | The JSON schema was deleted rather than shipped inert. Findings are prose (`- [P1] <title> — <path>:<start>-<end>` plus an indented rationale), captured to `findings.txt`, parsed as text. |
| 4 | `codex exec review`'s positional `[PROMPT]` is **mutually exclusive with all three target flags** — `--uncommitted`, `--base`, `--commit` each error `cannot be used with '[PROMPT]'`. | There is no `--prompt` on the runner. Every review this tool performs names a target, so a prompt could never be sent alongside one. The findings quality bar the prompt would have carried moved into `crossreview/SKILL.md`'s verification step. |
| 5 | Plain `codex exec` parses a **leading `-` in the prompt positional as a flag** — `codex exec ... "- Requirement: ..."` dies with `error: unexpected argument '- ' found`. | `cmd_plan` passes `--` before the positional. The crossplan brief template is a markdown bullet list, so this is the common case, not an exotic one. |
| 6 | `codex exec` **streams its output to stdout**; `-o` is an additional capture, not a redirect. | Backgrounding in `crossplan` is mandatory and both streams are redirected to a log. A foreground run delivers Codex's entire plan in the tool result before Claude writes its own, breaking blindness without the captured file ever being opened. |
| 7 | Exit 0 from either path means **only that the output file is non-empty**. A refusal, a rate-limit notice, or "nothing to review" all exit 0. | Both skills carry a viability gate before the success template: plan requires recognisable plan structure, review requires a parseable `[P<n>]` block or an explicit clean-review statement. `/crossreview` additionally verifies its target is non-empty before claiming a cross-check happened. |
| 8 | There is **no `sandbox_mode` in `~/.codex/config.toml`**. | The command-line flag is the entire sandbox control on both paths. Both paths therefore carry argv regression assertions in `tests/run-tests.sh`; without them, widening the flag leaves the suite green. |

Each one is also guarded by an assertion in `tests/run-tests.sh`, and
`tests/fixtures/codex` models the real CLI's flag parsing so a regression
fails the stubbed suite rather than only a live run.

## File layout

```
cross-model/                     this repo
├── README.md
├── DESIGN.md                    (this file)
├── install.sh                   copies the runner and skills into ~/.claude
├── codex-run.sh                 shared runner
├── skills/
│   ├── crossarch/SKILL.md       whole-codebase architecture review
│   ├── crossplan/SKILL.md       blind dual planning
│   └── crossreview/SKILL.md     diff review
└── tests/
    ├── run-tests.sh             stubbed suite
    ├── fixtures/codex           fake codex CLI
    └── smoke.md                 live-run results
```

Installed layout (what `install.sh` produces):

```
~/.claude/cross-model/codex-run.sh       the skills call it at this path
~/.claude/skills/<name>/SKILL.md         loaded by Claude Code
```

The skills hardcode `~/.claude/cross-model/codex-run.sh`, so the runner lives
in one place rather than being duplicated into each skill.

There is no `schemas/` directory. One was specified and built, then deleted —
see **Live-verified constraints** above.

## Component: `codex-run.sh`

Single entry point both skills call. Responsibilities:

1. Preflight — `codex` on PATH, `codex login status` reports logged in.
   On failure, exit non-zero with a machine-readable reason.
2. Invoke `codex exec` (plan) or `codex exec review` (review). The two
   subcommands accept **different** flag sets, so the invocations differ —
   see **Live-verified constraints** for why each difference exists.

   Both paths:
   - `--ephemeral` — no session files persisted
   - `-o <file>` — capture the final message

   Plan path (`codex exec`):
   - `-s read-only` — Codex reads the repo, never writes to it
   - `-C <repo>` — explicit working root
   - `--` before the prompt positional, so a brief opening with a markdown
     bullet is not parsed as a flag

   Review path (`codex exec review`):
   - `-c sandbox_mode="read-only"` — the same guarantee; this subcommand
     rejects `-s`
   - run from inside `<repo>` via a subshell `cd`; this subcommand has no
     `-C`/`--cd`
   - one of `--uncommitted` / `--base <branch>` / `--commit <sha>`, and **no**
     prompt positional, which is mutually exclusive with all three
3. Enforce a **10-minute timeout**. On expiry, kill and exit non-zero.
4. Never inherit the model from a hardcoded flag; let `~/.codex/config.toml`
   supply it so the pinned model can change without editing this tool.

## Component: `/crossplan`

Sequence, in strict order. Step 3 before step 4 is load-bearing:

1. **Capture** the task from the command argument or the conversation.
2. **Write a neutral brief** to the scratchpad: requirement, constraints,
   repo path, acceptance criteria. Explicitly excludes any approach, file
   list, or design Claude has already formed. This is the *only* input Codex
   receives.
3. **Launch Codex in background** against the brief.
4. **Claude writes its own plan** to `<scratch>/claude-plan.md`, complete, and
   commits it to disk **before taking in any output of the step-3 command** —
   the captured file, the streamed stdout/stderr log, and the tool result
   alike. `codex exec` streams to stdout, so a foreground run leaks the whole
   plan without the captured file ever being opened. Without this ordering,
   Claude anchors on Codex's plan and the result is one opinion wearing two
   hats.
5. **Gate on output viability.** Exit 0 only means the file is non-empty.
   Require recognisable plan structure; a refusal or a short "I need more
   context" reply otherwise reconciles as agreement by silence.
6. **Reconcile** into three buckets:
   - **Agreed** — summarized briefly.
   - **Material disagreement** — both positions stated fairly, plus Claude's
     recommendation. User decides.
   - **Unique to one model** — steps only one model produced. This is the
     payload: a step only Codex thought of is the blind spot being bought.
7. **Write the reconciled plan** to the repo's existing convention, in order
   of preference: `docs/superpowers/specs/` → `docs/plans/` → ask the user.
   Output is an ordinary plan file consumable by `/gsd:execute-plan` or
   superpowers' executing-plans.

### Optional flag: `--blind-claude` (default: off)

Spawns a fresh Claude subagent to produce the Claude-side plan from the same
neutral brief, rather than using the main session.

Rationale: Codex gets a clean process seeing only the brief, but the main
session carries the whole conversation — so Claude's plan is blind *to Codex*
but not blind in the way Codex's is. Usually that asymmetry is fine or
beneficial (the session has real context). It hurts when the conversation
already contains a half-formed approach worth anchoring on. Default off
because it costs an extra agent and most tasks don't need it.

## Component: `/crossreview`

1. **Determine target:** `--uncommitted` (default), `--base <branch>`,
   or `--commit <sha>`.
2. **Confirm the target contains changes** before invoking anything. A clean
   working tree with the default `uncommitted` target must be reported as
   "nothing to review", never as a clean review.
3. **Invoke** `codex exec review` with the target,
   `-c sandbox_mode="read-only"`, `--ephemeral`, `-o <scratch>/findings.txt`.
   Uses Codex's purpose-built review subcommand rather than a hand-rolled
   review prompt. Output is prose, not JSON — the file is `.txt`.
4. **Gate on output viability.** Exit 0 only means the file is non-empty.
   Require a parseable `[P<n>]` finding block, or an explicit statement that
   the diff was reviewed and found clean. Anything else is a degraded run and
   takes the disclosure-first template.
5. **Verify every finding against the actual code before surfacing it.**
   Codex produces confident findings about code that does not do what it
   thinks. Each finding is classified: confirmed / rejected / uncertain.
   A finding with no concrete failure path is rejected as a style opinion —
   this bar lives in the skill because it could not be put in a prompt.
6. **Report:** confirmed findings ranked by severity, followed by an explicit
   list of what was rejected and why — so the filtering is visible rather
   than silent. A genuine zero-findings result must name the target it
   reviewed, so it cannot be read as either of the two non-reviews above.
7. **`--fix`** applies confirmed findings to the working tree.

## Schemas — none (specified, built, then deleted)

This design originally gave the review path a JSON schema,
`schemas/review-findings.json`, constraining Codex's response to an array of
`{ file, line, severity, category, claim, why_it_breaks }` with
`why_it_breaks` required, so that style opinions dressed as bugs would be
suppressed at the source.

`codex exec review` **silently ignores `--output-schema`**. The flag parses;
the output comes back in review's own fixed prose format regardless (confirmed
live — see **Live-verified constraints**). The schema file was deleted rather
than left in the tree to mislead the next reader, and the requirement it
carried — every finding must state a concrete failure path — now lives in
`crossreview/SKILL.md`'s verification step, enforced by Claude reading the
actual code rather than requested of Codex and hoped for.

A plan is prose and was never schema-constrained: forcing it into JSON would
flatten exactly the reasoning the comparison depends on.

## Failure handling

The failure mode being designed against is a **silent fallback that leaves the
user believing two models agreed when only one ran.**

| Condition | Behavior |
|---|---|
| `codex` not on PATH | Report, proceed Claude-only, state it prominently |
| Not logged in | Report with the `codex login` remedy, proceed Claude-only |
| Timeout (10 min) | Kill, proceed Claude-only, state that the cross-check did not complete |
| Malformed/unparseable output | The viability gate in each skill. Exit 0 plus a non-empty file is not a result: plan requires recognisable plan structure, review requires a `[P<n>]` block or an explicit clean-review statement. Anything else is a degraded run and takes the disclosure-first template. |
| Non-zero exit, any cause | Never block the work; never imply agreement |
| Target contains no changes | `/crossreview` checks before invoking. Report "nothing to review" naming the target; never report it as a clean review. |
| Codex ran and genuinely found nothing | A real result, reported with the target named, so it cannot be confused with either row above. |

Every degraded path states, in the final response, that the cross-check did
not happen. A cross-check that failed must never read like a cross-check that
passed.

## Testing

1. **Review catches a real bug.** Plant a known defect on a scratch branch;
   confirm `/crossreview` surfaces it at appropriate severity.
2. **Review's verification layer works.** Confirm that a Codex finding about
   code that does not behave as claimed is rejected, with the rejection shown.
3. **Planning surfaces divergence.** Give `/crossplan` a deliberately
   underspecified task; confirm it reports disagreement rather than false
   consensus.
4. **Blindness holds.** Inspect the neutral brief; confirm it contains no
   trace of Claude's approach.
5. **Sandbox holds.** Instruct Codex to write a file; confirm the sandbox
   blocks it (`-s read-only` on the plan path, `-c sandbox_mode="read-only"`
   on the review path). Both paths also carry argv assertions in the stubbed
   suite, so a widened flag fails the suite rather than only a live run.
6. **Degraded paths are loud.** Simulate each failure row above; confirm the
   final response states the cross-check did not happen.

## Fork additions (Windows support, Grok backend)

### Windows (Git Bash) constraints, verified 2026-10-16 on codex-cli 0.163.0

| # | Constraint | Consequence |
|---|---|---|
| W1 | With `set -m`, a backgrounded command keeps the caller's stdin. `codex exec` then prints "Reading additional input from stdin..." and blocks until the watchdog fires. | `run_with_timeout` starts the command with `< /dev/null`. |
| W2 | GNU `mktemp` (Git Bash) rejects `mktemp -t crossmodel` ("too few X's"). The sentinel path came back empty, so a timeout surfaced as exit 13 instead of 12. | Explicit template: `mktemp "${TMPDIR:-/tmp}/crossmodel.XXXXXX"`. |
| W3 | A TERM sent to the watchdog subshell can be lost when it lands mid-fork. A single `sleep $secs` then held the caller in `wait` for the full timeout whenever the command finished almost instantly (the stubbed suite hung). | The watchdog sleeps in 1-second steps and exits as soon as the command is gone, so a lost signal costs at most a second. |

### Grok backend for `/crossreview`

| Decision | Rationale |
|---|---|
| Call xAI's Responses API, not xAI's Grok Build CLI. | Grok Build's read-only sandbox uses Landlock (Linux) and Seatbelt (macOS); there is none on Windows. An API call with no tools cannot touch the filesystem at all, so the read-only guarantee holds by construction. |
| Send the diff with 15 lines of context. | Grok cannot open files, so it gets more surrounding code than git's default 3 lines. Its findings about code outside the diff are treated as guesses until Claude checks them. |
| Same targets, output format and exit-code contract as `review`. | The skill parses one finding format and one exit-code table for both reviewers. `parse_review_args` is shared so both validate arguments identically. |
| 200 KB diff cap and a per-run cost line. | Grok bills per token, unlike Codex on a ChatGPT plan; an accidental whole-repo diff must not become a surprise bill. |
| Node.js for the HTTP call. | No `jq` dependency for JSON, built-in `fetch` and timeouts. |

## Limitations

- **Interactive sessions only.** The Claude half is a human-invoked Claude
  Code session, not a callable endpoint. This cannot run in CI, as a git hook,
  or from a webhook. An automated per-PR version would require real API access
  on both sides and real per-token cost.
- **Rate limits are the ceiling.** `high` reasoning effort consumes ChatGPT
  plan limits; exhausting them mid-session degrades this to Claude-only
  exactly when work is deepest.
- **Latency.** A blind planning pass over a large repo may run
  5–10 minutes. Mitigated by background execution, but `/crossplan` is for
  consequential work, not every small change.
