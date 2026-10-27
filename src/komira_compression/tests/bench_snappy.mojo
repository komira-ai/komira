# The snappy throughput of komira_compression's block API
# (`snappy_compress_into`, `snappy_uncompress_into`): `bench_snappy <run_id>`,
# run by :snappy_bench (BUCK) on a farm worker, which keeps the one JSON line
# this prints. Not a gated test: a number is not a pass or a fail.
#
# The input is 4 MiB of text-like bytes (words picked by a fixed
# linear-congruential generator), compressed and decompressed ROUNDS times per
# repeat; the figure is the best of REPEATS repeats, in MB (10^6 bytes) per
# second of the uncompressed size. The decoded bytes are compared with the
# input after the last round, so the timed work cannot be skipped.
#
# bench_snappy_static.mojo is the same program over the statically linked
# snappy this package used to call (//third_party/snappy), for the figure the
# system library is compared with.

from std.sys import argv
from std.time import perf_counter_ns

from komira_compression.snappy_block import (
    snappy_compress_into,
    snappy_max_compressed_length,
    snappy_uncompress_into,
)

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


def main() raises:
    var args = argv()
    if len(args) != 2:
        raise Error("usage: bench_snappy <run_id>")
    var src = _corpus()
    var packed = List[UInt8](
        length=snappy_max_compressed_length(len(src)), fill=0
    )
    var decoded = List[UInt8](length=len(src), fill=0)
    var packed_len = 0
    var best_compress = Int.MAX
    var best_uncompress = Int.MAX
    for _ in range(REPEATS):
        var t0 = Int(perf_counter_ns())
        for _ in range(ROUNDS):
            packed_len = snappy_compress_into(Span(packed), Span(src))
        var t1 = Int(perf_counter_ns())
        for _ in range(ROUNDS):
            var n = snappy_uncompress_into(
                Span(decoded), Span(packed)[0:packed_len]
            )
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
        '{"run_id":"' + String(args[1]) + '","impl":"libsnappy via'
        ' snappy_block","input_bytes":' + String(len(src))
        + ',"compressed_bytes":' + String(packed_len)
        + ',"rounds":' + String(ROUNDS) + ',"repeats":' + String(REPEATS)
        + ',"compress_mb_s":' + String(c_mbs)
        + ',"uncompress_mb_s":' + String(u_mbs) + "}"
    )
