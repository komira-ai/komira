# =============================================================================
# src/kci_build/affected.mojo -- the per-change check: a BUILD step run with
#   `--affected-by <base>` builds exactly the units the change reaches.
# =============================================================================
#
# `run_affected(req, result, recorder, runner, git)` (`run_build` hands a
# request with `affected_by` set here):
#
# 0. Checks that change nothing, each REFUSED before anything is recorded or
#    run: the platform is one kci releases; `--revision-id` and
#    `--affected-by` are full commit ids (KCI-E-REVISION); `--work-dir` an
#    absolute directory and `--log-dir` given (KCI-E-USAGE); the artifacts
#    read and validate, and hold what the check needs (kci_artifact
#    `require_affected_ready`: every unit names targets, every build system
#    owning a unit declares `affected` and `build_targets`), else
#    KCI-E-ARTIFACT.
# 1. The RUNNING record, BEFORE the first effect.
# 2. The change: revision.mojo `changed_files` (the checkout is the
#    revision, full history, nothing modified; then `git diff -z --name-only
#    --no-renames <base>...<revision>` into `<log>/_changed_files`). An EMPTY
#    change is REFUSED (KCI-E-AFFECTED-VACUOUS): a check over nothing is
#    never a pass.
# 2b. Each build system declaring `derive_checks`, in file order: its
#    command runs (cwd --work-dir, the affected command's placeholders,
#    `{units_file}` = `<log>/_declared_units.tsv`, every declared unit's
#    targets; stdout and stderr to `<log>/_derive_<bs>.stdout|.stderr`;
#    timeout as in step 3), and the checks it answers are added after the
#    declared ones under the file's rules (kci_artifact derive.mojo). A tool
#    that is not started for want of budget, fails or answers outside the
#    grammar is INDETERMINATE (KCI-E-AFFECTED); an answer BROKEN (its query
#    of the build graph failed) is FAILED (KCI-E-BUILD-FAILED), naming the
#    tool's reason, and nothing runs after it; an UNMATCHED
#    artifact target, or a derived check the file's rules refuse, is
#    REFUSED (KCI-E-ARTIFACT); an UNMATCHED check target is a NOTICE line
#    (stderr, and the outcome's lines before WOULD_BUILD / BUILT).
# 3. Each build system owning a unit, in file order: `<log>/_units_<bs>.tsv`
#    gets its units' targets (kci_artifact `units_file_text`), and its
#    affected command runs through the ProcessRunner (cwd --work-dir, stdout
#    and stderr to `<log>/_affected_<bs>.stdout|.stderr`, timeout
#    --build-timeout-s, or with --build-budget-s all that is left of it,
#    see affected_batch.mojo THE BUDGET; with nothing left it is not
#    started). A command that is not started, cannot be started, exits
#    non-zero, is killed or times out (a plain `timed out`, even under a
#    budget, so a hung command can use the whole budget left first), or
#    whose stdout breaks the answer grammar (kci_artifact
#    `parse_affected_answer`) is INDETERMINATE (KCI-E-AFFECTED): kci cannot
#    tell what the change reaches, and it never widens instead. An answer
#    BROKEN (the tool's query of its build graph failed: a target with an
#    unknown or invisible dependency, or any other failure of that query)
#    is FAILED (KCI-E-BUILD-FAILED), naming the tool's reason; nothing is
#    built and no later build system is asked.
#    Every build system is asked, even after a WIDENED.
# 4. The units to build, in unit order (artifacts, then checks): every
#    declared unit when any answer is WIDENED (the result's verdict WIDENED,
#    its reason `<build system>: <the tool's reason>` of the first); else
#    every unit some answer named (verdict AFFECTED). None is REFUSED
#    (KCI-E-AFFECTED-VACUOUS): a non-empty change reaching nothing means the
#    template does not cover the file, and that is never a pass.
#    PLAN stops here: one `WOULD_BUILD <unit>` line each, nothing built.
# 5. The units, built (affected_batch.mojo `build_affected_units`): one
#    run per group of units sharing a build_targets command (kci_artifact
#    `batch_groups`; one group for a file whose build systems share one).
#    A unit alone runs `render_targets_argv` with logs at
#    `<log>/<unit>.stdout|.stderr`; a group of two or more runs once as batch
#    k over the union of its targets (`render_batch_argv`), logs at
#    `<log>/_batch_<k>.stdout|.stderr` and its argv at `<log>/_batch_<k>.argv`.
#    A library's welded tests run inside its build. A batch that exits
#    non-zero is retried unit by unit to name the failing units, up to
#    MAX_FAILED_UNITS failures; a timed-out or killed batch is not retried.
#    With --build-budget-s, every run of this step 5 may take all that is
#    left of the budget, which counts from kci's own start (the steps above
#    and kci's start-up are charged to it); a run that times out is FAILED
#    and says `timed out after N min[ S s]` and names the budget (the step
#    2b and 3 commands time out INDETERMINATE instead), and a run with nothing
#    left is not started (its units are not built).
#    Any failed unit, unattributed batch or unit not built for want of
#    budget is FAILED (KCI-E-BUILD-FAILED); a
#    build that cannot be started is INDETERMINATE (KCI-E-CANNOT-TELL), and
#    so is a batch that failed while each of its units built alone (never a
#    pass). `BUILT <unit>` lines name exactly the units an exit-0 run
#    covered, whatever the outcome. Nothing is written under --release-dir,
#    there is no manifest and no release.json: nothing ships.
# 6. The result gets the step's row, the first error, and `affected_by`
#    (the base; the verdict, reason and units once step 4 decided them).
#    No `artifacts[]` row: nothing was built to ship.
#
# kci names no build tool and no path: what a change reaches, and which
# files widen it, are the affected command's to say.
#
# Encapsulation: owned values; no pointer, no wildcard origin.
# =============================================================================

