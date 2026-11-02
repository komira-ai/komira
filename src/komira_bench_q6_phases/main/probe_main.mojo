# The Q6 phase probe program: parses the flags (cli.mojo), runs the probe,
# prints the JSON it wrote. Exit status: 0 the probe ran and every answer was
# the expected one; 1 it ran and an answer was not; 2 a flag was refused or the
# run failed.

from std.sys import argv, exit

from komira_bench_q6_phases.cli import parse_probe_args
from komira_bench_q6_phases.probe import run_probe


def main():
    var all = argv()
    var args = List[String]()
    for i in range(1, len(all)):
        args.append(String(all[i]))
    try:
        var settings = parse_probe_args(args)
        var result = run_probe(settings)
        print(result.json)
        if not result.answers_match:
            print("the answer of a run was not the expected one")
            exit(1)
    except e:
        print("q6 phase probe: " + String(e))
        exit(2)
