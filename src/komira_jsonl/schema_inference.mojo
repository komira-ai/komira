# =============================================================================
# schema_inference.mojo — JSONL wide-default schema inferrer.
# =============================================================================
#
# Implements wide-default JSON schema inference.
# Walks the Stage 1 structural index
# (`structural_index.build_structural_index`) once and emits an Arrow
# `Schema` whose column types follow the wide-default lattice:
#
#   - JSON Number (no `.` / `e` / `E`)  -> Int64
#   - JSON Number (any `.` / `e` / `E`) -> Float64
#   - JSON Bool                          -> Bool
#   - JSON String                        -> String (Utf8 with i32 offsets)
#   - JSON Null                          -> NULL bottom (promotable)
#   - JSON Array  / JSON Object          -> not inferred: raises with a
#     hint to pass an explicit schema (LIST / STRUCT / MAP recursive
#     inference is possible future work; the explicit-schema materializer
#     reads them).
#
# Promotion lattice ("inference precedence"):
#
#       NULL  <  Int64  <  Float64
#       NULL  <  Bool
#       NULL  <  String
#       Int64 + Float64  ->  Float64
#       any T1 + T2 (mixed numeric/bool/string) -> conflict: raises
#         clearly on mismatch so the user can supply an explicit schema
#         via `ctx.read_json_batch(path, schema)` (a STRING column that
#         accepts unquoted scalars would make coercion possible).
#
# Output schema:
#   - One Field per first-seen key across records (insertion order).
#   - All fields are nullable=True (inference cannot prove non-null
#     from a sample; matches pandas/PyArrow wide-default behavior).
#   - All-null columns retain ArrowType.NULL (promotable in a re-read).
#
# Public API:
#   fn infer_jsonl_schema(bytes: Span[UInt8, _]) raises -> Schema
#       — single entry point. Reads the JSONL byte stream, runs the
#       lattice walker, returns the inferred Schema.
#
# Encapsulation discipline:
#   - Public surface accepts `Span[UInt8, _]` (no UnsafePointer).
#   - No wildcard origins.
#   - No `unsafe_from_address=Int(...)`.
#   - Internal byte indexing uses Span subscripting (Mojo lowers without
#     bounds-check overhead in -O3).
#
# Cross-references:
#   - Stage 1 structural index: `komira_json_index.structural_index`.
#   - Typed materializer (companion read path):
#     `komira_jsonl.columnar_materializer`.
# =============================================================================

from std.collections import Optional
from std.memory import UnsafePointer
from std.sys import num_physical_cores

from komira_async.cancellation.token import CancellationToken
from komira_async.ops.waker_sink import NoopSink
from komira_async.runtime.chunk_work import ChunkWork
from komira_async.runtime.local_dispatcher import LocalDispatcher
from komira_async.runtime.parallel_fork_join import (
    parallel_fork_join,
    parallel_fork_join_serial,
)
from komira_arrow.arrow_types import ArrowType
from komira_arrow.schema import Field, Schema, SchemaBuilder
from komira_collections.slab import Slab

from komira_jsonl.columnar_materializer import _compute_jsonl_line_ranges
from komira_json_index.input_limits import check_json_column_count
from komira_jsonl.key_dispatch import KeyRegistryBuilder
from komira_jsonl.key_unescape import key_has_escape, unescape_key
from komira_jsonl.line_check import _byte_text
from komira_json_index.simd_primitives import (
    TAG_OPEN_BRACE,
    TAG_CLOSE_BRACE,
    TAG_OPEN_BRACKET,
    TAG_CLOSE_BRACKET,
    TAG_COLON,
    TAG_COMMA,
    TAG_QUOTE_OPEN,
    TAG_QUOTE_CLOSE,
)
from komira_json_index.structural_index import (
    build_structural_index,
    JsonlPartitions,
    StructuralIndex,
)


# =============================================================================
# Inferred-type lattice — internal representation
# =============================================================================
#
# We use a UInt8 tag rather than an enum so the per-column inferred
# state list is a flat List[UInt8] (cheap to mutate, no per-element
# heap). The tag maps to ArrowType as follows:

comptime INF_NULL: UInt8 = 0          # Lattice bottom — promotable
comptime INF_INT64: UInt8 = 1         # JSON Number, integer
comptime INF_FLOAT64: UInt8 = 2       # JSON Number, decimal / exponent
comptime INF_BOOL: UInt8 = 3          # true / false literal
comptime INF_STRING: UInt8 = 4        # JSON string literal
comptime INF_MIXED_STRING: UInt8 = 5  # Heterogeneous (raises; never
                                   # mapped to an Arrow type)