from std.io import FileDescriptor
from std.os import makedirs
from std.os.path import isdir
from std.pathlib import Path

from kci_artifact import (
    AffectedValues,
    add_derived_checks,
    declared_units_file_text,
    parse_affected_answer,
    parse_derive_answer,
    render_derive_argv,
    unmatched_artifacts,
    read_artifacts,
    render_affected_argv,
    require_affected_ready,
    unit_names_of,
    units_file_text,
    units_of,
)
from kci_artifact_proto.artifact import Artifacts
from kci_api import (
    AFFECTED_VERDICT_AFFECTED,
    AFFECTED_VERDICT_WIDENED,
    ERROR_AFFECTED,
    ERROR_AFFECTED_VACUOUS,
    ERROR_ARTIFACT,
    ERROR_BUILD_FAILED,
    ERROR_CANNOT_TELL,
    ERROR_PLATFORM,
    ERROR_RESULT_FILE,
    ERROR_REVISION,
    ERROR_USAGE,
    OUTCOME_FAILED,
    OUTCOME_INDETERMINATE,
    OUTCOME_REFUSED,
    SCOPE_SELECTIVE,
    STEP_KIND_BUILD,
    ResultStep,
    RunRecorder,
    require_full_commit_id,
    require_release_platform,
)
from kci_api import RunResult as KciRunResult

from kci_build.affected_batch import affected_spec, budget_spent_text, budget_timeout_s, build_affected_units
from kci_build.request import BuildOutcome, BuildRequest
from kci_build.revision import changed_files
from kci_build.runner import ProcessRunner, RunResult, RunSpec

comptime _STDERR: FileDescriptor = FileDescriptor(2)


def _stop(outcome: String, error_id: String, why: String) -> BuildOutcome:
    return BuildOutcome(outcome.copy(), error_id.copy(), String("BUILD step: ") + why)


def _refused(error_id: String, why: String) -> BuildOutcome:
    return _stop(String(OUTCOME_REFUSED), error_id, why)


def _write(path: String, text: String) raises:
    var f = open(path, "w")
    f.write_bytes(text.as_bytes())
    f.close()


def _contains(xs: List[String], x: String) -> Bool:
    for i in range(len(xs)):
        if xs[i] == x:
            return True
    return False


def _tool_failed(bs: String, spec: RunSpec, why: String) -> BuildOutcome:
    return _stop(
        String(OUTCOME_INDETERMINATE),
        String(ERROR_AFFECTED),
        String("--affected-by: the affected command of build system '") + bs + String("', `")
        + spec.command_line() + String("`, ") + why
        + String(": kci cannot tell what the change reaches, and does not widen instead"),
    )


