# =============================================================================
# komira_bench_data/main/stage_main.mojo: the `komira-bench-stage` binary.
# Everything is `run_stage` (stage_cli.mojo, whose header lists the commands,
# the flags and the exit status); this file only hands it the arguments.
# =============================================================================

from std.sys import argv, exit

from komira_bench_data import run_stage


def main():
    var all = argv()
    var args = List[String]()
    for i in range(1, len(all)):
        args.append(String(all[i]))
    exit(run_stage(args))
