---
name: crossreview
description: Review the current changes with OpenAI Codex, xAI Grok, or both as independent second reviewers, verify their findings against the actual code, and report what was confirmed and what was rejected. Use when the user asks for a cross-model review, a second opinion on a diff, a review "with Grok" or "with both", or types /crossreview (optionally with --with codex|grok|codex,grok).
---

# Cross-Model Code Review

The selected reviewers (Codex, Grok, or both) review the diff; you verify every
finding before showing it. They are second opinions, not the verdict.

**Scope:** this skill reviews a **diff** (uncommitted changes, a branch, or a
commit). If the user asks to review the architecture of a whole site, app, or
codebase, or gives a URL, use `/crossarch` instead — `codex exec review` cannot
review anything but a diff.

## Setup

- `$REPO`: the root directory of the repository being reviewed
- `$SCRATCH`: the session's scratchpad directory (create if needed)
- `$REVIEWERS`: resolved in step 0

## 0. Pick the reviewers

| User passed | `$REVIEWERS` |
|---|---|
| nothing, or `--with codex` | `codex` |
| `--with grok` | `grok` |
| `--with codex,grok`, `--with both`, `--with all` | `codex grok` |

Natural phrasing counts too: "review this with Grok" is `grok`, "ask both" is
`codex grok`. You always review and verify; `$REVIEWERS` only decides who
else does.

The backends differ in ways the user should know about:

- **Codex** explores the repo itself in a read-only sandbox. Its cost is the
  user's ChatGPT plan rate limits.
- **Grok** receives only the diff as text (with 15 lines of context) through
  xAI's API. It has no file or tool access at all, so it cannot write
  anything, but it also cannot look past the diff. It needs `XAI_API_KEY` in
  the environment and **is billed per token** to the user's xAI account.

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

Before running any reviewer, measure the target. Each command below is chosen to
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
| `rc` non-zero | The target does not resolve — a bad branch name or sha, not an empty diff. Report the target and git's error. **Do not run any reviewer.** |
| `rc` 0, `stat` empty, `untracked` non-empty | The only changes are **untracked files**, which `codex exec review --uncommitted` cannot see. Say so explicitly, list them, and tell the user to `git add` them first. **Do not run any reviewer**: a review here would silently see nothing (the Grok backend sends the same diff, so it is blind to untracked files too). |
| `rc` 0, `stat` empty | **Nothing to review.** Name the target you checked and offer one that does have changes (`commit:$(git -C "$REPO" rev-parse HEAD)`, or `base:<branch>`). **Do not run any reviewer.** |
| `rc` 0, `stat` non-empty | Proceed. **Keep `stat`** — its last line is the files-and-lines figure step 7 requires. |

Never let any of the first three be reported as a clean review. Codex handed an
empty diff returns a short prose note, exits 0, and yields zero findings —
which renders identically to "two models reviewed this and found nothing."
That is a false clean bill of health, and the user cannot tell the difference.
The untracked-only case is the one to watch: a new file that has not been
`git add`ed yet is an ordinary, frequent state, not an edge case.

## 3. Run the reviewers in the background

Launch one job per reviewer in `$REVIEWERS`, all before you start reading the
diff yourself. Each writes to its own files, so they never see each other's
output. Run each in the background (the trailing `&`, plus your tool's own
background mode if it has one).

Codex (`codex` in `$REVIEWERS`):

```bash
mkdir -p "$SCRATCH"
{
  ~/.claude/cross-model/codex-run.sh review \
    --out "$SCRATCH/findings-codex.txt" \
    --repo "$REPO" \
    --target "$TARGET" \
    > "$SCRATCH/codex-review.log" 2>&1
  echo $? > "$SCRATCH/codex-review.exit"
} &
```

Grok (`grok` in `$REVIEWERS`):

```bash
mkdir -p "$SCRATCH"
{
  ~/.claude/cross-model/codex-run.sh grok-review \
    --out "$SCRATCH/findings-grok.txt" \
    --repo "$REPO" \
    --target "$TARGET" \
    > "$SCRATCH/grok-review.log" 2>&1
  echo $? > "$SCRATCH/grok-review.exit"
} &
```

Read the current diff yourself while they work. A `high`-effort Codex review
takes minutes; Grok usually returns within one or two. The exit codes go to
files because each shell invocation is a separate process: a later `wait`
cannot see these jobs.

## 4. Await every job and handle each exit code

For each reviewer in `$REVIEWERS` (`<r>` is `codex` or `grok`):

```bash
while [ ! -f "$SCRATCH/<r>-review.exit" ]; do sleep 5; done
cat "$SCRATCH/<r>-review.exit"
```

| Code | Codex | Grok |
|---|---|---|
| 0 | Continue to step 5 | Continue to step 5 |
| 10 | codex is not installed | Node.js or `grok-review.mjs` is missing (tell the user to re-run `install.sh`) |
| 11 | Tell the user to run `codex login` | `XAI_API_KEY` is not set or xAI rejected it. Tell the user to set it themselves; never ask them to paste the key into the chat |
| 12 | Timed out | Timed out |
| 13 | Codex failed. Quote the last error lines of its log | API error, or the diff exceeded the cost cap. Quote the `cross-model:` line from `grok-review.log` |
| 14 | Codex returned nothing | Grok returned nothing |
| 64 | Skill passed bad arguments to the runner: a bug in this skill. Report the runner's message | Same |

