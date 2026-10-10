# =============================================================================
# komira_git/object_id.mojo -- object formats, object kinds and object ids.
# =============================================================================
#
# An object id is the hash of `<kind> <decimal size>\0<payload>` under the
# repository's object format (gitformat-loose, "Object format"): SHA-1 (20
# bytes, 40 hex digits) or SHA-256 (32 bytes, 64 hex digits). Every
# `ObjectId` carries its format, so an id of one format is never compared
# equal to, or written into an object of, the other.
#
# `ObjectKind` numbers are git's own type codes (commit 1, tree 2, blob 3,
# tag 4), the numbers a pack entry header carries.
#
# SHA-1 ids are computed with collision detection (sha1dc.mojo, the SHA-1
# git uses): an object holding a block of a detected SHA-1 collision has no
# id, and `hash_object` raises the error OBJECT_ID_COLLISION names.
# =============================================================================

from komira_crypto import Sha256

from .bytes_util import _append_decimal, _append_str, _hex_digit, _hex_value
from .sha1dc import Sha1dc, _collision_error

comptime _FORMAT_SHA1: Int = 1
comptime _FORMAT_SHA256: Int = 2

comptime _KIND_COMMIT: Int = 1
comptime _KIND_TREE: Int = 2
comptime _KIND_BLOB: Int = 3
comptime _KIND_TAG: Int = 4


