# =============================================================================
# source_fingerprint -- the change gate: what was last ingested from each source,
#   keyed by partition and source.
# =============================================================================
#
# Re-syncing a source that has not changed should cost nothing. An ingest
# computes a fingerprint of the incoming content (`content_hash_of` for text,
# `content_hash_of_extraction` for facts handed over already extracted) and
# compares it with the one stored for `(partition_id, source)`. Equal means
# unchanged: the ingest returns the current head without extracting, embedding
# or writing. Different, or no stored fingerprint, means the content changed, so
# the ingest runs and its new fingerprint is stored with the snapshot it makes.
# The gate only ever skips work, never decides a change: a hash that differs for
# unchanged content re-ingests (correct, slower).
#
# `partition_id` and `source` are opaque strings the host chooses: the partition
# a graph's rows belong to, and a stable id for one source within it.
#
# The hash is FNV-1a over 64 bits (`komira_hash`), rendered as 16 lowercase hex
# digits. It is a change detector, not a cryptographic digest: it does not
# resist an adversary who chooses colliding content. For two inputs of the same
# length that differ in exactly one byte it always differs, because each step
# xors a byte into the state and multiplies by an odd constant, a bijection.
#
# The set of fingerprints is stored as an append-only lineage of its own, at
# `<prefix>/fingerprints` on the same store as the snapshots, one chunk per
# save, the latest chunk being the current set. An unchanged ingest reads one
# head and one chunk and never touches the snapshot lineage. A change loads the
# whole set, patches the one key and saves the whole set back. `save` refuses to
# replace a stored set with an empty one: a caller that lost the set it loaded
# would otherwise erase every source's fingerprint at once. Two writers that
# patch different keys from the same loaded set overwrite each other (the later
# save wins); a host that ingests one partition from several processes
# serializes them itself.
# =============================================================================

from komira_hash import fnv1a_64
from komira_objectstore.cas_manifest import CasManifestStore
from komira_objectstore.store import ConditionalWriteStore

from .ingest_types import Extraction
from .wire import get_i64_le, get_str, put_i64_le, put_str


# The format version of the stored set; the decoder accepts only this one.
comptime KG_FINGERPRINT_FORMAT_VERSION: Int64 = 1

comptime _HEX_DIGITS = "0123456789abcdef"


def fnv1a64_hex(bytes: Span[UInt8, _]) -> String:
    """FNV-1a over 64 bits of `bytes`, as 16 lowercase hex digits (most
    significant nibble first)."""
    var h = fnv1a_64(bytes)
    var digits = _HEX_DIGITS.as_bytes()
    var out = List[UInt8](capacity=16)
    var shift = 60
    while shift >= 0:
        out.append(digits[Int((h >> UInt64(shift)) & UInt64(0xF))])
        shift -= 4
    return String(unsafe_from_utf8=Span(out))


def content_hash_of(text: String) -> String:
    """The fingerprint of a source's text: `fnv1a64_hex` of its UTF-8 bytes."""
    return fnv1a64_hex(text.as_bytes())


def content_hash_of_extraction(extraction: Extraction) -> String:
    """The fingerprint of an extraction handed over without a text body.

    The hash is over a canonical serialization: the entity count, then each
    entity (name, type, summary), then the triple count, then each triple
    (subject, predicate, object, fact, valid_at, invalid_at). Every string is
    written with its byte length and every integer as eight little-endian bytes,
    so no content can imitate a boundary: two extractions that differ in any
    field, in a count or in the split of text between fields hash differently
    (up to the hash's collisions). The hash is order-sensitive, so a host whose
    extractor emits the same facts in a different order gets a changed
    fingerprint and re-ingests, which is correct and only slower.
    """
    var buf = List[UInt8]()
    put_i64_le(buf, Int64(len(extraction.entities)))
    for i in range(len(extraction.entities)):
        ref e = extraction.entities[i]
        put_str(buf, e.name)
        put_str(buf, e.entity_type)
        put_str(buf, e.summary)
    put_i64_le(buf, Int64(len(extraction.triples)))
    for i in range(len(extraction.triples)):
        ref t = extraction.triples[i]
        put_str(buf, t.subject_name)
        put_str(buf, t.predicate)
        put_str(buf, t.object_name)
        put_str(buf, t.fact)
        put_i64_le(buf, t.valid_at)
        put_i64_le(buf, t.invalid_at)
    return fnv1a64_hex(Span(buf))


