# =============================================================================
# byte_size.mojo -- the ONE parser for an operator-supplied byte budget
# =============================================================================
#
# A byte budget is always the same string: a decimal count with an optional
# 1024-based `G`/`M`/`K` suffix. This is the single definition of how that
# string becomes an Int.
#
# WHY IT IS HERE AND NOT COPIED. The scan-dedup cache budget and the parquet
# mmap-pin budget need the identical parse, and `komira_parquet` must not
# depend on the engine dispatch package. Copying a parser means two
# definitions of what `8G` means, and the day they disagree is the day a
# budget silently means something else in one subsystem than in the other.
# the core packages is the lowest common package and this function has no
# dependencies at all.
#
# PURE -- no FFI, no environment read, no allocation beyond the caller's
# String, so it is a deterministic unit test with explicit inputs.
# =============================================================================


def parse_byte_size(s: String) -> Int:
    """Parse a byte-size string (decimal, optional 1024-based `G`/`M`/`K`
    suffix) into bytes.

    Returns 0 on empty / non-numeric input, so an unset or malformed budget
    is IGNORED rather than interpreted as a zero budget. That direction is
    load-bearing: a typo'd `8GB` budget must fall back to the computed
    default, never silently disable the cache it is sizing. (`8GB` parses the digits, reads the `G`, and returns 8 GiB — the
    trailing `B` is ignored, which is the forgiving reading of the only typo
    anyone actually makes.)

    Accepted: leading spaces/tabs, then digits, then at most one of
    `G`/`g`/`M`/`m`/`K`/`k`. Anything after the suffix is ignored.
    """
    var n_bytes = s.byte_length()
    if n_bytes == 0:
        return 0
    var bs = s.as_bytes()
    var i = 0
    # Skip leading whitespace.
    while i < n_bytes and (bs[i] == UInt8(32) or bs[i] == UInt8(9)):
        i += 1
    var val = 0
    var saw_digit = False
    while i < n_bytes:
        var c = Int(bs[i])
        if c >= 48 and c <= 57:  # '0'..'9'
            val = val * 10 + (c - 48)
            saw_digit = True
            i += 1
        else:
            break
    if not saw_digit:
        return 0
    if i < n_bytes:
        var suf = Int(bs[i])
        if suf == 71 or suf == 103:  # 'G' / 'g'
            return val * 1024 * 1024 * 1024
        if suf == 77 or suf == 109:  # 'M' / 'm'
            return val * 1024 * 1024
        if suf == 75 or suf == 107:  # 'K' / 'k'
            return val * 1024
    return val
