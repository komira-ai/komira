"""covcheck: coverage reports to a GitHub check run, and the build gate.

    covcheck report ...   the PR check: summary, check-run bodies, result JSON
    covcheck gate ...     one package's numbers and findings; exit 3 when
                          --mode enforce and the package has a finding

Every flag, the inputs, the outputs and the exit codes are in README.md
(next to this file); the command line is parsed in covcheck/cli.mojo.
"""

from std.sys import argv, exit

from covcheck.cli import run


def main():
    var raw = argv()
    var args = List[String]()
    for i in range(1, len(raw)):
        args.append(String(raw[i]))
    exit(run(args))