@fieldwise_init
struct SourceFingerprint(Copyable, Movable):
    """The fingerprint last ingested for one `(partition_id, source)`.

    Fields:
        partition_id: The partition the source's rows belong to.
        source: A stable id of the source within the partition.
        content_hash: The fingerprint the change gate compares; never empty in
            a stored record.
        structural_sig: An optional second digest the host computes of the
            source's structure, for a finer comparison than the whole content.
            This package stores it and does not interpret it; "" if unused.
    """

    var partition_id: String
    var source: String
    var content_hash: String
    var structural_sig: String


struct SourceFingerprintSet(Movable):
    """Every stored fingerprint: the body of one chunk of the fingerprint lineage.

    One entry per `(partition_id, source)`. `lookup` finds a fingerprint,
    `patch` replaces or adds one, and `encode`/`decode` are the wire form.
    """

    var entries: List[SourceFingerprint]

    def __init__(out self):
        """An empty set: nothing has been fingerprinted."""
        self.entries = List[SourceFingerprint]()

    def __init__(out self, var entries: List[SourceFingerprint]):
        """A set over `entries`, moved in. The caller keeps keys unique."""
        self.entries = entries^

    @always_inline
    def num_entries(self) -> Int:
        """The number of fingerprinted sources."""
        return len(self.entries)

    @always_inline
    def is_empty(self) -> Bool:
        """True iff no source is fingerprinted."""
        return len(self.entries) == 0

    def _index_of(self, partition_id: String, source: String) -> Int:
        # A linear scan: a graph has one entry per source, and the set is
        # decoded whole for every change anyway.
        for i in range(len(self.entries)):
            ref e = self.entries[i]
            if e.partition_id == partition_id and e.source == source:
                return i
        return -1

    def lookup(self, partition_id: String, source: String) -> String:
        """The stored `content_hash` for the key, or "" if the source has
        never been fingerprinted. "" means changed: the gate never skips an
        unknown source."""
        var idx = self._index_of(partition_id, source)
        if idx < 0:
            return String("")
        return self.entries[idx].content_hash

    def lookup_structural(self, partition_id: String, source: String) -> String:
        """The stored `structural_sig` for the key, or "" if absent or unset."""
        var idx = self._index_of(partition_id, source)
        if idx < 0:
            return String("")
        return self.entries[idx].structural_sig

    def patch(
        mut self,
        var partition_id: String,
        var source: String,
        var content_hash: String,
        var structural_sig: String,
    ) raises:
        """Replace the fingerprint of one key, or add it. No other key changes.

        Raises:
            If `content_hash` is empty: an empty hash reads as "never
            fingerprinted" and would make the source look new forever.
        """
        if len(content_hash.as_bytes()) == 0:
            raise Error("SourceFingerprintSet.patch: empty content_hash")
        var idx = self._index_of(partition_id, source)
        var fp = SourceFingerprint(
            partition_id^, source^, content_hash^, structural_sig^
        )
        if idx >= 0:
            self.entries[idx] = fp^
        else:
            self.entries.append(fp^)

    def encode(self) -> List[UInt8]:
        """Encode the whole set (format version 1, little-endian)."""
        var out = List[UInt8]()
        put_i64_le(out, KG_FINGERPRINT_FORMAT_VERSION)
        put_i64_le(out, Int64(len(self.entries)))
        for i in range(len(self.entries)):
            ref e = self.entries[i]
            put_str(out, e.partition_id)
            put_str(out, e.source)
            put_str(out, e.content_hash)
            put_str(out, e.structural_sig)
        return out^

    @staticmethod
    def decode(bytes: List[UInt8]) raises -> SourceFingerprintSet:
        """Decode the wire form.

        Raises:
            On a truncated body, an unknown version, a negative count, a count
            the remaining bytes cannot hold, a string that is not UTF-8, an
            empty content hash, a key stored twice, or bytes left over.
        """
        var who = String("SourceFingerprintSet.decode")
        var fmt = get_i64_le(bytes, 0, who)
        if fmt != KG_FINGERPRINT_FORMAT_VERSION:
            raise Error(
                who
                + ": unsupported fingerprint format version "
                + String(fmt)
                + " (this build understands "
                + String(KG_FINGERPRINT_FORMAT_VERSION)
                + ")"
            )
        var count = Int(get_i64_le(bytes, 8, who))
        if count < 0:
            raise Error(who + ": negative entry count " + String(count))
        var off = 16
        # Each entry is at least 32 bytes (four lengths).
        if count > (len(bytes) - off) // 32:
            raise Error(who + ": truncated entry list")
        var result = SourceFingerprintSet()
        # Keys seen so far: a set, so a hostile count of entries costs linear
        # time (_index_of scans). The key is length-prefixed so two different
        # (partition, source) pairs never share one.
        var seen = Dict[String, Bool]()
        for _ in range(count):
            var partition_id = get_str(bytes, off, who, "partition_id")
            var source = get_str(bytes, off, who, "source")
            var content_hash = get_str(bytes, off, who, "content_hash")
            var structural_sig = get_str(bytes, off, who, "structural_sig")
            if len(content_hash.as_bytes()) == 0:
                raise Error(who + ": empty content_hash for " + source)
            var key = String(len(partition_id.as_bytes())) + ":" + partition_id + source
            if key in seen:
                raise Error(who + ": source stored twice: " + source)
            seen[key] = True
            result.entries.append(
                SourceFingerprint(
                    partition_id^, source^, content_hash^, structural_sig^
                )
            )
        if off != len(bytes):
            raise Error(
                who
                + ": "
                + String(len(bytes) - off)
                + " trailing bytes after the last entry"
            )
        return result^


