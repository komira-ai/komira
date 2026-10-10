from std.ffi import external_call

comptime SNAPPY_OK: Int32 = 0


def expect(ok: Bool, what: String) raises:
    if not ok:
        raise Error("test_snappy: " + what)


def main() raises:
    """Round-trips a buffer through snappy's C API (snappy-c.h)."""
    var n = 4096
    var input = List[UInt8](capacity=n)
    for i in range(n):
        input.append(UInt8(i % 7))

    var max_len = external_call["komira_snappy_max_compressed_length", UInt64](UInt64(n))
    expect(Int(max_len) == 32 + n + n // 6, "snappy_max_compressed_length(4096) = " + String(max_len))

    var compressed = List[UInt8](length=Int(max_len), fill=0)
    var compressed_len = List[UInt64](length=1, fill=max_len)
    var rc = external_call["komira_snappy_compress", Int32](
        input.unsafe_ptr(), UInt64(n), compressed.unsafe_ptr(), compressed_len.unsafe_ptr()
    )
    expect(rc == SNAPPY_OK, "snappy_compress returned " + String(rc))
    expect(Int(compressed_len[0]) < n, "a repetitive input did not compress")

    var output = List[UInt8](length=n, fill=0)
    var output_len = List[UInt64](length=1, fill=UInt64(n))
    rc = external_call["komira_snappy_uncompress", Int32](
        compressed.unsafe_ptr(), compressed_len[0], output.unsafe_ptr(), output_len.unsafe_ptr()
    )
    expect(rc == SNAPPY_OK, "snappy_uncompress returned " + String(rc))
    expect(Int(output_len[0]) == n, "uncompressed length " + String(output_len[0]))
    var differs = external_call["memcmp", Int32](output.unsafe_ptr(), input.unsafe_ptr(), UInt64(n))
    expect(differs == 0, "the round trip changed the bytes")
    print("test_snappy: PASS", n, "->", compressed_len[0], "bytes")
