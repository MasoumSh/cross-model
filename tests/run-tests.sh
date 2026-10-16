#!/usr/bin/env bash
# Plain-bash test harness. No bats installed; none needed.
HERE="$(cd "$(dirname "$0")" && pwd)"
RUNNER="$HERE/../codex-run.sh"
export PATH="$HERE/fixtures:$PATH"   # fake-codex shadows the real one
PASS=0; FAIL=0

assert_exit() {
  local expected="$1" label="$2"; shift 2
  local actual=0
  "$@" >/dev/null 2>&1 || actual=$?
  if [ "$actual" = "$expected" ]; then
    echo "  ok   $label"; PASS=$((PASS+1))
  else
    echo "  FAIL $label (expected exit $expected, got $actual)"; FAIL=$((FAIL+1))
  fi
}

echo "preflight:"
FAKE_CODEX_MODE=ok         assert_exit 0  "passes when logged in"        "$RUNNER" preflight
FAKE_CODEX_MODE=logged-out assert_exit 11 "exit 11 when logged out"      "$RUNNER" preflight
PATH="/usr/bin:/bin" \
                           assert_exit 10 "exit 10 when codex absent"    "$RUNNER" preflight

echo
echo "watchdog:"
# Capture sleep PIDs before watchdog tests to detect leaks via PID-set diff.
before_pids=$(pgrep -x sleep 2>/dev/null | sort)

CROSS_MODEL_SELFTEST=1 FAKE_CODEX_MODE=slow assert_exit 12 "exit 12 when command overruns" \
  "$RUNNER" _selftest_timeout 1
CROSS_MODEL_SELFTEST=1 FAKE_CODEX_MODE=ok   assert_exit 0  "exit 0 when command finishes in time" \
  "$RUNNER" _selftest_timeout 10

# _selftest_timeout ships in the production script and is reachable by name,
# so it must not be invocable by accident: it spends real rate limits. It is
# gated behind CROSS_MODEL_SELFTEST=1 (and carries -s read-only --ephemeral
# anyway, asserted below).
FAKE_CODEX_MODE=ok assert_exit 64 "exit 64 when _selftest_timeout is ungated" \
  "$RUNNER" _selftest_timeout 1

# Regression test: PID-set diff for leaked sleep processes.
# Capture after-test PIDs and verify no new ones persist.
# Give it a moment for process cleanup before checking.
sleep 0.5
after_pids=$(pgrep -x sleep 2>/dev/null | sort)

# Check: every PID in after_pids must have existed in before_pids.
leaked_sleep=0
for pid in $after_pids; do
  if ! echo "$before_pids" | grep -q "^$pid$"; then
    leaked_sleep=1
    break
  fi
done

if [ "$leaked_sleep" = "0" ]; then
  echo "  ok   no leaked sleep processes (PID-set diff)"; PASS=$((PASS+1))
else
  echo "  FAIL no leaked sleep processes (found orphaned sleep PID)"; FAIL=$((FAIL+1))
fi

echo
echo "plan:"
TMP="$HERE/tmp"; rm -rf "$TMP"; mkdir -p "$TMP"
echo "build a widget" > "$TMP/brief.md"

FAKE_CODEX_MODE=ok assert_exit 0 "writes output on success" \
  "$RUNNER" plan --brief "$TMP/brief.md" --out "$TMP/plan.md"
if [ -s "$TMP/plan.md" ]; then
  echo "  ok   output file is non-empty"; PASS=$((PASS+1))
else
  echo "  FAIL output file is non-empty"; FAIL=$((FAIL+1))
fi

FAKE_CODEX_MODE=fail  assert_exit 13 "exit 13 when codex fails" \
  "$RUNNER" plan --brief "$TMP/brief.md" --out "$TMP/p2.md"
FAKE_CODEX_MODE=empty assert_exit 14 "exit 14 on empty output" \
  "$RUNNER" plan --brief "$TMP/brief.md" --out "$TMP/p3.md"
