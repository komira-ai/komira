# =============================================================================
# cursor_store -- where an ingest left off, kept on a conditional-write store.
# =============================================================================
#
# A source that is read incrementally (a change feed, a paged listing, a
# watermark query) needs to remember how far the last read got, so the next run
# resumes there. `SurfaceCursor` is that memory for one source of one partition:
# an opaque token, a watermark and the time of the last advance. `CursorStore`
# keeps one cursor object per (partition id, source key) on a
# `ConditionalWriteStore`, and writes it with compare-and-set so two writers of
# the same cursor cannot silently overwrite each other.
#
# Everything about a cursor is the host's data: the partition id and the source
# key are opaque strings, the token is never parsed here, and the watermark and
# the time are integers in whatever unit the host stamps. The store reads no
# clock and no environment; the time of an advance is an argument.
#
# Writes.
#   `try_save(cursor, expected_version)` is one compare-and-set. It returns True
#     when the write landed and False when another writer got there first (the
#     loser is reported, never retried, never overwritten). An empty
#     `expected_version` means "create it, and fail if it exists".
#   `save(cursor, max_attempts)` is last-writer-wins with a bound: it reads the
#     current version, tries the compare-and-set, and on a lost race reads
#     again, at most `max_attempts` times; it raises when every attempt lost.
# Reads.
#   `read` returns the cursor and the version a later `try_save` must quote;
#     `load` returns the cursor alone, or an unseeded cursor when none exists.
#     An error from the store other than "not found" is raised, never read as
#     "no cursor": treating a failed read as a first run would restart a source
#     from its beginning.
#
# Stored form. One object per cursor at `<prefix>/cursor/<hash>.cur`, where the
# hash (FNV-1a-64, 16 hex digits) is of the partition id and source key with the
# length of the partition id in front, so the key is safe on any store. The hash
# is not trusted to be unique: the object records both strings and a read that
# finds different ones raises. `save` reads before it writes, so it refuses to
# replace such an object too. A bare `try_save` with an empty version does not
# read: it loses to any existing object (a colliding one included) and returns
# False, and with a quoted version it writes over whatever holds that version.
# The object body is
#     u8 format version (1)
#     u32 length, partition id bytes
#     u32 length, source key bytes
#     u32 length, token bytes
#     i64 watermark, i64 synced_at
# with little-endian integers and strings of at most `CURSOR_MAX_FIELD_BYTES`.
# A body that is truncated, has bytes after the last field, names an unknown
# version, a length larger than the bytes that remain, or text that is not UTF-8
# is refused with an error naming the defect.
# =============================================================================

from komira_kg_format.utf8_check import bytes_are_utf8
from komira_objectstore.cas_manifest import is_not_found, is_precondition
from komira_objectstore.path import Path
from komira_objectstore.store import ConditionalWriteStore
from komira_objectstore.types import WritePrecondition

comptime CURSOR_FORMAT_VERSION: Int = 1
comptime CURSOR_MAX_FIELD_BYTES: Int = 65536
"""The longest partition id, source key or token, in bytes."""

comptime _FNV_OFFSET: UInt64 = 14695981039346656037
comptime _FNV_PRIME: UInt64 = 1099511628211


struct SurfaceCursor(Copyable, Movable):
    """Where an incremental read of one source stopped.

    Fields:
        partition_id: The partition the source's rows belong to.
        source_key: The host's name for the source.
        token: The opaque resume token; empty when the source uses a watermark
            alone or has not been read yet. Never parsed here.
        watermark: The newest position the host has already ingested, in the
            host's unit; 0 when unseeded.
        synced_at: When the cursor last advanced, in the host's unit; 0 when
            unseeded. Provenance only.
    """

    var partition_id: String
    var source_key: String
    var token: String
    var watermark: Int64
    var synced_at: Int64

    def __init__(
        out self,
        var partition_id: String,
        var source_key: String,
        var token: String,
        watermark: Int64,
        synced_at: Int64,
    ):
        self.partition_id = partition_id^
        self.source_key = source_key^
        self.token = token^
        self.watermark = watermark
        self.synced_at = synced_at

    @staticmethod
    def empty(
        var partition_id: String, var source_key: String
    ) -> SurfaceCursor:
        """An unseeded cursor: no token, watermark 0, never synced."""
        return SurfaceCursor(
            partition_id^, source_key^, String(""), Int64(0), Int64(0)
        )

    def is_seeded(self) -> Bool:
        """True if the cursor holds a token or a watermark above 0."""
        return len(self.token.as_bytes()) > 0 or self.watermark > Int64(0)


struct CursorRead(Movable):
    """A cursor as read, with the version a later write must quote.

    Fields:
        cursor: The stored cursor, or an unseeded one when `found` is False.
        version: The store's version of the object read; empty when not found.
        found: Whether a cursor was stored.
    """

    var cursor: SurfaceCursor
    var version: String
    var found: Bool

    def __init__(
        out self, var cursor: SurfaceCursor, var version: String, found: Bool
    ):
        self.cursor = cursor^
        self.version = version^
        self.found = found


