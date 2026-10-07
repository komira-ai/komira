# =============================================================================
# test_connect_conformance.mojo -- komira_connect against the Connect suite
# =============================================================================
#
# The pinned `connectconformance` runner (third_party/connect-conformance,
# v1.0.5, staged as `connectconformance`) runs in server mode with
# conformance.yaml (the feature subset komira_connect serves) and the
# runner's own `--known-failing @known_failing.txt`. For each server
# configuration it computes (HTTP/2 over TLS, per protocol) it starts
# `conformance_server` (the server/ binary, staged under `server/`), which
# serves the ConformanceService on a komira_connect ConnectService behind a
# komira_http_server HttpServer on 127.0.0.1, and drives it with the suite's
# Connect-Go and grpc-go reference clients, in-process in the runner. The
# suite supplies every case; nothing here decides what a case expects.
#
# The reference client issues one RPC at a time (`-p 1`). At the runner's
# default parallelism (four times GOMAXPROCS) 96 of the 236 RPCs never got an
# answer from the komira server and timed out, a different set on every run,
# so the outcome of a case would depend on scheduling: a defect of the server
# under concurrent RPCs that this gate does not cover (reported, not listed).
#
# The test requires:
#   1. the runner ran to completion within its deadline and exited 0: no case
#      failed that known_failing.txt does not list, no listed case passed (a
#      stale entry), and every pattern matched a case;
#   2. its report agrees with that: the counts add up to the total, the
#      banners name as many cases as the counts say, no case "could not be
#      run" (a server that died or hung; the runner's verdict ignores those),
#      the total is this config's case count at the pin (_SUITE_CASES) and at
#      least _MIN_PASSED cases passed, so a vacuous or truncated run fails;
#   3. every pattern in known_failing.txt has its reason (known_failing.mojo).
#
# Defects it catches: any komira_connect / komira_http_server behavior on the
# RPC path that the suite checks and that passes at this pin (framing, status
# and trailer emission, error-code mapping, content-type handling, routing of
# unknown methods); a fix nobody recorded (the case passes, so its
# known-failing pattern is stale); a server that crashes or wedges.
#
# The runner's stdout and stderr are printed whole, so a red run's log names
# every failing case with the errors the reference client saw.
# =============================================================================

from std.pathlib import Path

from komira_http_conformance import run_child
from komira_runtime_paths import data_path
from komira_supervisor import ChildSpec

from komira_connect_conformance import (
    parse_known_failing,
    parse_report,
    summary_problems,
)

# The whole run's budget, under the remote action's 600 s limit.
comptime _SUITE_DEADLINE_S = 420
# The number of cases conformance.yaml selects from the pinned suite
# (the runner's "Total cases"). A new pin or a config change changes it.
comptime _SUITE_CASES = 236
# Cases that pass at this pin (the run's "passed" count); a run with fewer
# passes is not this run.
comptime _MIN_PASSED = 16


def test_connect_conformance_suite_against_connect_service() raises:
    var known_text = Path(data_path(String("known_failing.txt"))).read_text()
    var parsed = parse_known_failing(known_text)
    print("known_failing.txt: " + String(len(parsed[0])) + " patterns")

    var spec = ChildSpec(data_path(String("connectconformance")))
    spec.with_arg(String("--mode"))
    spec.with_arg(String("server"))
    spec.with_arg(String("--conf"))
    spec.with_arg(data_path(String("conformance.yaml")))
    spec.with_arg(String("--known-failing"))
    spec.with_arg(String("@") + data_path(String("known_failing.txt")))
    spec.with_arg(String("-p"))
    spec.with_arg(String("1"))
    spec.with_arg(String("-v"))
    spec.with_arg(String("--"))
    spec.with_arg(data_path(String("server/conformance_server")))
    var run = run_child(spec, _SUITE_DEADLINE_S)
    print("connectconformance " + run.describe())
    print("---- connectconformance stderr ----")
    print(run.stderr)
    print("---- connectconformance stdout ----")
    print(run.stdout)
    print("-----------------------------------")

    var problems = List[String]()
    for ref p in parsed[1]:
        problems.append("known_failing.txt " + p)
    if run.timed_out or run.exit.signal >= Int32(0):
        problems.append("the runner did not run to completion (" + run.describe() + ")")
    elif run.exit.exit_code != Int32(0):
        problems.append("the runner's verdict is red (" + run.describe() + ")")
    try:
        var report = parse_report(run.stdout)
        print("connectconformance summary: " + report.summary.describe())
        for ref p in summary_problems(report, _SUITE_CASES, _MIN_PASSED):
            problems.append(p)
    except e:
        problems.append("the runner's report cannot be read: " + String(e))
    if len(problems) > 0:
        var msg = String("Connect conformance gate: ") + String(len(problems)) + " problem(s)"
        for ref p in problems:
            msg += "\n  " + p
        raise Error(msg)
    print("  test_connect_conformance_suite_against_connect_service PASS")


def main() raises:
    test_connect_conformance_suite_against_connect_service()
    print("PASS komira_connect_conformance")
