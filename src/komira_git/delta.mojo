# =============================================================================
# komira_git/delta.mojo -- applying a git delta (gitformat-pack, "Deltified
# representation").
# =============================================================================
#
# A delta is two sizes, each a little-endian base-128 number (seven bits per
# byte, low group first, 0x80 = more): the base's size and the result's
# size. Then instructions until the end of the delta:
#
#   * `1xxxxxxx` copy: bits 0-3 say which of four offset bytes follow, bits
#     4-6 which of three size bytes follow (each little-endian, absent bytes
#     zero); a size of zero means 0x10000. Copies `base[offset:offset+size]`.
#   * `0xxxxxxx` with x > 0, insert: the next x bytes of the delta.
#   * `00000000` is reserved; git refuses it and so does `apply_delta`.
#
# `apply_delta` refuses a base whose size is not the declared one, a result
# over `max_size` (before anything is allocated), a copy outside the base,
# an insert past the end of the delta, and a result whose size is not the
# declared one, so no instruction reads or writes past a buffer.
# =============================================================================


struct DeltaHeader(ImplicitlyCopyable, Movable):
    """The two sizes at the start of a delta, and where its instructions
    start."""

    var base_size: Int
    var result_size: Int
    var instructions_start: Int

    def __init__(out self, base_size: Int, result_size: Int, instructions_start: Int):
        self.base_size = base_size
        self.result_size = result_size
        self.instructions_start = instructions_start


def _delta_varint(delta: Span[UInt8, _], mut p: Int) raises -> Int:
    var v = 0
    var shift = 0
    while True:
        if p >= len(delta):
            raise Error("komira_git: delta: truncated header")
        if shift > 56:
            raise Error("komira_git: delta: size does not fit 64 bits")
        var c = Int(delta[p])
        p += 1
        v |= (c & 127) << shift
        shift += 7
        if (c & 128) == 0:
            return v


def read_delta_header(delta: Span[UInt8, _]) raises -> DeltaHeader:
    """The base size and result size a delta declares."""
    var p = 0
    var base_size = _delta_varint(delta, p)
    var result_size = _delta_varint(delta, p)
    return DeltaHeader(base_size, result_size, p)


def apply_delta(
    base: Span[UInt8, _], delta: Span[UInt8, _], max_size: Int
) raises -> List[UInt8]:
    """The object `delta` rebuilds from `base`. The result may be at most
    `max_size` bytes; every refusal the header of this file lists raises."""
    var head = read_delta_header(delta)
    if head.base_size != len(base):
        raise Error(
            "komira_git: delta: expects a base of " + String(head.base_size)
            + " bytes, the base is " + String(len(base))
        )
    if head.result_size > max_size:
        raise Error(
            "komira_git: delta: result of " + String(head.result_size)
            + " bytes is over the limit " + String(max_size)
        )
    var want = head.result_size
    var out = List[UInt8](capacity=want)
    var p = head.instructions_start
    var n = len(delta)
    while p < n:
        var op = Int(delta[p])
        p += 1
        if op & 128:
            var off = 0
            var size = 0
            for i in range(4):
                if op & (1 << i):
                    if p >= n:
                        raise Error("komira_git: delta: truncated copy instruction")
                    off |= Int(delta[p]) << (8 * i)
                    p += 1
            for i in range(3):
                if op & (16 << i):
                    if p >= n:
                        raise Error("komira_git: delta: truncated copy instruction")
                    size |= Int(delta[p]) << (8 * i)
                    p += 1
            if size == 0:
                size = 0x10000
            if off + size > len(base):
                raise Error(
                    "komira_git: delta: copy of " + String(size) + " bytes at "
                    + String(off) + " runs past the " + String(len(base))
                    + "-byte base"
                )
            if len(out) + size > want:
                raise Error(
                    "komira_git: delta: result runs past its declared "
                    + String(want) + " bytes"
                )
            out.extend(base[off : off + size])
        elif op != 0:
            if p + op > n:
                raise Error(
                    "komira_git: delta: insert of " + String(op)
                    + " bytes runs past the end of the delta"
                )
            if len(out) + op > want:
                raise Error(
                    "komira_git: delta: result runs past its declared "
                    + String(want) + " bytes"
                )
            out.extend(delta[p : p + op])
            p += op
        else:
            raise Error("komira_git: delta: opcode 0 is reserved")
    if len(out) != want:
        raise Error(
            "komira_git: delta: result is " + String(len(out))
            + " bytes, the header says " + String(want)
        )
    return out^
