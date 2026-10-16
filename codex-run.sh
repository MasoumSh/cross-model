#!/usr/bin/env bash
# Shared runner for the cross-model consensus skills.
# Exit codes are a contract consumed by the SKILL.md files. See DESIGN.md.
set -uo pipefail

EXIT_NO_CODEX=10
EXIT_NO_LOGIN=11
EXIT_TIMEOUT=12
EXIT_CODEX_FAIL=13
EXIT_NO_OUTPUT=14
EXIT_USAGE=64
DEFAULT_TIMEOUT=600

die() { echo "cross-model: $1" >&2; exit "$2"; }

preflight() {
  command -v codex >/dev/null 2>&1 \
    || die "codex CLI not found on PATH" $EXIT_NO_CODEX
  codex login status 2>&1 | grep -qi '^Logged in' \
    || die "codex is not logged in (run: codex login)" $EXIT_NO_LOGIN
}

# run_with_timeout <seconds> <command...>
# Returns the command's status, or $EXIT_TIMEOUT if the watchdog fired.
# bash 3.2: no `wait -n`. A sentinel file is the only reliable way to tell a
# watchdog kill (143) apart from the command exiting 143 by itself.
run_with_timeout() {
  local secs="$1"; shift
  # Explicit XXXXXX template: GNU mktemp (Git Bash on Windows) rejects `-t crossmodel`.
  local sentinel; sentinel="$(mktemp "${TMPDIR:-/tmp}/crossmodel.XXXXXX")"
  rm -f "$sentinel"

  set -m
  # With job control on, a background job keeps the caller's stdin; codex then
  # blocks on "Reading additional input from stdin..." until the watchdog fires.
  "$@" < /dev/null &
  local cmd_pid=$!
  set +m

  (
    sleep "$secs" &
    local sleep_pid=$!
    trap "kill -TERM $sleep_pid 2>/dev/null; wait $sleep_pid 2>/dev/null; exit 0" TERM
    wait "$sleep_pid" 2>/dev/null
    if kill -0 -"$cmd_pid" 2>/dev/null || kill -0 "$cmd_pid" 2>/dev/null; then
      : > "$sentinel"
      kill -TERM -"$cmd_pid" 2>/dev/null || kill -TERM "$cmd_pid" 2>/dev/null
      # Poll for termination with short grace period (2s total via 0.1s intervals)
      local poll=0
      while [ $poll -lt 20 ] && (kill -0 -"$cmd_pid" 2>/dev/null || kill -0 "$cmd_pid" 2>/dev/null); do
        sleep 0.1
        poll=$((poll+1))
      done
      if kill -0 -"$cmd_pid" 2>/dev/null || kill -0 "$cmd_pid" 2>/dev/null; then
        kill -KILL -"$cmd_pid" 2>/dev/null || kill -KILL "$cmd_pid" 2>/dev/null
      fi
    fi
  ) &
  local dog_pid=$!

  local status=0
  wait "$cmd_pid" || status=$?

  kill -TERM "$dog_pid" 2>/dev/null
  wait "$dog_pid" 2>/dev/null

  if [ -f "$sentinel" ] && [ "$status" -ge 128 ]; then
    rm -f "$sentinel"
    return $EXIT_TIMEOUT
  fi
  rm -f "$sentinel"
  return $status
}

