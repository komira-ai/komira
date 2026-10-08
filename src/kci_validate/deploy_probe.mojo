# =============================================================================
# src/kci_validate/deploy_probe.mojo -- a DEPLOY_PROBE validation: run the
#   operator's digest-pinned image against the cell a DEPLOY step just
#   deployed into, and decide the verdict from what it wrote.
# =============================================================================
#
# `run_deploy_probe` runs one probe (`ProbeRequest`) in this order:
#
#   -  plan      under --plan nothing runs: WOULD_VALIDATE, no outcome, no
#                checks
#   -  reached   the DEPLOY step did not succeed: NOT_REACHED, nothing runs
#   -  scratch   `<scratch>/<validation>/`, fresh: work/out/ (the one
#                writable mount) and docker/ (the docker CLI's empty HOME and
#                DOCKER_CONFIG: images are pulled anonymously)
#   -  pre-flight `docker pull` of the --preflight-image digest, then its
#                container (probe_container.mojo): `nc -z` to the link-local
#                metadata address. ONLY exit 1 (nothing answered) lets the
#                probe run. Exit 0 (it answered), any other exit (125, 126,
#                127: docker could not run it), a signal, kci's timeout
#                around it (the container is then removed by name) or a
#                failed pull: INDETERMINATE, and the probe never runs
#   -  image     `docker pull <image@sha256>`
#   -  probe     `docker run` (probe_container.mojo) with timeout_seconds.
#                At the timeout, or when the docker client is killed, kci
#                runs `docker rm -f kci-probe-<id>` with the same docker
#                environment, and the container check says how that went
#   -  verdict   read back /work/out/results.jsonl (probe_results.mojo)
#
# THE VERDICT (kci decides; the image never does):
#
#   every `expect` id has exactly one row, outcome `pass`; no other rows; the
#     container exited 0                                    VALIDATED, SUCCEEDED
#   an `expect` id has no row, an id is not in `expect`, an id appears twice,
#     a row is not `pass`, a line is malformed, the exit is not 0, or the
#     timeout was reached                                   VALIDATED, VALIDATION_FAILED (7)
#   a pull fails, docker cannot be started, the container cannot start
#     (docker's 125, 126, 127), the scratch directory cannot be made, or the
#     pre-flight connect succeeds or cannot run            VALIDATED, INDETERMINATE (5),
#                                                           with a skip_reason; never a pass
#   the DEPLOY step did not succeed                         NOT_REACHED
#
# ONE ROW, environment CONTAINER. Its checks are one per `expect` id and one
# per other id the image wrote (probe_results.mojo), then the checks kci
# makes itself, each named `kci:<what>` (a case id cannot hold `:`):
# CHECK_CONTAINER (the exit, the timeout and the removal), CHECK_RESULTS (a
# malformed file), CHECK_PREFLIGHT, CHECK_IMAGE, CHECK_SCRATCH. A SUCCEEDED
# row holds at least one check and every check ok, so an image that writes
# nothing never passes.
#
# The probe's validation run id is `probe_run_id` (probe_container.mojo); it
# is passed to the image as `--validation-run-id=<id>` and names the
# containers. The expiry sweep of containers a killed kci left behind is
# probe_sweep.mojo's, run once at kci's start, not here.
#
# The seam is kci_build's `ProcessRunner` (SupervisorRunner for real,
# ScriptedRunner in the welded tests). Nothing here reads a clock.
#
# Encapsulation: owned values; no pointer, no wildcard origin.
# =============================================================================

from std.os import listdir, makedirs
from std.os.path import exists, isdir

from kci_api import (
    OUTCOME_INDETERMINATE,
    OUTCOME_SUCCEEDED,
    OUTCOME_VALIDATION_FAILED,
    VALIDATION_ENVIRONMENT_CONTAINER,
    VALIDATION_KIND_DEPLOY_PROBE,
    VALIDATION_NOT_REACHED,
    VALIDATION_VALIDATED,
    VALIDATION_WOULD_VALIDATE,
    ResultValidation,
    ResultValidationCheck,
)
from kci_build.runner import ProcessRunner, RunResult, RunSpec
from kci_release_machine import StageValidation, is_digest_pinned_image

