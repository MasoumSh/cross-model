---
name: crossreview
description: Review the current changes with OpenAI Codex as an independent second reviewer, verify its findings against the actual code, and report what was confirmed and what was rejected. Use when the user asks for a cross-model review, a second opinion on a diff, or types /crossreview.
---

# Cross-Model Code Review

Codex reviews the diff; you verify every finding before showing it. Codex is
the second opinion, not the verdict.

**Scope:** this skill reviews a **diff** (uncommitted changes, a branch, or a
commit). If the user asks to review the architecture of a whole site, app, or
codebase, or gives a URL, use `/crossarch` instead — `codex exec review` cannot
review anything but a diff.

## Setup

- `$REPO`: the root directory of the repository being reviewed
- `$SCRATCH`: the session's scratchpad directory (create if needed)

## 1. Pick the target

- Default: `uncommitted`
- User named a branch: `base:<branch>`
- User named a commit: `commit:<sha>`

**Important:** The value after `base:` or `commit:` may contain only letters,
digits, `.`, `_`, `/`, `-`, and may not start with a dash. Note what this
restriction is and is not: it is **not** what prevents Codex writing to the
repo. The sandbox on this path is `-c sandbox_mode="read-only"` (`codex exec
review` rejects `-s`), and the runner builds codex's argv as an indexed array,
so the target value cannot split into extra flags whatever it contains. The
restriction stays for two other reasons: DESIGN.md specifies a **resolved SHA**
rather than a revision expression, so shapes like `HEAD~1` are out of contract
anyway; and defence in depth is cheap at the one point where a user-supplied
string enters a command line. To target a relative revision, resolve it first:
`commit:$(git rev-parse HEAD~1)`.

## 2. Confirm the target actually contains changes

Before running Codex, measure the target. Each command below is chosen to
return **exactly what `codex exec review` will see** — the obvious command is
wrong in all three cases, each in a way that lets an empty diff through:

```bash
rc=0; stat=""; untracked=""
case "$TARGET" in
  uncommitted)
    # `git diff HEAD --stat`, NOT `git status --porcelain`. Untracked files
    # are invisible to `codex exec review --uncommitted`, but porcelain
    # reports them, so a tree whose only change is a new unstaged file looks
    # non-empty here while codex receives nothing.
    stat=$(git -C "$REPO" diff HEAD --stat); rc=$?
    untracked=$(git -C "$REPO" ls-files --others --exclude-standard)
    ;;
  base:*)
    stat=$(git -C "$REPO" diff --stat "${TARGET#base:}"...HEAD 2>/dev/null); rc=$?
    ;;
  commit:*)
    # `--format=` suppresses the commit header. With `--oneline` an EMPTY
    # commit still prints "<sha> <subject>" — 21 bytes of non-content — so an
    # emptiness test on that output can never fire.
    stat=$(git -C "$REPO" show --stat --format= "${TARGET#commit:}" 2>/dev/null); rc=$?
    ;;
esac
```

Then branch on all four outcomes. **Check `rc` before emptiness** — an
unresolvable target also produces empty stdout (`git diff --stat
<bad-branch>...HEAD` exits 128 and prints nothing), and reporting that as
"nothing to review" tells the user their diff is clean when in fact you never
looked at it:

| Outcome | Action |
|---|---|
| `rc` non-zero | The target does not resolve — a bad branch name or sha, not an empty diff. Report the target and git's error. **Do not run Codex.** |
| `rc` 0, `stat` empty, `untracked` non-empty | The only changes are **untracked files**, which `codex exec review --uncommitted` cannot see. Say so explicitly, list them, and tell the user to `git add` them first. **Do not run Codex** — a review here would silently see nothing. |
| `rc` 0, `stat` empty | **Nothing to review.** Name the target you checked and offer one that does have changes (`commit:$(git -C "$REPO" rev-parse HEAD)`, or `base:<branch>`). **Do not run Codex.** |
| `rc` 0, `stat` non-empty | Proceed. **Keep `stat`** — its last line is the files-and-lines figure step 7 requires. |

Never let any of the first three be reported as a clean review. Codex handed an
empty diff returns a short prose note, exits 0, and yields zero findings —
which renders identically to "two models reviewed this and found nothing."
That is a false clean bill of health, and the user cannot tell the difference.
The untracked-only case is the one to watch: a new file that has not been
`git add`ed yet is an ordinary, frequent state, not an edge case.

## 3. Run Codex in the background

```bash
mkdir -p "$SCRATCH"
{
  ~/.claude/cross-model/codex-run.sh review \
    --out "$SCRATCH/findings.txt" \
    --repo "$REPO" \
    --target "$TARGET" \
    > "$SCRATCH/codex-review.log" 2>&1
  echo $? > "$SCRATCH/codex-review.exit"
} &
```