@always_inline
def _inferred_to_arrow(tag: UInt8) -> ArrowType:
    """Map an internal lattice tag to the public ArrowType.

    Lattice tags map 1:1 to Arrow types except `INF_NULL`, which
    surfaces as `ArrowType.NULL` (all-null column — the wide-default
    lattice bottom; a future re-read promotes the column to whatever
    type non-null values resolve to)."""
    if tag == INF_INT64:
        return ArrowType.INT64
    elif tag == INF_FLOAT64:
        return ArrowType.FLOAT64
    elif tag == INF_BOOL:
        return ArrowType.BOOL
    elif tag == INF_STRING:
        return ArrowType.STRING
    elif tag == INF_MIXED_STRING:
        # Mixed-type columns cannot be materialized through the existing
        # parser path (the STRING-column-with-unquoted-scalar arm in
        # `columnar_materializer` raises), so reaching this
        # arm at schema-emit time is a programmer-error.
        # `_promote_pair` raises before we ever map MIXED to ArrowType.
        return ArrowType.STRING
    else:
        # INF_NULL — all-null column.
        return ArrowType.NULL


# =============================================================================
# Type promotion (lattice join)
# =============================================================================
#
# Combines the existing per-column inferred tag with the observed type
# from a new record:
#   * NULL is the bottom — any T promotes NULL to T (and back).
#   * Int64 + Float64 -> Float64 (the only allowed numeric widening).
#   * Same-type joins stay at that type.
#   * Cross-family (Int/Float vs Bool vs String) -> MIXED, which is
#     surfaced by raising at `infer_jsonl_schema` exit time.


@always_inline
def _promote_pair(curr: UInt8, observed: UInt8) raises -> UInt8:
    """Lattice join of `curr` (existing column tag) and `observed`
    (new record's value tag).

    Raises (with a helpful message) if the join would yield
    INF_MIXED_STRING — a mixed-type column cannot be materialized
    through the existing parsers, so the inferrer is the right place
    to surface the conflict. Callers can recover by supplying an
    explicit schema via `ctx.read_json_batch(path, schema)`."""
    if curr == observed:
        return curr
    # NULL is bottom — any non-NULL absorbs.
    if curr == INF_NULL:
        return observed
    if observed == INF_NULL:
        return curr
    # Int64 + Float64 -> Float64.
    if (curr == INF_INT64 and observed == INF_FLOAT64) or (
        curr == INF_FLOAT64 and observed == INF_INT64
    ):
        return INF_FLOAT64
    # Cross-family conflict.
    return INF_MIXED_STRING


# =============================================================================
# Scalar classification — peek-value-type
# =============================================================================
#
# Given a byte range [start, end) holding the scalar value (after
# whitespace trim), classify it as INT64 / FLOAT64 / BOOL / NULL.
# String values are classified separately at the structural-tape walk
# (TAG_QUOTE_OPEN at the value position bypasses this fn).


@always_inline
def _is_digit(b: UInt8) -> Bool:
    return b >= UInt8(0x30) and b <= UInt8(0x39)  # '0'..'9'


@always_inline
def _is_ws(b: UInt8) -> Bool:
    """Per RFC 8259 §2 JSON whitespace: space, tab, LF, CR."""
    return (
        b == UInt8(0x20)
        or b == UInt8(0x09)
        or b == UInt8(0x0A)
        or b == UInt8(0x0D)
    )


def _classify_scalar(bytes: Span[UInt8, _], start: Int, end: Int) raises -> UInt8:
    """Classify a scalar JSON value (number / true / false / null) in
    `bytes[start:end]` to an INF_* lattice tag.

    Whitespace at the boundaries is assumed already trimmed by the
    caller (the structural-index walker handles this).

    Raises if the scalar is unrecognized — surfaces the offending byte
    range so the user can inspect."""
    if end <= start:
        raise Error(
            "_classify_scalar: empty scalar at byte " + String(start)
        )
    var first = bytes[start]
    # Bool: 'true' (4 chars) or 'false' (5 chars).
    if first == UInt8(0x74):  # 't'
        return INF_BOOL
    if first == UInt8(0x66):  # 'f'
        return INF_BOOL
    # Null literal.
    if first == UInt8(0x6E):  # 'n'
        return INF_NULL
    # Number: starts with '-' or digit. Scan the byte range for `.` or
    # `e` / `E` to distinguish Int64 vs Float64.
    if first == UInt8(0x2D) or _is_digit(first):  # '-' or digit
        var has_float_marker = False
        for i in range(start, end):
            var b = bytes[i]
            if b == UInt8(0x2E) or b == UInt8(0x65) or b == UInt8(0x45):
                # '.' or 'e' or 'E'
                has_float_marker = True
                break
        if has_float_marker:
            return INF_FLOAT64
        return INF_INT64
    # Anything else is malformed JSON — the caller's structural walk
    # should have raised already, but defensively surface the issue.
    raise Error(
        "_classify_scalar: unrecognized scalar starting with "
        + _byte_text(first)
        + " at byte "
        + String(start)
    )


# =============================================================================
# Column-name registry — first-seen key insertion order
# =============================================================================
#
# We do NOT use a Mojo Dict here — its API is awkward for the
# "insert-if-absent, return index" pattern. A linear-scan List of
# `String` is fast enough for the typical column count (≤ 30 in
# practice); the hot paths use `KeyRegistryBuilder` from
# `komira_jsonl.key_dispatch`.


