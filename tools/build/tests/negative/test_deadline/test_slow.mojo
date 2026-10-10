# Sleeps 180 s, then passes. Run with buck2's test timeout at 90 s, it must be
# killed by its own time limit (30 s) first; see BUCK.
from std.time import sleep


def main() raises:
    print("TEST_DEADLINE_FIXTURE start", flush=True)
    sleep(180.0)
    print("TEST_DEADLINE_FIXTURE slept 180 s with no limit stopping it", flush=True)
