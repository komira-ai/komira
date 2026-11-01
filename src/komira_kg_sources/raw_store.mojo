# =============================================================================
# raw_store -- raw source records kept once each, under their content hash.
# =============================================================================
#
# A host that reads from many sources first lands what it fetched as it came,
# unparsed, and lowers it to episodes later. `RawStore` is that landing zone: one
# object per distinct payload on a `ConditionalWriteStore`, keyed by the hash of
# the payload bytes. The surface tag (an opaque string naming which kind of
# record the bytes are, and so which adapter lowers them) is metadata on the
# record, not part of its key:
#
#   * the same bytes put under two tags are one record. The first put keeps its
#     tag and its `received_at`; the second reports `created = False` and
#     writes nothing;
#   * a payload is never overwritten. `put` writes with create-if-absent. When
#     that loses (the object is already there, or another writer got there
#     first) the stored record is read back and compared with the payload: the
#     same bytes are a repeat, different bytes under the same hash are a hash
#     collision and are refused with an error, never replaced.
#
# Stored form. One object at `<prefix>/raw/<hash>.rawrec`, where the hash is
# `fnv1a64_hex` of the payload (16 lowercase hex digits). The body is
#     u8 format version (1)
#     u32 length, surface tag bytes
#     i64 received_at
#     u32 length, payload bytes
# in little-endian. A read recomputes the payload's hash and refuses a record
# whose payload does not hash to the name it was read under. A body that is
# truncated, names another version, holds a length past its end, a tag that is
# not UTF-8 or bytes after the payload is refused with an error naming the
# defect.
#
# The store reads no clock: `received_at` is an argument in whatever unit the
# host uses. It is provenance only.
# =============================================================================

from komira_kg_format import fnv1a64_hex
from komira_objectstore.cas_manifest import is_not_found, is_precondition
from komira_objectstore.path import Path
from komira_objectstore.store import ConditionalWriteStore
from komira_objectstore.types import WritePrecondition

from .framing import (
    check_prefix,
    check_text,
    expect_end,
    get_bytes,
    get_i64,
    get_text,
    get_u8,
    is_hash_name,
    name_without_suffix,
    put_bytes,
    put_i64,
    put_text,
    put_u8,
    sort_strings,
)

comptime RAW_FORMAT_VERSION: Int = 1
"""The format version of a stored raw record; the decoder accepts only this."""

comptime _WHO: String = "RawStore"
comptime _SUFFIX: String = ".rawrec"


def raw_content_hash(payload: List[UInt8]) -> String:
    """The key a payload is stored under: `fnv1a64_hex` of its bytes."""
    return fnv1a64_hex(Span(payload))


def _same_bytes(a: List[UInt8], b: List[UInt8]) -> Bool:
    if len(a) != len(b):
        return False
    for i in range(len(a)):
        if a[i] != b[i]:
            return False
    return True


struct RawRecord(Copyable, Movable):
    """One stored raw payload.

    Fields:
        surface_tag: The opaque tag the host stored it under; it selects the
            adapter that lowers the payload. Never interpreted here.
        received_at: When the host received the payload, in the host's unit.
            Provenance only.
        payload: The bytes exactly as they were put.
    """

    var surface_tag: String
    var received_at: Int64
    var payload: List[UInt8]

    def __init__(
        out self,
        var surface_tag: String,
        received_at: Int64,
        var payload: List[UInt8],
    ):
        self.surface_tag = surface_tag^
        self.received_at = received_at
        self.payload = payload^

    def content_hash(self) -> String:
        """The key this record is stored under."""
        return raw_content_hash(self.payload)


@fieldwise_init
struct RawPut(Copyable, Movable):
    """What a `RawStore.put` did.

    Fields:
        content_hash: The key of the record the payload is stored as.
        created: True if this put wrote the record; False if the same bytes
            were already stored (under any tag) and nothing was written.
    """

    var content_hash: String
    var created: Bool


def check_same_payload(
    existing: RawRecord, payload: List[UInt8], key: String
) raises:
    """Refuse unless the stored record under `key` holds exactly `payload`.

    `put` calls this when its create-if-absent write finds the object already
    there: the same bytes are a repeat, other bytes under one hash are a hash
    collision, and nothing may replace the stored record.

    Raises:
        If the bytes differ.
    """
    if not _same_bytes(existing.payload, payload):
        raise Error(
            _WHO
            + ".put: a record with different bytes is already stored under "
            + key
            + " (a hash collision); refusing to replace it"
        )


def encode_raw_record(record: RawRecord) raises -> List[UInt8]:
    """The stored form of `record` (see the file header).

    Raises:
        If the tag is empty, over the size limit or holds a control byte, or the
        payload is too long to count in a u32.
    """
    check_text("surface tag", record.surface_tag, False)
    var out = List[UInt8]()
    put_u8(out, RAW_FORMAT_VERSION)
    put_text(out, record.surface_tag, "surface tag")
    put_i64(out, record.received_at)
    put_bytes(out, record.payload, "payload")
    return out^


