# =============================================================================
# src/kci_validate/conda_install_smoke.mojo -- a CONDA_INSTALL_SMOKE
#   validation: install what a PUBLISH step published, from that step's
#   channel, the way a consumer gets it, inside a digest-pinned container,
#   and run a program against it.
# =============================================================================
#
# `run_install_smoke` runs one validation (`ValidateRequest`, request.mojo)
# in this order; the first four checks are the shell reference's
# (tools/build/package/validate_published.sh), in its order and its words:
#
#   0  release   the release directory of the step's platform, built from
#                --revision-id, every member verified; the channel's
#                location from the channels file; each `install` name a
#                conda member of the set, pinned to release.json's version,
#                build and sha256 (metadata.json: payload path and sha256,
#                mojo_pin)
#   1  channel   ANONYMOUS reads from this machine (channel_index.mojo): the
#                index lists every pinned file with its sha256 and serves
#                those bytes; the absence of a file is waited for up to
#                `wait_for_index_seconds`, then it is a failure
#   -  scratch   `<scratch>/<validation>/`, fresh; work/pixi.toml and a copy
#                of the program (container.mojo)
#   -  image     `docker pull <image@sha256>`
#   -  container `docker run` of the install and the program: pixi install,
#                the payloads' sha256, mojo run (container.mojo)
#   2  install   read back: the install's exit, then every conda-meta record
#                (readback.mojo)
#   3  payload   each library's installed payload is the build's
#   4  program   `<stem> validation: N of N checks passed`, N > 0
#
# FAIL CLOSED. Every way this can go wrong is VALIDATION_FAILED with a check
# row: there is no SKIP, and a validation that could not run is a validation
# that failed. A failed phase before the container ends the validation (a
# failed channel check never installs: it would test something other than
# this release); after the container, checks 3 and 4 are read even when 2
# found something, as the reference does, unless the install itself failed.
#
# Under `--plan` nothing runs: no request, no container, no directory. The
# row says WOULD_VALIDATE with no outcome and no checks, so it can never read
# as a pass (kci_api refuses a WOULD_VALIDATE row with either).
#
# The seams: kci_build's `ProcessRunner` starts docker (SupervisorRunner for
# real, ScriptedRunner in the welded tests, which plays the container by
# writing what it would leave in the mount); kci_pkg_upload's `PkgTransport`
# reads the channel (ScriptedPkgTransport in the tests); komira_retry's
# `Sleeper` waits; an `IndexPollLog` says each poll of the index
# (StderrIndexPollLog in the CLI, RecordingIndexPollLog in the tests). Nothing here names a channel, a package or an
# organisation.
#
# Encapsulation: owned values; no pointer, no wildcard origin.
# =============================================================================

from std.os import listdir, makedirs
from std.os.path import exists, isdir

from komira_retry import Sleeper

from kci_build.runner import ProcessRunner, RunSpec
from kci_api import (
    OUTCOME_SUCCEEDED,
    OUTCOME_VALIDATION_FAILED,
    VALIDATION_KIND_CONDA_INSTALL_SMOKE,
    VALIDATION_VALIDATED,
    VALIDATION_WOULD_VALIDATE,
    ResultValidation,
    ResultValidationCheck,
)
from kci_pkg_upload import PkgTransport

from .channel_index import IndexPollLog, check_channel
from .container import (
    MANIFEST_NAME,
    PROGRAM_COPY,
    PULL_TIMEOUT_S,
    RUN_TIMEOUT_S,
    container_script,
    docker_child_env,
    install_manifest_text,
    join_path,
    pull_argv,
    run_argv,
    work_subdirs,
)
from .readback import check_installed, check_payloads, check_program, install_exited_zero
from .request import ContainerHost, InstallPin, ValidateRequest, install_pins, load_validated_release, mojo_pin_of


def _finish(var row: ResultValidation, var checks: List[ResultValidationCheck]) -> ResultValidation:
    var all_ok = len(checks) > 0
    for i in range(len(checks)):
        if not checks[i].ok:
            all_ok = False
    row.outcome = String(OUTCOME_SUCCEEDED) if all_ok else String(OUTCOME_VALIDATION_FAILED)
    row.checks = checks^
    return row^


def _run_checked[R: ProcessRunner](
    mut runner: R, var spec: RunSpec, check: String, expected: String, mut checks: List[ResultValidationCheck]
) -> Bool:
    """Run `spec`; append the check (`exit 0` expected); True when it exited
    0. A process that cannot be started is a failed check."""
    var got: String
    var ok = False
    try:
        var r = runner.run(spec)
        got = spec.path + String(" ") + spec.argv[0] + String(": ") + r.describe()
        ok = r.ok()
        if not ok and r.stderr_tail.byte_length() > 0:
            got += String(": ") + String(r.stderr_tail.strip())
    except e:
        got = spec.path + String(" ") + spec.argv[0] + String(": not started: ") + String(e)
    checks.append(ResultValidationCheck(check.copy(), expected.copy(), got^, ok))
    return ok


def _fresh_dir(dir: String) -> String:
    """"" when `dir` is absent or empty; why it is not, otherwise."""
    try:
        if not exists(dir):
            return String("")
        if not isdir(dir):
            return String("exists and is not a directory")
        if len(listdir(dir)) > 0:
            return String("exists and is not empty")
        return String("")
    except e:
        return String(e)


