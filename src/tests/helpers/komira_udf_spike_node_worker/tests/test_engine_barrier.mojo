# The engine loop's two system-specific parts (native/engine_loop.c), on
# the system the test runs on: the CPU count it reports as `cpus` (Linux:
# the CPUs of the process's affinity mask; macOS: sysctl hw.activecpu) and
# the barrier its threads meet at before and after the measured phase
# (Linux: pthread_barrier_t; macOS: a mutex, a condition variable and a
# generation count). test_threads runs the whole loop, with workers; this
# test needs none.
#
# What it proves, and the defect each part catches:
#   - the CPU count is at least 1 and at most the machine's logical CPUs (a
#     failed query reported as -1; a figure that is not a CPU count).
#   - the barrier at 1, 2, 4 and 64 threads (64 is the most the engine
#     runs), 200 rounds on one barrier, the last thread arriving only after
#     all the others have: no thread leaves a round before every thread has
#     arrived in it (a barrier that lets threads through early, or releases
#     one arrival short). A barrier that never releases its waiters hangs,
#     and the watchdog's alarm ends the test.
#   - the check refuses 0 threads, 65 threads and 0 rounds with -1.

from std.ffi import external_call
from std.sys import num_logical_cores
from std.testing import assert_equal, assert_true

from komira_udf_spike_node_worker.watchdog import arm_watchdog


def _cpus() -> Int:
    return Int(external_call["kudfw_engine_cpus", Int64]())


def _early_reads(threads: Int, rounds: Int) -> Int:
    return Int(external_call["kudfw_engine_barrier_check", Int64](Int64(threads), Int64(rounds)))


def main() raises:
    arm_watchdog()
    var cpus = _cpus()
    assert_true(cpus >= 1, "cpus: " + String(cpus))
    assert_true(cpus <= num_logical_cores(), "cpus: " + String(cpus) + " of " + String(num_logical_cores()))
    for threads in [1, 2, 4, 64]:
        assert_equal(_early_reads(threads, 200), 0, String(threads) + " threads: reads before the round was full")
    assert_equal(_early_reads(0, 1), -1, "0 threads")
    assert_equal(_early_reads(65, 1), -1, "65 threads")
    assert_equal(_early_reads(2, 0), -1, "0 rounds")
    print("test_engine_barrier: ok")
