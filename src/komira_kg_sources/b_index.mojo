# =============================================================================
# b_index -- a brute-force cosine index over the episodes of raw records.
# =============================================================================
#
# `BIndex` answers "which stored passages are nearest this question" without the
# graph: it lowers each raw record to episodes through the `AdapterRegistry`,
# embeds each episode's body with an `Embedder`, keeps the vectors on a
# `ConditionalWriteStore`, and ranks them against a query vector by cosine
# similarity by scanning every vector. A hit names the raw record (its content
# hash), the episode's position in that record, the episode's `uuid`, its time
# and its score; `episode_of` maps a hit back to the episode through the
# registry.
#
# Building. `build` visits every record of a `RawStore`:
#   * a record already indexed is skipped, so a second build over the same store
#     embeds nothing. A record's rows are one object written with create-if-
#     absent, so a record is indexed whole or not at all; a builder that loses
#     the race leaves the winner's rows in place;
#   * a record whose tag has no adapter is skipped and counted, not refused: a
#     raw store may hold kinds of record the index does not cover;
#   * a record that lowers to no episode is skipped and counted (and visited
#     again by the next build, as it leaves no trace);
#   * an adapter that cannot read its record raises, and the build stops there;
#     the records indexed before stay indexed.
# The embedder must report the index's dimension, return one vector of exactly
# that many finite components per text, and the vectors are stored narrowed to
# f32.
#
# Ranking. `top_k` scores every stored vector with `cosine` and returns the best
# `k`, score descending. Equal scores come in the order raw key ascending, then
# position ascending, so the answer does not depend on how the store lists. Only
# the current record's rows and the `k` best so far are held in memory.
#
# Stored form. One object per indexed raw record at `<prefix>/index/<hash>.bidx`,
# where the hash is the raw record's content hash. The body is
#     u8 format version (1)
#     u32 length, surface tag bytes
#     u32 row count
#     per row: u32 length, episode uuid bytes; i64 valid_at;
#              u32 length, embedding bytes (4 per component, little-endian f32)
# A body that is truncated, names another version, holds a length or row count
# larger than the bytes that remain, a text that is not UTF-8, an embedding that
# is not exactly the index's dimension, or bytes after the last row is refused
# with an error naming the defect; no allocation is sized from a count the body
# has not been shown to hold.
# =============================================================================

from std.math import isfinite

from komira_kg import Embedder, EpisodeInput
from komira_kg_format import cosine, pack_embedding, unpack_embedding_checked
from komira_objectstore.cas_manifest import is_not_found, is_precondition
from komira_objectstore.path import Path
from komira_objectstore.store import ConditionalWriteStore
from komira_objectstore.types import WritePrecondition

from .adapter_registry import AdapterRegistry
from .framing import (
    check_prefix,
    expect_end,
    get_bytes,
    get_i64,
    get_text,
    get_u32,
    get_u8,
    is_hash_name,
    name_without_suffix,
    put_i64,
    put_text,
    put_u32,
    put_u8,
    sort_strings,
)
from .raw_store import RawStore

comptime INDEX_FORMAT_VERSION: Int = 1
"""The format version of a stored index record; the decoder accepts only this."""

comptime _WHO: String = "BIndex"
comptime _SUFFIX: String = ".bidx"
comptime _MIN_ROW_BYTES: Int = 16
"""The least a row can take: two u32 lengths and an i64."""


@fieldwise_init
struct IndexRow(Copyable, Movable):
    """One indexed episode.

    Fields:
        episode_uuid: The `uuid` of the episode the adapter lowered.
        valid_at: The episode's `valid_at`.
        embedding: The embedding of the episode's body (f32 precision).
    """

    var episode_uuid: String
    var valid_at: Int64
    var embedding: List[Float64]


@fieldwise_init
struct IndexRecord(Copyable, Movable):
    """The indexed rows of one raw record.

    Fields:
        surface_tag: The raw record's tag when it was indexed.
        rows: One row per episode, in the order the adapter returned them.
    """

    var surface_tag: String
    var rows: List[IndexRow]


@fieldwise_init
struct BIndexHit(Copyable, Movable):
    """One ranked answer.

    Fields:
        raw_key: The content hash of the raw record the episode came from.
        ordinal: The episode's position among the record's episodes.
        episode_uuid: The episode's `uuid`.
        surface_tag: The tag the record was indexed under.
        valid_at: The episode's `valid_at`.
        score: Cosine similarity with the query, in [-1.0, 1.0].
    """

    var raw_key: String
    var ordinal: Int
    var episode_uuid: String
    var surface_tag: String
    var valid_at: Int64
    var score: Float64