struct SourceFingerprintStore[Store: ConditionalWriteStore](Movable):
    """The fingerprint lineage at `<prefix>/fingerprints` on a store.

    `load` reads the latest set (empty on a fresh lineage); `save` appends a
    whole set as a new chunk.

    Parameters:
        Store: The object store; one conditional-write store serves the
            snapshots and the fingerprints.
    """

    var _manifest: CasManifestStore[Self.Store]

    def __init__(out self, var store: Self.Store, var prefix: String):
        """Fingerprints under `<prefix>/fingerprints` on `store`."""
        self._manifest = CasManifestStore[Self.Store](
            store^, prefix + "/fingerprints"
        )

    def load(self) raises -> SourceFingerprintSet:
        """The latest stored set, or an empty set if none was saved.

        The head is read from the store's listing, not from a head pointer a
        long-lived writer may have left behind, so a fresh handle sees every
        committed chunk; a stale head would load an old set and the next save
        would drop the fingerprints written since.

        Raises:
            If the latest chunk does not decode.
        """
        var head = self._manifest.read_head_fresh()
        if head.chunk_seq < Int64(0):
            return SourceFingerprintSet()
        return SourceFingerprintSet.decode(
            self._manifest.read_chunk(head.chunk_seq)
        )

    def save(mut self, var fps: SourceFingerprintSet) raises:
        """Append `fps` as the new current set.

        Saving an empty set onto an empty lineage writes nothing.

        Raises:
            If `fps` is empty and a set was saved before (see the file header).
        """
        if fps.is_empty():
            var head = self._manifest.read_head_fresh()
            if head.chunk_seq >= Int64(0):
                raise Error(
                    "SourceFingerprintStore.save: refusing to replace a stored"
                    " fingerprint set with an empty one (a caller that lost the"
                    " set it loaded would erase every source's fingerprint)"
                )
            return
        _ = self._manifest.append(fps.encode(), Int64(fps.num_entries()))