def _lookup_or_insert(
    mut names: List[String],
    mut inferred: List[UInt8],
    var key: String,
) -> Int:
    """Linear-scan for `key` in `names`. If found, return its index.
    Otherwise append (`key`, INF_NULL) and return the new index.

    `key` is consumed (moved into the names List on insert; dropped on
    hit). Caller must transfer via `key^`."""
    var n = len(names)
    for i in range(n):
        if names[i] == key:
            return i
    names.append(key^)
    inferred.append(INF_NULL)
    return n


# =============================================================================
# Public entry point — infer_jsonl_schema
# =============================================================================


def infer_jsonl_schema(bytes: Span[UInt8, _]) raises -> Schema:
    """Wide-default schema inferrer for a JSONL byte stream.

    Walks the Stage 1 structural index once, collecting per-key
    observed types and merging via the lattice (`_promote_pair`).
    Emits a Schema whose fields are first-seen-key insertion order,
    all nullable=True, with the lattice-resolved Arrow type per column.

    Algorithm (wide-default):
      1. Build structural index over `bytes`.
      2. Walk top-level objects; for each (key, value) pair:
         - Look up or insert the key in the column registry.
         - Peek the value at structural tape position `t`:
             TAG_QUOTE_OPEN  -> INF_STRING
             TAG_OPEN_BRACE  -> raise (nested struct inference is
                                 not supported)
             TAG_OPEN_BRACKET-> raise (nested list inference is not
                                 supported)
             else            -> scalar (classify via _classify_scalar)
         - Promote `inferred[ki]` with the observed type.
      3. After all records consumed, build a Schema with one Field
         per column (insertion order, nullable=True).

    Inference does not check that each line is one JSON object, nor the
    grammar of values it does not classify: it skips a top-level token that
    is not `{`. The read does check (`materialize_jsonl_to_batch` and the
    paths built on it refuse a bad line naming it, `line_check.mojo`), so
    a file inferred here and then read is refused there.

    Raises on:
      * Malformed JSON structure (unbalanced braces, missing colon).
      * Heterogeneous types in the same column (cross-family
        Int/Float vs Bool vs String). Recovery: supply an explicit
        schema via `ctx.read_json_batch(path, schema)`.
      * Nested object / array values (not inferred).

    Performance: one pass over the structural index + one pass at
    schema-build time. The inference cost is dominated by the
    structural-index build (Stage 1 SIMD kernel), so the overhead
    over `materialize_jsonl_to_batch` is just the per-key linear
    scan of the registry (typical ≤ 30 keys × O(n) = trivial).

    The index built here is the SAME index the
    materializer needs. The combined `infer_jsonl_schema_with_index`
    entry-point returns BOTH so the SDK read path can thread the index
    into `materialize_jsonl_to_batch` and skip the second full-file
    Stage-1 SIMD walk (one full pass over the input saved)."""
    var idx = build_structural_index(bytes)
    return _infer_jsonl_schema_from_index(bytes, idx)


def infer_jsonl_schema_with_index(
    bytes: Span[UInt8, _],
) raises -> Tuple[Schema, StructuralIndex]:
    """Wide-default schema inferrer that ALSO returns the Stage-1
    structural index it built.

    The materializer needs the exact same `StructuralIndex` over the
    same byte stream. Building it once here and threading it into
    `materialize_jsonl_to_batch(bytes, schema, idx)` eliminates the
    second full-file Stage-1 SIMD pass."""
    var idx = build_structural_index(bytes)
    var schema = _infer_jsonl_schema_from_index(bytes, idx)
    return (schema^, idx^)


# Below this size, parallel inference's partition + per-worker index-build
# cold-cache fill costs more than the serial single-index walk.
comptime _MIN_PARALLEL_INFER_BYTES: Int = 4 * 1024 * 1024  # 4 MiB
comptime _MAX_INFER_WORKERS: Int = 32


# `JsonlPartitions` lives in `structural_index.mojo`
# (the leaf of the JSONL module DAG) so both the inferrer and the
# materializer can import it without introducing a circular import.


# =============================================================================
# Parallel JSONL schema inference — fork-join work unit (the komira_async
# fork-join helper).
#
# Each chunk infers a PARTIAL schema over its byte slice + builds its OWN
# StructuralIndex, producing one owned `_PartialInferOut` per chunk into the
# helper's disjoint output Slab. The driver then merges the partials IN FILE
# ORDER (so column insertion order matches the serial first-seen order) and
# hands the per-chunk indices off via the `partitions` out-arg.
#
# DISPATCH-BOUNDARY SAFETY: the per-worker disjointness contract —
# chunk `c` reads ONLY `[los[c], his[c])` of the shared
# read-only byte stream (the `\n`-anchored partition contract makes these
# ranges disjoint and ordered); writes ONLY its own `_PartialInferOut`
# out_slot. The byte stream + offset lists are owned by / borrowed through the
# bundle's concrete immutable origin; no wildcard.
# =============================================================================


