# =============================================================================
# src/kci_build/affected_batch.mojo -- step 5 of the per-change check: build
#   the decided units, one run per shared build_targets command, and name the
#   failing units when a run fails.
# =============================================================================
#
# `build_affected_units(req, arts, units, head, notices, runner)`:
#
# 1. GROUP: kci_artifact `batch_groups` splits `units` (decision order) into
#    groups whose build_targets commands are element-wise identical; groups
#    in the order of their first unit, decision order inside each.
# 2. Each group runs ONCE (cwd --work-dir, timeout --build-timeout-s):
#    - a group of one unit runs `render_targets_argv` with stdout and stderr
#      at `<log>/<unit>.stdout|.stderr`, and is never rerun;
#    - a group of two or more is BATCH k (k counts multi-unit groups from 1):
#      `render_batch_argv` (the shared command, then every unit's targets,
#      exact repeats dropped), logs at `<log>/_batch_<k>.stdout|.stderr`, its
#      argv one argument per line at `<log>/_batch_<k>.argv`.
# 3. How a run ended:
#    - it could not be started (the runner raises): INDETERMINATE
#      (KCI-E-CANNOT-TELL) naming every unit of that run; stop at once;
#    - exit 0: every unit of the run is PROVEN;
#    - timed out or killed by a signal: no unit of it is attributed (FAILED,
#      KCI-E-BUILD-FAILED), and it is not retried;
#    - a non-zero exit of a batch: its units run one at a time, in order,
#      each as a group of one. A unit that fails (a timeout counts) is a
#      FAILED UNIT. Once MAX_FAILED_UNITS units have failed across the step,
#      nothing more is retried: the rest are "not tried", and a later batch
#      that fails is noted "not attributed" (a later batch that passes still
#      proves its units). A batch that failed while every one of its units
#      built alone is INTERFERENCE.
# 4. The outcome, first match: a run that could not be started is
#    INDETERMINATE (KCI-E-CANNOT-TELL); any failed unit, or a batch nobody
#    was attributed for, is FAILED (KCI-E-BUILD-FAILED); any interference is
#    INDETERMINATE (KCI-E-CANNOT-TELL: the units interfere or the build is
#    flaky, never a pass); else SUCCEEDED, `<head>: N unit(s) built`.
#    A FAILED message's first line is `BUILD step: F of N unit(s) failed:
#    a, c`, then one paragraph per failed unit, the units not tried, and the
#    batch notes.
# 5. The lines: `notices`, then `BUILT <unit>` for each proven unit in
#    decision order, whatever the outcome. A unit is BUILT only when an
#    exit-0 run covered it.
#
# Raises only when an argv cannot be rendered or the argv file cannot be
# written; the caller maps that to FAILED (KCI-E-BUILD-FAILED).
#
# Encapsulation: owned values; no pointer, no wildcard origin. This file
# does not import kci_build.affected (that file imports this one).
# =============================================================================

from std.io import FileDescriptor
from std.os import makedirs

from kci_artifact import batch_groups, render_batch_argv, render_targets_argv, units_of
from kci_artifact_proto.artifact import Artifacts
from kci_api import ERROR_BUILD_FAILED, ERROR_CANNOT_TELL, OUTCOME_FAILED, OUTCOME_INDETERMINATE

from kci_build.request import BuildOutcome, BuildRequest
from kci_build.runner import ProcessRunner, RunResult, RunSpec

comptime MAX_FAILED_UNITS: Int = 3
"""Failed units named before the step stops building units one at a time."""

comptime _SHOWN_TARGETS: Int = 4
comptime _STDERR: FileDescriptor = FileDescriptor(2)


def affected_spec(argv: List[String], req: BuildRequest, base: String) -> RunSpec:
    """`argv` run from --work-dir with --build-timeout-s, stdout and stderr
    at `<base>.stdout` and `<base>.stderr`."""
    var rest = List[String]()
    for k in range(1, len(argv)):
        rest.append(argv[k].copy())
    return RunSpec(
        argv[0].copy(),
        rest^,
        req.work_dir.copy(),
        req.build_timeout_s,
        base + String(".stdout"),
        base + String(".stderr"),
    )


struct _Tally(Movable):
    """What the runs so far proved and failed.

    Layout: owned values only. No pointer field."""

    var proven: List[String]
    var failed: List[String]
    var paragraphs: List[String]
    var not_tried: List[String]
    var batch_notes: List[String]
    var unattributed: List[String]
    var interference: List[String]
    var cannot: String

    def __init__(out self):
        self.proven = List[String]()
        self.failed = List[String]()
        self.paragraphs = List[String]()
        self.not_tried = List[String]()
        self.batch_notes = List[String]()
        self.unattributed = List[String]()
        self.interference = List[String]()
        self.cannot = String("")


