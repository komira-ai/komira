# spsc_ring: the komira_spsc_ring microbenchmark (komira_bench/spsc_ring_bench.mojo).
#
#   mopm run --bin komira_bench:spsc_ring [-- --total-ops=N --caps=A,B,... --hide-times]

from komira_bench.harness import command_line, parse_args, usage
from komira_bench.spsc_ring_bench import (
    DEFAULT_TOTAL_OPS,
    bench_lines,
    default_caps,
)


def main() raises:
    var args = parse_args(command_line(), DEFAULT_TOTAL_OPS, default_caps())
    if args.help:
        print(usage("spsc_ring", DEFAULT_TOTAL_OPS, default_caps()))
        return
    for i in range(len(args.caps)):
        var lines = bench_lines(args.caps[i], args)
        for j in range(len(lines)):
            print(lines[j])