struct _PartialInferOut(Movable, Deinitable):
    """One chunk's partial-inference output: per-column observed names +
    inferred-type tags + the chunk's pre-built StructuralIndex (handed off to
    the downstream materializer). Movable owned bundle — one per chunk."""

    var names: List[String]
    var inferred: List[UInt8]
    var index: StructuralIndex

    def __init__(
        out self,
        var names: List[String],
        var inferred: List[UInt8],
        var index: StructuralIndex,
    ):
        self.names = names^
        self.inferred = inferred^
        self.index = index^

    def into_index(deinit self) -> StructuralIndex:
        """Consume the partial and return its StructuralIndex; the names +
        inferred lists drop here (already merged by the caller). `deinit
        self` consumes the whole struct, so this is a clean full destructure
        — NOT a partial-move-out-of-the-middle (which Mojo rejects)."""
        var idx = self.index^
        return idx^


@fieldwise_init
struct _InferInput[byte_o: Origin[mut=False]](Deinitable):
    """Input bundle for the parallel inferrer work unit. OWNS the offset
    lists (moved in); only the byte stream is borrowed, through the Span's
    own CONCRETE immutable origin `byte_o` (NO wildcard).

    # SAFETY: `byte_o` is CONCRETE. The byte pointer is read-only and live
    # for the synchronous dispatch; never exposed publicly.
    """

    var bytes_ptr: UnsafePointer[UInt8, Self.byte_o]
    var bytes_len: Int
    var los: List[Int]
    var his: List[Int]


@fieldwise_init
struct _InferPartialWork[byte_o: Origin[mut=False]](ChunkWork):
    """Per-chunk partial-inference work. Reads chunk `chunk_id`'s byte range,
    builds its StructuralIndex, infers the partial schema, writes the owned
    `_PartialInferOut` into `out_slot`."""

    var _pad: Int32

    def process[
        In: Deinitable, O: Movable & Deinitable
    ](
        self,
        chunk_id: Int,
        n_chunks: Int,
        ref input: In,
        mut out_slot: Optional[O],
    ) raises:
        # SAFETY: the helper binds In=_InferInput[byte_o],
        # O=_PartialInferOut at the parallel_fork_join[...] call site; the
        # bitcasts resolve to those concrete types. Internal to this module.
        var ip = UnsafePointer(to=input).bitcast[_InferInput[Self.byte_o]]()
        var lo = ip[].los[chunk_id]
        var hi = ip[].his[chunk_id]
        var slice = Span(unsafe_ptr=ip[].bytes_ptr + lo, length=hi - lo)
        var idx = build_structural_index(slice)
        var names = List[String]()
        var inferred = List[UInt8]()
        _infer_partial_into(slice, idx, names, inferred)
        var out = _PartialInferOut(names^, inferred^, idx^)
        var op = UnsafePointer(to=out_slot).bitcast[
            Optional[_PartialInferOut]
        ]()
        op[] = Optional[_PartialInferOut](out^)


def infer_jsonl_schema_parallel(
    bytes: Span[UInt8, _],
    n_workers: Int = 0,
) raises -> Schema:
    """LINE-RANGE PARALLEL wide-default schema inferrer.

    Shards `bytes` into N `\\n`-aligned line-range partitions (the same
    partition contract as `materialize_jsonl_to_batch_parallel`), builds a
    per-slice `StructuralIndex` + infers a PARTIAL schema in each worker,
    then merges the partials via the wide-default lattice
    (`_merge_partial_into`). Output is IDENTICAL to the serial
    `infer_jsonl_schema(bytes)`:
      - The lattice promotion (`_promote_pair`) is associative and
        commutative over the per-column observed-type set, so partition
        order does not change a column's resolved type.
      - Partials are merged in FILE ORDER (worker 0 first), so the column
        INSERTION order matches the serial first-seen order — same Schema
        field order, byte-for-byte.

    This parallelizes the full-file Stage-1 SIMD index pass, the single
    dominant cost of the SDK `ctx.read_json` path on a large file (about
    10x faster across 10 cores). Below
    `_MIN_PARALLEL_INFER_BYTES` (or n_workers<=1, or a single-range file) it
    falls back to the serial `infer_jsonl_schema`.

    Args:
        bytes:     origin-poly Span over the full JSONL byte stream. Must
                   outlive the call (the caller owns it across the
                   synchronous dispatch).
        n_workers: worker count; 0 → `num_physical_cores()` capped at
                   `_MAX_INFER_WORKERS`. Pass 1 to force serial.
    """
    # Route through the partition-returning entry but
    # discard the partitions (the caller doesn't want them).
    var sink = JsonlPartitions(
        los=List[Int](),
        his=List[Int](),
        indices=List[StructuralIndex](),
    )
    var schema = infer_jsonl_schema_parallel_into(
        bytes, sink, n_workers
    )
    _ = sink^
    return schema^


