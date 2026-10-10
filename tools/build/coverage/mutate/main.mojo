"""mutate: operator mutants of a Mojo package and their score.

    mutate list ...    the sampled mutants of a package's sources
    mutate apply ...   one source file with one mutant applied
    mutate score ...   each mutant's verdict, covcheck's mutants file and a summary

The command line is mutate/cli.mojo; what runs it is the `[mutation]`
sub-target of every mojo_library (tools/build/coverage/README.md, "Mutation
score").
"""

from std.sys import argv, exit

from mutate.cli import run


def main():
    var raw = argv()
    var args = List[String]()
    for i in range(1, len(raw)):
        args.append(String(raw[i]))
    exit(run(args))
