# =============================================================================
# src/kci_build/preflight.mojo -- prove the farm is there before building
#   anything, and stop at once if it is not.
# =============================================================================
#
#   1. `--buck2` is an absolute path to an executable file, and `--repo-root`
#      holds a `.buckconfig`.                                       (REFUSED)
#   2. `buck2 audit config komira_re.linux_properties --style json` names a
#      worker property set. If it names none, every action would run on this
#      machine: REFUSED, never a quiet local build. If buck2 cannot answer at
#      all: CANNOT_TELL.
#   3. `buck2 build <probe_target> -c komira.execution=remote
#      -c kci.probe_nonce=<nonce>` succeeds within `probe_timeout_s`. The
#      nonce changes the probe action's key on every run, so it must execute
#      on the farm. Failure or timeout: CANNOT_TELL "farm unreachable", with
#      the end of buck2's stderr and the path of its log.
#
# There is no fallback to a local build at any step.
#
# Encapsulation: owned values; no pointer, no wildcard origin.
# =============================================================================

from std.os import makedirs, stat
from std.os.path import isdir, isfile
from std.pathlib import Path

from komira_json import JSON_STRING, parse_json_value

from kci_build.request import (
    EXIT_CANNOT_TELL,
    EXIT_OK,
    EXIT_REFUSED,
    BuildOutcome,
    BuildRequest,
)
from kci_build.runner import ProcessRunner, RunResult, RunSpec

comptime FARM_PROPERTIES_KEY: String = "komira_re.linux_properties"


def log_spec(req: BuildRequest, var argv: List[String], name: String, timeout_s: Int) -> RunSpec:
    """A buck2 run in the repo root, its output logged as
    `<log_dir>/<name>.stdout` and `.stderr`."""
    return RunSpec(
        req.buck2_path.copy(),
        argv^,
        req.repo_root.copy(),
        timeout_s,
        req.log_dir + String("/") + name + String(".stdout"),
        req.log_dir + String("/") + name + String(".stderr"),
    )


def config_args(req: BuildRequest) -> List[String]:
    """`-c komira.execution=remote` and then each `--buck2-config`."""
    var a = List[String]()
    a.append(String("-c"))
    a.append(String("komira.execution=remote"))
    for i in range(len(req.buck2_config)):
        a.append(String("-c"))
        a.append(req.buck2_config[i].copy())
    if req.target_platforms.byte_length() > 0:
        a.append(String("--target-platforms"))
        a.append(req.target_platforms.copy())
    return a^


def failure_text(spec: RunSpec, r: RunResult) -> String:
    """`<describe>; log <stderr path>: <stderr tail>`."""
    var s = r.describe() + String("; log ") + spec.stderr_path
    if r.stderr_tail.byte_length() > 0:
        s += String(":\n") + r.stderr_tail
    return s^


def _refused(why: String) -> BuildOutcome:
    return BuildOutcome(EXIT_REFUSED, String("kci build: ") + why)


def _cannot_tell(why: String) -> BuildOutcome:
    return BuildOutcome(EXIT_CANNOT_TELL, String("kci build: ") + why)


def _check_paths(req: BuildRequest) raises -> BuildOutcome:
    if not req.buck2_path.startswith(String("/")):
        return _refused(String("--buck2 '") + req.buck2_path + String("' is not an absolute path"))
    if not isfile(req.buck2_path):
        return _refused(String("--buck2 '") + req.buck2_path + String("' is not a file"))
    if (stat(req.buck2_path).st_mode & 0o111) == 0:
        return _refused(String("--buck2 '") + req.buck2_path + String("' is not executable"))
    if not isfile(req.repo_root + String("/.buckconfig")):
        return _refused(String("--repo-root '") + req.repo_root + String("' has no .buckconfig"))
    return BuildOutcome(EXIT_OK, String(""))


def _farm_properties(stdout_path: String) raises -> String:
    """The configured farm property set from `audit config`'s JSON, or ""
    when the key is unset or empty. Raises if the output is not JSON."""
    var doc = parse_json_value(Path(stdout_path).read_text())
    if not doc.is_object():
        raise Error(String("audit config printed a JSON value that is not an object"))
    if not doc.has(String(FARM_PROPERTIES_KEY)):
        return String("")
    var v = doc.get(String(FARM_PROPERTIES_KEY))
    if v.kind_tag() != JSON_STRING:
        return String("")
    return String(v.as_string().strip())


def preflight[R: ProcessRunner](req: BuildRequest, mut runner: R) raises -> BuildOutcome:
    """Steps 1-3 of the file header. OK means: go on and build."""
    var paths = _check_paths(req)
    if not paths.ok():
        return paths^
    makedirs(req.log_dir, exist_ok=True)

    var audit = List[String]()
    audit.append(String("audit"))
    audit.append(String("config"))
    for i in range(len(req.buck2_config)):
        audit.append(String("-c"))
        audit.append(req.buck2_config[i].copy())
    audit.append(String(FARM_PROPERTIES_KEY))
    audit.append(String("--style"))
    audit.append(String("json"))
    var aspec = log_spec(req, audit^, String("preflight_audit_config"), req.probe_timeout_s)
    var ar = runner.run(aspec)
    if not ar.ok():
        return _cannot_tell(
            String("cannot read the buckconfig: buck2 audit config ") + failure_text(aspec, ar)
        )
    var props: String
    try:
        props = _farm_properties(aspec.stdout_path)
    except e:
        return _cannot_tell(
            String("cannot read the buckconfig: ") + String(e) + String("; log ") + aspec.stdout_path
        )
    if props.byte_length() == 0:
        return _refused(
            String("the buckconfig names no farm ([komira_re] linux_properties is not")
            + String(" set): this run would build locally")
        )

    var probe = List[String]()
    probe.append(String("build"))
    probe.extend(config_args(req))
    probe.append(String("-c"))
    probe.append(String("kci.probe_nonce=") + req.probe_nonce)
    probe.append(req.probe_target.copy())
    var pspec = log_spec(req, probe^, String("preflight_probe"), req.probe_timeout_s)
    var pr = runner.run(pspec)
    if not pr.ok():
        return _cannot_tell(
            String("farm unreachable: probe ")
            + req.probe_target
            + String(" ")
            + failure_text(pspec, pr)
        )
    return BuildOutcome(EXIT_OK, String(""))