def infer_jsonl_schema_parallel_into(
    bytes: Span[UInt8, _],
    mut partitions: JsonlPartitions,
    n_workers: Int = 0,
) raises -> Schema:
    """Parallel inferrer that ALSO returns its
    per-worker structural indices (and the partition boundaries that
    produced them) so the materializer can REUSE them instead of
    re-building each from scratch.

    On the serial-fallback paths (file size < `_MIN_PARALLEL_INFER_BYTES`,
    n_workers <= 1, single-range file), returns the inferred schema with
    `JsonlPartitions{los=[], his=[], indices=[]}` — the caller must detect
    `len(partitions.indices) == 0` and fall back to the serial
    materializer (which builds its own single full-file index — cheap on
    small files).

    The structural indices are owned by the returned `JsonlPartitions`
    and must outlive the immediately-following
    `materialize_jsonl_to_batch_parallel_with_partitions(...)` call.

    Memory: ~5 bytes per structural-token × ~N/30 tokens for a typical
    JSON workload = ~10-15% of input file size per partition × k workers
    total (a 2.7 GB file over 10 workers: ~500 MB peak). Indices are
    dropped at the end of
    materialize.

    No-dispatcher entry: routes the per-partition inference through the
    SERIAL fork-join fallback (`parallel_fork_join_serial`). Callers with
    an EngineContext-owned dispatcher should use
    `infer_jsonl_schema_parallel_into_with_dispatcher` for true multi-worker
    parallelism.
    """
    return _infer_parallel_into_impl[
        has_dispatcher=False, disp_o=MutAnyOrigin
    ](
        bytes,
        partitions,
        n_workers,
        Optional[Pointer[LocalDispatcher[NoopSink], MutAnyOrigin]](None),
        CancellationToken.never(),
    )


def infer_jsonl_schema_parallel_into_with_dispatcher[
    disp_o: Origin[mut=True],
](
    bytes: Span[UInt8, _],
    mut partitions: JsonlPartitions,
    dispatcher_ptr: Pointer[LocalDispatcher[NoopSink], disp_o],
    var cancel_token: CancellationToken,
    n_workers: Int = 0,
) raises -> Schema:
    """Dispatcher-aware twin of `infer_jsonl_schema_parallel_into`. Caller
    threads `ctx.dispatcher()` + `ctx.cancel_token()` for true multi-worker
    parallelism via the shared `parallel_fork_join` helper."""
    return _infer_parallel_into_impl[
        has_dispatcher=True, disp_o=disp_o
    ](
        bytes,
        partitions,
        n_workers,
        Optional[Pointer[LocalDispatcher[NoopSink], disp_o]](dispatcher_ptr),
        cancel_token^,
    )


def _infer_parallel_into_impl[
    has_dispatcher: Bool,
    disp_o: Origin[mut=True],
](
    bytes: Span[UInt8, _],
    mut partitions: JsonlPartitions,
    n_workers: Int,
    dispatcher_ptr: Optional[Pointer[LocalDispatcher[NoopSink], disp_o]],
    var cancel_token: CancellationToken,
) raises -> Schema:
    """Shared body for the parallel inferrer.

    Partitions the byte stream into line-range sub-ranges, then dispatches
    one chunk per partition via the shared `parallel_fork_join` fork-join
    helper (dispatcher-aware) or `parallel_fork_join_serial` (no-dispatcher),
    each producing one owned `_PartialInferOut` in INDEX ORDER. Merges the
    partials in FILE ORDER (byte-identical Schema field order) and hands the
    per-chunk indices + boundaries off via the `partitions` out-arg. The
    helper owns the dispatch-boundary safety contract."""
    var n = len(bytes)

    var effective_workers = n_workers
    if effective_workers <= 0:
        effective_workers = num_physical_cores()
    if effective_workers > _MAX_INFER_WORKERS:
        effective_workers = _MAX_INFER_WORKERS
    if effective_workers < 1:
        effective_workers = 1

    if n < _MIN_PARALLEL_INFER_BYTES or effective_workers == 1:
        # Serial fallback: caller sees empty partitions and routes to
        # the standard parallel materializer.
        _ = cancel_token^
        partitions.los = List[Int]()
        partitions.his = List[Int]()
        partitions.indices = List[StructuralIndex]()
        return infer_jsonl_schema(bytes)

    var los = List[Int]()
    var his = List[Int]()
    _compute_jsonl_line_ranges(bytes, n, effective_workers, los, his)
    var k = len(los)
    if k <= 1:
        _ = cancel_token^
        partitions.los = List[Int]()
        partitions.his = List[Int]()
        partitions.indices = List[StructuralIndex]()
        return infer_jsonl_schema(bytes)

    # ---------------------------------------------------------------------
    # Parallel partial-inference via the fork-join helper. Build the input
    # bundle (OWNS los/his copies; only the byte stream is borrowed, through
    # the Span's own CONCRETE immutable origin). The synchronous wake-word
    # barrier guarantees the byte pointer outlives the dispatch.
    # ---------------------------------------------------------------------
    comptime byte_o = bytes.origin
    var fj_in = _InferInput[byte_o](
        bytes.unsafe_ptr(), n, los.copy(), his.copy()
    )
    var work = _InferPartialWork[byte_o](Int32(0))

    var fj_out: Slab[Optional[_PartialInferOut]]

    comptime if has_dispatcher:
        comptime in_o = origin_of(fj_in)
        fj_out = parallel_fork_join[
            _InferPartialWork[byte_o],
            _InferInput[byte_o],
            _PartialInferOut,
            in_o,
            disp_o,
        ](
            work^, fj_in, k, dispatcher_ptr.value(), cancel_token^,
        )
    else:
        _ = cancel_token^
        comptime in_o2 = origin_of(fj_in)
        fj_out = parallel_fork_join_serial[
            _InferPartialWork[byte_o],
            _InferInput[byte_o],
            _PartialInferOut,
            in_o2,
        ](
            work^, fj_in, k,
        )
    _ = fj_in^

    # ---------------------------------------------------------------------
    # Merge partials IN FILE ORDER (chunk 0 first) so the column insertion
    # order matches the serial first-seen order → byte-identical Schema.
    # Each chunk's owned `_PartialInferOut` is taken from its slot; the
    # names/inferred drive the merge, the index is collected for the caller.
    # ---------------------------------------------------------------------
    var merged_names = List[String]()
    var merged_inferred = List[UInt8]()
    var part_indices = List[StructuralIndex]()
    var m = 0
    while m < k:
        ref slot = fj_out.get_mut_interior(m)
        var partial = slot.take()
        _merge_partial_into(
            merged_names, merged_inferred,
            partial.names, partial.inferred,
        )
        # Consume the partial: its index is handed to the caller; names +
        # inferred (already merged above) drop inside `into_index` via the
        # `deinit self` full destructure.
        part_indices.append(partial^.into_index())
        m = m + 1
    _ = fj_out^

    # Same ceiling as the serial inferrer, stated on the MERGED name set --
    # each worker's partial can be under the cap while their union is not.
    check_json_column_count(len(merged_names))
    var sb = SchemaBuilder()
    for i in range(len(merged_names)):
        var at = _inferred_to_arrow(merged_inferred[i])
        sb.add_field(Field(merged_names[i].copy(), at, True))
    # Hand the per-worker indices + boundaries off to the
    # caller via the mut `partitions` out-arg.
    partitions.los = los^
    partitions.his = his^
    partitions.indices = part_indices^
    return sb.build()