@fieldwise_init
struct BIndexBuild(Copyable, Movable):
    """What one `BIndex.build` did.

    Fields:
        records_indexed: Raw records indexed by this build.
        rows_added: Episodes embedded and stored by this build.
        skipped_existing: Records already indexed, or indexed by a builder that
            won the race.
        skipped_unregistered: Records whose tag has no adapter.
        skipped_empty: Records that lowered to no episode.
    """

    var records_indexed: Int
    var rows_added: Int
    var skipped_existing: Int
    var skipped_unregistered: Int
    var skipped_empty: Int


def encode_index_record(record: IndexRecord) raises -> List[UInt8]:
    """The stored form of `record` (see the file header).

    Raises:
        If the tag or a uuid is over the size limit.
    """
    var out = List[UInt8]()
    put_u8(out, INDEX_FORMAT_VERSION)
    put_text(out, record.surface_tag, "surface tag")
    put_u32(out, len(record.rows))
    for i in range(len(record.rows)):
        ref row = record.rows[i]
        put_text(out, row.episode_uuid, "episode uuid")
        put_i64(out, row.valid_at)
        var packed = pack_embedding(row.embedding)
        var pb = packed.as_bytes()
        put_u32(out, len(pb))
        for j in range(len(pb)):
            out.append(pb[j])
    return out^


def decode_index_record(body: List[UInt8], dimension: Int) raises -> IndexRecord:
    """The record stored in `body` (the inverse of `encode_index_record`).

    Args:
        body: The stored bytes.
        dimension: The components every embedding must have.

    Raises:
        If the body is empty or truncated, names an unknown format version,
        claims more rows than the bytes that remain can hold, holds a length
        past the end, text that is not UTF-8 or an embedding that is not
        `dimension` components, or has bytes after the last row.
    """
    var off = 0
    var version = get_u8(body, off, _WHO, "format version")
    if version != INDEX_FORMAT_VERSION:
        raise Error(
            _WHO
            + ": format version "
            + String(version)
            + " is not the supported "
            + String(INDEX_FORMAT_VERSION)
        )
    var tag = get_text(body, off, _WHO, "surface tag")
    var count = get_u32(body, off, _WHO, "row count")
    # Divided, not multiplied: `count` comes from the body.
    if count > (len(body) - off) // _MIN_ROW_BYTES:
        raise Error(
            _WHO
            + ": the row count claims "
            + String(count)
            + " rows, more than the "
            + String(len(body) - off)
            + " remaining bytes can hold"
        )
    var rows = List[IndexRow]()
    for _ in range(count):
        var uuid = get_text(body, off, _WHO, "episode uuid")
        var valid_at = get_i64(body, off, _WHO, "valid_at")
        var cell = get_bytes(body, off, _WHO, "embedding")
        var vec = unpack_embedding_checked(Span(cell), dimension)
        rows.append(IndexRow(uuid^, valid_at, vec^))
    expect_end(body, off, _WHO)
    return IndexRecord(tag^, rows^)


def _all_finite_f32(v: List[Float64]) -> Bool:
    for i in range(len(v)):
        if not isfinite(Float64(Float32(v[i]))):
            return False
    return True