def _derive[R: ProcessRunner](
    req: BuildRequest, mut arts: Artifacts, changed_path: String, mut runner: R, mut notices: List[String]
) -> BuildOutcome:
    """Step 2b: each build system's derived checks, added to `arts`."""
    var declared_path = req.log_dir + String("/_declared_units.tsv")
    var declared = units_of(arts)
    var wrote = False
    for i in range(len(arts.build_systems)):
        if not arts.build_systems[i].derive_checks:
            continue
        var bs = arts.build_systems[i].name.copy()
        var argv: List[String]
        try:
            if not wrote:
                _write(declared_path, declared_units_file_text(arts))
                wrote = True
            argv = render_derive_argv(
                arts, bs,
                AffectedValues(changed_path.copy(), declared_path.copy(), req.affected_by.copy(), req.revision_id.copy()),
            )
        except e:
            return _stop(
                String(OUTCOME_INDETERMINATE), String(ERROR_CANNOT_TELL),
                String("--affected-by: build system '") + bs + String("': ") + String(e),
            )
        var timeout_s = budget_timeout_s(req, runner)
        var spec = affected_spec(argv, req, req.log_dir + String("/_derive_") + bs, timeout_s)
        var what = String("the derive_checks command of build system '") + bs + String("', `") + spec.command_line() + String("`, ")
        var cannot = String(": kci cannot tell which checks the build graph holds")
        if timeout_s < 1:
            return _stop(
                String(OUTCOME_INDETERMINATE), String(ERROR_AFFECTED),
                what + String("was not started: ") + budget_spent_text(req) + cannot,
            )
        print(String("BUILD step: derive_checks: ") + bs + String(": ") + spec.command_line(), file=_STDERR)
        var r: RunResult
        try:
            r = runner.run(spec)
        except e:
            return _stop(String(OUTCOME_INDETERMINATE), String(ERROR_AFFECTED), what + String("could not be started: ") + String(e) + cannot)
        if not r.ok():
            var why = r.describe() + String(" (stderr: ") + spec.stderr_path + String(")")
            if r.stderr_tail.byte_length() > 0:
                why += String("\n") + r.stderr_tail
            return _stop(String(OUTCOME_INDETERMINATE), String(ERROR_AFFECTED), what + why + cannot)
        try:
            var answer = parse_derive_answer(Path(spec.stdout_path).read_text(), declared)
            if answer.broken:
                print(String("BUILD step: derive_checks: ") + bs + String(": BROKEN ") + answer.reason, file=_STDERR)
                return _stop(
                    String(OUTCOME_FAILED),
                    String(ERROR_BUILD_FAILED),
                    String("--affected-by: ") + what + String("answered BROKEN: ") + answer.reason
                    + String(": its query of the build graph failed, so the check fails"),
                )
            var refused = unmatched_artifacts(arts, answer)
            if len(refused) > 0:
                var names = String("")
                for k in range(len(refused)):
                    names += String(" `") + refused[k] + String("`")
                return _refused(
                    String(ERROR_ARTIFACT),
                    String("--affected-by: the build graph holds no target an artifact names:") + names
                    + String(" (") + what + String("answered UNMATCHED): an artifact must name what a release builds"),
                )
            for k in range(len(answer.unmatched_units)):
                var n = String("NOTICE check '") + answer.unmatched_units[k] + String("' names `")
                n += answer.unmatched_targets[k] + String("`, which matches nothing in the build graph")
                print(String("BUILD step: derive_checks: ") + bs + String(": ") + n, file=_STDERR)
                notices.append(n^)
            try:
                add_derived_checks(arts, bs, answer, req.artifacts_file)
            except e:
                return _refused(String(ERROR_ARTIFACT), String("--affected-by: ") + String(e))
            print(
                String("BUILD step: derive_checks: ") + bs + String(": ") + String(len(answer.names))
                + String(" check(s) derived"),
                file=_STDERR,
            )
        except e:
            return _stop(
                String(OUTCOME_INDETERMINATE), String(ERROR_AFFECTED), what + String("answered outside the protocol: ") + String(e) + cannot
            )
    return BuildOutcome.succeeded(String(""))


struct _Decision(Copyable, Movable):
    """Step 4's answer: the verdict, its reason and the units, in unit order.

    Layout: owned values only. No pointer field."""

    var verdict: String
    var reason: String
    var units: List[String]

    def __init__(out self):
        self.verdict = String("")
        self.reason = String("")
        self.units = List[String]()


