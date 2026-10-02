# =============================================================================
# src/kci_build/build.mojo -- build the whole publishable set in one buck2
#   invocation, then read what it built from the build report.
# =============================================================================
#
#   <buck2> build -c komira.execution=remote [-c k=v ...] [--target-platforms P]
#           --build-report <log_dir>/build_report.json
#           <t1> <t1>[manifest] <t2> <t2>[manifest] ...
#
# One invocation, so the farm builds the set in parallel. A run that fails
# with a farm fault (`Failed to create build directory` ... `file exists`,
# a known fault of the farm's workers, not of the build) has each target it
# did not build rebuilt alone, up to `FARM_FAULT_ATTEMPTS` times, every
# attempt logged separately. Any other failure is final: FAILED, naming the
# failed targets and the log. After a successful build each target must
# have exactly one default output and exactly one `[manifest]` output, or it
# is REFUSED as not publishable.
#
# Encapsulation: owned values; no pointer, no wildcard origin.
# =============================================================================

from std.os.path import isfile
from std.pathlib import Path

from kci_build.allowlist import PublishableEntry
from kci_build.preflight import config_args, failure_text, log_spec
from kci_build.report import TargetResult, read_build_report
from kci_build.request import (
    EXIT_CANNOT_TELL,
    EXIT_FAILED,
    EXIT_OK,
    EXIT_REFUSED,
    FARM_FAULT_ATTEMPTS,
    MANIFEST_SUB_TARGET,
    BuildOutcome,
    BuildRequest,
)
from kci_build.runner import ProcessRunner, RunResult, RunSpec


def is_farm_fault(stderr_text: String) -> Bool:
    """True iff buck2's stderr reports the farm's build-directory fault."""
    var low = stderr_text.lower()
    return (
        low.find(String("failed to create build directory")) >= 0
        and low.find(String("file exists")) >= 0
    )


def _read_or_empty(path: String) -> String:
    try:
        return Path(path).read_text()
    except:
        return String("")


def _build_argv(req: BuildRequest, report_path: String, targets: List[String]) -> List[String]:
    var a = List[String]()
    a.append(String("build"))
    a.extend(config_args(req))
    a.append(String("--build-report"))
    a.append(report_path.copy())
    for i in range(len(targets)):
        a.append(targets[i].copy())
        a.append(targets[i] + String("[") + String(MANIFEST_SUB_TARGET) + String("]"))
    return a^


def _failed_list(results: List[TargetResult]) -> String:
    var s = String("")
    for i in range(len(results)):
        if results[i].found and results[i].success:
            continue
        if s.byte_length() > 0:
            s += String("; ")
        s += results[i].target
        if results[i].error.byte_length() > 0:
            s += String(": ") + results[i].error
        elif not results[i].found:
            s += String(": not in the build report")
    return s^


struct _Attempt(Movable):
    var outcome: BuildOutcome
    var results: List[TargetResult]
    var faulted: Bool

    def __init__(out self, var outcome: BuildOutcome, var results: List[TargetResult], faulted: Bool):
        self.outcome = outcome^
        self.results = results^
        self.faulted = faulted


def _attempt[R: ProcessRunner](
    req: BuildRequest, targets: List[String], name: String, mut runner: R
) raises -> _Attempt:
    """One buck2 build of `targets`. `outcome` is OK only when buck2
    succeeded and its report was read; `faulted` says the failure was a
    farm fault, so the failed targets may be rebuilt."""
    var report = req.log_dir + String("/") + name + String("_report.json")
    var spec = log_spec(req, _build_argv(req, report, targets), name, req.build_timeout_s)
    var r = runner.run(spec)
    var results = List[TargetResult]()
    var report_error = String("")
    if isfile(report):
        try:
            results = read_build_report(report, targets, String(MANIFEST_SUB_TARGET))
        except e:
            report_error = String(e)
    else:
        report_error = String("buck2 wrote no build report at '") + report + String("'")
    if r.ok():
        if report_error.byte_length() > 0:
            return _Attempt(
                BuildOutcome(
                    EXIT_CANNOT_TELL,
                    String("kci build: buck2 build succeeded but ") + report_error,
                ),
                results^,
                False,
            )
        return _Attempt(BuildOutcome(EXIT_OK, String("")), results^, False)
    var faulted = not r.timed_out and is_farm_fault(_read_or_empty(spec.stderr_path))
    var why = String("kci build: buck2 build ") + failure_text(spec, r)
    if len(results) > 0:
        var failed = _failed_list(results)
        if failed.byte_length() > 0:
            why += String("\nfailed: ") + failed
    return _Attempt(BuildOutcome(EXIT_FAILED, why^), results^, faulted)