from .container import docker_child_env, join_path, pull_argv
from .probe_container import (
    DOCKER_SHORT_TIMEOUT_S,
    PREFLIGHT_ADDRESS,
    PREFLIGHT_PORT,
    PREFLIGHT_TIMEOUT_S,
    PROBE_PULL_TIMEOUT_S,
    preflight_container_name,
    preflight_run_argv,
    probe_container_name,
    probe_run_argv,
    probe_run_id,
    remove_argv,
)
from .probe_results import RESULTS_FILE, probe_case_checks, read_probe_rows
from .request import ContainerHost

comptime CHECK_CONTAINER: String = "kci:container"
comptime CHECK_PREFLIGHT: String = "kci:preflight"
comptime CHECK_IMAGE: String = "kci:image"
comptime CHECK_SCRATCH: String = "kci:scratch"

comptime PREFLIGHT_UNPINNED_DIGEST: String = "sha256:0000000000000000000000000000000000000000000000000000000000000000"
"""The digest of the platform table's placeholder for a helper image whose
pin is not recorded yet (tools/build/platforms/table.bzl
`preflight_image`). A --preflight-image with it is refused wherever a probe
would run: the placeholder fails closed."""


def is_unpinned_preflight_image(image: String) -> Bool:
    """Whether `image` is the platform table's placeholder (its digest is
    PREFLIGHT_UNPINNED_DIGEST)."""
    return image.endswith(String("@") + String(PREFLIGHT_UNPINNED_DIGEST))


def preflight_image_refusal(image: String) -> String:
    """"" when `image` can be the pre-flight's helper image; why not
    otherwise: a tag, or the table's unpinned placeholder."""
    if not is_digest_pinned_image(image):
        return (
            String("--preflight-image '") + image
            + String("' is not pinned by digest, <reference>@sha256:<64 lowercase hex> (a tag is refused)")
        )
    if is_unpinned_preflight_image(image):
        return (
            String("--preflight-image '") + image
            + String("' is the platform table's placeholder: the helper image's pin is not recorded yet")
        )
    return String("")


struct ProbeRequest(Copyable, Movable):
    """One DEPLOY_PROBE validation of one DEPLOY step.

    `target_url` is the value of the probe's `target`, read from this run's
    recorded outputs by the caller ("" when the probe has no target);
    `step_succeeded` says whether the DEPLOY step it checks succeeded.

    Layout: owned values only. No pointer field."""

    var step_name: String
    var validation: StageValidation
    var run_id: String
    var attempt: Int
    var target_url: String
    var scratch_dir: String
    var preflight_image: String
    var plan: Bool
    var step_succeeded: Bool

    def __init__(out self, var validation: StageValidation):
        self.step_name = String("")
        self.validation = validation^
        self.run_id = String("")
        self.attempt = 0
        self.target_url = String("")
        self.scratch_dir = String("")
        self.preflight_image = String("")
        self.plan = False
        self.step_succeeded = True

    def validation_run_id(self) -> String:
        return probe_run_id(self.run_id, self.attempt, self.validation.name)


def _row(req: ProbeRequest, effect: String) -> ResultValidation:
    ref v = req.validation
    return ResultValidation(v.name.copy(), req.step_name.copy(), v.kind.copy(), effect.copy(), String(""))


def _finish(var row: ResultValidation, var checks: List[ResultValidationCheck]) -> ResultValidation:
    var all_ok = len(checks) > 0
    for i in range(len(checks)):
        if not checks[i].ok:
            all_ok = False
    row.outcome = String(OUTCOME_SUCCEEDED) if all_ok else String(OUTCOME_VALIDATION_FAILED)
    row.checks = checks^
    return row^


def _indeterminate(
    var row: ResultValidation, var checks: List[ResultValidationCheck], var check: ResultValidationCheck
) -> ResultValidation:
    """INDETERMINATE: `check` says what could not run; it is the skip
    reason too."""
    row.skip_reason = check.got.copy()
    checks.append(check^)
    row.outcome = String(OUTCOME_INDETERMINATE)
    row.checks = checks^
    return row^


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


