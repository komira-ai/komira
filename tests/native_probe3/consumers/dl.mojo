# Probe 3's program for DL and DL-MISS: each codec library opened by its
# owner, by soname, at first use (OwnedDLHandle): libzstd.so.1 by
# komira_compression, liblz4.so.1 by komira_lz4, libz.so.1 by komira_zlib.
# Known answers prove each was opened and called; where each was loaded from
# is read from the loader's record by case.sh.
from komira_compression.zstd_frame import zstd_compress_bound, zstd_compress_into, zstd_decompress_into
from komira_lz4.codec import lz4_compress, lz4_decompress
from komira_zlib import zlib_crc32
from p3util import report, same


def main() raises:
    var data = List[UInt8](capacity=4096)
    for i in range(4096):
        data.append(UInt8(0x61 + (i % 7)))

    var c = lz4_compress(Span(data))
    var back = lz4_decompress(Span(c), len(data))
    var ok = report("lz4_roundtrip", len(c) < len(data) and same(Span(back), Span(data)), "liblz4.so.1: 4096 bytes -> " + String(len(c)))

    var crc = zlib_crc32(String("abc").as_bytes())
    ok = report("zlib_crc32_abc", crc == UInt32(0x352441C2), "libz.so.1: crc32(abc) " + hex(Int(crc))) and ok

    var z = List[UInt8](length=zstd_compress_bound(len(data)), fill=0)
    var zn = zstd_compress_into(Span(z), Span(data), Int32(3))
    var out = List[UInt8](length=len(data), fill=0)
    var on = zstd_decompress_into(Span(out), Span(z)[0:zn])
    ok = report("zstd_roundtrip", zn < len(data) and on == len(data) and same(Span(out), Span(data)), "libzstd.so.1: 4096 bytes -> " + String(zn)) and ok
    print("RESULT", "PASS" if ok else "FAIL", flush=True)
