# The page faults of this process, for the komira arm: the minor and major
# fault counts `getrusage(RUSAGE_SELF)` keeps for every thread of the process.
# A count is a total since the process started, so a run's faults are the
# difference of two readings taken around it (the runner does that in
# measure.mojo). Where `getrusage` fails the reading is absent, never zero.

from std.ffi import c_int, external_call
from std.memory import UnsafePointer, alloc

from komira_bench_duckdb import FaultCount

comptime _RUSAGE_SELF: Int = 0
# `struct rusage` is 18 longs (144 bytes) on 64-bit Linux and macOS; after the
# two timevals and `ru_maxrss`, `ru_ixrss`, `ru_idrss` and `ru_isrss`,
# `ru_minflt` is at byte offset 64 and `ru_majflt` at 72 on both.
comptime _RUSAGE_BYTES: Int = 144
comptime _OFF_MINFLT: Int = 64
comptime _OFF_MAJFLT: Int = 72


@always_inline
def _read_i64(buf: UnsafePointer[UInt8, _], offset: Int) -> Int64:
    # SAFETY: the caller guarantees `buf` holds at least `offset + 8` bytes.
    var acc: UInt64 = 0
    for i in range(8):
        acc = acc | (UInt64(buf[offset + i]) << (UInt64(i) * 8))
    return Int64(acc)


def process_faults() -> Optional[FaultCount]:
    """The minor and major page faults this process has taken so far, or
    nothing when `getrusage` fails."""
    # FFI-BOUNDARY: `getrusage` fills a buffer this function allocates and frees
    # before it returns; no pointer leaves the function.
    # SAFETY: the buffer is `_RUSAGE_BYTES` long, zero-filled, and read only at
    # offsets inside it.
    var buf = alloc[UInt8](_RUSAGE_BYTES)
    for i in range(_RUSAGE_BYTES):
        buf[i] = 0
    var out = Optional[FaultCount]()
    var rc = external_call["getrusage", c_int](c_int(_RUSAGE_SELF), buf)
    if rc == 0:
        out = Optional[FaultCount](FaultCount(_read_i64(buf, _OFF_MINFLT), _read_i64(buf, _OFF_MAJFLT)))
    buf.free()
    return out^
