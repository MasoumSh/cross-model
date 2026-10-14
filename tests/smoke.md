# Live smoke test results

Run by the controller against the real `codex` CLI (v0.154.0, gpt-5.6-sol, ChatGPT auth).
Date: 2026-09-26.

| # | Check | Result |
|---|---|---|
| 1 | `-s read-only` blocks writes on the plan path | **PASS** |
| 2 | Review catches a planted bug | **PASS** (after 3 fixes) |
| 3 | Verification layer rejects a bad finding | see note |
| 4 | Planning surfaces divergence | not run — see note |
| 5 | Blindness: brief contains no Claude approach | enforced in skill text |
| 6 | Degraded paths are loud | **PASS** |
| 7 | `--repo` honoured from a foreign cwd | **PASS** |

## 1. Sandbox gate — PASS

Instructed Codex to create `proof.txt` and append to `existing.txt` in a throwaway repo.
Header reported `sandbox: read-only`. Codex attempted the write and was refused:

    ERROR codex_core::tools::router: error=patch rejected:
          writing is blocked by read-only sandbox

Independent filesystem check afterwards: `proof.txt` absent, `existing.txt` unchanged
(`hello`), `git status` clean. `-o` capture produced 211 bytes.

## 2. Review catches a planted bug — PASS, after three live-only defects

Planted an off-by-one (`range(len(prices) - 1)` omitting the final element) and an
average-vs-total error with a `ZeroDivisionError` on empty input. Final run: exit 0,
`sandbox: read-only`, both bugs found at **P1**, each with a concrete failure path.

Three defects were found here that the 29-assertion stubbed suite could not see, because
`tests/fixtures/codex` accepted any flag:

1. `codex exec review` does not accept `-s`/`--sandbox`. Replaced with
   `-c sandbox_mode="read-only"`, verified live.
2. `codex exec review` does not accept `-C`/`--cd`. Replaced with a subshell `cd`.
3. All three target flags are mutually exclusive with a positional prompt:
   `--uncommitted`/`--base`/`--commit` + PROMPT each error out. `--prompt` was removed
   from the runner entirely and the findings quality bar moved into the skill's
   verification step.

The fixture now encodes review's full accepted-flag set AND the target/prompt conflict,
so this class of defect cannot hide again.

## 3-4. Notes

Step 3 (verification layer rejects a bad finding) and step 4 (planning surfaces divergence)
are skill-level behaviours that require a `/crossreview` and `/crossplan` invocation inside
a Claude Code session rather than a runner call. The runner-level plumbing both depend on is
verified above. They are the natural first real use of the tool.

## 6. Degraded paths — PASS

    codex absent   -> exit 10
    bad --repo     -> exit 64
    bad target     -> exit 64
    --prompt (removed) -> exit 64

## 7. `--repo` from a foreign cwd — PASS

Invoked from `$HOME` targeting `/tmp/xm-sandbox`; header reported
`workdir: /private/tmp/xm-sandbox`. The subshell `cd` replacing `-C` works.

## Output format

`codex exec review` returns PROSE, not JSON, even when `--output-schema` is passed
(the flag parses but does not constrain output). Findings look like:

    - [P1] <title> — <absolute-path>:<start>-<end>
      <indented rationale with a concrete failure path>

The JSON schema was deleted rather than left in the tree to mislead the next reader.