def _fnv_hex(partition_id: String, source_key: String) -> String:
    var h = _FNV_OFFSET
    var head = String(len(partition_id.as_bytes())) + ":"
    var hb = head.as_bytes()
    for i in range(len(hb)):
        h = (h ^ UInt64(Int(hb[i]))) * _FNV_PRIME
    var pb = partition_id.as_bytes()
    for i in range(len(pb)):
        h = (h ^ UInt64(Int(pb[i]))) * _FNV_PRIME
    var sb = source_key.as_bytes()
    for i in range(len(sb)):
        h = (h ^ UInt64(Int(sb[i]))) * _FNV_PRIME
    var digits = "0123456789abcdef"
    var db = digits.as_bytes()
    var out = List[UInt8](capacity=16)
    var shift = 60
    while shift >= 0:
        out.append(db[Int((h >> UInt64(shift)) & UInt64(0xF))])
        shift -= 4
    # SAFETY: every byte was taken from the ASCII digit table above.
    return String(unsafe_from_utf8=Span(out))


def _put_u32(mut out: List[UInt8], v: Int):
    for k in range(4):
        out.append(UInt8((v >> (8 * k)) & 0xFF))


def _put_i64(mut out: List[UInt8], v: Int64):
    var u = UInt64(Int(v))
    for k in range(8):
        out.append(UInt8(Int((u >> UInt64(8 * k)) & UInt64(0xFF))))


def _put_text(mut out: List[UInt8], s: String, what: String) raises:
    var b = s.as_bytes()
    if len(b) > CURSOR_MAX_FIELD_BYTES:
        raise Error(
            "CursorStore: the "
            + what
            + " is "
            + String(len(b))
            + " bytes, over the limit of "
            + String(CURSOR_MAX_FIELD_BYTES)
        )
    _put_u32(out, len(b))
    for i in range(len(b)):
        out.append(b[i])


def encode_cursor(cursor: SurfaceCursor) raises -> List[UInt8]:
    """The stored form of `cursor` (see the file header).

    Raises:
        If the partition id, source key or token is over the size limit.
    """
    var out = List[UInt8]()
    out.append(UInt8(CURSOR_FORMAT_VERSION))
    _put_text(out, cursor.partition_id, "partition id")
    _put_text(out, cursor.source_key, "source key")
    _put_text(out, cursor.token, "token")
    _put_i64(out, cursor.watermark)
    _put_i64(out, cursor.synced_at)
    return out^


def _need(body: List[UInt8], off: Int, count: Int, what: String) raises:
    # Subtraction, never `off + count`: the count is read from the body.
    if count < 0 or len(body) - off < count:
        raise Error(
            "CursorStore.decode: truncated "
            + what
            + " at offset "
            + String(off)
            + " ("
            + String(len(body) - off)
            + " bytes remain)"
        )


def _get_text(body: List[UInt8], mut off: Int, what: String) raises -> String:
    _need(body, off, 4, what + " length")
    var n = (
        Int(body[off])
        | (Int(body[off + 1]) << 8)
        | (Int(body[off + 2]) << 16)
        | (Int(body[off + 3]) << 24)
    )
    off += 4
    if n > CURSOR_MAX_FIELD_BYTES:
        raise Error(
            "CursorStore.decode: the "
            + what
            + " claims "
            + String(n)
            + " bytes, over the limit of "
            + String(CURSOR_MAX_FIELD_BYTES)
        )
    _need(body, off, n, what)
    var bytes = List[UInt8](capacity=n)
    for i in range(n):
        bytes.append(body[off + i])
    off += n
    if not bytes_are_utf8(Span(bytes)):
        raise Error("CursorStore.decode: the " + what + " is not valid UTF-8")
    # SAFETY: checked well-formed just above.
    return String(unsafe_from_utf8=Span(bytes))


def _get_i64(body: List[UInt8], mut off: Int, what: String) raises -> Int64:
    _need(body, off, 8, what)
    var u = UInt64(0)
    for k in range(8):
        u = u | (UInt64(Int(body[off + k])) << UInt64(8 * k))
    off += 8
    return Int64(Int(u))


def decode_cursor(body: List[UInt8]) raises -> SurfaceCursor:
    """The cursor stored in `body` (the inverse of `encode_cursor`).

    Raises:
        If the body is empty or truncated, names an unknown format version,
        holds a length over the limit or past the end, holds text that is not
        UTF-8, or has bytes after the last field.
    """
    var off = 0
    _need(body, off, 1, "format version")
    var version = Int(body[0])
    off += 1
    if version != CURSOR_FORMAT_VERSION:
        raise Error(
            "CursorStore.decode: format version "
            + String(version)
            + " is not the supported "
            + String(CURSOR_FORMAT_VERSION)
        )
    var partition_id = _get_text(body, off, "partition id")
    var source_key = _get_text(body, off, "source key")
    var token = _get_text(body, off, "token")
    var watermark = _get_i64(body, off, "watermark")
    var synced_at = _get_i64(body, off, "synced_at")
    if off != len(body):
        raise Error(
            "CursorStore.decode: "
            + String(len(body) - off)
            + " trailing bytes after the last field"
        )
    return SurfaceCursor(
        partition_id^, source_key^, token^, watermark, synced_at
    )


