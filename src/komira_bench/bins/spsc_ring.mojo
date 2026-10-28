# spsc_ring: the komira_spsc_ring microbenchmark (komira_bench/spsc_ring_bench.mojo).
#
#   mopm run --bin komira_bench:spsc_ring      (mopm run passes no arguments: the defaults)
#   spsc_ring --total-ops=N --caps=A,B,... --hide-times      (a binary built from the installed source)

from komira_bench.harness import command_line
from komira_bench.spsc_ring_bench import run_program


def main() raises:
    run_program(command_line())