FAKE_CODEX_MODE=ok    assert_exit 64 "exit 64 when --brief missing" \
  "$RUNNER" plan --out "$TMP/p4.md"
FAKE_CODEX_MODE=ok    assert_exit 64 "exit 64 when brief file absent" \
  "$RUNNER" plan --brief "$TMP/nope.md" --out "$TMP/p5.md"
FAKE_CODEX_MODE=ok    assert_exit 64 "exit 64 when --brief is last token" \
  "$RUNNER" plan --brief
FAKE_CODEX_MODE=ok    assert_exit 64 "exit 64 when --timeout is last token" \
  "$RUNNER" plan --brief "$TMP/brief.md" --timeout
FAKE_CODEX_MODE=ok    assert_exit 64 "exit 64 when --timeout is non-numeric" \
  "$RUNNER" plan --brief "$TMP/brief.md" --out "$TMP/p7.md" --timeout notanumber

# --repo parity with cmd_review: cmd_plan passes it straight to `codex exec -C`,
# so a non-directory must fail fast with a usage error, not an opaque exit 13.
FAKE_CODEX_MODE=ok    assert_exit 64 "exit 64 when plan --repo is not a directory" \
  "$RUNNER" plan --brief "$TMP/brief.md" --out "$TMP/p9.md" --repo "$TMP/does-not-exist"

# A brief whose FIRST CHARACTER is `-` must not be parsed as a flag. The
# crossplan skill's brief template is a markdown bullet list, so this is the
# common case: confirmed live, `codex exec ... "- Requirement: ..."` without a
# `--` separator dies with "unexpected argument '- ' found". cmd_plan now
# passes `--` before the positional; tests/fixtures/codex models exec's flag
# parsing, so removing that `--` makes this assertion fail (exit 13, not 0).
printf -- '- Requirement: build a thing\n- Constraint: bash 3.2\n' > "$TMP/dash-brief.md"
FAKE_CODEX_MODE=ok    assert_exit 0 "brief starting with a dash is not parsed as a flag" \
  "$RUNNER" plan --brief "$TMP/dash-brief.md" --out "$TMP/p10.md"

# Sandbox regression guard for the PLAN path, mirroring the review-path argv
# assertions below. This path had NO argv coverage: changing cmd_plan's
# `-s read-only` to `-s danger-full-access` left the suite reporting
# "passed: 32  failed: 0". There is no `sandbox_mode` in ~/.codex/config.toml,
# so this command-line flag is the entire control on the plan path.
: > "$TMP/argv_plan.log"
CODEX_ARGV_LOG="$TMP/argv_plan.log" \
FAKE_CODEX_MODE=ok "$RUNNER" plan --brief "$TMP/brief.md" --out "$TMP/p11.md" >/dev/null 2>&1
if grep -q '^-s$' "$TMP/argv_plan.log" && grep -Fxq 'read-only' "$TMP/argv_plan.log" && \
   grep -q '^--ephemeral$' "$TMP/argv_plan.log"; then
  echo "  ok   -s, read-only and --ephemeral reach codex on the plan path"; PASS=$((PASS+1))
else
  echo "  FAIL -s, read-only and --ephemeral reach codex on the plan path"; FAIL=$((FAIL+1))
fi

# Presence-only greps are satisfied by an argv that ALSO carries a later,
# wider `-s`/`--dangerously-*` (last one wins). Assert there is exactly one
# -s, that the token immediately after it is `read-only`, and that no
# escape-hatch flag appears anywhere in the plan argv.
plan_s_count=$(grep -c '^-s$' "$TMP/argv_plan.log")
plan_s_value=$(grep -A1 '^-s$' "$TMP/argv_plan.log" | sed -n '2p')
if [ "$plan_s_count" = "1" ] && [ "$plan_s_value" = "read-only" ] && \
   ! grep -q '^--dangerously-' "$TMP/argv_plan.log" && \
   ! grep -q 'danger-full-access\|workspace-write' "$TMP/argv_plan.log"; then
  echo "  ok   plan argv has exactly one -s, valued read-only, no escape hatch"; PASS=$((PASS+1))