def _names(xs: List[String]) -> String:
    var s = String("")
    for i in range(len(xs)):
        if i > 0:
            s += String(", ")
        s += xs[i]
    return s^


def _contains(xs: List[String], x: String) -> Bool:
    for i in range(len(xs)):
        if xs[i] == x:
            return True
    return False


def _write_argv(path: String, argv: List[String]) raises:
    var text = String("")
    for i in range(len(argv)):
        text += argv[i] + String("\n")
    var f = open(path, "w")
    f.write_bytes(text.as_bytes())
    f.close()


def _command_len(arts: Artifacts, unit: String) raises -> Int:
    """How many leading words of `unit`'s argv are the build_targets command."""
    var argv = render_targets_argv(arts, unit)
    var all = units_of(arts)
    for i in range(len(all)):
        if all[i].name == unit:
            return len(argv) - len(all[i].targets)
    raise Error(String("no unit '") + unit + String("' is declared"))


def _shown(argv: List[String], command_len: Int) -> String:
    """The command and its first `_SHOWN_TARGETS` targets, space-joined."""
    var n = min(len(argv), command_len + _SHOWN_TARGETS)
    var s = String("")
    for i in range(n):
        if i > 0:
            s += String(" ")
        s += argv[i]
    return s^


def _with_tail(var text: String, r: RunResult) -> String:
    if r.stderr_tail.byte_length() > 0:
        text += String("\n") + r.stderr_tail
    return text^


def _run_unit[R: ProcessRunner](
    req: BuildRequest, arts: Artifacts, name: String, mut runner: R, mut t: _Tally
) raises:
    """One unit alone, as a group of one: proven, or a failed unit with
    its paragraph, or `t.cannot` set when it could not be started."""
    var spec = affected_spec(render_targets_argv(arts, name), req, req.log_dir + String("/") + name)
    print(String("BUILD step: building unit ") + name + String(": ") + spec.command_line(), file=_STDERR)
    var r: RunResult
    try:
        r = runner.run(spec)
    except e:
        t.cannot = String("unit '") + name + String("': the build could not be started: ") + String(e)
        return
    if r.ok():
        t.proven.append(name.copy())
        return
    t.failed.append(name.copy())
    t.paragraphs.append(
        _with_tail(
            String("unit '") + name + String("': `") + spec.command_line() + String("` ")
            + r.describe() + String(" (stderr: ") + spec.stderr_path + String(")"),
            r,
        )
    )


def _run_batch[R: ProcessRunner](
    req: BuildRequest, arts: Artifacts, group: List[String], k: Int, mut runner: R, mut t: _Tally
) raises:
    """Batch `k` over `group` (file header, steps 2 and 3)."""
    var argv = render_batch_argv(arts, group)
    var base = req.log_dir + String("/_batch_") + String(k)
    var argv_path = base + String(".argv")
    _write_argv(argv_path, argv)
    var spec = affected_spec(argv, req, base)
    var command_len = _command_len(arts, group[0])
    var shown = _shown(argv, command_len)
    var more = len(argv) - command_len - _SHOWN_TARGETS
    var tag = String("batch ") + String(k)
    var n = String(len(group)) + String(" unit(s)")
    var where = String("argv in ") + argv_path
    if more > 0:
        where = String("+") + String(more) + String(" more; ") + where
    print(
        String("BUILD step: building ") + n + String(" in ") + tag + String(": `") + shown + String("` (") + where
        + String(")"),
        file=_STDERR,
    )
    var r: RunResult
    try:
        r = runner.run(spec)
    except e:
        t.cannot = tag + String(" (") + n + String(": ") + _names(group) + String("): the build could not be started: ") + String(e)
        return
    if r.ok():
        for i in range(len(group)):
            t.proven.append(group[i].copy())
        return
    if r.timed_out or r.signaled:
        t.unattributed.append(
            _with_tail(
                tag + String(" (") + n + String(": ") + _names(group) + String("): `") + shown + String("` ")
                + r.describe() + String(" (stderr: ") + spec.stderr_path
                + String("): no unit of it was attributed"),
                r,
            )
        )
        return
    if len(t.failed) >= MAX_FAILED_UNITS:
        t.unattributed.append(
            tag + String(" (") + n + String("): ") + r.describe() + String("; not attributed: ")
            + String(MAX_FAILED_UNITS) + String(" failed units already named")
        )
        for i in range(len(group)):
            t.not_tried.append(group[i].copy())
        return
    t.batch_notes.append(
        tag + String(" (") + n + String("): `") + shown + String("` ") + r.describe() + String(" (stderr: ")
        + spec.stderr_path + String("; ") + where + String(")")
    )
    print(
        String("BUILD step: ") + tag + String(" failed (") + r.describe()
        + String("); building its units one at a time to name the failing ones"),
        file=_STDERR,
    )
    var failed_before = len(t.failed)
    var every_one_tried = True
    for i in range(len(group)):
        if len(t.failed) >= MAX_FAILED_UNITS:
            t.not_tried.append(group[i].copy())
            every_one_tried = False
            continue
        _run_unit(req, arts, group[i], runner, t)
        if t.cannot.byte_length() > 0:
            return
    if every_one_tried and len(t.failed) == failed_before:
        t.interference.append(
            tag + String(" (`") + shown + String("` ") + r.describe() + String(", stderr: ") + spec.stderr_path
            + String(") failed but each of its ") + String(len(group))
            + String(" unit(s) built alone: the units interfere or the build is flaky; never a pass")
        )