def _rebuild_alone[R: ProcessRunner](
    req: BuildRequest, target: String, index: Int, mut runner: R
) raises -> _Attempt:
    """Rebuild one target after a farm fault, up to FARM_FAULT_ATTEMPTS
    times; stop at the first success or at a failure that is not a fault."""
    var one = List[String]()
    one.append(target.copy())
    var last = _Attempt(BuildOutcome(EXIT_FAILED, String("")), List[TargetResult](), True)
    for attempt in range(1, FARM_FAULT_ATTEMPTS + 1):
        var name = String("rebuild_") + String(index) + String("_attempt_") + String(attempt)
        print(
            String("kci build: farm fault; rebuilding ")
            + target
            + String(" alone (attempt ")
            + String(attempt)
            + String(" of ")
            + String(FARM_FAULT_ATTEMPTS)
            + String("), log ")
            + req.log_dir
            + String("/")
            + name
            + String(".stderr")
        )
        last = _attempt(req, one, name, runner)
        if last.outcome.ok() or not last.faulted:
            return last^
    last.outcome.message = (
        String("kci build: ")
        + target
        + String(": the farm fault persisted through ")
        + String(FARM_FAULT_ATTEMPTS)
        + String(" rebuilds\n")
        + last.outcome.message
    )
    return last^


def build_targets[R: ProcessRunner](
    req: BuildRequest, entries: List[PublishableEntry], mut runner: R, mut results: List[TargetResult]
) raises -> BuildOutcome:
    """Build every entry (see the file header). On OK, `results` holds one
    publishable `TargetResult` per entry, in entry order."""
    var targets = List[String]()
    for i in range(len(entries)):
        targets.append(entries[i].target.copy())
    var first = _attempt(req, targets, String("build"), runner)
    results = first.results.copy()
    if not first.outcome.ok():
        if not first.faulted:
            return first.outcome.copy()
        for i in range(len(targets)):
            var built = False
            for j in range(len(results)):
                if results[j].target == targets[i] and results[j].found and results[j].success:
                    built = True
            if built:
                continue
            var again = _rebuild_alone(req, targets[i], i, runner)
            if not again.outcome.ok():
                return again.outcome.copy()
            var replaced = False
            for j in range(len(results)):
                if results[j].target == targets[i]:
                    results[j] = again.results[0].copy()
                    replaced = True
            if not replaced:
                results.append(again.results[0].copy())
    for i in range(len(targets)):
        var found = False
        for j in range(len(results)):
            if results[j].target != targets[i]:
                continue
            found = True
            ref tr = results[j]
            var why = String("")
            if not tr.found:
                why = String("not in the build report")
            elif not tr.success:
                why = String("did not build: ") + tr.error
            elif len(tr.default_outputs) != 1:
                why = (
                    String("has ")
                    + String(len(tr.default_outputs))
                    + String(" default outputs, not one package file")
                )
            elif len(tr.sub_outputs) != 1:
                why = (
                    String("has ")
                    + String(len(tr.sub_outputs))
                    + String(" [")
                    + String(MANIFEST_SUB_TARGET)
                    + String("] outputs, not one artifact manifest")
                )
            if why.byte_length() > 0:
                return BuildOutcome(
                    EXIT_REFUSED,
                    String("kci build: ") + targets[i] + String(": not publishable: ") + why,
                )
        if not found:
            return BuildOutcome(
                EXIT_REFUSED,
                String("kci build: ") + targets[i] + String(": not publishable: not in the build report"),
            )
    return BuildOutcome(EXIT_OK, String(""))