struct ObjectFormat(ImplicitlyCopyable, Movable, Equatable, Writable):
    """A repository object format: `sha1` or `sha256`."""

    var _code: Int

    def __init__(out self, *, _code: Int):
        self._code = _code

    @staticmethod
    def sha1() -> ObjectFormat:
        """SHA-1: 20-byte ids, 40 hex digits."""
        return ObjectFormat(_code=_FORMAT_SHA1)

    @staticmethod
    def sha256() -> ObjectFormat:
        """SHA-256: 32-byte ids, 64 hex digits."""
        return ObjectFormat(_code=_FORMAT_SHA256)

    @staticmethod
    def from_name(name: String) raises -> ObjectFormat:
        """`sha1` or `sha256` (the `extensions.objectFormat` spelling)."""
        if name == "sha1":
            return ObjectFormat.sha1()
        if name == "sha256":
            return ObjectFormat.sha256()
        raise Error("komira_git: unknown object format '" + name + "'")

    def raw_size(self) -> Int:
        """Bytes in one id: 20 or 32."""
        if self._code == _FORMAT_SHA1:
            return 20
        return 32

    def hex_size(self) -> Int:
        """Hex digits in one id: 40 or 64."""
        return 2 * self.raw_size()

    def name(self) -> String:
        """`sha1` or `sha256`."""
        if self._code == _FORMAT_SHA1:
            return String("sha1")
        return String("sha256")

    def __eq__(self, other: Self) -> Bool:
        return self._code == other._code

    def __ne__(self, other: Self) -> Bool:
        return self._code != other._code

    def write_to[W: Writer, //](self, mut writer: W):
        writer.write(self.name())


struct ObjectKind(ImplicitlyCopyable, Movable, Equatable, Writable):
    """The kind of a git object: commit, tree, blob or tag."""

    var _code: Int

    def __init__(out self, *, _code: Int):
        self._code = _code

    @staticmethod
    def commit() -> ObjectKind:
        return ObjectKind(_code=_KIND_COMMIT)

    @staticmethod
    def tree() -> ObjectKind:
        return ObjectKind(_code=_KIND_TREE)

    @staticmethod
    def blob() -> ObjectKind:
        return ObjectKind(_code=_KIND_BLOB)

    @staticmethod
    def tag() -> ObjectKind:
        return ObjectKind(_code=_KIND_TAG)

    @staticmethod
    def from_name(name: Span[UInt8, _]) raises -> ObjectKind:
        """`commit`, `tree`, `blob` or `tag`, exactly (lowercase)."""
        var n = len(name)
        var s = String()
        for i in range(n):
            var c = Int(name[i])
            if c < 97 or c > 122 or n > 6:
                raise Error("komira_git: unknown object kind")
            s += chr(c)
        if s == "commit":
            return ObjectKind.commit()
        if s == "tree":
            return ObjectKind.tree()
        if s == "blob":
            return ObjectKind.blob()
        if s == "tag":
            return ObjectKind.tag()
        raise Error("komira_git: unknown object kind '" + s + "'")

    @staticmethod
    def from_code(code: Int) raises -> ObjectKind:
        """git's type number: 1 commit, 2 tree, 3 blob, 4 tag."""
        if code >= _KIND_COMMIT and code <= _KIND_TAG:
            return ObjectKind(_code=code)
        raise Error("komira_git: unknown object type number " + String(code))

    def code(self) -> Int:
        """git's type number: 1 commit, 2 tree, 3 blob, 4 tag."""
        return self._code

    def name(self) -> String:
        """`commit`, `tree`, `blob` or `tag`."""
        if self._code == _KIND_COMMIT:
            return String("commit")
        if self._code == _KIND_TREE:
            return String("tree")
        if self._code == _KIND_BLOB:
            return String("blob")
        return String("tag")

    def __eq__(self, other: Self) -> Bool:
        return self._code == other._code

    def __ne__(self, other: Self) -> Bool:
        return self._code != other._code

    def write_to[W: Writer, //](self, mut writer: W):
        writer.write(self.name())


struct ObjectId(ImplicitlyCopyable, Movable, Equatable, Writable):
    """An object id: its format and its 20 or 32 raw bytes.

    Stored as four 8-lane byte vectors (alignment 8, implicitly copyable);
    the bytes past `format.raw_size()` are zero.
    """

    var _format: ObjectFormat
    var _w0: SIMD[DType.uint8, 8]
    var _w1: SIMD[DType.uint8, 8]
    var _w2: SIMD[DType.uint8, 8]
    var _w3: SIMD[DType.uint8, 8]

    def __init__(out self, format: ObjectFormat):
        """The all-zero id of `format` (git's null id)."""
        self._format = format
        self._w0 = SIMD[DType.uint8, 8](0)
        self._w1 = SIMD[DType.uint8, 8](0)
        self._w2 = SIMD[DType.uint8, 8](0)
        self._w3 = SIMD[DType.uint8, 8](0)

    @staticmethod
    def zero(format: ObjectFormat) -> ObjectId:
        """git's null id of `format` (all zero bytes)."""
        return ObjectId(format)

    @staticmethod
    def from_raw(format: ObjectFormat, raw: Span[UInt8, _]) raises -> ObjectId:
        """The id whose bytes are `raw`; `len(raw)` must be the format's size."""
        if len(raw) != format.raw_size():
            raise Error(
                "komira_git: a " + format.name() + " id is "
                + String(format.raw_size()) + " bytes, got " + String(len(raw))
            )
        var id = ObjectId(format)
        for i in range(len(raw)):
            id._set_byte(i, raw[i])
        return id

    @staticmethod
    def parse_hex(format: ObjectFormat, text: String) raises -> ObjectId:
        """The id spelled by `text`: exactly `format.hex_size()` hex digits,
        either case."""
        var b = text.as_bytes()
        if len(b) != format.hex_size():
            raise Error(
                "komira_git: a " + format.name() + " id is "
                + String(format.hex_size()) + " hex digits, got "
                + String(len(b))
            )
        return ObjectId._from_hex_span(format, b, 0)

    @staticmethod
    def _from_hex_span(
        format: ObjectFormat, b: Span[UInt8, _], start: Int
    ) raises -> ObjectId:
        """The id spelled by `format.hex_size()` hex digits at `b[start:]`;
        the caller has checked that they are there."""
        var id = ObjectId(format)
        for i in range(format.raw_size()):
            var hi = _hex_value(Int(b[start + 2 * i]))
            var lo = _hex_value(Int(b[start + 2 * i + 1]))
            if hi < 0 or lo < 0:
                raise Error(
                    "komira_git: bad hex digit in object id at offset "
                    + String(2 * i if hi < 0 else 2 * i + 1)
                )
            id._set_byte(i, UInt8(hi * 16 + lo))
        return id

    @always_inline
    def _byte(self, i: Int) -> UInt8:
        if i < 8:
            return self._w0[i]
        if i < 16:
            return self._w1[i - 8]
        if i < 24:
            return self._w2[i - 16]
        return self._w3[i - 24]

    @always_inline
    def _set_byte(mut self, i: Int, v: UInt8):
        if i < 8:
            self._w0[i] = v
        elif i < 16:
            self._w1[i - 8] = v
        elif i < 24:
            self._w2[i - 16] = v
        else:
            self._w3[i - 24] = v

    def format(self) -> ObjectFormat:
        """The object format this id belongs to."""
        return self._format

    def byte_at(self, i: Int) -> UInt8:
        """Raw byte `i`, 0 <= i < format().raw_size()."""
        return self._byte(i)

    def raw_bytes(self) -> List[UInt8]:
        """The 20 or 32 raw bytes."""
        var out = List[UInt8](capacity=self._format.raw_size())
        self.append_raw_to(out)
        return out^

    def append_raw_to(self, mut out: List[UInt8]):
        """Append the raw bytes to `out` (the form a tree entry carries)."""
        for i in range(self._format.raw_size()):
            out.append(self._byte(i))

    def to_hex(self) -> String:
        """Lowercase hex, 40 or 64 digits."""
        var s = String()
        for i in range(self._format.raw_size()):
            var v = Int(self._byte(i))
            s += _hex_digit(v >> 4)
            s += _hex_digit(v & 15)
        return s^

    def append_hex_to(self, mut out: List[UInt8]):
        """Append the lowercase hex spelling to `out` (the form a commit or
        tag header carries)."""
        _append_str(out, self.to_hex())

    def is_zero(self) -> Bool:
        """True for git's null id."""
        for i in range(self._format.raw_size()):
            if self._byte(i) != 0:
                return False
        return True

    def __eq__(self, other: Self) -> Bool:
        if self._format != other._format:
            return False
        for i in range(self._format.raw_size()):
            if self._byte(i) != other._byte(i):
                return False
        return True

    def __ne__(self, other: Self) -> Bool:
        return not (self == other)

    def write_to[W: Writer, //](self, mut writer: W):
        writer.write(self.to_hex())


def object_header(kind: ObjectKind, size: Int) -> List[UInt8]:
    """`<kind> <size>\\0`, the bytes hashed (and stored loose) before an
    object's payload."""
    var out = List[UInt8]()
    _append_str(out, kind.name())
    out.append(UInt8(32))
    _append_decimal(out, size)
    out.append(UInt8(0))
    return out^


def _sha1_object_digest(
    h: Sha1dc, kind: ObjectKind, size: Int
) raises -> InlineArray[UInt8, 20]:
    """The digest of the object stream `h` absorbed (the header of a `kind`
    object of `size` payload bytes, then the payload), or the
    OBJECT_ID_COLLISION error naming that object when `h` detected a
    collision."""
    var d = InlineArray[UInt8, 20](fill=0)
    if h.finalize_into(d):
        raise _collision_error(
            "the " + kind.name() + " of " + String(size) + " bytes"
        )
    return d^


def hash_object(
    format: ObjectFormat, kind: ObjectKind, payload: Span[UInt8, _]
) raises -> ObjectId:
    """The id of the object of `kind` whose payload is `payload`: the
    format's hash of `object_header(kind, len(payload))` then `payload`
    (what `git hash-object -t <kind>` prints). Under SHA-1 the hash detects
    collisions: an object holding a block of one raises the
    OBJECT_ID_COLLISION error, as git refuses it."""
    var header = object_header(kind, len(payload))
    var id = ObjectId(format)
    if format == ObjectFormat.sha1():
        var h = Sha1dc()
        h.update(Span(header))
        h.update(payload)
        var d = _sha1_object_digest(h, kind, len(payload))
        for i in range(20):
            id._set_byte(i, d[i])
    else:
        var h = Sha256()
        h.update(Span(header))
        h.update(payload)
        var d = InlineArray[UInt8, 32](fill=0)
        h.finalize_into(d)
        for i in range(32):
            id._set_byte(i, d[i])
    return id
