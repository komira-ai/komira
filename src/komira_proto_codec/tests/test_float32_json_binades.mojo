# =============================================================================
# test_float32_json_binades.mojo — every float32 of four whole binades
# round-trips through the proto3-JSON float32 writer and reader.
# =============================================================================
#
# Not a welded gate (about 34 million values; run it with `buck2 test`). Each
# binade is split into PARTS equal frac ranges, and each (binade, part) is its
# own target (`test_float32_json_binades_<field>_<part>` in BUCK, which passes
# BINADE, PART and PARTS as defines), so the units run as parallel actions and
# each stays far below the test time limit. Together the units cover exactly
# the values of the single sweep they replace: part k of a binade is frac in
# [k * 2^23 / PARTS, (k + 1) * 2^23 / PARTS). Each unit asserts its own count
# (the range size, less the zero pattern in binade 0) and that its first and
# last frac are the bounds of its part, so a unit whose range drops, repeats or
# shifts values fails. The welded suite (`test_proto_codec_json_float32.mojo`)
# samples every binade; this one is exhaustive where the risks are densest:
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
from std.sys.defines import get_defined_int

from komira_proto_codec import parse_decimal_f32, write_proto3_json_f32


comptime BINADE = get_defined_int["BINADE"]()
comptime PART = get_defined_int["PART"]()
comptime PARTS = get_defined_int["PARTS"]()
comptime PART_SIZE = (1 << 23) // PARTS


def check_binade(
    field: Int, part: Int, mut first: Int, mut last: Int
) raises -> Int:
    var checked = 0
    first = -1
    last = -1
    for frac in range(part * PART_SIZE, (part + 1) * PART_SIZE):
        if first < 0:
            first = frac
        last = frac
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
    if PART < 0 or PART >= PARTS:
        raise Error(
            "part " + String(PART) + " is outside [0, " + String(PARTS) + ")"
        )
    var first = 0
    var last = 0
    var n = check_binade(BINADE, PART, first, last)
    # The bounds are recomputed here from PART and PARTS, not read back from
    # the loop's own range expression, so a range shifted by a constant fails.
    var want_first = PART * ((1 << 23) // PARTS)
    var want_last = (PART + 1) * ((1 << 23) // PARTS) - 1
    if first != want_first or last != want_last:
        raise Error(
            "binade "
            + String(BINADE)
            + " part "
            + String(PART)
            + ": frac range ["
            + String(first)
            + ", "
            + String(last)
            + "], expected ["
            + String(want_first)
            + ", "
            + String(want_last)
            + "]"
        )
    var expected = PART_SIZE
    if BINADE == 0 and PART == 0:
        expected -= 1  # the zero pattern is skipped
    if n != expected:
        raise Error(
            "binade "
            + String(BINADE)
            + " part "
            + String(PART)
            + ": checked "
            + String(n)
            + " values, expected "
            + String(expected)
        )
    print(
        "test_float32_json_binades: binade",
        BINADE,
        "part",
        PART,
        "PASS (",
        n,
        "values )",
    )