def _docker_spec(host: ContainerHost, dir: String, var argv: List[String], timeout_s: Int, what: String) raises -> RunSpec:
    var spec = RunSpec(
        host.docker.copy(), argv^, dir.copy(), timeout_s,
        join_path(dir, what + String(".stdout")), join_path(dir, what + String(".stderr")),
    )
    spec.set_env(docker_child_env(join_path(dir, String("docker")), host.path_env))
    return spec^


def _describe(r: RunResult) -> String:
    var s = r.describe()
    if not r.ok() and r.stderr_tail.byte_length() > 0:
        s += String(": ") + String(r.stderr_tail.strip())
    return s^


def _cannot_start(r: RunResult) -> Bool:
    """docker's own exits: 125 (the daemon could not run the container), 126
    (its command cannot be invoked), 127 (its command was not found)."""
    if r.timed_out or r.signaled:
        return False
    return r.exit_code == Int32(125) or r.exit_code == Int32(126) or r.exit_code == Int32(127)


def _remove[R: ProcessRunner](mut runner: R, host: ContainerHost, dir: String, name: String) -> String:
    """`docker rm -f <name>`, said in words."""
    try:
        var r = runner.run(_docker_spec(host, dir, remove_argv(name), DOCKER_SHORT_TIMEOUT_S, String("rm")))
        return String("docker rm -f ") + name + String(": ") + _describe(r)
    except e:
        return String("docker rm -f ") + name + String(": not started: ") + String(e)


def _preflight[R: ProcessRunner](
    mut runner: R, req: ProbeRequest, host: ContainerHost, dir: String, id: String
) -> ResultValidationCheck:
    """The pre-flight (file header): ok only when the connect exits 1."""
    var expected = (
        String("nc -z to ") + String(PREFLIGHT_ADDRESS) + String(":") + String(PREFLIGHT_PORT)
        + String(" exits 1: the link-local metadata address does not answer")
    )
    var got: String
    try:
        var pull = runner.run(
            _docker_spec(host, dir, pull_argv(req.preflight_image), PROBE_PULL_TIMEOUT_S, String("preflight_pull"))
        )
        if not pull.ok():
            return ResultValidationCheck(
                String(CHECK_PREFLIGHT), expected^,
                String("the pre-flight cannot run: docker pull ") + req.preflight_image + String(": ") + _describe(pull),
                False,
            )
        var r = runner.run(
            _docker_spec(
                host, dir, preflight_run_argv(req.preflight_image, host.user, id), PREFLIGHT_TIMEOUT_S,
                String("preflight"),
            )
        )
        if r.timed_out or r.signaled:
            got = (
                String("the pre-flight cannot run: ") + r.describe() + String("; ")
                + _remove(runner, host, dir, preflight_container_name(id))
            )
            return ResultValidationCheck(String(CHECK_PREFLIGHT), expected^, got^, False)
        if r.exit_code == Int32(1):
            return ResultValidationCheck(String(CHECK_PREFLIGHT), expected^, String("exit 1: nothing answered"), True)
        if r.exit_code == Int32(0):
            got = (
                String("exit 0: ") + String(PREFLIGHT_ADDRESS) + String(":") + String(PREFLIGHT_PORT)
                + String(" answered, so a probe could reach this host's metadata credentials; the runner's")
                + String(" host rule is missing (docs/ci.md)")
            )
            return ResultValidationCheck(String(CHECK_PREFLIGHT), expected^, got^, False)
        return ResultValidationCheck(
            String(CHECK_PREFLIGHT), expected^, String("the pre-flight cannot run: ") + _describe(r), False
        )
    except e:
        return ResultValidationCheck(
            String(CHECK_PREFLIGHT), expected^, String("the pre-flight cannot run: not started: ") + String(e), False
        )