cmd_plan() {
  local brief="" out="" repo="$PWD" secs="$DEFAULT_TIMEOUT"
  while [ $# -gt 0 ]; do
    case "$1" in
      --brief)
        [ $# -ge 2 ] || die "--brief requires a value" $EXIT_USAGE
        brief="$2"; shift
        ;;
      --out)
        [ $# -ge 2 ] || die "--out requires a value" $EXIT_USAGE
        out="$2"; shift
        ;;
      --repo)
        [ $# -ge 2 ] || die "--repo requires a value" $EXIT_USAGE
        repo="$2"; shift
        ;;
      --timeout)
        [ $# -ge 2 ] || die "--timeout requires a value" $EXIT_USAGE
        secs="$2"; shift
        ;;
      *) die "unknown option: $1" $EXIT_USAGE ;;
    esac
    shift
  done
  [ -n "$brief" ] || die "--brief <file> is required" $EXIT_USAGE
  [ -f "$brief" ] || die "brief file not found: $brief" $EXIT_USAGE
  [ -n "$out" ]   || die "--out <file> is required"   $EXIT_USAGE

  # Validate timeout is a positive integer
  case "$secs" in
    ''|*[!0-9]*) die "--timeout must be a positive integer, got: $secs" $EXIT_USAGE ;;
  esac
  [ "$secs" -gt 0 ] || die "--timeout must be positive, got: $secs" $EXIT_USAGE

  # Validate output directory exists and is writable
  local outdir; outdir="$(dirname "$out")"
  [ -d "$outdir" ] || die "--out directory does not exist: $outdir" $EXIT_USAGE
  [ -w "$outdir" ] || die "--out directory is not writable: $outdir" $EXIT_USAGE

  # Validate repo directory exists. cmd_review already did this; cmd_plan did
  # not, so a typo'd --repo reached `codex exec -C <nonexistent>` and surfaced
  # as an opaque exit 13 instead of a usage error. Same check, same message.
  [ -d "$repo" ] || die "--repo is not a directory: $repo" $EXIT_USAGE

  preflight

  # Prompt is passed as argv, not stdin: backgrounded commands in bash get
  # stdin from /dev/null, which would silently send an empty prompt.
  #
  # `--` terminates option parsing before the brief. Without it a brief whose
  # first character is `-` is parsed as a flag: confirmed live, a brief
  # opening with a markdown bullet dies with
  #   error: unexpected argument '- ' found
  # and the crossplan skill's own brief template is a bullet list, so this is
  # the common case, not the exotic one.
  #
  # --skip-git-repo-check: plan and arch read a directory, not a diff, so a
  # non-git target is legitimate. Without it codex exec refuses with "Not
  # inside a trusted directory" (exit 1 → our 13). Safe here because the
  # sandbox is read-only. Not added to cmd_review: that one needs git anyway.
  local status=0
  run_with_timeout "$secs" codex exec \
    -s read-only --ephemeral --skip-git-repo-check \
    -C "$repo" -o "$out" -- "$(cat "$brief")" || status=$?

  [ "$status" -eq $EXIT_TIMEOUT ] && die "codex timed out after ${secs}s" $EXIT_TIMEOUT
  [ "$status" -ne 0 ] && die "codex exited with status $status" $EXIT_CODEX_FAIL
  [ -s "$out" ] || die "codex produced no output" $EXIT_NO_OUTPUT
  return 0
}