def decode_raw_record(body: List[UInt8]) raises -> RawRecord:
    """The record stored in `body` (the inverse of `encode_raw_record`).

    Raises:
        If the body is empty or truncated, names an unknown format version,
        holds a length past the end, a tag that is not UTF-8, or has bytes after
        the payload.
    """
    var off = 0
    var version = get_u8(body, off, _WHO, "format version")
    if version != RAW_FORMAT_VERSION:
        raise Error(
            _WHO
            + ": format version "
            + String(version)
            + " is not the supported "
            + String(RAW_FORMAT_VERSION)
        )
    var tag = get_text(body, off, _WHO, "surface tag")
    var received_at = get_i64(body, off, _WHO, "received_at")
    var payload = get_bytes(body, off, _WHO, "payload")
    expect_end(body, off, _WHO)
    return RawRecord(tag^, received_at, payload^)


struct RawStore[Store: ConditionalWriteStore](Movable):
    """Raw records on a conditional-write store, one object per distinct
    payload (see the file header).

    Parameters:
        Store: The object store; the in-memory and local-file stores and the
            cloud stores all conform.
    """

    var _store: Self.Store
    var _prefix: String

    def __init__(out self, var store: Self.Store, var prefix: String) raises:
        """Records under `<prefix>/raw/` on `store`.

        Raises:
            If the prefix is empty, holds a control byte, starts or ends with
            '/' or holds '//'.
        """
        check_prefix("raw store prefix", prefix)
        self._store = store^
        self._prefix = prefix^

    def prefix(self) -> String:
        """The key prefix this store writes under."""
        return self._prefix

    def _dir(self) -> String:
        return self._prefix + "/raw/"

    def _path_for(self, content_hash: String) raises -> Path:
        if not is_hash_name(content_hash):
            raise Error(
                _WHO
                + ": '"
                + content_hash
                + "' is not a content hash (16 lowercase hex digits)"
            )
        return Path.parse(self._dir() + content_hash + _SUFFIX)

    def put(
        mut self,
        surface_tag: String,
        payload: List[UInt8],
        received_at: Int64,
    ) raises -> RawPut:
        """Store `payload` unless its bytes are already stored.

        Args:
            surface_tag: The opaque tag the host knows the payload's kind by.
            payload: The bytes to keep.
            received_at: When the host received them, in the host's unit.

        Returns:
            The key and whether this call wrote the record.

        Raises:
            If the tag is not acceptable, or the store fails for any reason but
            the lost race, or a record with the same hash but different bytes is
            stored (a hash collision; nothing is written).
        """
        var record = RawRecord(surface_tag.copy(), received_at, payload.copy())
        var body = encode_raw_record(record)
        var key = raw_content_hash(payload)
        var path = self._path_for(key)
        try:
            _ = self._store.conditional_put(
                path, body^, WritePrecondition.if_none_match_star()
            )
            return RawPut(key.copy(), True)
        except e:
            if not is_precondition(String(e)):
                raise e^
        check_same_payload(self.get(key), payload, key)
        return RawPut(key.copy(), False)

    def find(self, content_hash: String) raises -> Optional[RawRecord]:
        """The record stored under `content_hash`, or nothing if none is.

        Raises:
            If `content_hash` is not 16 lowercase hex digits, the store fails for
            any reason but "not found", the object does not decode, or its
            payload does not hash to `content_hash`.
        """
        var path = self._path_for(content_hash)
        var body: List[UInt8]
        try:
            body = self._store.get(path)
        except e:
            if is_not_found(String(e)):
                return Optional[RawRecord]()
            raise e^
        var record = decode_raw_record(body)
        if record.content_hash() != content_hash:
            raise Error(
                _WHO
                + ": the object stored under "
                + content_hash
                + " holds a payload that hashes to "
                + record.content_hash()
                + "; refusing to use it"
            )
        return Optional[RawRecord](record^)

    def get(self, content_hash: String) raises -> RawRecord:
        """The record stored under `content_hash`.

        Raises:
            If none is stored, or for any reason `find` raises.
        """
        var found = self.find(content_hash)
        if not found:
            raise Error(_WHO + ".get: no record is stored under " + content_hash)
        return found.take()

    def has(self, content_hash: String) raises -> Bool:
        """Whether a record is stored under `content_hash` (a head, no body).

        Raises:
            If `content_hash` is malformed or the store fails for any reason but
            "not found".
        """
        var path = self._path_for(content_hash)
        try:
            _ = self._store.head(path)
        except e:
            if is_not_found(String(e)):
                return False
            raise e^
        return True

    def list_hashes(self) raises -> List[String]:
        """The key of every stored record, ascending.

        Raises:
            If the store fails, or an object under the raw directory is not named
            like a record (it is reported, not skipped).
        """
        var dir = self._dir()
        var listing = self._store.list_with_delimiter(Path.parse(dir.copy()))
        var out = List[String]()
        for i in range(len(listing.objects)):
            var name = name_without_suffix(
                listing.objects[i].location, dir, _SUFFIX
            )
            if not is_hash_name(name):
                raise Error(
                    _WHO
                    + ".list_hashes: '"
                    + listing.objects[i].location
                    + "' is not a raw record name"
                )
            out.append(name^)
        sort_strings(out)
        return out^
