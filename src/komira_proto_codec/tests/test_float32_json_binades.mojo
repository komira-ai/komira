# =============================================================================
# test_float32_json_binades.mojo — every float32 of four whole binades
# round-trips through the proto3-JSON float32 writer and reader.
# =============================================================================
#
# Not a welded gate (about 34 million values; run it with `buck2 test`). The
# welded suite (`test_proto_codec_json_float32.mojo`) samples every binade;
# this one is exhaustive where the risks are densest:
#   field 0    every subnormal (the 2^-149 grid, the zero / subnormal edge);
#   field 1    the first normal binade (the subnormal / normal edge, where
#              the standard library's `String(Float32)` misprints);
#   field 43   the binade of 0x15AE43FD, whose shortest decimal a reader that
#              parses to Float64 first reads back as 0x15AE43FE;
#   field 254  the top binade (float32 max, the overflow threshold).
# Each value is written with `write_proto3_json_f32` and read back with
# `parse_decimal_f32`; both signs are covered through the sign bit of every
# other value. A mismatch raises naming the bits and the text.
# =============================================================================

from std.memory import bitcast

from komira_proto_codec import parse_decimal_f32, write_proto3_json_f32


def check_binade(field: Int) raises -> Int:
    var checked = 0
    for frac in range(1 << 23):
        var bits = (UInt32(field) << UInt32(23)) | UInt32(frac)
        if (frac & 1) == 1:
            bits |= UInt32(0x80000000)
        if (bits & UInt32(0x7FFFFFFF)) == UInt32(0):
            continue
        var buf = List[UInt8]()
        write_proto3_json_f32(buf, bitcast[DType.float32](bits))
        var text = String(unsafe_from_utf8=Span(buf))
        var back = bitcast[DType.uint32](parse_decimal_f32(text))
        if back != bits:
            raise Error(
                "binade "
                + String(field)
                + ": bits "
                + String(bits)
                + " wrote "
                + text
                + " which reads back as "
                + String(back)
            )
        checked += 1
    return checked


def main() raises:
    var total = 0
    for field in [0, 1, 43, 254]:
        var n = check_binade(field)
        print("  binade", field, ":", n, "values round-trip")
        total += n
    print("test_float32_json_binades: ALL PASS (", total, "values )")