cmd_review() {
  local out="" repo="$PWD" secs="$DEFAULT_TIMEOUT" target="uncommitted"
  while [ $# -gt 0 ]; do
    case "$1" in
      --out)
        [ $# -ge 2 ] || die "--out requires a value" $EXIT_USAGE
        out="$2"; shift
        ;;
      --repo)
        [ $# -ge 2 ] || die "--repo requires a value" $EXIT_USAGE
        repo="$2"; shift
        ;;
      --timeout)
        [ $# -ge 2 ] || die "--timeout requires a value" $EXIT_USAGE
        secs="$2"; shift
        ;;
      --target)
        [ $# -ge 2 ] || die "--target requires a value" $EXIT_USAGE
        target="$2"; shift
        ;;
      *) die "unknown option: $1" $EXIT_USAGE ;;
    esac
    shift
  done
  [ -n "$out" ] || die "--out <file> is required" $EXIT_USAGE

  # Validate target format and extract flag and value
  local target_flag="" target_val=""
  case "$target" in
    uncommitted) target_flag="--uncommitted" ;;
    base:*)      target_flag="--base";   target_val="${target#base:}" ;;
    commit:*)    target_flag="--commit"; target_val="${target#commit:}" ;;
    *) die "--target must be uncommitted | base:<branch> | commit:<sha>" $EXIT_USAGE ;;
  esac
  [ "$target_flag" != "--uncommitted" ] && [ -z "$target_val" ] \
    && die "--target $target is missing a value" $EXIT_USAGE

  # Validate target_val shape: no leading dash, no spaces, only safe characters
  # (letters, digits, dots, underscores, slashes, hyphens)
  if [ -n "$target_val" ]; then
    case "$target_val" in
      -*) die "--target value must not start with a dash: $target_val" $EXIT_USAGE ;;
      *\ *) die "--target value must not contain spaces: $target_val" $EXIT_USAGE ;;
      *[!A-Za-z0-9._/\-]*) die "--target value contains invalid characters: $target_val" $EXIT_USAGE ;;
    esac
  fi

  # Validate timeout is a positive integer
  case "$secs" in
    ''|*[!0-9]*) die "--timeout must be a positive integer, got: $secs" $EXIT_USAGE ;;
  esac
  [ "$secs" -gt 0 ] || die "--timeout must be positive, got: $secs" $EXIT_USAGE

  # Validate output directory exists and is writable
  local outdir; outdir="$(dirname "$out")"
  [ -d "$outdir" ] || die "--out directory does not exist: $outdir" $EXIT_USAGE
  [ -w "$outdir" ] || die "--out directory is not writable: $outdir" $EXIT_USAGE

  # Validate repo directory exists (cmd_review cds into it — see below —
  # since `codex exec review` has no -C/--cd of its own).
  [ -d "$repo" ] || die "--repo is not a directory: $repo" $EXIT_USAGE

  preflight

  # Build codex argv as indexed array to keep each token separate
  # (prevents target_val from injecting flags regardless of content)
  local args=(exec review "$target_flag")
  [ -n "$target_val" ] && args+=("$target_val")

  # `codex exec review` (unlike plain `codex exec`) does NOT accept -s /
  # --sandbox — confirmed live: it dies with "unexpected argument '-s' found"
  # and exit 2. -c sandbox_mode="read-only" IS honoured on this subcommand
  # (confirmed live: printed "sandbox: read-only" in its header) and is the
  # replacement. --ephemeral is valid on both plan and review.
  #
  # `codex exec review` also does NOT accept -C/--cd — confirmed live: it
  # dies with "unexpected argument '-C' found" and exit 2, the same failure
  # mode as -s. review has no working-directory flag of its own, so the
  # invocation itself is run from inside $repo (see the subshell below)
  # instead of passing a flag. Not `env -C`: that's a GNU coreutils
  # extension, unavailable on macOS.
  args+=(-c 'sandbox_mode="read-only"' --ephemeral -o "$out")

  # `codex exec review` also silently ignores --output-schema (confirmed
  # live: real output came back as review's own fixed prose format, not
  # JSON, despite the flag being passed). There is no schema flag for this
  # subcommand, and there is deliberately no prompt argument here either:
  # `review`'s own [PROMPT] positional is mutually exclusive with all three
  # target flags — confirmed live, `error: the argument '--uncommitted'
  # cannot be used with '[PROMPT]'` (and the same for --base/--commit). This
  # tool always reviews a specific target, so a prompt could never be sent
  # anyway; round 1's attempt to fold the deleted schema's quality bar into
  # a review prompt is not viable here and was removed along with the
  # --prompt flag. That requirement now lives in skills/crossreview/SKILL.md step 6
  # instead, enforced by Claude reading the actual code rather than
  # requested of Codex.

  # No -C/--cd on this subcommand (see above), so run from inside $repo.
  # The subshell's exit status is run_with_timeout's own status (the `cd`
  # cannot fail here: $repo was already validated as a directory above),
  # and it propagates through `||` exactly like the direct call did.
  local status=0
  ( cd "$repo" && run_with_timeout "$secs" codex "${args[@]}" ) || status=$?

  [ "$status" -eq $EXIT_TIMEOUT ] && die "codex timed out after ${secs}s" $EXIT_TIMEOUT
  [ "$status" -ne 0 ] && die "codex exited with status $status" $EXIT_CODEX_FAIL
  [ -s "$out" ] || die "codex produced no output" $EXIT_NO_OUTPUT
  return 0
}

case "${1:-}" in
  preflight) shift; preflight ;;
  plan) shift; cmd_plan "$@" ;;
  # arch: whole-codebase architecture review (crossarch skill). `codex exec
  # review` only reviews a diff, so this is plain `codex exec` with a prompt,
  # exactly the plan path: same flags, same read-only sandbox, same exit
  # contract. Only the brief's content differs, so it shares cmd_plan.
  arch) shift; cmd_plan "$@" ;;
  review) shift; cmd_review "$@" ;;
  _selftest_timeout)
    # Test hook for run_with_timeout. It ships in the production script and is
    # reachable by name, so it is hardened two ways rather than one:
    #   1. gated behind CROSS_MODEL_SELFTEST=1, so a stray `codex-run.sh
    #      _selftest_timeout` from a shell or a script cannot spend the user's
    #      rate limits by accident;
    #   2. carrying `-s read-only --ephemeral` anyway, so that even when the
    #      gate IS set the invocation obeys the same sandbox contract as every
    #      other codex call in this file.
    # Belt and braces deliberately: the gate stops accidental invocation, the
    # flags stop an intentional one from being the single unsandboxed hole.
    shift
    [ "${CROSS_MODEL_SELFTEST:-}" = "1" ] \
      || die "_selftest_timeout is a test hook; set CROSS_MODEL_SELFTEST=1 to run it" $EXIT_USAGE
    run_with_timeout "${1:-5}" codex exec -s read-only --ephemeral -o /dev/null -- "selftest"
    exit $?
    ;;
  *) die "usage: codex-run.sh {preflight|plan|arch|review} [options]" $EXIT_USAGE ;;
esac
