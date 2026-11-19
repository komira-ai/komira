# Sizes as DuckDB prints them (`953.6 MiB`, `4.0 GiB`, `10 GB`) and the check
# that a read-back size is the size that was asked for, within the rounding of
# the printed digits.

from .text import slice_bytes

comptime _PREFIXES: String = "kmgtp"
"""The unit prefixes in order: 1024^1.. for `kib`.., 1000^1.. for `kb`..."""


def lower_ascii(s: String) -> String:
    """`s` with ASCII capitals made small."""
    var out = List[UInt8]()
    for c in s.as_bytes():
        out.append(c + UInt8(32) if c >= UInt8(65) and c <= UInt8(90) else c)
    return String(unsafe_from_utf8=Span[UInt8](out))


def _unit_bytes(unit: String) raises -> Float64:
    """The number of bytes in one `unit` (`b`, `kb`..`pb`, `kib`..`pib`, any
    case). Raises for another unit."""
    var u = lower_ascii(unit)
    if u == "b" or u.byte_length() == 0:
        return Float64(1)
    var b = u.as_bytes()
    var prefixes = String(_PREFIXES)
    var ub = prefixes.as_bytes()
    for i in range(len(ub)):
        var binary = len(b) == 3 and b[0] == ub[i] and b[1] == UInt8(105) and b[2] == UInt8(98)
        var decimal = len(b) == 2 and b[0] == ub[i] and b[1] == UInt8(98)
        if binary or decimal:
            var scale = Float64(1)
            for _ in range(i + 1):
                scale *= Float64(1024) if binary else Float64(1000)
            return scale
    raise Error(String("not a size unit: ") + unit)


struct ParsedSize(Copyable, Movable):
    """A size read from text: its bytes, the size of its unit and the number of
    decimals that were written (the rounding it carries)."""

    var bytes: Float64
    var unit_bytes: Float64
    var decimals: Int

    def __init__(out self, bytes: Float64, unit_bytes: Float64, decimals: Int):
        self.bytes = bytes
        self.unit_bytes = unit_bytes
        self.decimals = decimals

    def rounding(self) -> Float64:
        """Half of the last written digit, in bytes."""
        var half = Float64(0.5) * self.unit_bytes
        for _ in range(self.decimals):
            half /= Float64(10)
        return half


def parse_size(text: String) raises -> ParsedSize:
    """A number with an optional fraction, then an optional space, then a unit
    (a bare number is bytes). Raises for anything else."""
    var b = text.as_bytes()
    var i = 0
    var n = len(b)
    while i < n and b[i] == UInt8(32):
        i += 1
    var whole = Float64(0)
    var digits = 0
    while i < n and b[i] >= UInt8(48) and b[i] <= UInt8(57):
        whole = whole * Float64(10) + Float64(Int(b[i]) - 48)
        digits += 1
        i += 1
    var frac = Float64(0)
    var decimals = 0
    if i < n and b[i] == UInt8(46):
        i += 1
        var place = Float64(1)
        while i < n and b[i] >= UInt8(48) and b[i] <= UInt8(57):
            place /= Float64(10)
            frac += place * Float64(Int(b[i]) - 48)
            decimals += 1
            digits += 1
            i += 1
    if digits == 0:
        raise Error(String("not a size: ") + text)
    while i < n and b[i] == UInt8(32):
        i += 1
    var unit = String(text[byte=i:n])
    while unit.byte_length() > 0 and unit.as_bytes()[unit.byte_length() - 1] == UInt8(32):
        unit = slice_bytes(unit, 0, unit.byte_length() - 1)
    var scale = _unit_bytes(unit)
    return ParsedSize((whole + frac) * scale, scale, decimals)


def size_matches(readback: String, requested_bytes: Float64) raises -> Bool:
    """Whether the size written in `readback` is `requested_bytes` within the
    rounding of its written digits. Raises when `readback` is not a size."""
    var got = parse_size(readback)
    var d = got.bytes - requested_bytes
    if d < Float64(0):
        d = -d
    return d <= got.rounding() + Float64(1)
