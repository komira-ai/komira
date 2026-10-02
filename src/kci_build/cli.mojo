# =============================================================================
# src/kci_build/cli.mojo -- `kci build` end to end: flags, publishable list,
#   preflight, build, verify, emit.
# =============================================================================
#
# `build_publishable` runs one `BuildRequest` through a `ProcessRunner`;
# `build_main_with` adds the flags and prints the result; `build_main` is
# `build_main_with` over the real `SupervisorRunner`. All three return the
# exit code of request.mojo. The order is fixed: nothing is built before the
# list parses and the preflight passes, and nothing is copied before every
# target is verified.
#
# Encapsulation: owned values; no pointer, no wildcard origin.
# =============================================================================

from std.ffi import external_call
from std.time import perf_counter_ns

from kci_build.allowlist import read_publishable, select_publishable
from kci_build.build import build_targets
from kci_build.emit import VerifiedArtifact, check_out_dir, emit_artifacts, verify_artifacts
from kci_build.flags import BUILD_USAGE, parse_build_flags
from kci_build.preflight import preflight
from kci_build.report import TargetResult
from kci_build.request import EXIT_OK, EXIT_REFUSED, EXIT_USAGE, BuildOutcome, BuildRequest
from kci_build.runner import ProcessRunner
from kci_build.supervisor_runner import SupervisorRunner


def build_publishable[R: ProcessRunner](req: BuildRequest, mut runner: R) -> BuildOutcome:
    """Build, verify and emit the publishable set of `req`."""
    try:
        var entries = select_publishable(
            read_publishable(req.publishable_file), req.only, req.publishable_file
        )
        var gate = check_out_dir(req.out_dir)
        if not gate.ok():
            return gate^
        var pre = preflight(req, runner)
        if not pre.ok():
            return pre^
        var results = List[TargetResult]()
        var built = build_targets(req, entries, runner, results)
        if not built.ok():
            return built^
        var verified = List[VerifiedArtifact]()
        var checked = verify_artifacts(entries, results, verified)
        if not checked.ok():
            return checked^
        var emitted = emit_artifacts(req.out_dir, verified)
        if emitted.ok():
            emitted.message = (
                String("kci build: ")
                + String(len(emitted.manifests))
                + String(" artifact(s) written to ")
                + req.out_dir
            )
        return emitted^
    except e:
        return BuildOutcome(EXIT_REFUSED, String("kci build: ") + String(e))


def probe_nonce() -> String:
    """`<epoch seconds>-<monotonic ns>`: new on every run."""
    var epoch = external_call["time", Int](0)
    return String(epoch) + String("-") + String(Int(perf_counter_ns()))


def build_main_with[R: ProcessRunner](args: List[String], mut runner: R) -> Int:
    """`kci build <args>`: parse, run, print the outcome, return its code."""
    var req: BuildRequest
    try:
        var flags = parse_build_flags(args)
        if flags.help:
            print(String(BUILD_USAGE))
            return EXIT_OK
        req = flags.request.copy()
    except e:
        print(String(e))
        return EXIT_USAGE
    req.probe_nonce = probe_nonce()
    var outcome = build_publishable(req, runner)
    print(outcome.message)
    for i in range(len(outcome.manifests)):
        print(String("  ") + outcome.manifests[i])
    return outcome.exit_code


def build_main(args: List[String]) -> Int:
    """`build_main_with` over the real process runner."""
    var runner = SupervisorRunner()
    return build_main_with(args, runner)