def _ask[R: ProcessRunner](
    req: BuildRequest, arts: Artifacts, changed_path: String, mut runner: R, mut decision: _Decision
) -> BuildOutcome:
    """Steps 3 and 4: every owning build system's answer, then the units."""
    var widened = False
    var reason = String("")
    var reached = List[String]()
    for i in range(len(arts.build_systems)):
        var bs = arts.build_systems[i].name.copy()
        var owned = unit_names_of(arts, bs)
        if len(owned) == 0:
            continue
        var units_path = req.log_dir + String("/_units_") + bs + String(".tsv")
        var argv: List[String]
        try:
            _write(units_path, units_file_text(arts, bs))
            argv = render_affected_argv(
                arts, bs,
                AffectedValues(changed_path.copy(), units_path.copy(), req.affected_by.copy(), req.revision_id.copy()),
            )
        except e:
            return _stop(
                String(OUTCOME_INDETERMINATE), String(ERROR_CANNOT_TELL),
                String("--affected-by: build system '") + bs + String("': ") + String(e),
            )
        var timeout_s = budget_timeout_s(req, runner)
        var spec = affected_spec(argv, req, req.log_dir + String("/_affected_") + bs, timeout_s)
        if timeout_s < 1:
            return _tool_failed(bs, spec, String("was not started: ") + budget_spent_text(req))
        print(String("BUILD step: affected: ") + bs + String(": ") + spec.command_line(), file=_STDERR)
        var r: RunResult
        try:
            r = runner.run(spec)
        except e:
            return _tool_failed(bs, spec, String("could not be started: ") + String(e))
        if not r.ok():
            var why = r.describe() + String(" (stderr: ") + spec.stderr_path + String(")")
            if r.stderr_tail.byte_length() > 0:
                why += String("\n") + r.stderr_tail
            return _tool_failed(bs, spec, why)
        var text: String
        try:
            text = Path(spec.stdout_path).read_text()
        except e:
            return _tool_failed(bs, spec, String("printed nothing kci can read: ") + String(e))
        try:
            var answer = parse_affected_answer(text, owned)
            if answer.broken:
                print(String("BUILD step: affected: ") + bs + String(": BROKEN ") + answer.reason, file=_STDERR)
                return _stop(
                    String(OUTCOME_FAILED),
                    String(ERROR_BUILD_FAILED),
                    String("--affected-by: build system '") + bs + String("' answered BROKEN: ") + answer.reason
                    + String(": its query of the build graph failed, so the check fails"),
                )
            if answer.widened:
                print(String("BUILD step: affected: ") + bs + String(": WIDENED ") + answer.reason, file=_STDERR)
                if not widened:
                    reason = bs + String(": ") + answer.reason
                widened = True
            else:
                print(
                    String("BUILD step: affected: ") + bs + String(": ") + String(len(answer.units))
                    + String(" unit(s)"),
                    file=_STDERR,
                )
                for k in range(len(answer.units)):
                    reached.append(answer.units[k].copy())
        except e:
            return _tool_failed(bs, spec, String("answered outside the protocol: ") + String(e))
    var all = units_of(arts)
    decision.verdict = String(AFFECTED_VERDICT_WIDENED) if widened else String(AFFECTED_VERDICT_AFFECTED)
    decision.reason = reason^
    for i in range(len(all)):
        if widened or _contains(reached, all[i].name):
            decision.units.append(all[i].name.copy())
    return BuildOutcome.succeeded(String(""))