Run it in the background and read the current diff yourself while it works.
A `high`-effort review takes minutes. The exit code goes to a file because each
shell invocation is a separate process: a later `wait` cannot see this job.

## 4. Await the job and handle the exit code

```bash
while [ ! -f "$SCRATCH/codex-review.exit" ]; do sleep 5; done
cat "$SCRATCH/codex-review.exit"
```

| Code | Action |
|---|---|
| 0 | Continue to step 5 |
| 10 | Tell the user codex is not installed. Review alone. **Say the cross-check did not run.** |
| 11 | Tell the user to run `codex login`. Review alone. **Say the cross-check did not run.** |
| 12 | Timed out. Review alone. **Say the cross-check did not complete.** |
| 13/14 | Codex failed or returned nothing. Review alone. **Say the cross-check did not run.** |
| 64 | Skill passed bad arguments to the runner (a bug in the skill itself, not a codex failure). Report the error message from the runner's stderr. **Do not proceed as if cross-check succeeded.** |

**On any non-zero exit (10, 11, 12, 13, 14, 64):** The disclosure that the
cross-check failed must be **the FIRST thing in your response**, not a footnote.
The success-path template (Confirmed / Rejected / your findings) is **REPLACED**
entirely — do not use that framing when Codex never ran. A single-model review
must never be presented in the shape of a two-model result. Never let a Codex
failure read like success.

## 5. Check that the output is actually a review (viability gate)

Exit 0 means only that `findings.txt` is **non-empty**. It does not mean a
review happened. A rate-limit message, a refusal, a request for more context,
or a one-line "there is nothing to review here" all exit 0 with a non-empty
file — and all of them produce zero `[P<n>]` blocks, which the step-7 template
would render as "Confirmed: none. Rejected: none." That reads as *Codex
reviewed this diff and found nothing*, when Codex reviewed nothing at all.

Open `findings.txt` and require **one** of the following:

1. at least one parseable `[P<n>]` finding block (see step 6), **or**
2. an explicit statement that the diff **was reviewed and found clean** —
   admissible **only** if step 2 measured the target as non-empty and you
   still hold that non-empty `stat`. "Nothing to review here" and "the diff
   is clean" are the same sentence from Codex when the diff was zero lines,
   so a clean-review claim is not evidence of a review; the step-2
   measurement is. Without it, this option does not apply and the run is
   degraded.

Anything else is a **degraded run**. Handle it exactly like a non-zero exit:
disclosure first, quote verbatim what Codex actually returned, review alone,
and do not use the Confirmed / Rejected framing.

## 6. Verify every finding (success path only)

`findings.txt` is **not JSON** — `codex exec review` ignores structured
output requests and always returns its own fixed prose format, one finding
per block:

```
- [P1] <title> — <absolute-path>:<startline>-<endline>
  <indented rationale paragraph: the concrete input/state that triggers it
  and the wrong result it produces>
```

Read the file as text and parse that shape. Map Codex's priority to this
skill's severity language:

| Codex | Treat as |
|---|---|
| P1 | blocking |
| P2 | major |
| P3 | minor |

For each finding, **open the cited file at the given path and line range and
confirm the code does what the finding claims**. Codex produces confident
findings about code that does not behave the way it thinks.

**A finding that does not state a concrete failure path — the input or state
that triggers it and the wrong result it produces — is REJECTED as a style
opinion**, regardless of whether the underlying code point is real, and goes
in the Rejected list with that reason. (`codex exec review`'s [PROMPT]
argument, which would have carried this requirement, cannot be combined with
`--uncommitted`/`--base`/`--commit` — confirmed live — so this bar is
enforced here, by you reading the actual code, rather than requested of
Codex.)

Classify each: **confirmed** / **rejected** / **uncertain**. A finding you
cannot verify either way is uncertain, not confirmed.

## 7. Report (success path only)

- Confirmed findings, ordered blocking → major → minor, each with the concrete
  failure path.
- Then an explicit **Rejected** list with one line per finding on why it does
  not hold. The filtering must be visible, not silent.
- Then your own findings, if Codex missed something you caught.

### When Codex genuinely found nothing

This is a real outcome and it has its own wording, because the bare string
"Confirmed: none. Rejected: none." is identical to what a non-review produces.
State what was actually reviewed: the target, and its size — the last line of
the `stat` you kept in step 2, e.g. `3 files changed, 47 insertions(+)` — plus
the fact that Codex returned no findings on it. Then
give your own findings as usual. Never report zero findings without naming the
target that was reviewed — that is the one sentence that distinguishes this
case from step 2's empty target and step 5's degraded run.

## 8. `--fix`

Only if the user passed `--fix`: apply the confirmed findings to the working
tree. Never apply rejected or uncertain ones. Do not commit.
