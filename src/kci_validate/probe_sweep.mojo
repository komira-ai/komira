# =============================================================================
# src/kci_validate/probe_sweep.mojo -- the expiry sweep: remove the probe
#   containers a killed kci left behind, and only those.
# =============================================================================
#
# If kci itself is killed (SIGKILL), nobody runs the `docker rm -f` of a
# probe's timeout. Removing every `kci-probe-*` container is NOT safe: two
# runners can share one docker daemon, and a prefix match would kill another
# run's live probe. So every probe and pre-flight container carries the
# label `kci-probe-max-seconds=<its timeout + 60>`, a maximum DURATION, and
# `sweep_expired_probes`, run at kci's start, removes exactly the containers
# whose own elapsed time exceeds their own label:
#
#   1  `docker ps -a --no-trunc --filter label=kci-probe-max-seconds
#      --format {{.ID}}`: the labelled containers, running or not
#   2  `docker inspect --format '<id> <StartedAt> <Created> <label>' <ids>`
#   3  `docker info --format {{.SystemTime}}`: the DAEMON's clock
#   4  `docker rm -f <id>` of each container whose elapsed time, SystemTime
#      minus its StartedAt (its Created when it never started: StartedAt is
#      then the zero time, year 0001), is over its label
#
# Both readings come from the one daemon, so the runner's own clock and any
# skew against it play no part: nothing here reads this machine's clock.
# They are compared as INSTANTS, each with its offset applied
# (komira_datetime `parse_rfc3339`): SystemTime carries the daemon host's
# local offset (`+02:00`), StartedAt and Created are UTC (`Z`).
#
# A container past its own maximum is one kci would already have removed,
# so no live probe is touched. A reading that cannot be parsed, a label that
# is not a positive number of seconds, or a removal that fails is reported in
# `SweepReport.problems` and that container is left: the sweep never removes
# on a guess. A failed list, inspect or info leaves everything. The sweep
# never fails a run: its report is the caller's to show.
#
# Encapsulation: owned values; no pointer, no wildcard origin.
# =============================================================================

from std.os import makedirs

from komira_datetime import parse_rfc3339

from kci_build.runner import ProcessRunner, RunSpec

from .container import docker_child_env, join_path
from .probe_container import (
    DOCKER_SHORT_TIMEOUT_S,
    daemon_time_argv,
    remove_argv,
    sweep_inspect_argv,
    sweep_list_argv,
)
from .request import ContainerHost

comptime _NEVER_STARTED_PREFIX: String = "0001-01-01T"
"""docker's zero time: a container created and never started."""


struct SweepReport(Movable):
    """What the sweep removed, left and could not judge.

    Layout: owned Lists of Strings. No pointer field."""

    var removed: List[String]
    var kept: List[String]
    var problems: List[String]

    def __init__(out self):
        self.removed = List[String]()
        self.kept = List[String]()
        self.problems = List[String]()


def instant_seconds(text: String) raises -> Int:
    """An RFC 3339 reading as UTC seconds, its offset applied; the fraction
    (docker writes nine digits) does not count."""
    return parse_rfc3339(text, truncate_fraction=True).seconds


def _words(line: String) -> List[String]:
    var out = List[String]()
    var parts = line.split(String(" "))
    for i in range(len(parts)):
        var w = String(parts[i])
        if w.byte_length() > 0:
            out.append(w^)
    return out^


def _positive(text: String) -> Int:
    """`text` as a positive decimal number of seconds, 0 when it is not one."""
    var b = text.as_bytes()
    if len(b) == 0 or len(b) > 9:
        return 0
    var n = 0
    for i in range(len(b)):
        var c = Int(b[i])
        if c < 48 or c > 57:
            return 0
        n = n * 10 + (c - 48)
    return n


def _docker[R: ProcessRunner](
    mut runner: R, host: ContainerHost, dir: String, var argv: List[String], what: String, mut report: SweepReport
) -> String:
    """Run `docker <argv>`; its stdout, or "" with a problem reported."""
    var spec = RunSpec(
        host.docker.copy(), argv^, dir.copy(), DOCKER_SHORT_TIMEOUT_S,
        join_path(dir, what + String(".stdout")), join_path(dir, what + String(".stderr")),
    )
    try:
        spec.set_env(docker_child_env(join_path(dir, String("docker")), host.path_env))
        var r = runner.run(spec)
        if not r.ok():
            var why = String("docker ") + spec.argv[0] + String(": ") + r.describe()
            if r.stderr_tail.byte_length() > 0:
                why += String(": ") + String(r.stderr_tail.strip())
            report.problems.append(why^)
            return String("")
        return open(spec.stdout_path, "r").read()
    except e:
        report.problems.append(String("docker ") + spec.argv[0] + String(": not started: ") + String(e))
        return String("")


def sweep_expired_probes[R: ProcessRunner](mut runner: R, host: ContainerHost, dir: String) -> SweepReport:
    """The sweep (file header). `dir` holds the docker CLI's empty
    configuration and the commands' output; it is made when absent."""
    var report = SweepReport()
    try:
        makedirs(join_path(dir, String("docker")), exist_ok=True)
    except e:
        report.problems.append(String("sweep directory ") + dir + String(": ") + String(e))
        return report^
    var listed = _docker(runner, host, dir, sweep_list_argv(), String("ps"), report)
    if len(report.problems) > 0:
        return report^
    var ids = _words(listed.replace(String("\n"), String(" ")))
    if len(ids) == 0:
        return report^
    var inspected = _docker(runner, host, dir, sweep_inspect_argv(ids), String("inspect"), report)
    if len(report.problems) > 0:
        return report^
    var now_text = String(_docker(runner, host, dir, daemon_time_argv(), String("info"), report).strip())
    if len(report.problems) > 0:
        return report^
    var now: Int
    try:
        now = instant_seconds(now_text)
    except e:
        report.problems.append(String("the daemon's SystemTime '") + now_text + String("': ") + String(e))
        return report^
    var lines = inspected.split(String("\n"))
    for i in range(len(lines)):
        var w = _words(String(lines[i]))
        if len(w) == 0:
            continue
        if len(w) != 4:
            report.problems.append(String("inspect line '") + String(lines[i]) + String("' is not <id> <started> <created> <label>"))
            continue
        var max_seconds = _positive(w[3])
        if max_seconds == 0:
            report.problems.append(w[0] + String(": label '") + w[3] + String("' is not a positive number of seconds"))
            continue
        var since = w[1].copy()
        if since.startswith(String(_NEVER_STARTED_PREFIX)):
            since = w[2].copy()
        var started: Int
        try:
            started = instant_seconds(since)
        except e:
            report.problems.append(w[0] + String(": start '") + since + String("': ") + String(e))
            continue
        if now - started <= max_seconds:
            report.kept.append(w[0].copy())
            continue
        var before = len(report.problems)
        _ = _docker(runner, host, dir, remove_argv(w[0]), String("rm"), report)
        if len(report.problems) == before:
            report.removed.append(w[0].copy())
    return report^