def _affected[R: ProcessRunner, G: ProcessRunner, C: RunRecorder](
    req: BuildRequest,
    mut result: KciRunResult,
    mut recorder: C,
    mut runner: R,
    mut git: G,
    mut decision: _Decision,
) -> BuildOutcome:
    """Steps 0 to 5 of the file header."""
    try:
        require_release_platform(req.platform)
    except e:
        return _refused(String(ERROR_PLATFORM), String(e))
    try:
        require_full_commit_id(String("--revision-id"), req.revision_id)
        require_full_commit_id(String("--affected-by"), req.affected_by)
    except e:
        return _refused(String(ERROR_REVISION), String(e))
    try:
        if not req.work_dir.startswith(String("/")):
            return _refused(
                String(ERROR_USAGE),
                String("--work-dir '") + req.work_dir
                + String("' is not an absolute path: it is the cwd every build resolves against"),
            )
        if not isdir(req.work_dir):
            return _refused(String(ERROR_USAGE), String("--work-dir '") + req.work_dir + String("' is not a directory"))
        if req.log_dir.byte_length() == 0:
            return _refused(String(ERROR_USAGE), String("--log-dir is EMPTY"))
        var arts: Artifacts
        try:
            arts = read_artifacts(req.artifacts_file)
            require_affected_ready(arts, req.artifacts_file)
        except e:
            return _refused(String(ERROR_ARTIFACT), String(e))
        # ── step 1: RUNNING, before the first effect ────────────────────────
        result.revision = req.revision_id.copy()
        result.platform = req.platform.copy()
        result.set_run(req.run)
        result.scope = String(SCOPE_SELECTIVE)
        result.has_affected_by = True
        result.affected_base = req.affected_by.copy()
        try:
            recorder.begin(result.begin_record())
        except e:
            return _stop(
                String(OUTCOME_FAILED),
                String(ERROR_RESULT_FILE),
                String("the run's RUNNING record could not be written; nothing was done: ") + String(e),
            )
        makedirs(req.log_dir, exist_ok=True)
        # ── step 2: the change ──────────────────────────────────────────────
        var change = changed_files(req, git)
        if not change.ok():
            return BuildOutcome(change.outcome.copy(), change.error_id.copy(), change.message.copy())
        var span = req.affected_by + String("...") + req.revision_id
        if change.count == 0:
            return _refused(
                String(ERROR_AFFECTED_VACUOUS),
                String("--affected-by: the change ") + span
                + String(" touches no file: a check over nothing is never a pass"),
            )
        print(
            String("BUILD step: --affected-by: the change ") + span + String(" touches ")
            + String(change.count) + String(" file(s)"),
            file=_STDERR,
        )
        # ── step 2b: the derived checks ─────────────────────────────────────
        var notices = List[String]()
        var derived = _derive(req, arts, change.path, runner, notices)
        if not derived.ok():
            return derived^
        # ── steps 3 and 4: the answers, then the units ──────────────────────
        var asked = _ask(req, arts, change.path, runner, decision)
        if not asked.ok():
            return asked^
        if len(decision.units) == 0:
            return _refused(
                String(ERROR_AFFECTED_VACUOUS),
                String("--affected-by: the change ") + span + String(" touches ") + String(change.count)
                + String(" file(s) and reaches no declared unit (")
                + change.path + String("): a file no unit covers is never a pass; declare a unit")
                + String(" (an artifact or a check) whose targets cover it"),
            )
        var head = String("BUILD step: --affected-by ") + req.affected_by + String(": ") + decision.verdict
        if decision.reason.byte_length() > 0:
            head += String(" (") + decision.reason + String(")")
        if req.plan:
            var o = BuildOutcome.succeeded(
                head + String(": plan: ") + String(len(decision.units))
                + String(" unit(s) would be built; nothing was built"),
            )
            for i in range(len(notices)):
                o.lines.append(notices[i].copy())
            for i in range(len(decision.units)):
                o.lines.append(String("WOULD_BUILD ") + decision.units[i])
            return o^
        # ── step 5: the units, built ────────────────────────────────────────
        return build_affected_units(req, arts, decision.units, head, notices, runner)
    except e:
        return _stop(String(OUTCOME_FAILED), String(ERROR_BUILD_FAILED), String(e))


def run_affected[R: ProcessRunner, G: ProcessRunner, C: RunRecorder](
    req: BuildRequest, mut result: KciRunResult, mut recorder: C, mut runner: R, mut git: G
) -> BuildOutcome:
    """One BUILD step of the per-change check (file header). Never raises;
    the step's row, the first error and `affected_by` go into `result`."""
    var decision = _Decision()
    var o = _affected(req, result, recorder, runner, git, decision)
    result.scope = String(SCOPE_SELECTIVE)
    result.has_affected_by = True
    result.affected_base = req.affected_by.copy()
    result.affected_verdict = decision.verdict.copy()
    result.affected_reason = decision.reason.copy()
    result.affected_units = decision.units.copy()
    result.steps.append(
        ResultStep(req.step_name.copy(), String(STEP_KIND_BUILD), req.platform.copy(), o.outcome.copy())
    )
    if o.error_id.byte_length() > 0:
        try:
            result.set_error(o.error_id.copy(), o.message.copy())
        except e:
            return BuildOutcome(
                String(OUTCOME_INDETERMINATE),
                String(ERROR_CANNOT_TELL),
                o.message + String("\nBUILD step: the result document could not record this step: ") + String(e),
            )
    return o^
