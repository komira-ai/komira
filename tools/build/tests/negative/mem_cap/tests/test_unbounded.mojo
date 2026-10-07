# Allocates without a bound of its own: chunk after chunk, until an
# allocation fails. A fuse stops it at 2 GiB and EXITS 0, so on a run with no
# cap this test passes and the harness, which requires it to fail, goes red;
# the fuse only keeps a broken cap from exhausting the worker.
from memcap import hold_chunks

comptime FUSE_CHUNKS = 32


def main() raises:
    print("MEMCAP_FIXTURE start", flush=True)
    _ = hold_chunks(FUSE_CHUNKS)
    print("MEMCAP_FIXTURE reached the fuse with no cap stopping it", flush=True)
