---
name: crossplan
description: Plan a feature with OpenAI Codex as an independent second planner — both models plan blind, then the plans are reconciled into agreed, disputed, and unique-to-one buckets. Use when the user asks for a cross-model plan, a second opinion on an approach, or types /crossplan.
---

# Cross-Model Planning

Both models plan **blind**, then the plans are compared. The value is entirely
in the independence — if Codex sees your approach, it confirms it, and you have
bought nothing.

## Setup

- `$REPO`: the root directory of the repository being planned
- `$SCRATCH`: the session's scratchpad directory (create if needed)

## 1. Write a neutral brief

Write `$SCRATCH/brief.md` containing only:

- the requirement, in the user's terms
- constraints (stack, compatibility, deadlines)
- the repo path
- acceptance criteria

It must contain **no approach, no file list, no design of yours**. Before
continuing, re-read it and ask: could a reader infer how I would build this?
If yes, rewrite it.

## 2. Launch Codex — backgrounding is mandatory, not stylistic

Run the command **in the background**: the trailing `&` below, plus your tool's
own background mode if it has one. Do not run it in the foreground.

A foreground run blocks until Codex finishes and then hands you its entire plan
in the tool result, before you have written a line of your own. That defeats
step 3 exactly as thoroughly as opening the file would, and it does so without
ever touching the filename the old rule named. `codex exec` **streams its plan
to stdout**; `-o` is an additional capture, not a redirect. So both streams are
redirected here into a log you will not open:

```bash
mkdir -p "$SCRATCH"
{
  ~/.claude/cross-model/codex-run.sh plan \
    --brief "$SCRATCH/brief.md" \
    --out "$SCRATCH/codex-plan.md" \
    --repo "$REPO" \
    > "$SCRATCH/codex-plan.log" 2>&1
  echo $? > "$SCRATCH/codex-plan.exit"
} &
```

The exit code is written to a file because each shell invocation is a separate
process: a later `wait` cannot see this job. Step 4 reads that file.

## 3. Write your own plan first — this ordering is load-bearing

While Codex runs, write your plan to `$SCRATCH/claude-plan.md`.

**Until `claude-plan.md` is complete on disk, do not read, display, quote, or
otherwise take in ANY output of the step-2 command.** The prohibition is on the
command's output as a whole, not on one filename:

- `$SCRATCH/codex-plan.md` — the captured final message
- `$SCRATCH/codex-plan.log` — the streamed stdout and stderr
- the tool result of the command itself, if it ran in the foreground
- any excerpt, summary, or paraphrase of the above, from any source

If Codex's output has reached you by any of those routes before your plan is
written, the blind comparison did not happen. Say so plainly in your response
instead of presenting buckets. A reconciliation you know to be anchored, but
report as independent, is precisely the agreement theatre this command exists
to prevent — and the user has no way to detect it from the outside.

**"Written to disk" means complete, not started.** `claude-plan.md` satisfies
this step only when it is the plan you would hand to an implementer with no
further input from you: every acceptance criterion in the brief addressed,
concrete steps naming the files or components each one touches, an ordering,
and the risks you see. A three-line stub, a list of headings, or a placeholder
does not count — and writing one in order to unlock reading Codex's plan is the
same violation by a different route.

### Optional `--blind-claude`

Only if the user passed it: dispatch a fresh subagent with **only** `brief.md`
to produce `claude-plan.md`. Use when this conversation already contains a
half-formed approach worth anchoring on. Off by default — it costs an extra
agent and most tasks do not need it.

This flag blinds the subagent, not you. The rule above still binds the **main
session**: if you have taken in any step-2 output before the subagent's plan is
on disk, the reconciliation is anchored regardless of how blind the drafting
agent was, because you are the one who reconciles. Disclose it the same way.

## 4. Await the job, then read its exit code

Only after step 3 is complete. Block until the job has finished — an absent or
still-empty output file is not evidence of anything until then — and read the
code it recorded:

```bash
while [ ! -f "$SCRATCH/codex-plan.exit" ]; do sleep 5; done
cat "$SCRATCH/codex-plan.exit"
```

| Code | Action |
|---|---|
| 0 | Continue to step 5 |
| 10/11/13/14 | Present your plan alone. **State plainly that no second model ran.** |
| 12 | Timed out. Present your plan alone. **State that the cross-check did not complete.** |
| 64 | Skill passed bad arguments to the runner (a bug in the skill itself, not a codex failure). Report the error message. **State plainly that the cross-check did not run.** |

**On any non-zero exit (10, 11, 12, 13, 14, 64):** The disclosure that the
cross-check failed must be **the FIRST thing in your response**, not a footnote.
The success-path template (Agreed / Disputed / Unique buckets) is **REPLACED**
entirely — do not use that framing when Codex never ran. A single-model plan
must never be presented in the shape of a two-model result. A plan the user
believes two models agreed on, when only one ran, is the worst outcome this tool
can produce. Never let a failure pass silently.

## 5. Check that the output is actually a plan (viability gate)

Exit 0 means only that `codex-plan.md` is **non-empty**. It does not mean Codex
planned anything. A refusal, a rate-limit notice, or a 200-byte "I need more
context to answer that" each exits 0 with a non-empty file — and each one
reconciles as **agreement by silence**: nothing to dispute, nothing unique, so
the buckets render as two models agreeing when only one ever planned.

Open `codex-plan.md` and require **recognisable plan structure**: several
discrete steps of concrete work that address the requirement in the brief,
naming files, components, or actions.

Anything else is a **degraded run**: prose with no steps, a question back to
you, an apology or refusal, an error or quota message, or a file too short to
contain a plan at all. Handle a degraded run exactly like a non-zero exit —
disclosure first, quote what Codex actually returned, present your plan alone,
and do not use the Agreed / Disputed / Unique framing.

A genuinely short plan is still a plan; the test is structure and coverage of
the brief, not length. When you cannot tell, report the cross-check as
unconfirmed rather than presenting buckets.

## 6. Reconcile into three buckets (success path only)

- **Agreed** — summarise briefly. Do not pad.
- **Disputed** — where the plans materially conflict. State both positions
  fairly, then your recommendation. The user decides.
- **Unique to one model** — steps only one plan contains. **This is the
  payload.** A step only Codex produced is the blind spot the user is paying
  for. Never quietly drop one because it was not in your plan.

Ignore differences of wording, ordering, and granularity **when the same step
appears in both plans**. Only surface differences that change what gets built or
what could break. **This rule does NOT apply to a step that exists in one plan
and is absent from the other** — a step present in only one model is material
by definition, even if it might resemble a granularity difference. All Unique
steps must be surfaced.

## 7. Write the reconciled plan

Write it to the repo's existing convention, first that exists:

1. `docs/superpowers/specs/`
2. `docs/plans/`
3. ask the user

Raw plans stay in the scratchpad and are not committed. The output is an
ordinary plan file — `/gsd:execute-plan` and superpowers' executing-plans can
consume it unchanged.
