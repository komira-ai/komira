# The benchmark program: everything is `run_entrypoint` (entrypoint.mojo, whose
# header says what it does and what the exit status means); this file hands it
# the arguments.

from std.sys import argv, exit

from komira_bench_runner import run_entrypoint


def main():
    var all = argv()
    var args = List[String]()
    for i in range(1, len(all)):
        args.append(String(all[i]))
    exit(run_entrypoint(args))