else
  echo "  FAIL plan argv has exactly one -s, valued read-only, no escape hatch"
  echo "       (-s count=$plan_s_count value=$plan_s_value)"; FAIL=$((FAIL+1))
fi

# The hardened _selftest_timeout hook must itself run sandboxed: it reaches a
# real `codex exec` when the gate is set, and previously carried neither
# -s read-only nor --ephemeral.
: > "$TMP/argv_selftest.log"
CROSS_MODEL_SELFTEST=1 CODEX_ARGV_LOG="$TMP/argv_selftest.log" \
FAKE_CODEX_MODE=ok "$RUNNER" _selftest_timeout 10 >/dev/null 2>&1
st_s_value=$(grep -A1 '^-s$' "$TMP/argv_selftest.log" | sed -n '2p')
if [ "$st_s_value" = "read-only" ] && grep -q '^--ephemeral$' "$TMP/argv_selftest.log"; then
  echo "  ok   _selftest_timeout runs with -s read-only --ephemeral"; PASS=$((PASS+1))
else
  echo "  FAIL _selftest_timeout runs with -s read-only --ephemeral"; FAIL=$((FAIL+1))
fi

echo
echo "review:"
FAKE_CODEX_MODE=ok assert_exit 0 "default target succeeds" \
  "$RUNNER" review --out "$TMP/rev.json"
FAKE_CODEX_MODE=ok assert_exit 0 "base target succeeds" \
  "$RUNNER" review --out "$TMP/rev2.json" --target base:main
FAKE_CODEX_MODE=ok assert_exit 0 "commit target succeeds" \
  "$RUNNER" review --out "$TMP/rev3.json" --target commit:abc123
FAKE_CODEX_MODE=fail assert_exit 13 "exit 13 when codex fails" \
  "$RUNNER" review --out "$TMP/rev4.json"
FAKE_CODEX_MODE=empty assert_exit 14 "exit 14 on empty output" \
  "$RUNNER" review --out "$TMP/rev5.json"

# Malformed target must error with cmd_review's message, not generic usage
if "$RUNNER" review --out "$TMP/rev6.json" --target nonsense 2>"$TMP/err_malformed.txt" >/dev/null; then
  echo "  FAIL exit 64 on malformed target (expected non-zero)"; FAIL=$((FAIL+1))
else
  actual=$?
  if [ "$actual" -eq 64 ] && grep -q "must be uncommitted | base:<branch> | commit:<sha>" "$TMP/err_malformed.txt"; then
    echo "  ok   exit 64 on malformed target with correct message"; PASS=$((PASS+1))
  else
    echo "  FAIL exit 64 on malformed target (exit $actual, or message wrong)"; FAIL=$((FAIL+1))
  fi
fi

# Last-token hang check
FAKE_CODEX_MODE=ok assert_exit 64 "exit 64 when --out is last token" \
  "$RUNNER" review --out

# Target with space must be rejected
if "$RUNNER" review --out "$TMP/rev7.json" --target "base:main branch" 2>"$TMP/err_space.txt" >/dev/null; then
  echo "  FAIL exit 64 on target with space (expected non-zero)"; FAIL=$((FAIL+1))
else
  actual=$?
  if [ "$actual" -eq 64 ] && grep -q "must not contain spaces" "$TMP/err_space.txt"; then
    echo "  ok   exit 64 on target with space"; PASS=$((PASS+1))
  else
    echo "  FAIL exit 64 on target with space (exit $actual, or message wrong)"; FAIL=$((FAIL+1))
  fi
fi

