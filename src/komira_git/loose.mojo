# =============================================================================
# komira_git/loose.mojo -- loose objects (gitformat-loose).
# =============================================================================
#
# A loose object is one zlib stream (RFC 1950 framing) whose inflated bytes
# are `<kind> SP <decimal size> NUL <payload>`; it lives at
# `objects/<first two hex digits>/<the rest>` of its id.
#
# `decode_loose` refuses:
#   * an unknown kind, a size that is not a plain decimal (no sign, no
#     leading zero), a header with no NUL in its first 64 inflated bytes,
#   * a declared size above the caller's `max_size` (checked before the
#     payload is inflated, so a small file cannot claim a huge buffer),
#   * a stream that inflates to more or fewer bytes than declared, a corrupt
#     or truncated stream, and bytes after the end of the stream.
# `read_loose` also hashes the result and refuses an id other than the one
# the object was looked up by.
#
# `encode_loose` deflates at level 1, the level git writes loose objects at
# (`core.looseCompression` defaults to best speed).
# =============================================================================

from komira_zlib import ZLIB_WINDOW_BITS_ZLIB, zlib_compress_bound, zlib_deflate_into, zlib_inflate_once

from .bytes_util import _append_span, _find_byte, _parse_decimal, _to_list
from .object_id import ObjectId, ObjectKind, hash_object, object_header

comptime LOOSE_LEVEL: Int32 = 1
"""The zlib level `encode_loose` uses (git's loose-object default)."""

comptime _HEADER_PROBE: Int = 64
comptime _Z_OK: Int = 0
comptime _Z_STREAM_END: Int = 1
comptime _Z_BUF_ERROR: Int = -5


struct LooseObject(Copyable, Movable):
    """A decoded loose object: its kind and its payload."""

    var kind: ObjectKind
    var payload: List[UInt8]

    def __init__(out self, kind: ObjectKind, var payload: List[UInt8]):
        self.kind = kind
        self.payload = payload^


def loose_path(id: ObjectId) -> String:
    """`<2 hex digits>/<the rest>`, the path of the object under `objects/`."""
    var hex = id.to_hex()
    var b = hex.as_bytes()
    var out = String()
    for i in range(len(b)):
        if i == 2:
            out += "/"
        out += chr(Int(b[i]))
    return out^


def encode_loose(kind: ObjectKind, payload: Span[UInt8, _]) raises -> List[UInt8]:
    """The loose-object bytes of an object: its header and payload in one
    zlib stream."""
    var plain = object_header(kind, len(payload))
    _append_span(plain, payload)
    var bound = zlib_compress_bound(len(plain), ZLIB_WINDOW_BITS_ZLIB)
    var out = List[UInt8](length=bound, fill=UInt8(0))
    var n = zlib_deflate_into(Span(out), Span(plain), LOOSE_LEVEL, ZLIB_WINDOW_BITS_ZLIB)
    out.resize(n, UInt8(0))
    return out^


def decode_loose(data: Span[UInt8, _], max_size: Int) raises -> LooseObject:
    """Inflate and check a loose object whose payload may be at most
    `max_size` bytes, refusing every malformation the header of this file
    lists."""
    if len(data) == 0:
        raise Error("komira_git: loose object: empty file")
    var probe = List[UInt8](length=_HEADER_PROBE, fill=UInt8(0))
    var first = zlib_inflate_once(Span(probe), data, ZLIB_WINDOW_BITS_ZLIB)
    var rc = Int(first.rc)
    if rc != _Z_OK and rc != _Z_STREAM_END and rc != _Z_BUF_ERROR:
        raise Error(
            "komira_git: loose object: corrupt zlib stream (rc=" + String(rc) + ")"
        )
    var head = Span(probe)[0 : first.written]
    var nul = _find_byte(head, 0, 0)
    if nul < 0:
        raise Error("komira_git: loose object: no NUL in the first 64 bytes")
    var sp = _find_byte(head[0:nul], 0, 32)
    if sp < 0:
        raise Error("komira_git: loose object: header has no space")
    var kind: ObjectKind
    try:
        kind = ObjectKind.from_name(head[0:sp])
    except:
        raise Error("komira_git: loose object: unknown kind")
    var size = _parse_decimal(head, sp + 1, nul, "komira_git: loose object: size")
    if size > max_size:
        raise Error(
            "komira_git: loose object: size " + String(size)
            + " exceeds the limit " + String(max_size)
        )
    var want = nul + 1 + size
    var full = List[UInt8](length=want + 1, fill=UInt8(0))
    var out = zlib_inflate_once(Span(full), data, ZLIB_WINDOW_BITS_ZLIB)
    rc = Int(out.rc)
    if rc == _Z_STREAM_END:
        if out.unread > 0:
            raise Error(
                "komira_git: loose object: " + String(out.unread)
                + " bytes after the zlib stream"
            )
        if out.written != want:
            raise Error(
                "komira_git: loose object: inflates to "
                + String(out.written - nul - 1) + " payload bytes, header says "
                + String(size)
            )
        return LooseObject(kind, _to_list(Span(full), nul + 1, want))
    if rc == _Z_OK or rc == _Z_BUF_ERROR:
        if out.unwritten == 0:
            raise Error(
                "komira_git: loose object: inflates past its declared size "
                + String(size)
            )
        raise Error("komira_git: loose object: truncated zlib stream")
    raise Error(
        "komira_git: loose object: corrupt zlib stream (rc=" + String(rc) + ")"
    )


def read_loose(
    expected: ObjectId, data: Span[UInt8, _], max_size: Int
) raises -> LooseObject:
    """`decode_loose`, then refuse the object unless it hashes to
    `expected` under `expected`'s format."""
    var obj = decode_loose(data, max_size)
    var got = hash_object(expected.format(), obj.kind, Span(obj.payload))
    if got != expected:
        raise Error(
            "komira_git: loose object: hashes to " + got.to_hex()
            + ", expected " + expected.to_hex()
        )
    return obj^
