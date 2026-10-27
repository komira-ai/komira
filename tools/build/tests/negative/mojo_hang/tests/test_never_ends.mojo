# Blocks, the way a test blocks that waits for an event that never comes. The
# welded test's hang limit (5 s on the target) stops it; with no limit it
# would hold its worker for the hour below.
from hangfix import answer
from std.time import sleep


def main() raises:
    print("HANG_FIXTURE start", answer(), flush=True)
    sleep(3600.0)
    print("HANG_FIXTURE was not stopped", flush=True)