# Verify argv logging: safety flags must reach codex as separate tokens.
# codex exec review does not accept -s/--sandbox (confirmed live: real codex
# errors "unexpected argument '-s' found" and exits 2); -c sandbox_mode is
# the flag that subcommand actually honours (confirmed live: printed
# "sandbox: read-only" in its header). --ephemeral is valid on both.
# Truncate explicitly. `tail -n 1 argv.log` below is only correct if this run
# is the only writer, and the fixture APPENDS. That held by accident because
# TMP is wiped at the top of the plan section; decouple it from that.
: > "$TMP/argv.log"
CODEX_ARGV_LOG="$TMP/argv.log" \
FAKE_CODEX_MODE=ok "$RUNNER" review --out "$TMP/rev8.json" --target base:main >/dev/null 2>&1
if grep -q '^-c$' "$TMP/argv.log" && grep -Fxq 'sandbox_mode="read-only"' "$TMP/argv.log" && \
   grep -q "^--ephemeral$" "$TMP/argv.log"; then
  echo "  ok   -c sandbox_mode=\"read-only\" and --ephemeral reach codex"; PASS=$((PASS+1))
else
  echo "  FAIL -c sandbox_mode=\"read-only\" and --ephemeral reach codex"; FAIL=$((FAIL+1))
fi

# Hardening of the presence-only check above: every grep in it stays true if
# a SECOND, wider `-c sandbox_mode="danger-full-access"` is appended (codex
# applies the last -c), or if a --dangerously-* flag is added alongside.
# Assert exactly one sandbox_mode override, that its value is read-only, and
# that no escape-hatch flag appears anywhere in the review argv.
sandbox_c_count=$(grep -c '^sandbox_mode=' "$TMP/argv.log")
if [ "$sandbox_c_count" = "1" ] && \
   grep -Fxq 'sandbox_mode="read-only"' "$TMP/argv.log" && \
   ! grep -q '^--dangerously-' "$TMP/argv.log" && \
   ! grep -q 'danger-full-access\|workspace-write' "$TMP/argv.log"; then
  echo "  ok   review argv has exactly one sandbox_mode override, no escape hatch"; PASS=$((PASS+1))
else
  echo "  FAIL review argv has exactly one sandbox_mode override, no escape hatch"
  echo "       (sandbox_mode count=$sandbox_c_count)"; FAIL=$((FAIL+1))
fi

# Regression guard: codex exec review does NOT accept -s/--sandbox — this is
# the exact defect that made every live review run die with "unexpected
# argument '-s' found". The fixture now rejects it too (see
# tests/fixtures/codex), so this is a real guard, not cosmetic: a revert of
# the -s -> -c fix would fail this assertion AND every review assert_exit
# above (fixture would exit 2, cmd_review would surface exit 13).
if grep -q "^-s$" "$TMP/argv.log"; then
  echo "  FAIL review path must not pass -s to codex"; FAIL=$((FAIL+1))
else
  echo "  ok   review path does not pass -s to codex"; PASS=$((PASS+1))
fi

# Regression guard #2: codex exec review does NOT accept -C/--cd either —
# the second live-only defect, found after -s was fixed ("unexpected
# argument '-C' found", exit 2). cmd_review now cds into $repo itself
# instead of passing -C. Assert the review path's argv never contains it.
if grep -q "^-C$" "$TMP/argv.log"; then
  echo "  FAIL review path must not pass -C to codex"; FAIL=$((FAIL+1))
else
  echo "  ok   review path does not pass -C to codex"; PASS=$((PASS+1))
fi

# Standing contract test: tests/fixtures/codex now encodes review's full
# accepted-flag set (see the fixture) and exits 2 like the real CLI on
# anything outside it. A normal review invocation succeeding end-to-end
# means its full argv passed that guard — this is the check that would have
# caught both the -s and -C defects before they ever reached a live run.
FAKE_CODEX_MODE=ok assert_exit 0 \
  "review's full argv passes codex's accepted-flag guard" \
  "$RUNNER" review --out "$TMP/rev10.json" --target base:main --repo "$TMP"