struct BIndex[Store: ConditionalWriteStore](Movable):
    """A cosine index of embedded episodes on a conditional-write store (see the
    file header).

    Parameters:
        Store: The object store the index records live on.
    """

    var _store: Self.Store
    var _prefix: String
    var _dim: Int

    def __init__(
        out self, var store: Self.Store, var prefix: String, dimension: Int
    ) raises:
        """An index under `<prefix>/index/` on `store`.

        Args:
            store: The object store.
            prefix: The key prefix: not empty, no control byte, no leading or
                trailing '/', no '//'.
            dimension: The components of every vector, more than zero. There is
                no default.

        Raises:
            If the prefix is not acceptable or the dimension is not positive.
        """
        check_prefix("index prefix", prefix)
        if dimension <= 0:
            raise Error(
                _WHO + ": dimension must be positive, got " + String(dimension)
            )
        self._store = store^
        self._prefix = prefix^
        self._dim = dimension

    def prefix(self) -> String:
        """The key prefix this index writes under."""
        return self._prefix

    def dimension(self) -> Int:
        """The components of every vector in the index."""
        return self._dim

    def _dir(self) -> String:
        return self._prefix + "/index/"

    def _path_for(self, raw_key: String) raises -> Path:
        if not is_hash_name(raw_key):
            raise Error(
                _WHO
                + ": '"
                + raw_key
                + "' is not a raw key (16 lowercase hex digits)"
            )
        return Path.parse(self._dir() + raw_key + _SUFFIX)

    def has_record(self, raw_key: String) raises -> Bool:
        """Whether the raw record `raw_key` is indexed (a head, no body).

        Raises:
            If `raw_key` is malformed or the store fails for any reason but
            "not found".
        """
        var path = self._path_for(raw_key)
        try:
            _ = self._store.head(path)
        except e:
            if is_not_found(String(e)):
                return False
            raise e^
        return True

    def list_keys(self) raises -> List[String]:
        """The raw key of every indexed record, ascending.

        Raises:
            If the store fails, or an object under the index directory is not
            named like an index record.
        """
        var dir = self._dir()
        var listing = self._store.list_with_delimiter(Path.parse(dir.copy()))
        var out = List[String]()
        for i in range(len(listing.objects)):
            var name = name_without_suffix(listing.objects[i].location, dir, _SUFFIX)
            if not is_hash_name(name):
                raise Error(
                    _WHO
                    + ".list_keys: '"
                    + listing.objects[i].location
                    + "' is not an index record name"
                )
            out.append(name^)
        sort_strings(out)
        return out^

    def read_record(self, raw_key: String) raises -> IndexRecord:
        """The indexed rows of the raw record `raw_key`.

        Raises:
            If the record is not indexed, the store fails, or the object does
            not decode.
        """
        var body = self._store.get(self._path_for(raw_key))
        return decode_index_record(body, self._dim)

    def build[
        RawBackend: ConditionalWriteStore, Reg: AdapterRegistry, Emb: Embedder
    ](
        mut self,
        raw: RawStore[RawBackend],
        registry: Reg,
        embedder: Emb,
        partition_id: String,
    ) raises -> BIndexBuild:
        """Index every record of `raw` that is not indexed yet (see the file
        header for what is skipped).

        Args:
            raw: The raw records.
            registry: The adapters, by surface tag.
            embedder: The embedder; it must report this index's dimension.
            partition_id: The partition the adapters stamp on the episodes they
                lower. The index stores no partition: it is the caller's.

        Returns:
            What the build indexed and skipped.

        Raises:
            If the embedder's dimension is not the index's, it returns the wrong
            number of vectors, a vector of the wrong size or a non-finite
            component, an adapter cannot read a record, or the store fails.
        """
        if embedder.dimension() != self._dim:
            raise Error(
                _WHO
                + ".build: the embedder's dimension is "
                + String(embedder.dimension())
                + ", the index's is "
                + String(self._dim)
            )
        var indexed = 0
        var added = 0
        var existing = 0
        var unregistered = 0
        var empty = 0
        var keys = raw.list_hashes()
        for k in range(len(keys)):
            if self.has_record(keys[k]):
                existing += 1
                continue
            var record = raw.get(keys[k])
            var lowered = registry.lower_raw(
                record.surface_tag, record.payload, partition_id
            )
            if not lowered:
                unregistered += 1
                continue
            var episodes = lowered.take()
            if len(episodes) == 0:
                empty += 1
                continue
            var texts = List[String](capacity=len(episodes))
            for i in range(len(episodes)):
                texts.append(episodes[i].body.copy())
            var vectors = embedder.embed_batch(texts)
            if len(vectors) != len(episodes):
                raise Error(
                    _WHO
                    + ".build: the embedder returned "
                    + String(len(vectors))
                    + " vectors for "
                    + String(len(episodes))
                    + " texts"
                )
            var rows = List[IndexRow](capacity=len(episodes))
            for i in range(len(episodes)):
                if len(vectors[i]) != self._dim:
                    raise Error(
                        _WHO
                        + ".build: the embedder returned "
                        + String(len(vectors[i]))
                        + " components, the index's dimension is "
                        + String(self._dim)
                    )
                if not _all_finite_f32(vectors[i]):
                    raise Error(
                        _WHO + ".build: the embedder returned a non-finite component"
                    )
                rows.append(
                    IndexRow(
                        episodes[i].uuid.copy(),
                        episodes[i].valid_at,
                        vectors[i].copy(),
                    )
                )
            var n = len(rows)
            var body = encode_index_record(
                IndexRecord(record.surface_tag.copy(), rows^)
            )
            try:
                _ = self._store.conditional_put(
                    self._path_for(keys[k]),
                    body^,
                    WritePrecondition.if_none_match_star(),
                )
                indexed += 1
                added += n
            except e:
                if not is_precondition(String(e)):
                    raise e^
                existing += 1
        return BIndexBuild(indexed, added, existing, unregistered, empty)

    def top_k(self, query: List[Float64], k: Int) raises -> List[BIndexHit]:
        """The `k` stored episodes nearest `query` by cosine similarity.

        Args:
            query: The query vector, this index's dimension, finite.
            k: How many to return, more than zero; fewer come back if fewer are
                stored.

        Returns:
            The hits, score descending, equal scores by raw key then position.

        Raises:
            If `k` is not positive, the query is the wrong size or not finite,
            or an index record does not decode.
        """
        if k <= 0:
            raise Error(_WHO + ".top_k: k must be positive, got " + String(k))
        if len(query) != self._dim:
            raise Error(
                _WHO
                + ".top_k: the query has "
                + String(len(query))
                + " components, the index's dimension is "
                + String(self._dim)
            )
        for i in range(len(query)):
            if not isfinite(query[i]):
                raise Error(_WHO + ".top_k: the query has a non-finite component")
        var best = List[BIndexHit]()
        var keys = self.list_keys()
        for r in range(len(keys)):
            var record = self.read_record(keys[r])
            for o in range(len(record.rows)):
                var score = cosine(query, record.rows[o].embedding)
                # Keep `best` sorted: the new hit goes after every hit with an
                # equal or higher score, and the list never exceeds `k`.
                var pos = len(best)
                while pos > 0 and best[pos - 1].score < score:
                    pos -= 1
                if pos >= k:
                    continue
                best.insert(
                    pos,
                    BIndexHit(
                        keys[r].copy(),
                        o,
                        record.rows[o].episode_uuid.copy(),
                        record.surface_tag.copy(),
                        record.rows[o].valid_at,
                        score,
                    ),
                )
                if len(best) > k:
                    _ = best.pop()
        return best^

    def search[
        Emb: Embedder
    ](self, embedder: Emb, text: String, k: Int) raises -> List[BIndexHit]:
        """Embed `text` and return the `k` nearest stored episodes.

        Raises:
            If the embedder's dimension is not the index's, or for any reason
            `top_k` raises.
        """
        if embedder.dimension() != self._dim:
            raise Error(
                _WHO
                + ".search: the embedder's dimension is "
                + String(embedder.dimension())
                + ", the index's is "
                + String(self._dim)
            )
        return self.top_k(embedder.embed(text), k)


