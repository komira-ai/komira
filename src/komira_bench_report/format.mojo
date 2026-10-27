# Text helpers of the report: fixed-point numbers and column padding, written
# out so that a table is the same bytes on every platform.


def format_fixed(x: Float64, decimals: Int) -> String:
    """`x` rounded half up to `decimals` places, always with that many."""
    var negative = x < 0.0
    var a = x
    if negative:
        a = -x
    var scale = 1
    for _ in range(decimals):
        scale *= 10
    var scaled = Int(a * Float64(scale) + 0.5)
    var out = String(scaled // scale)
    if decimals > 0:
        var frac = String(scaled % scale)
        while frac.byte_length() < decimals:
            frac = String("0") + frac
        out += String(".") + frac
    if negative and scaled != 0:
        out = String("-") + out
    return out^


def pad_left(s: String, width: Int) -> String:
    """`s` with spaces before it up to `width` bytes."""
    var out = String("")
    for _ in range(width - s.byte_length()):
        out += String(" ")
    return out + s


def pad_right(s: String, width: Int) -> String:
    """`s` with spaces after it up to `width` bytes."""
    var out = s.copy()
    for _ in range(width - s.byte_length()):
        out += String(" ")
    return out^