def _finish(units: List[String], head: String, notices: List[String], t: _Tally) -> BuildOutcome:
    """The outcome, first match (file header, step 4), and the lines."""
    var o: BuildOutcome
    if t.cannot.byte_length() > 0:
        var m = String("BUILD step: ") + t.cannot
        for i in range(len(t.paragraphs)):
            m += String("\n") + t.paragraphs[i]
        o = BuildOutcome(String(OUTCOME_INDETERMINATE), String(ERROR_CANNOT_TELL), m^)
    elif len(t.failed) > 0 or len(t.unattributed) > 0:
        var m: String
        var skip = 0
        if len(t.failed) > 0:
            m = (
                String("BUILD step: ") + String(len(t.failed)) + String(" of ") + String(len(units))
                + String(" unit(s) failed: ") + _names(t.failed)
            )
        else:
            m = String("BUILD step: ") + t.unattributed[0]
            skip = 1
        for i in range(len(t.paragraphs)):
            m += String("\n") + t.paragraphs[i]
        if len(t.not_tried) > 0:
            m += (
                String("\n") + String(len(t.not_tried)) + String(" unit(s) not tried after ")
                + String(MAX_FAILED_UNITS) + String(" failures: ") + _names(t.not_tried)
            )
        for i in range(len(t.batch_notes)):
            m += String("\n") + t.batch_notes[i]
        for i in range(skip, len(t.unattributed)):
            m += String("\n") + t.unattributed[i]
        for i in range(len(t.interference)):
            m += String("\n") + t.interference[i]
        o = BuildOutcome(String(OUTCOME_FAILED), String(ERROR_BUILD_FAILED), m^)
    elif len(t.interference) > 0:
        var m = String("BUILD step: ") + t.interference[0]
        for i in range(1, len(t.interference)):
            m += String("\n") + t.interference[i]
        for i in range(len(t.batch_notes)):
            m += String("\n") + t.batch_notes[i]
        o = BuildOutcome(String(OUTCOME_INDETERMINATE), String(ERROR_CANNOT_TELL), m^)
    else:
        o = BuildOutcome.succeeded(head + String(": ") + String(len(units)) + String(" unit(s) built"))
    for i in range(len(notices)):
        o.lines.append(notices[i].copy())
    for i in range(len(units)):
        if _contains(t.proven, units[i]):
            o.lines.append(String("BUILT ") + units[i])
    return o^


def build_affected_units[R: ProcessRunner](
    req: BuildRequest,
    arts: Artifacts,
    units: List[String],
    head: String,
    notices: List[String],
    mut runner: R,
) raises -> BuildOutcome:
    """Step 5 of the per-change check (file header): build `units`, in
    decision order, one run per shared build_targets command."""
    makedirs(req.log_dir, exist_ok=True)
    var t = _Tally()
    var groups = batch_groups(arts, units)
    var k = 0
    for g in range(len(groups)):
        if len(groups[g]) == 1:
            _run_unit(req, arts, groups[g][0], runner, t)
        else:
            k += 1
            _run_batch(req, arts, groups[g], k, runner, t)
        if t.cannot.byte_length() > 0:
            break
    return _finish(units, head, notices, t)
