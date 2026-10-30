# The sum-emit bench program: parses the flags (cli.mojo), runs the bench,
# prints the JSON it wrote. Exit status: 0 the bench ran and every answer was
# the expected one; 1 it ran and an answer was not; 2 a flag was refused or the
# run failed.

from std.sys import argv, exit

from komira_bench_sum_emit.bench import run_bench
from komira_bench_sum_emit.cli import parse_bench_args


def main():
    var all = argv()
    var args = List[String]()
    for i in range(1, len(all)):
        args.append(String(all[i]))
    try:
        var settings = parse_bench_args(args)
        var result = run_bench(settings)
        print(result.json)
        if not result.answers_match:
            print("the answer of a run was not the expected one")
            exit(1)
    except e:
        print("sum emit bench: " + String(e))
        exit(2)
