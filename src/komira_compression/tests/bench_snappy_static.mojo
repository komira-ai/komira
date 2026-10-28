# The snappy throughput of the statically linked snappy this package called
# before it opened the system library: the same program as bench_snappy.mojo
# (see its header), calling //third_party/snappy's prefixed C API directly.
# `bench_snappy_static <run_id>`, run by :snappy_bench_static (BUCK).
#
# FFI-BOUNDARY: snappy_compress and snappy_uncompress through external_call;
# snappy keeps no pointer past a call. This is a benchmark and no library
# imports it.

from std.ffi import external_call
from std.sys import argv
from std.time import perf_counter_ns

comptime CORPUS_BYTES = 4 * 1024 * 1024
comptime ROUNDS = 20
comptime REPEATS = 7


def _corpus() -> List[UInt8]:
    var out = List[UInt8](capacity=CORPUS_BYTES + 8)
    var state = UInt64(88172645463325252)
    while len(out) < CORPUS_BYTES:
        state = state * 6364136223846793005 + 1442695040888963407
        var word = Int((state >> 33) & 63)
        for j in range(5):
            out.append(UInt8(97 + (word * 7 + j * 3) % 26))
        out.append(UInt8(32))
    return out^


def _compress(
    mut dst: List[UInt8], src: List[UInt8]
) raises -> Int:
    var size = UInt64(len(dst))
    # SAFETY: snappy reads len(src) bytes and writes at most `size` bytes of
    # dst, storing the count in `size`, a stack local; all alive across the
    # synchronous call.
    var status = external_call[
        "komira_snappy_compress",
        Int32,
        UnsafePointer[UInt8, MutUntrackedOrigin],
        UInt64,
        UnsafePointer[UInt8, MutUntrackedOrigin],
        UnsafePointer[UInt64, MutUntrackedOrigin],
    ](
        src.unsafe_ptr().unsafe_mut_cast[True]().unsafe_origin_cast[MutUntrackedOrigin](),
        UInt64(len(src)),
        dst.unsafe_ptr().unsafe_origin_cast[MutUntrackedOrigin](),
        UnsafePointer(to=size).unsafe_origin_cast[MutUntrackedOrigin](),
    )
    if status != 0:
        raise Error("snappy_compress status " + String(Int(status)))
    return Int(size)


def _uncompress(
    mut dst: List[UInt8], src: List[UInt8], src_len: Int
) raises -> Int:
    var size = UInt64(len(dst))
    # SAFETY: as _compress.
    var status = external_call[
        "komira_snappy_uncompress",
        Int32,
        UnsafePointer[UInt8, MutUntrackedOrigin],
        UInt64,
        UnsafePointer[UInt8, MutUntrackedOrigin],
        UnsafePointer[UInt64, MutUntrackedOrigin],
    ](
        src.unsafe_ptr().unsafe_mut_cast[True]().unsafe_origin_cast[MutUntrackedOrigin](),
        UInt64(src_len),
        dst.unsafe_ptr().unsafe_origin_cast[MutUntrackedOrigin](),
        UnsafePointer(to=size).unsafe_origin_cast[MutUntrackedOrigin](),
    )
    if status != 0:
        raise Error("snappy_uncompress status " + String(Int(status)))
    return Int(size)


def main() raises:
    var args = argv()
    if len(args) != 2:
        raise Error("usage: bench_snappy_static <run_id>")
    var src = _corpus()
    var packed = List[UInt8](length=32 + len(src) + len(src) // 6, fill=0)
    var decoded = List[UInt8](length=len(src), fill=0)
    var packed_len = 0
    var best_compress = Int.MAX
    var best_uncompress = Int.MAX
    for _ in range(REPEATS):
        var t0 = Int(perf_counter_ns())
        for _ in range(ROUNDS):
            packed_len = _compress(packed, src)
        var t1 = Int(perf_counter_ns())
        for _ in range(ROUNDS):
            var n = _uncompress(decoded, packed, packed_len)
            if n != len(src):
                raise Error("decoded length " + String(n))
        var t2 = Int(perf_counter_ns())
        best_compress = min(best_compress, t1 - t0)
        best_uncompress = min(best_uncompress, t2 - t1)
    for i in range(len(src)):
        if decoded[i] != src[i]:
            raise Error("round trip differs at byte " + String(i))
    var bytes = Float64(len(src) * ROUNDS)
    var c_mbs = bytes / (Float64(best_compress) / 1e9) / 1e6
    var u_mbs = bytes / (Float64(best_uncompress) / 1e9) / 1e6
    print(
        '{"run_id":"' + String(args[1]) + '","impl":"static'
        ' //third_party/snappy","input_bytes":' + String(len(src))
        + ',"compressed_bytes":' + String(packed_len)
        + ',"rounds":' + String(ROUNDS) + ',"repeats":' + String(REPEATS)
        + ',"compress_mb_s":' + String(c_mbs)
        + ',"uncompress_mb_s":' + String(u_mbs) + "}"
    )
