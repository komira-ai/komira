# =============================================================================
# komira_kg_enrich/framing.mojo -- checks and codecs shared by the queue, the
#   lease and the drain worker.
# =============================================================================
#
# A partition id, an item id and a holder token become path segments of object
# keys and fields of newline-framed objects, so each is held to a small alphabet
# before it is used: non-empty, no control byte, no '/', no '"' and no '\'. The
# opaque source key is only held to one line, because it rides one header line
# of the queue object. Nothing here reads a clock or an environment.
# =============================================================================


@always_inline
def _bad_identifier_byte(c: UInt8) -> Bool:
    return (
        c < UInt8(0x20)
        or c == UInt8(0x7F)
        or c == UInt8(0x2F)  # '/'
        or c == UInt8(0x22)  # '"'
        or c == UInt8(0x5C)  # '\'
    )


def check_identifier(what: String, value: String) raises:
    """Refuse an empty value, a control byte, '/', '"' and '\\' in `value`.
    `what` names the field in the error."""
    var b = value.as_bytes()
    if len(b) == 0:
        raise Error(what + " must not be empty")
    for i in range(len(b)):
        if _bad_identifier_byte(b[i]):
            raise Error(
                what
                + " must not hold a control byte, '/', a quote or a backslash"
            )


def check_prefix(what: String, value: String) raises:
    """Refuse a key prefix that is empty, holds a control byte, starts or ends
    with '/' or holds '//'. Slashes inside are allowed ("area/queue"). The
    prefixes of two queues, or of a queue and a lease, must not nest."""
    var b = value.as_bytes()
    if len(b) == 0:
        raise Error(what + " must not be empty")
    if b[0] == UInt8(0x2F) or b[len(b) - 1] == UInt8(0x2F):
        raise Error(what + " must not start or end with '/'")
    for i in range(len(b)):
        if b[i] < UInt8(0x20) or b[i] == UInt8(0x7F):
            raise Error(what + " must not hold a control byte")
        if b[i] == UInt8(0x2F) and i + 1 < len(b) and b[i + 1] == UInt8(0x2F):
            raise Error(what + " must not hold '//'")


def check_one_line(what: String, value: String) raises:
    """Refuse a newline in `value`: it rides one line of a framed object."""
    var b = value.as_bytes()
    for i in range(len(b)):
        if b[i] == UInt8(0x0A):
            raise Error(what + " must not hold a newline")


def to_bytes(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    var bs = s.as_bytes()
    for i in range(len(bs)):
        out.append(bs[i])
    return out^


def zeropad(v: Int64, width: Int) -> String:
    """The decimal `v` (at least zero) left-padded with '0' to `width` digits."""
    var s = String(v)
    var have = len(s.as_bytes())
    if have >= width:
        return s^
    var out = String("")
    for _ in range(width - have):
        out += String("0")
    out += s
    return out^


def parse_nonneg_i64(what: String, s: String) raises -> Int64:
    """The decimal `s` as an Int64. An empty string, a non-digit and a value
    that does not fit are errors; `what` names the field."""
    var b = s.as_bytes()
    if len(b) == 0:
        raise Error(what + " is empty")
    var acc = Int64(0)
    var limit = Int64(9223372036854775807)
    for i in range(len(b)):
        var c = Int(b[i])
        if c < 0x30 or c > 0x39:
            raise Error(what + " is not a decimal number: " + s)
        var d = Int64(c - 0x30)
        if acc > (limit - d) // Int64(10):
            raise Error(what + " does not fit in 64 bits: " + s)
        acc = acc * Int64(10) + d
    return acc


def sort_strings(mut keys: List[String]):
    """Sort `keys` ascending by insertion. A listing from an object store is
    already in key order, which is the best case (one pass); the sort is there
    so the order never depends on the store."""
    var n = len(keys)
    for i in range(1, n):
        var j = i
        while j > 0 and keys[j - 1] > keys[j]:
            var tmp = keys[j - 1].copy()
            keys[j - 1] = keys[j].copy()
            keys[j] = tmp^
            j -= 1
