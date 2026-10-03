# =============================================================================
# src/kci_build/cli.mojo -- `kci build` end to end: flags, then build.mojo.
# =============================================================================
#
# `build_main_with` parses the flags, runs `build_release` through the two
# given `ProcessRunner`s (the builds; the git commands of revision.mojo) and
# prints the outcome (the message, then on success one line per member,
# `<name>  <version>  <build>  <sha256>`, and `SET_HASH <64 hex>`);
# `build_main` is the same over the real `SupervisorRunner`.
# Both return the exit code of request.mojo.
#
# Encapsulation: owned values; no pointer, no wildcard origin.
# =============================================================================

from kci_build.build import build_release
from kci_build.flags import BUILD_USAGE, parse_build_flags
from kci_build.request import EXIT_OK, EXIT_USAGE, BuildRequest
from kci_build.runner import ProcessRunner
from kci_build.supervisor_runner import SupervisorRunner


def build_main_with[R: ProcessRunner, G: ProcessRunner](
    args: List[String], mut runner: R, mut git: G
) -> Int:
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
    var outcome = build_release(req, runner, git)
    print(outcome.message)
    for i in range(len(outcome.lines)):
        print(outcome.lines[i])
    return outcome.exit_code


def build_main(args: List[String]) -> Int:
    """`build_main_with` over the real process runner."""
    var runner = SupervisorRunner()
    var git = SupervisorRunner()
    return build_main_with(args, runner, git)