# --repo must be a real directory: cmd_review cds into it (no -C on this
# subcommand), so an absent/non-directory --repo must fail fast with a
# clear usage error rather than a confusing cd failure inside the subshell.
FAKE_CODEX_MODE=ok assert_exit 64 "exit 64 when --repo is not a directory" \
  "$RUNNER" review --out "$TMP/rev11.json" --repo "$TMP/does-not-exist"

# Regression guard #3, part A: --prompt no longer exists on the review path
# at all. codex exec review's positional [PROMPT] cannot be combined with
# any target flag (confirmed live: "error: the argument '--uncommitted'
# cannot be used with '[PROMPT]'", same for --base/--commit) — every review
# this tool runs sets a target, so the flag was removed rather than made
# conditional. It must now fail the same way any other unknown option does.
FAKE_CODEX_MODE=ok assert_exit 64 "exit 64 when --prompt is passed (flag removed)" \
  "$RUNNER" review --out "$TMP/rev12.json" --prompt "anything"

# Regression guard #3, part B: the review path's real argv must never carry
# a trailing positional after its target flag and recognized options — i.e.
# it must never reconstruct the [PROMPT]-vs-target conflict from part A by
# some other route. The last token in a normal review's argv must be the
# --out value itself, nothing after it.
last_argv_line="$(tail -n 1 "$TMP/argv.log")"
if [ "$last_argv_line" = "$TMP/rev8.json" ]; then
  echo "  ok   review path sends no trailing prompt after its target flag"; PASS=$((PASS+1))
else
  echo "  FAIL review path sends no trailing prompt after its target flag (got: $last_argv_line)"
  FAIL=$((FAIL+1))
fi

# Regression guard #3, part C: tests/fixtures/codex itself now detects the
# target+[PROMPT] conflict the way the real CLI does (see the fixture) —
# verified directly against the stub, independent of codex-run.sh, so a
# future caller of the fixture (or a reintroduced --prompt) is still caught.
if codex exec review --uncommitted -c 'sandbox_mode="read-only"' --ephemeral \
     -o "$TMP/rev13.json" "a trailing prompt" 2>"$TMP/err_promptconflict.txt"; then
  echo "  FAIL fixture rejects a target flag combined with a trailing prompt"
  FAIL=$((FAIL+1))
else
  actual=$?
  if [ "$actual" -eq 2 ] && grep -q "cannot be used with '\[PROMPT\]'" "$TMP/err_promptconflict.txt"; then
    echo "  ok   fixture rejects a target flag combined with a trailing prompt"
    PASS=$((PASS+1))
  else
    echo "  FAIL fixture rejects a target flag combined with a trailing prompt (exit $actual, or message wrong)"
    FAIL=$((FAIL+1))
  fi
fi

# Fixture completeness: `codex exec review --help` also advertises --enable
# and --disable. The fixture's accepted-flag set omitted them, so it failed
# CLOSED (rejecting a flag the real CLI takes) rather than open. Harmless
# today because the runner passes neither, but a fixture narrower than the
# real CLI makes any future use of those flags look like a defect.
if codex exec review --uncommitted -c 'sandbox_mode="read-only"' --ephemeral \
     --enable some-feature --disable other-feature -o "$TMP/rev14.json" \
     2>"$TMP/err_enable.txt" >/dev/null; then
  echo "  ok   fixture accepts review's --enable/--disable"; PASS=$((PASS+1))
else
  echo "  FAIL fixture accepts review's --enable/--disable ($(cat "$TMP/err_enable.txt"))"
  FAIL=$((FAIL+1))
fi

# Verify target values arrive as separate tokens (not collapsed/injected)
: > "$TMP/argv2.log"
CODEX_ARGV_LOG="$TMP/argv2.log" \
FAKE_CODEX_MODE=ok "$RUNNER" review --out "$TMP/rev9.json" --target base:mybranch >/dev/null 2>&1
if grep -q "^--base$" "$TMP/argv2.log" && grep -q "^mybranch$" "$TMP/argv2.log"; then
  echo "  ok   base and branch arrive as separate tokens"; PASS=$((PASS+1))
