---
name: crossarch
description: Review the architecture of a whole website or app with OpenAI Codex as an independent second reviewer — both models review blind, every finding is verified against the actual code, and the result is reconciled into found-by-both, Codex-only, Claude-only, and rejected. Use when the user asks for an architecture review, a cross-model review of a site, codebase, or project (not a diff), "review the architecture of …", or types /crossarch.
---

# Cross-Model Architecture Review

`/crossreview` reviews a **diff**. This reviews a **whole system**: how a site
or app is structured, where its invariants live, and what breaks as it grows
or ships. Both models review **blind**, then you verify and reconcile.

The two failure modes this skill exists to prevent are the same as its
siblings': a single-model review presented in the shape of a two-model one, and
a confident finding about code that does not behave the way the reviewer
thinks. Every rule below serves one of those two.

## Setup

- `$SCRATCH`: the session's scratchpad directory, plus `/crossarch` (create it)
- `$TARGET`: what the user named — resolved in step 1
- `$REPO`: the directory Codex will read — resolved in step 1
- `$FOCUS`: anything the user asked to emphasise (security, scaling, data
  model, cost…), else empty

## 1. Resolve the target

| User gave | `$REPO` | Mode |
|---|---|---|
| nothing | the session's working directory | **source** |
| a local path | that path | **source** |
| a URL, and its source is on this machine (the cwd's git remote, `package.json` homepage, or the user says so) | the source directory | **source** — and also capture the URL as in the next row, as runtime evidence |
| a URL only | `$SCRATCH/site/` (built below) | **external** |

**Source mode.** Measure it before going further, and keep the numbers — step 8
reports them:

```bash
git -C "$REPO" ls-files 2>/dev/null | grep -vE '(^|/)(node_modules|dist|build|\.next|vendor)/|lock(file)?\.|\.lock$' | wc -l
```

Fall back to `find "$REPO" -type f` with the same exclusions when it is not a
git repo. Zero files means **there is nothing to review**: say which path you
checked and stop. **Do not run Codex** — an empty review renders identically
to a clean one.

**External mode.** You can only review what the site exposes. Capture it into
`$SCRATCH/site/` so both models read the same evidence:

- `headers.txt` — `curl -sSIL <url>` (redirect chain, server, caching, security headers)
- `index.html` — `curl -sSL <url>`
- `robots.txt`, `sitemap.xml` if present
- `assets.txt` — the script, stylesheet, and API URLs referenced by the HTML
- up to 3 more pages linked from the homepage that are a different page type

Use only `curl` with the user's URL and same-origin links — never submit forms,
log in, or follow links to other origins. If the fetch fails or returns a
bot-wall page, say so and stop. Tell the user up front that an external review
sees the delivery layer (hosting, rendering, caching, headers, bundle and
third-party footprint), **not** the backend, data model, or code — and that
pointing the skill at the source gives a far deeper review.

## 2. Write the brief

Write `$SCRATCH/brief.md`. It holds the review instructions and **none of your
opinions about this system** — no suspected issues, no file you think is the
problem. A brief that hints at a finding turns Codex into a confirmation
engine.

```markdown
You are reviewing the ARCHITECTURE of the system in the current directory
(<source code | a captured snapshot of the public site <URL>>). Read-only:
do not modify files, run builds, or install anything.

Ignore node_modules, build output, lockfiles and generated files.

Assess, as they apply to this system:
1. Boundaries and layering — what depends on what; where business rules live
2. Data model and integrity — where invariants are enforced and whether
   they hold under concurrency
3. Rendering, state, and caching — what is static, dynamic, cached; staleness
4. Security — authentication, authorisation, input validation at trust
   boundaries, secrets
5. Deployment topology and scaling — what the design assumes about hosting
   and what breaks first under growth
6. Reliability and operations — failure handling, observability, recovery
7. Testability and change cost — what is hard to change, and why
<Extra emphasis: $FOCUS>

Output, exactly:

## Summary
3–6 sentences: what the system is and how it is put together.

## Findings
One block per finding, most severe first:

- [P1|P2|P3] <title> — <relative/path>:<startline>-<endline>
  <The concrete input, state, or growth scenario that triggers it, and the
  wrong result it produces. A finding without a concrete failure path is an
  opinion: omit it.>

P1 = breaks correctness, security, or data integrity now; P2 = will break
under realistic use or growth; P3 = real but contained.
(External mode: cite the captured file and line, e.g. headers.txt:4-4.)

If you find nothing that meets that bar, write "No findings" and list what
you examined.
```

## 3. Launch Codex in the background — backgrounding is mandatory

A foreground run hands you Codex's full review before you have formed your own,
which defeats step 4. `codex exec` streams to stdout, and `-o` is an extra copy,
so both streams go into a log you will not open yet:

```bash
mkdir -p "$SCRATCH"
{
  ~/.claude/cross-model/codex-run.sh arch \
    --brief "$SCRATCH/brief.md" \
    --out "$SCRATCH/codex-arch.md" \
    --repo "$REPO" \
    --timeout 1200 \
    > "$SCRATCH/codex-arch.log" 2>&1
  echo $? > "$SCRATCH/codex-arch.exit"
} &
```

Use your tool's own background mode as well, if it has one. The exit code goes
to a file because a later shell cannot `wait` on this job. `--timeout 1200`
because a whole-codebase read takes longer than a diff review.

## 4. Do your own review first — this ordering is load-bearing

While Codex runs, review the same target against the same seven dimensions and
write your findings to `$SCRATCH/claude-arch.md` in the same format.

**Until `claude-arch.md` is complete on disk, do not read, display, quote, or
otherwise take in any output of the step-3 command** — not `codex-arch.md`,
not `codex-arch.log`, not a foreground tool result, not a summary of any of
them. "Complete" means the review you would hand over if Codex never answered:
every dimension considered, each finding citing a file and line range. A stub
written to unlock Codex's output is the same violation by another route.

Read the code to do this — entry points, data layer, server/API boundary,
config, and tests first. For a large codebase, dispatch an Explore subagent to
map structure, but form the findings yourself.

If Codex's output reached you early by any route, the comparison is not blind.
Say so plainly in the report, and do not label any finding "found by both".

## 5. Await the job and handle the exit code

```bash
while [ ! -f "$SCRATCH/codex-arch.exit" ]; do sleep 5; done
cat "$SCRATCH/codex-arch.exit"
```

| Code | Action |
|---|---|
| 0 | Continue to step 6 |
| 10 | Codex is not installed. **Say the cross-check did not run.** |
| 11 | Tell the user to run `codex login`. **Say the cross-check did not run.** |
| 12 | Timed out. **Say the cross-check did not complete.** |
| 13/14 | Codex failed or returned nothing. Quote the last error lines of `codex-arch.log`. **Say the cross-check did not run.** |
| 64 | The skill passed bad arguments to the runner — a bug in this skill. Report the runner's message. |

A `model … is not supported when using Codex with a ChatGPT account` error
(exit 13) almost always means the Codex CLI is older than the model set in
`~/.codex/config.toml`: `codex debug models` will not list it. Tell the user to
run `codex update`, not to change models.

**On any non-zero exit the disclosure is the FIRST thing in your response.**
Then present your own review alone, with a plain heading such as "Claude's
review (single model)". Do not use step 8's four-bucket framing — a
single-model review must never be presented in the shape of a two-model one.

## 6. Viability gate

Exit 0 means only that `codex-arch.md` is non-empty. A refusal, a quota notice,
or "I need more context" all exit 0 and contain zero findings — which would
reconcile as "Codex agreed with everything".

Require one of:

1. at least one parseable `- [P<n>] … — <path>:<start>-<end>` block, or
2. an explicit "No findings" **with** a list of what Codex examined, and a
   `## Summary` that matches the system you measured in step 1.

Anything else is a **degraded run**: handle it exactly like a non-zero exit,
and quote what Codex actually returned.

## 7. Verify every Codex finding

Open the cited file at the cited range and confirm the code does what the
finding claims. Classify each:

- **confirmed** — the failure path is real
- **rejected** — the code does not behave as claimed, the path does not exist,
  or the finding states no concrete failure path (an opinion, however
  plausible). Rejected findings stay visible with a one-line reason.
- **uncertain** — you cannot verify either way. Never upgrade to confirmed.

Re-check your own findings with the same bar — yours do not get a pass for
being yours.

Two findings are **the same** only when they name the same failure mechanism,
even if worded differently or cited at different lines. Same file, different
mechanism, is two findings.

## 8. Report (success path only)

Lead with what was reviewed: target, mode, and the file count from step 1
(external mode: the pages and files captured). Then:

1. **Architecture summary** — yours, corrected by anything Codex saw that you
   did not. A few sentences, not an essay.
2. **Found by both** — the strongest signal. Severity blocking (P1) → major
   (P2) → minor (P3), each with its failure path.
3. **Codex only (verified)** — the blind spots this skill exists to surface.
   Never drop one because it was not in your review.
4. **Claude only** — each still holding up to step 7's bar.
5. **Rejected** — one line each: what was claimed, and why it does not hold.
6. **Uncertain** — what would settle each.

When both models found nothing, say so with the target and size — that one
sentence is what separates a clean review from a non-review.

Raw outputs stay in `$SCRATCH`; nothing is committed. If the user passed
`--write`, save the report as `docs/architecture-review-<YYYY-MM-DD>.md` in the
target repo (source mode only). If they passed `--fix`, apply only confirmed
findings — never rejected or uncertain ones — and do not commit.