struct CursorStore[Store: ConditionalWriteStore](Movable):
    """Cursors on a conditional-write store, one object each (see the header).

    Parameters:
        Store: The object store; the in-memory and local-file stores and the
            cloud stores all conform.
    """

    var _store: Self.Store
    var _prefix: String

    def __init__(out self, var store: Self.Store, var prefix: String):
        """Cursors under `<prefix>/cursor/` on `store`."""
        self._store = store^
        self._prefix = prefix^

    def prefix(self) -> String:
        """The key prefix this store writes under."""
        return self._prefix

    def _path_for(self, partition_id: String, source_key: String) raises -> Path:
        return Path.parse(
            self._prefix
            + "/cursor/"
            + _fnv_hex(partition_id, source_key)
            + ".cur"
        )

    def read(
        self, partition_id: String, source_key: String
    ) raises -> CursorRead:
        """The stored cursor and its version, or an unseeded cursor with
        `found` False when none is stored.

        The version is read before the body: a writer that lands between the
        two makes the version stale, so a write quoting it loses and the caller
        reads again, where the reverse order could pair a new version with an
        old body.

        Raises:
            If the store fails for any reason but "not found", if the object
            does not decode, or if it holds a different partition id or source
            key (a hash collision).
        """
        var path = self._path_for(partition_id, source_key)
        var version: String
        try:
            version = self._store.head(path).etag
        except e:
            if is_not_found(String(e)):
                return CursorRead(
                    SurfaceCursor.empty(partition_id, source_key),
                    String(""),
                    False,
                )
            raise e^
        var body = self._store.get(path)
        var cursor = decode_cursor(body)
        if cursor.partition_id != partition_id or cursor.source_key != source_key:
            raise Error(
                "CursorStore.read: the object at "
                + path.raw()
                + " holds a cursor for a different partition id or source key"
                " (a hash collision); refusing to use it"
            )
        return CursorRead(cursor^, version^, True)

    def load(
        self, partition_id: String, source_key: String
    ) raises -> SurfaceCursor:
        """The stored cursor, or an unseeded one when none is stored."""
        var r = self.read(partition_id, source_key)
        return r.cursor.copy()

    def has(self, partition_id: String, source_key: String) raises -> Bool:
        """Whether a cursor is stored for the pair."""
        return self.read(partition_id, source_key).found

    def try_save(
        mut self, cursor: SurfaceCursor, expected_version: String
    ) raises -> Bool:
        """One compare-and-set of `cursor`.

        Args:
            cursor: The cursor to store.
            expected_version: The `version` of the `read` this write follows;
                empty to create the cursor and fail if one exists.

        Returns:
            True if the write landed, False if another writer changed (or
            created) the object since the read. The object is untouched then.

        Raises:
            If the cursor is over the size limits, or the store fails for any
            reason but the lost race.
        """
        var body = encode_cursor(cursor)
        var path = self._path_for(cursor.partition_id, cursor.source_key)
        var precondition: WritePrecondition
        if len(expected_version.as_bytes()) == 0:
            precondition = WritePrecondition.if_none_match_star()
        else:
            precondition = WritePrecondition.if_match(expected_version)
        try:
            _ = self._store.conditional_put(path, body^, precondition)
        except e:
            if is_precondition(String(e)):
                return False
            raise e^
        return True

    def save(mut self, cursor: SurfaceCursor, max_attempts: Int) raises:
        """Store `cursor`, replacing what is there; the last writer wins.

        Each attempt reads the current version and tries one compare-and-set; a
        lost race starts the next attempt.

        Args:
            cursor: The cursor to store.
            max_attempts: The most attempts to make; at least 1.

        Raises:
            If `max_attempts` is under 1, if every attempt lost its race, or if
            a read or write fails (see `read` and `try_save`).
        """
        if max_attempts < 1:
            raise Error(
                "CursorStore.save: max_attempts is "
                + String(max_attempts)
                + ", and at least one attempt is needed"
            )
        for _ in range(max_attempts):
            var current = self.read(cursor.partition_id, cursor.source_key)
            if self.try_save(cursor, current.version):
                return
        raise Error(
            "CursorStore.save: lost the compare-and-set race on all "
            + String(max_attempts)
            + " attempts for partition '"
            + cursor.partition_id
            + "', source '"
            + cursor.source_key
            + "'"
        )

    def list_cursors(self) raises -> List[SurfaceCursor]:
        """Every stored cursor, in the store's listing order.

        Raises:
            If a stored object does not decode.
        """
        var listing = self._store.list_with_delimiter(
            Path.parse(self._prefix + "/cursor/")
        )
        var out = List[SurfaceCursor]()
        for i in range(len(listing.objects)):
            var location = listing.objects[i].location
            if not location.endswith(".cur"):
                continue
            var body = self._store.get(Path.parse(location))
            out.append(decode_cursor(body))
        return out^
