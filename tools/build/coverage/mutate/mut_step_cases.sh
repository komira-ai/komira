#!/bin/sh
# The cases of mut_step.sh, run as a build action by the `mut_step_cases`
# target (defs.bzl):
#   sh mut_step_cases.sh <busybox> <result.json> <mut_step.sh>
# Each case says the defect (mutant) of mut_step.sh it kills. Exits 1 on
# the first wrong result, naming it; writes the validation result and exits
# 0 when every case holds.
set -eu

abs() { case "$1" in /*) printf '%s' "$1" ;; *) printf '%s/%s' "$PWD" "$1" ;; esac; }
BB=$(abs "$1")
RESULT=$(abs "$2")
STEP=$(abs "$3")

case "${BUCK_SCRATCH_PATH:-}" in
    "") T="$PWD/.mut_step_cases" ;;
    /*) T="$BUCK_SCRATCH_PATH/mut_step_cases" ;;
    *) T="$PWD/$BUCK_SCRATCH_PATH/mut_step_cases" ;;
esac
"$BB" mkdir -p "$T/bin" "$T/work"
"$BB" --install -s "$T/bin"
PATH="$T/bin"
export PATH LC_ALL=C
W="$T/work"
cd "$W"

N=0
red() {
    echo "mut_step_cases RED: $*" >&2
    exit 1
}
pass() { N=$((N + 1)); }

# step <case> <limit> [options...] -- <command...>: runs mut_step.sh with a
# scratch directory of its own; the status is $W/<case>.status, its exit
# status $RC.
step() {
    name=$1
    shift
    RC=0
    BUCK_SCRATCH_PATH="$T/scratch/$name" "$BB" sh "$STEP" "$BB" "$W/$name.status" "$@" > "$W/$name.out" 2>&1 || RC=$?
}
first() { head -n 1 "$W/$1.status"; }

# ok: the first line is `ok` (kills a status written from the wrong branch).
step ok 5 -- sh -c 'echo fine'
[ "$RC" = 0 ] || red "ok: exit $RC"
[ "$(first ok)" = ok ] || red "ok: status '$(first ok)'"
grep -qx fine "$W/ok.status" || red "ok: the output is not kept after the first line"
pass

# fail <n>: the command's own status, its output kept (kills a fixed status,
# a lost log, a failed step failing the action).
step fail 5 -- sh -c 'echo boom >&2; exit 3'
[ "$RC" = 0 ] || red "fail: mut_step exited $RC; a failing step is a result"
[ "$(first fail)" = "fail 3" ] || red "fail: status '$(first fail)', want 'fail 3'"
grep -qx boom "$W/fail.status" || red "fail: stderr not kept"
pass

# timeout: a command still running at the limit is `timeout <limit>`, not
# `fail <n>` (kills a wrong limit check or the timeout recorded as a fail,
# which the scorer would count as a kill), and its whole process group is
# gone, a child it left running included (kills a kill of the command only).
start=$(date +%s)
step timeout 1 -- sh -c 'sleep 60 & echo $! > child.pid; wait'
end=$(date +%s)
[ "$RC" = 0 ] || red "timeout: exit $RC"
[ "$(first timeout)" = "timeout 1" ] || red "timeout: status '$(first timeout)', want 'timeout 1'"
[ $((end - start)) -lt 20 ] || red "timeout: took $((end - start)) s with a limit of 1 s"
child=$(cat child.pid)
if kill -0 "$child" 2>/dev/null; then
    kill -9 "$child" 2>/dev/null || true
    red "timeout: the command's child $child still runs"
fi
pass

# A command that finishes inside its limit is not a timeout (kills a limit
# check that always fires).
step quick 3 -- sh -c 'sleep 1; exit 4'
[ "$(first quick)" = "fail 4" ] || red "quick: status '$(first quick)', want 'fail 4'"
pass

# skipped: a prerequisite that is not ok skips the command, whose -o output
# is created empty (kills running anyway, and a missing declared output).
echo "fail 1" > "$W/pre.status"
step skipped 5 --after "$W/pre.status" -- sh -c 'echo ran > ran.txt' x -o "$W/skipped.o"
[ "$(first skipped)" = skipped ] || red "skipped: status '$(first skipped)'"
[ ! -e ran.txt ] || red "skipped: the command ran"
[ -f "$W/skipped.o" ] && [ ! -s "$W/skipped.o" ] || red "skipped: -o output not created empty"
echo ok > "$W/pre_ok.status"
step after_ok 5 --after "$W/pre_ok.status" -- sh -c 'exit 0'
[ "$(first after_ok)" = ok ] || red "after_ok: an ok prerequisite skipped the step"
pass

# -o outputs: created empty after a failure, kept after a success.
step outfail 5 -- sh -c 'exit 1' x -o "$W/fail.o"
[ -f "$W/fail.o" ] && [ ! -s "$W/fail.o" ] || red "outfail: -o output not created empty"
step outok 5 -- sh -c 'echo data > "$1"' x "$W/ok.o" -o "$W/ok.o"
[ "$(cat "$W/ok.o")" = data ] || red "outok: the command's -o output was replaced"
pass

# --infra-exit: the compile wrapper's watchdog status fails the action, so
# a farm failure is never cached as the mutant's result; another status
# still is a result.
step infra 5 --infra-exit 124 -- sh -c 'exit 124'
[ "$RC" = 124 ] || red "infra: exit $RC, want 124"
step notinfra 5 --infra-exit 124 -- sh -c 'exit 1'
[ "$RC" = 0 ] && [ "$(first notinfra)" = "fail 1" ] || red "notinfra: exit $RC, status '$(first notinfra)'"
pass

# @MUT_SCRATCH@: replaced by the private scratch directory, not written
# into the action's working directory.
step scratch 5 -- sh -c 'echo PASS > "$1"; cat "$1"' x @MUT_SCRATCH@/marker
[ "$(first scratch)" = ok ] || red "scratch: status '$(first scratch)'"
[ -f "$T/scratch/scratch/mut_step/marker" ] || red "scratch: the marker is not in the scratch directory"
[ ! -e "@MUT_SCRATCH@" ] || red "scratch: the prefix was not replaced"
pass

# usage errors exit 2
for args in "0 -- true" "x -- true" "5 --what -- true" "5 --after"; do
    # shellcheck disable=SC2086 # each case is a word list
    step usage $args
    [ "$RC" = 2 ] || red "usage '$args': exit $RC, want 2"
done
pass

cd /
rm -rf "$T"
printf '{"version": 1, "data": {"status": "success", "message": "mut_step: %s cases passed"}}\n' "$N" >"$RESULT"
echo "mut_step_cases GREEN: $N cases"