def run_install_smoke[R: ProcessRunner, T: PkgTransport, S: Sleeper, L: IndexPollLog](
    mut runner: R, mut transport: T, mut sleeper: S, mut log: L, req: ValidateRequest, host: ContainerHost
) raises -> ResultValidation:
    """One CONDA_INSTALL_SMOKE validation (file header); each poll of the
    channel's index is a line on `log`. RAISES only on a
    caller's error (another kind); everything about the release, the
    channel, the container and the program is a failed check."""
    ref v = req.validation
    if v.kind != VALIDATION_KIND_CONDA_INSTALL_SMOKE:
        raise Error(
            String("validation '") + v.name + String("' is ") + v.kind + String(", not ")
            + String(VALIDATION_KIND_CONDA_INSTALL_SMOKE)
        )
    if req.plan:
        return ResultValidation(
            v.name.copy(), req.step_name.copy(), v.kind.copy(), String(VALIDATION_WOULD_VALIDATE), String("")
        )
    var row = ResultValidation(
        v.name.copy(), req.step_name.copy(), v.kind.copy(), String(VALIDATION_VALIDATED), String("")
    )
    var checks = List[ResultValidationCheck]()

    # 0. the release, the channel's location, the pins
    var pins: List[InstallPin]
    var mojo_pin: String
    var channel_url: String
    try:
        var rel = load_validated_release(req)
        pins = install_pins(rel.loaded, v.installs)
        mojo_pin = mojo_pin_of(rel.loaded)
        channel_url = rel.channel_url.copy()
    except e:
        checks.append(
            ResultValidationCheck(
                String("release"),
                String("the release of step '") + req.step_name + String("' and a pin for every install name"),
                String("release: ") + String(e),
                False,
            )
        )
        return _finish(row^, checks^)
    var names = String("")
    for i in range(len(pins)):
        if i > 0:
            names += String(", ")
        names += pins[i].file_name()
    checks.append(
        ResultValidationCheck(
            String("release"),
            String("a pin for every install name"),
            String("release: ") + names + String(" with mojo-compiler ") + mojo_pin,
            True,
        )
    )

    # 1. the channel, anonymously, from this machine
    if not check_channel(transport, sleeper, log, channel_url, pins, v.wait_for_index_seconds, checks):
        return _finish(row^, checks^)

    # the scratch directory, the manifest, the program's copy
    var dir = join_path(req.scratch_dir, v.name)
    var work = join_path(dir, String("work"))
    var docker_dir = join_path(dir, String("docker"))
    var why = String("")
    if not req.scratch_dir.startswith(String("/")):
        why = String("--scratch-dir '") + req.scratch_dir + String("' is not an absolute path (docker mounts it)")
    else:
        why = _fresh_dir(dir)
    if why.byte_length() == 0:
        try:
            makedirs(work, exist_ok=True)
            makedirs(docker_dir, exist_ok=True)
            var subs = work_subdirs()
            for i in range(len(subs)):
                makedirs(join_path(work, subs[i]), exist_ok=True)
            var subdir = pins[0].subdir.copy()
            var f = open(join_path(work, String(MANIFEST_NAME)), "w")
            f.write_bytes(install_manifest_text(v, channel_url, subdir, pins, mojo_pin).as_bytes())
            f.close()
            var program = open(join_path(req.repo_root, v.program), "r").read()
            var g = open(join_path(work, String(PROGRAM_COPY)), "w")
            g.write_bytes(program.as_bytes())
            g.close()
        except e:
            why = String(e)
    checks.append(
        ResultValidationCheck(
            String("scratch"),
            String("a fresh ") + dir + String(" holding pixi.toml and a copy of ") + v.program,
            String("ready") if why.byte_length() == 0 else why.copy(),
            why.byte_length() == 0,
        )
    )
    if why.byte_length() > 0:
        return _finish(row^, checks^)

    # the image, then the container
    var env = docker_child_env(docker_dir, host.path_env)
    var pull = RunSpec(
        host.docker.copy(), pull_argv(v.image), dir.copy(), PULL_TIMEOUT_S,
        join_path(dir, String("pull.stdout")), join_path(dir, String("pull.stderr")),
    )
    pull.set_env(env.copy())
    if not _run_checked(runner, pull^, String("image"), String("docker pull ") + v.image + String(" exits 0"), checks):
        return _finish(row^, checks^)
    var run = RunSpec(
        host.docker.copy(), run_argv(v.image, work, host.user, container_script(pins)), dir.copy(), RUN_TIMEOUT_S,
        join_path(dir, String("run.stdout")), join_path(dir, String("run.stderr")),
    )
    run.set_env(env^)
    if not _run_checked(runner, run^, String("container"), String("docker run exits 0"), checks):
        return _finish(row^, checks^)

    # 2 to 4, read back from the mount
    var out_dir = join_path(work, String("out"))
    if not install_exited_zero(out_dir, checks):
        return _finish(row^, checks^)
    _ = check_installed(work, v, channel_url, pins, mojo_pin, checks)
    _ = check_payloads(out_dir, pins, checks)
    _ = check_program(out_dir, v.program, checks)
    return _finish(row^, checks^)