else
  echo "  FAIL base and branch arrive as separate tokens"; FAIL=$((FAIL+1))
fi

echo
echo "arch:"
FAKE_CODEX_MODE=ok    assert_exit 0  "exit 0 on arch success" \
  "$RUNNER" arch --brief "$TMP/brief.md" --out "$TMP/a1.md"
FAKE_CODEX_MODE=empty assert_exit 14 "exit 14 when arch output is empty" \
  "$RUNNER" arch --brief "$TMP/brief.md" --out "$TMP/a2.md"
FAKE_CODEX_MODE=ok    assert_exit 64 "exit 64 when arch --brief is missing" \
  "$RUNNER" arch --out "$TMP/a3.md"
FAKE_CODEX_MODE=ok    assert_exit 64 "exit 64 when arch --repo is not a directory" \
  "$RUNNER" arch --brief "$TMP/brief.md" --out "$TMP/a4.md" --repo "$TMP/does-not-exist"
: > "$TMP/argv_arch.log"
CODEX_ARGV_LOG="$TMP/argv_arch.log" \
FAKE_CODEX_MODE=ok "$RUNNER" arch --brief "$TMP/brief.md" --out "$TMP/a5.md" >/dev/null 2>&1
arch_s_value=$(grep -A1 '^-s$' "$TMP/argv_arch.log" | sed -n '2p')
if [ "$(grep -c '^-s$' "$TMP/argv_arch.log")" = "1" ] && [ "$arch_s_value" = "read-only" ] && \
   grep -q '^--ephemeral$' "$TMP/argv_arch.log" && ! grep -q '^--dangerously-' "$TMP/argv_arch.log"; then
  echo "  ok   arch path is read-only and ephemeral"; PASS=$((PASS+1))
else
  echo "  FAIL arch path is read-only and ephemeral"; FAIL=$((FAIL+1))
fi

echo
echo "grok-review:"
# Every case below fails before grok-review.mjs reaches the network, so the
# suite never spends xAI credits. The live run is recorded in tests/smoke.md.
G="$TMP/grepo"; mkdir -p "$G"
git -C "$G" init -q
printf 'a\n' > "$G/f.txt"
git -C "$G" add f.txt
git -C "$G" -c user.name=t -c user.email=t@t commit -qm init
XAI_API_KEY=dummy assert_exit 64 "exit 64 when the diff is empty" \
  "$RUNNER" grok-review --out "$TMP/g1.txt" --repo "$G"
printf 'a\nb\n' > "$G/f.txt"
XAI_API_KEY= assert_exit 11 "exit 11 when XAI_API_KEY is unset" \
  "$RUNNER" grok-review --out "$TMP/g2.txt" --repo "$G"
XAI_API_KEY=dummy CROSS_MODEL_GROK_MAX_BYTES=10 assert_exit 13 "exit 13 when the diff is over the cost cap" \
  "$RUNNER" grok-review --out "$TMP/g3.txt" --repo "$G"
XAI_API_KEY=dummy assert_exit 64 "exit 64 on a malformed --target" \
  "$RUNNER" grok-review --out "$TMP/g4.txt" --repo "$G" --target nonsense
XAI_API_KEY=dummy assert_exit 13 "exit 13 when the base branch does not exist" \
  "$RUNNER" grok-review --out "$TMP/g5.txt" --repo "$G" --target base:no-such-branch
if grep -q '"Authorization"\|XAI_API_KEY' "$TMP"/*.txt 2>/dev/null; then
  echo "  FAIL API key never written to output files"; FAIL=$((FAIL+1))
else
  echo "  ok   API key never written to output files"; PASS=$((PASS+1))
fi

echo
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]