def run_deploy_probe[R: ProcessRunner](mut runner: R, req: ProbeRequest, host: ContainerHost) raises -> ResultValidation:
    """One DEPLOY_PROBE validation (file header). RAISES only on a caller's
    error: another kind, a probe with a target and no target URL, or a
    --preflight-image that `preflight_image_refusal` refuses (kci refuses
    those at start)."""
    ref v = req.validation
    if v.kind != VALIDATION_KIND_DEPLOY_PROBE:
        raise Error(
            String("validation '") + v.name + String("' is ") + v.kind + String(", not ")
            + String(VALIDATION_KIND_DEPLOY_PROBE)
        )
    if v.target_resource.byte_length() > 0 and req.target_url.byte_length() == 0:
        raise Error(String("validation '") + v.name + String("' has a target and was given no target URL"))
    var refusal = preflight_image_refusal(req.preflight_image)
    if refusal.byte_length() > 0:
        raise Error(String("validation '") + v.name + String("': ") + refusal)
    if req.plan:
        return _row(req, String(VALIDATION_WOULD_VALIDATE))
    if not req.step_succeeded:
        return _row(req, String(VALIDATION_NOT_REACHED))
    var row = _row(req, String(VALIDATION_VALIDATED))
    row.environment = String(VALIDATION_ENVIRONMENT_CONTAINER)
    var checks = List[ResultValidationCheck]()
    var id = req.validation_run_id()

    # the scratch directory
    var dir = join_path(req.scratch_dir, v.name)
    var work = join_path(dir, String("work"))
    var why = String("")
    if not req.scratch_dir.startswith(String("/")):
        why = String("--scratch-dir '") + req.scratch_dir + String("' is not an absolute path (docker mounts it)")
    else:
        why = _fresh_dir(dir)
    if why.byte_length() == 0:
        try:
            makedirs(join_path(work, String("out")), exist_ok=True)
            makedirs(join_path(dir, String("docker")), exist_ok=True)
        except e:
            why = String(e)
    if why.byte_length() > 0:
        return _indeterminate(
            row^, checks^,
            ResultValidationCheck(String(CHECK_SCRATCH), String("a fresh ") + dir, String("the probe cannot run: ") + why, False),
        )

    # the pre-flight: only its exit 1 lets the probe run
    var pre = _preflight(runner, req, host, dir, id)
    if not pre.ok:
        return _indeterminate(row^, checks^, pre^)
    checks.append(pre^)

    # the image
    var expected_pull = String("docker pull ") + v.image + String(" exits 0")
    try:
        var pull = runner.run(_docker_spec(host, dir, pull_argv(v.image), PROBE_PULL_TIMEOUT_S, String("pull")))
        if not pull.ok():
            return _indeterminate(
                row^, checks^,
                ResultValidationCheck(
                    String(CHECK_IMAGE), expected_pull^, String("the probe cannot run: ") + _describe(pull), False
                ),
            )
    except e:
        return _indeterminate(
            row^, checks^,
            ResultValidationCheck(
                String(CHECK_IMAGE), expected_pull^, String("the probe cannot run: docker not started: ") + String(e),
                False,
            ),
        )
    checks.append(ResultValidationCheck(String(CHECK_IMAGE), expected_pull^, String("exit 0"), True))

    # the probe
    var name = probe_container_name(id)
    var expected_run = String("docker run --name ") + name + String(" exits 0 within ") + String(v.timeout_seconds) + String("s")
    var container: ResultValidationCheck
    try:
        var r = runner.run(
            _docker_spec(
                host, dir, probe_run_argv(v.image, work, host.user, id, v.timeout_seconds, v.args, req.target_url),
                v.timeout_seconds, String("run"),
            )
        )
        if _cannot_start(r):
            return _indeterminate(
                row^, checks^,
                ResultValidationCheck(
                    String(CHECK_CONTAINER), expected_run^, String("the container cannot start: ") + _describe(r), False
                ),
            )
        if r.timed_out or r.signaled:
            container = ResultValidationCheck(
                String(CHECK_CONTAINER), expected_run^,
                r.describe() + String("; ") + _remove(runner, host, dir, name), False,
            )
        else:
            container = ResultValidationCheck(String(CHECK_CONTAINER), expected_run^, _describe(r), r.ok())
    except e:
        return _indeterminate(
            row^, checks^,
            ResultValidationCheck(
                String(CHECK_CONTAINER), expected_run^, String("the probe cannot run: docker not started: ") + String(e),
                False,
            ),
        )

    # the verdict, from what the image wrote
    var cases = probe_case_checks(v.expects, read_probe_rows(join_path(join_path(work, String("out")), String(RESULTS_FILE))))
    for i in range(len(cases)):
        checks.append(cases[i].copy())
    checks.append(container^)
    return _finish(row^, checks^)
