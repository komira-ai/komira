# The test of tests//functional/mem_cap:lib_under_cap, run here under a cap
# below the 256 MiB it holds (lib_over_cap): for an hour here, so the kill
# does not depend on a sleep racing the cap's sampling interval.
from memcap import hold_chunks
from std.testing import assert_equal


def main() raises:
    print("MEMCAP_FIXTURE start", flush=True)
    assert_equal(hold_chunks(4, 3600.0), 1 + 2 + 3 + 4, "one byte read back from each chunk")