def episode_of[
    RawBackend: ConditionalWriteStore, Reg: AdapterRegistry
](
    hit: BIndexHit,
    raw: RawStore[RawBackend],
    registry: Reg,
    partition_id: String,
) raises -> EpisodeInput:
    """The episode a hit names: the raw record is read, lowered through the
    registry, and the episode at the hit's position returned.

    Args:
        hit: A hit from `BIndex.top_k` or `search`.
        raw: The raw store the index was built from.
        registry: The adapters, by surface tag.
        partition_id: The partition to lower for.

    Returns:
        The episode.

    Raises:
        If the raw record is gone, no adapter is registered for its tag, the
        record lowers to fewer episodes than the hit's position, or the episode
        there has another `uuid` than the hit (the adapter or the record has
        changed since the index was built).
    """
    var record = raw.get(hit.raw_key)
    var lowered = registry.lower_raw(
        record.surface_tag, record.payload, partition_id
    )
    if not lowered:
        raise Error(
            _WHO
            + ".episode_of: no adapter is registered for tag '"
            + record.surface_tag
            + "'"
        )
    var episodes = lowered.take()
    if hit.ordinal < 0 or hit.ordinal >= len(episodes):
        raise Error(
            _WHO
            + ".episode_of: record "
            + hit.raw_key
            + " lowers to "
            + String(len(episodes))
            + " episodes, the hit names position "
            + String(hit.ordinal)
        )
    if episodes[hit.ordinal].uuid != hit.episode_uuid:
        raise Error(
            _WHO
            + ".episode_of: position "
            + String(hit.ordinal)
            + " of record "
            + hit.raw_key
            + " is episode '"
            + episodes[hit.ordinal].uuid
            + "', the hit names '"
            + hit.episode_uuid
            + "'"
        )
    return episodes[hit.ordinal].copy()