def _infer_jsonl_schema_from_index(
    bytes: Span[UInt8, _], ref idx: StructuralIndex
) raises -> Schema:
    """Core inferrer over an already-built structural index. Shared by
    `infer_jsonl_schema` (builds the index, discards it) and
    `infer_jsonl_schema_with_index` (builds it, returns it for reuse).
    Takes `idx` by `ref` — NO copy of the (large) offsets/tags Lists."""
    var column_names = List[String]()
    var column_inferred = List[UInt8]()
    _infer_partial_into(bytes, idx, column_names, column_inferred)

    # Build the Schema. All fields are nullable=True (inference cannot prove
    # non-null from a sample).
    var sb = SchemaBuilder()
    for i in range(len(column_names)):
        var at = _inferred_to_arrow(column_inferred[i])
        sb.add_field(Field(column_names[i].copy(), at, True))
    return sb.build()


def _infer_partial_into(
    bytes: Span[UInt8, _],
    ref idx: StructuralIndex,
    mut column_names: List[String],
    mut column_inferred: List[UInt8],
) raises:
    """Walk one structural index and accumulate per-column observed-type
    lattice cells into the caller's parallel `(column_names,
    column_inferred)` lists (first-seen insertion order).

    Factored out of `_infer_jsonl_schema_from_index` so the PARALLEL
    inferrer (`infer_jsonl_schema_parallel`) can run this per line-range
    slice in a worker, then merge the partials via the same lattice
    (`_merge_partial_into`). The serial path calls this once over the
    full-file index.

    Does NOT build the Schema — the caller decides whether to merge with
    another partial first. The lists may be non-empty on entry (the
    serial path passes empties; the merge path would not use this directly).

    The per-key resolution is driven by a `KeyRegistryBuilder` (FNV-1a
    hash + open addressing): keys are looked up by Span[UInt8] directly,
    with no linear scan and no per-call String allocation; the only String
    allocation happens on first-seen insert. The output contract
    (column_names / column_inferred parallel Lists) is what the parallel
    inferrer's merge path consumes.
    """
    # Seed the builder with names already in the lists (no caller passes
    # any today); only the names past them are appended at the end.
    var builder = KeyRegistryBuilder()
    var seeded = len(column_names)
    if seeded > 0:
        var s_i = 0
        while s_i < seeded:
            _ = builder.lookup_or_insert_owned(column_names[s_i].copy())
            s_i = s_i + 1

    var tape_len = idx.size()
    var input_len = len(bytes)
    # The decoded spelling of a key that holds an escape, reused per key.
    var key_buf = List[UInt8]()

    var t: Int = 0
    while t < tape_len:
        # Find next OPEN_BRACE (start of a top-level object).
        if idx.tags[t] != TAG_OPEN_BRACE:
            t += 1
            continue
        # Walk this object: pairs of (key, value) until CLOSE_BRACE.
        t += 1  # consume OPEN_BRACE
        while t < tape_len:
            var tag = idx.tags[t]
            if tag == TAG_CLOSE_BRACE:
                t += 1
                break
            if tag == TAG_COMMA:
                t += 1
                continue
            if tag != TAG_QUOTE_OPEN:
                raise Error(
                    "infer_jsonl_schema: expected TAG_QUOTE_OPEN at tape"
                    " position "
                    + String(t)
                    + ", got tag="
                    + String(Int(tag))
                )
            var quote_open_offset = Int(idx.offsets[t])
            t += 1
            # Find matching TAG_QUOTE_CLOSE.
            if t >= tape_len or idx.tags[t] != TAG_QUOTE_CLOSE:
                raise Error(
                    "infer_jsonl_schema: missing TAG_QUOTE_CLOSE for"
                    " key at byte "
                    + String(quote_open_offset)
                )
            var quote_close_offset = Int(idx.offsets[t])
            t += 1
            # Extract the key bytes (exclusive of both quote bytes).
            var key_start = quote_open_offset + 1
            var key_end = quote_close_offset
            # No String allocation here. The key is
            # resolved by Span[UInt8] directly via the hash table; the
            # String is only materialized on first-seen insert inside the
            # builder.
            # Expect colon next.
            if t >= tape_len or idx.tags[t] != TAG_COLON:
                raise Error(
                    "infer_jsonl_schema: expected TAG_COLON after key"
                    " at byte "
                    + String(quote_open_offset)
                )
            var colon_offset = Int(idx.offsets[t])
            t += 1
            # Dispatch on the value's tag.
            if t >= tape_len:
                raise Error(
                    "infer_jsonl_schema: truncated input (expected"
                    " value after colon at byte "
                    + String(colon_offset)
                    + ")"
                )
            var value_tag = idx.tags[t]
            var observed: UInt8
            if value_tag == TAG_QUOTE_OPEN:
                # STRING value — consume the matched quote pair.
                t += 1  # quote_open
                if t >= tape_len or idx.tags[t] != TAG_QUOTE_CLOSE:
                    raise Error(
                        "infer_jsonl_schema: missing TAG_QUOTE_CLOSE"
                        " for string value at byte "
                        + String(quote_open_offset)
                    )
                t += 1  # quote_close
                observed = INF_STRING
            elif value_tag == TAG_OPEN_BRACE or value_tag == TAG_OPEN_BRACKET:
                # Nested types (LIST / STRUCT / MAP) surface as an
                # inference-not-supported error. Users who need nested
                # columns can supply an explicit schema via
                # `ctx.read_json_batch(path, schema)`.
                raise Error(
                    "infer_jsonl_schema: nested JSON value (object or"
                    " array) at byte "
                    + String(Int(idx.offsets[t]))
                    + " — wide-default inference of LIST / STRUCT /"
                    + " MAP is not supported. Pass an explicit"
                    + " schema via ctx.read_json_batch(path, schema)"
                    + " to read this file."
                )
            else:
                # Scalar value (number / true / false / null). Compute
                # its byte range = colon_offset+1 .. next-tape-pos
                # (or end of input if at the tail).
                var next_tape_pos: Int
                if t < tape_len:
                    next_tape_pos = Int(idx.offsets[t])
                else:
                    next_tape_pos = input_len
                var s_start = colon_offset + 1
                while s_start < next_tape_pos and _is_ws(bytes[s_start]):
                    s_start += 1
                var s_end = next_tape_pos
                while s_end > s_start and _is_ws(bytes[s_end - 1]):
                    s_end -= 1
                if s_end <= s_start:
                    raise Error(
                        "infer_jsonl_schema: empty scalar value after"
                        " key at byte "
                        + String(quote_open_offset)
                    )
                observed = _classify_scalar(bytes, s_start, s_end)
            # Lookup-or-insert by byte span (O(1)
            # avg hash hit; String allocation only on first-seen insert).
            # The column is named by the text the key spells, as the
            # reader looks it up (key_unescape.mojo).
            var ki: Int
            if key_has_escape(bytes[key_start:key_end]):
                unescape_key(bytes[key_start:key_end], key_buf)
                ki = builder.lookup_or_insert_bytes(key_buf)
            else:
                ki = builder.lookup_or_insert_bytes(bytes[key_start:key_end])
            # Grow the parallel `column_inferred` list to keep in lockstep
            # with the builder's column count (the builder appended a new
            # column iff ki == len(column_inferred)).
            if ki == len(column_inferred):
                column_inferred.append(INF_NULL)
            var promoted = _promote_pair(column_inferred[ki], observed)
            if promoted == INF_MIXED_STRING:
                # Heterogeneous types across rows — surface clearly so
                # the user can supply an explicit schema. This does NOT
                # fall back to STRING because the materializer raises on
                # a STRING column with an unquoted scalar — so a silent
                # fallback would just defer the failure to materialize
                # time with a less helpful error.
                raise Error(
                    "infer_jsonl_schema: heterogeneous types for column"
                    " '"
                    + builder.name_at(ki)
                    + "' across records (existing="
                    + _inferred_tag_name(column_inferred[ki])
                    + ", observed="
                    + _inferred_tag_name(observed)
                    + "). Wide-default inference requires uniform"
                    + " types per column. Recovery: pass an explicit"
                    + " schema via ctx.read_json_batch(path, schema)."
                )
            column_inferred[ki] = promoted

    # Drain the builder's owned names list into the caller's
    # `column_names`. This preserves the original output contract
    # (insertion-ordered List[String]).
    var final_names = builder^.into_names()
    # HOSTILE-INPUT CEILING (ASSERT=none hardening).
    #
    # The distinct-key count inferred here IS the `cols` factor of the
    # materializer's rows x cols allocation, and nothing bounded it: this
    # inferrer inserts one column per first-seen key with no max-column
    # policy, so a document of key-per-value data yields a Schema with
    # millions of fields.
    #
    # ⚠ PLACEMENT IS DELIBERATE. The obvious spot is
    # `KeyRegistryBuilder.lookup_or_insert_bytes`, on the insert branch --
    # and that is WRONG, because making that method `raises` puts an error
    # check on the per-key LOOKUP path too, which runs once per key per
    # row (tens of millions of times on a large file). Here the check runs
    # ONCE per inference (or
    # once per partition worker). Nothing is lost by waiting: the registry's
    # own growth is O(input bytes) -- every distinct key costs at least a few
    # input bytes -- so the unbounded QUADRATIC blowup is downstream, in the
    # materializer, and this raise happens long before it.
    check_json_column_count(len(final_names))
    for i in range(seeded, len(final_names)):  # the seeded names are there
        column_names.append(final_names[i].copy())


