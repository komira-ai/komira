# Allocates without a bound of its own: chunk after chunk, until something
# stops it. A fuse stops it at 2 GiB and holds that for an hour, so a sampled
# cap that has not yet acted always sees it (no sleep here races the sampler):
# on a run with no cap the test does not end, and the action's time limit
# ends it; the fuse only keeps a broken cap from exhausting the worker.
from memcap import hold_chunks

comptime FUSE_CHUNKS = 32


def main() raises:
    print("MEMCAP_FIXTURE start", flush=True)
    _ = hold_chunks(FUSE_CHUNKS, 3600.0)
    print("MEMCAP_FIXTURE reached the fuse with no cap stopping it", flush=True)
