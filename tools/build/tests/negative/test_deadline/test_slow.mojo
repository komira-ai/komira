# Built and inspected, never run: tools/build/selftest/config_refusals.zig reads
# the command `buck2 test` runs for it (the time limit's flags), and the gate's
# own tests (tools/build/run) kill a test at its limit. See BUCK.
def main() raises:
    print("TEST_DEADLINE_FIXTURE start", flush=True)