# =============================================================================
# PARALLEL schema inference (line-range sharded).
# =============================================================================


def _merge_partial_into(
    mut dst_names: List[String],
    mut dst_inferred: List[UInt8],
    src_names: List[String],
    src_inferred: List[UInt8],
) raises:
    """Merge a partial `(src_names, src_inferred)` into the running
    `(dst_names, dst_inferred)` accumulator via the wide-default lattice.

    For each src column: look up (or insert, preserving first-seen order)
    the column in dst, then promote dst's cell with src's observed cell via
    `_promote_pair`. Because partitions are processed in FILE ORDER and dst
    starts from worker 0, the resulting insertion order is identical to the
    single-thread first-seen order — so the emitted Schema is byte-identical
    to the serial inferrer's. Heterogeneous-type promotion (INF_MIXED_STRING)
    raises here exactly as it would in the serial walk.
    """
    for i in range(len(src_names)):
        var ki = _lookup_or_insert(
            dst_names, dst_inferred, src_names[i].copy()
        )
        var promoted = _promote_pair(dst_inferred[ki], src_inferred[i])
        if promoted == INF_MIXED_STRING:
            raise Error(
                "infer_jsonl_schema: heterogeneous types for column '"
                + dst_names[ki]
                + "' across records (existing="
                + _inferred_tag_name(dst_inferred[ki])
                + ", observed="
                + _inferred_tag_name(src_inferred[i])
                + "). Wide-default inference requires uniform types"
                + " per column. Recovery: pass an explicit schema via"
                + " ctx.read_json_batch(path, schema)."
            )
        dst_inferred[ki] = promoted


