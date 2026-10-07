# Holds 256 MiB for 2 s and passes under a cap well above it (lib_under_cap); its twin
# tests//negative/mem_cap:lib_over_cap runs it under a cap below it.
from memcap import hold_chunks
from std.testing import assert_equal


def main() raises:
    print("MEMCAP_FIXTURE start", flush=True)
    assert_equal(hold_chunks(4, 2.0), 1 + 2 + 3 + 4, "one byte read back from each chunk")