A reviewer with any non-zero exit **did not review**. Do not proceed as if it
had.

**Disclosure rule.** Every reviewer that did not produce a usable review (a
non-zero exit here, or a degraded run in step 5) is named in **the FIRST lines
of your response**, with the reason, not in a footnote. Then:

- **No selected reviewer succeeded:** the success-path template is
  **REPLACED** entirely. Present your review alone, plainly labelled as a
  single-model review. A single-model review must never be presented in the
  shape of a cross-model result.
- **Some succeeded:** use the success-path template, but only with the
  reviewers that actually ran, and say which those are. Never let a failed
  reviewer's silence read as agreement.

## 5. Check that the output is actually a review (viability gate)

Do this separately for each reviewer that exited 0.

Exit 0 means only that `findings-<r>.txt` is **non-empty**. It does not mean a
review happened. A rate-limit message, a refusal, a request for more context,
or a one-line "there is nothing to review here" all exit 0 with a non-empty
file — and all of them produce zero `[P<n>]` blocks, which the step-7 template
would render as "Confirmed: none. Rejected: none." That reads as *the reviewer
looked at this diff and found nothing*, when it reviewed nothing at all.

Open `findings-<r>.txt` and require **one** of the following:

1. at least one parseable `[P<n>]` finding block (see step 6), **or**
2. an explicit statement that the diff **was reviewed and found clean** —
   admissible **only** if step 2 measured the target as non-empty and you
   still hold that non-empty `stat`. "Nothing to review here" and "the diff
   is clean" are the same sentence from a reviewer when the diff was zero lines,
   so a clean-review claim is not evidence of a review; the step-2
   measurement is. Without it, this option does not apply and the run is
   degraded.

Anything else is a **degraded run** for that reviewer. Handle it exactly like
a non-zero exit under step 4's disclosure rule: name it first, quote verbatim
what it actually returned, and leave it out of the success-path template.

## 6. Verify every finding (success path only)

The findings files are **not JSON**. Both backends return the same prose
format, one finding per block (`codex exec review` ignores structured output
requests; the Grok backend is instructed to match this shape):

```
- [P1] <title> — <path>:<startline>-<endline>
  <indented rationale paragraph: the concrete input/state that triggers it
  and the wrong result it produces>
```

Codex cites absolute paths. Grok cites paths as they appear in the diff
headers, relative to `$REPO`. Read each file as text and parse that shape.
Map the priority to this skill's severity language:

| Reviewer | Treat as |
|---|---|
| P1 | blocking |
| P2 | major |
| P3 | minor |

For each finding, **open the cited file at the given path and line range and
confirm the code does what the finding claims**. Both reviewers produce
confident findings about code that does not behave the way they think. Grok
is more exposed to this: it saw only the diff, so a finding that depends on
code outside it (a caller, a type, a config) is a guess until you check it.

**Merge duplicates before reporting.** Two findings are the same only when
they name the same failure mechanism, even if worded differently or cited at
different lines. Same file, different mechanism, is two findings. Keep track
of who raised each one: Codex, Grok, or both.

**A finding that does not state a concrete failure path — the input or state
that triggers it and the wrong result it produces — is REJECTED as a style
opinion**, regardless of whether the underlying code point is real, and goes
in the Rejected list with that reason. (`codex exec review`'s [PROMPT]
argument, which would have carried this requirement, cannot be combined with
`--uncommitted`/`--base`/`--commit` — confirmed live — so this bar is
enforced here, by you reading the actual code, rather than requested of
Codex. The Grok backend does ask for it, but asking is not enforcing: apply
the same bar to Grok.)

Classify each: **confirmed** / **rejected** / **uncertain**. A finding you
cannot verify either way is uncertain, not confirmed.

## 7. Report (success path only)

Open with one line naming the reviewers that actually ran, e.g. "Reviewed by
Claude + Codex + Grok".

- Confirmed findings, ordered blocking → major → minor, each with the concrete
  failure path and a source tag: `[Codex]`, `[Grok]`, or `[Codex + Grok]`.
  When both external reviewers ran, a finding both raised is the strongest
  signal; say so.
- Then an explicit **Rejected** list with one line per finding on why it does
  not hold, tagged the same way. The filtering must be visible, not silent.
- Then your own findings, if the reviewers missed something you caught.
- If Grok ran, end with its cost: the `grok usage:` line from
  `grok-review.log` (tokens and an approximate dollar figure). Grok is billed
  per token, so the user should always see what a run cost.

### When a reviewer genuinely found nothing

This is a real outcome and it has its own wording, because the bare string
"Confirmed: none. Rejected: none." is identical to what a non-review produces.
State what was actually reviewed: the target, and its size — the last line of
the `stat` you kept in step 2, e.g. `3 files changed, 47 insertions(+)` — plus
which reviewer returned no findings on it. Then
give your own findings as usual. Never report zero findings without naming the
target that was reviewed — that is the one sentence that distinguishes this
case from step 2's empty target and step 5's degraded run.

## 8. `--fix`

Only if the user passed `--fix`: apply the confirmed findings to the working
tree. Never apply rejected or uncertain ones. Do not commit.