# =============================================================================
# Helpers
# =============================================================================


def _bytes_to_string(bytes: Span[UInt8, _], start: Int, end: Int) -> String:
    """Build a Mojo `String` from a byte range. No escape decoding
    (JSON key strings cannot contain `\\uXXXX` per RFC 8259 in a sane
    schema; non-ASCII bytes are valid UTF-8 and copied verbatim).

    A single bulk byte-slice copy via `String(unsafe_from_utf8=...)` — the
    same idiom the ORC / Avro readers use. A per-character
    `out += chr(Int(b))` loop would grow one heap String PER BYTE and
    RE-ENCODE bytes >127, mangling multi-byte UTF-8 keys; here raw bytes
    are preserved verbatim (correct UTF-8)."""
    return String(unsafe_from_utf8=bytes[start:end])


@always_inline
def _write_inferred_tag_name[W: Writer](mut writer: W, tag: UInt8):
    """WRITE what `_inferred_tag_name` returns. ⚠ THIS WRITES; IT DOES NOT RETURN.

    The arms live here so no string constant is ever SELECTED and
    returned. A literal-returning ladder lowers to two parallel
    (pointer, length) constant arrays whose two call-site references
    an `--emit shared-lib` link binds INDEPENDENTLY, and a shared library
    can bind such a pair CROSSED and take the host interpreter down with
    it."""
    if tag == INF_NULL:
        writer.write(String("NULL"))
        return
    elif tag == INF_INT64:
        writer.write(String("Int64"))
        return
    elif tag == INF_FLOAT64:
        writer.write(String("Float64"))
        return
    elif tag == INF_BOOL:
        writer.write(String("Bool"))
        return
    elif tag == INF_STRING:
        writer.write(String("String"))
        return
    else:
        writer.write(String("MIXED"))
        return


@always_inline
def _inferred_tag_name(tag: UInt8) -> String:
    """Human-readable name for an internal lattice tag — used in the
    heterogeneous-type error message."""
    var out = String()
    _write_inferred_tag_name(out, tag)
    return out^
