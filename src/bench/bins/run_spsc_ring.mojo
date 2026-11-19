# spsc_ring: the spsc_ring microbenchmark (bench/spsc_ring_bench.mojo).
#
#   mopm run --bin bench:spsc_ring      (mopm run passes no arguments: the defaults)
#   spsc_ring --total-ops=N --caps=A,B,... --hide-times      (a binary built from the installed source)

from bench.harness import command_line
from bench.spsc_ring_bench import run_program


def main() raises:
    run_program(command_line())
