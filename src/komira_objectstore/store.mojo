# =============================================================================
# komira_objectstore/store.mojo — the ObjectStore trait + ObjectStoreHttp stub
# =============================================================================
#
# The NETWORK-FREE TRAIT surface is declared here as the vendor-neutral
# contract; concrete backends (`S3Store`, `GcsStore`, `AzureStore`) live in
# `komira_aws_s3`, `komira_gcp_gcs` and `komira_azure_blob`.
#
# Design choice — a narrow base trait + an ObjectStoreHttp local stub. A full
# trait surface would carry `IoOp[T, Self.S,...]`-typed async carriers
# (`GetOp`, `GetRangeOp`, etc.) threaded through `komira_async`'s
# `WakerSink`, coupling every conformer to the HTTP client's runtime shape.
#
# So the base trait declares
#   (a) the synchronous metadata surface (runtime-free — `head`,
#       `list_with_delimiter`); and
#   (b) the ObjectStoreHttp LOCAL STUB (the HTTP client seam).
# The runtime-coupled byte-fetch surface lives on REFINING traits below
# (`RangeFetchStore.get_ranges`, `AsyncCasStore`), so a conformer opts in
# to exactly the verbs it implements.
#
# Encapsulation discipline:
#   * ZERO UnsafePointer in any public surface.
#   * ZERO wildcard origins.
# =============================================================================

from komira_buffer.byte_view import ByteView

from komira_async.ops.waker_sink import WakerSink
from komira_async.reactor.reactor import Reactor

from komira_objectstore.path import Path
from komira_objectstore.types import (
    CoalescePolicy,
    GetRange,
    ListResult,
    ObjectMeta,
    RangeFetchResult,
    RangeSet,
    WritePrecondition,
)


# The default concurrency depth for the concurrent get_ranges fan-out. It
# mirrors the engine's S3 prefetch depth of 64. Declared here
# so the trait surface can default `max_concurrency` without importing the
# engine-side prefetch constant (which would be a wrong-direction edge).
comptime PREFETCH_DEPTH_S3_STANDARD = Int(64)


# -----------------------------------------------------------------------------
# ObjectStoreHttp — LOCAL STUB
# -----------------------------------------------------------------------------
#
# This is a deliberately MINIMAL stub of the HTTP client's `ObjectStoreHttp`
# trait. It lets the type design, the URI parser and the trait elaboration
# compile and test without the production HTTP client.
#
# The full trait shape:
#
#   trait ObjectStoreHttp(Movable, Deinitable):
#       fn head[RT: Runtime](
#           mut self, url: Url, mut rt: RT, ref token: CancellationToken,
#       ) raises -> ClientResponse: ...
#
#       fn get_range[RT: Runtime](
#           mut self, url: Url, start: Int64, end: Int64,
#           mut rt: RT, ref token: CancellationToken,
#       ) raises -> ClientResponse: ...
#
#       fn get_ranges[RT: Runtime, //, dst_origin: Origin[mut=True]](
#           mut self, url: Url, ranges: List[ByteRange],
#           dst: ByteView[mut=True, dst_origin],
#           dst_offsets: List[Int], max_concurrency: Int,
#           mut rt: RT, ref token: CancellationToken,
#       ) raises -> RangeFanoutResult: ...
#
# Replacing the stub with the real trait:
#   1. Delete this trait declaration.
#   2. Add `from komira_http import ObjectStoreHttp` to consumers (a
#      `komira_objectstore -> komira_http` dependency).
#   3. Expand the narrowed surface above to the full shape (byte-fetch
#      methods returning IoOp-shaped carriers) using komira_async's
#      `WakerSink` + `IoOp`.
#   4. `tests/test_path_uri.mojo` is unaffected (it tests Path/URI parsing,
#      which has no transport dependency).
# -----------------------------------------------------------------------------


trait ObjectStoreHttpStub(Movable, Deinitable):
    """!!! STUB !!! — local placeholder for the HTTP client's
    `ObjectStoreHttp` trait. See the block above this trait declaration for
    how the real trait replaces it.

    The stub carries only a `head_url` method to keep the trait
    self-describing (conformers must provide *something*); the real trait
    has the full byte-fetch surface.
    """

    def head_url(mut self, url: String) raises -> Int64:
        """STUB: return the size of the object at `url`, or raise on
        not-found / transport error. The real `ObjectStoreHttp.head`
        returns a typed `ClientResponse`; this stub returns just the size
        to keep the seam concrete enough to compile against without
        pulling komira_http types in early.
        """
        ...


# -----------------------------------------------------------------------------
# ObjectStore — vendor-neutral trait (a narrowed surface)
# -----------------------------------------------------------------------------
#
# The base surface carries the synchronous metadata methods only. The
# runtime-coupled byte-fetch methods live on refining traits below.
#
# Conformers: S3Store (komira_aws_s3), GcsStore (komira_gcp_gcs),
# AzureStore (komira_azure_blob), MinioStore (S3Store with endpoint override).
# -----------------------------------------------------------------------------


trait ObjectStore(Movable, Deinitable):
    """Cloud object-storage backend.

    The base SURFACE — synchronous metadata operations. The byte-fetch
    methods couple to the `ObjectStoreHttp` seam and the `komira_async`
    `WakerSink` substrate, so they live on refining traits.

    Pointer discipline: ZERO UnsafePointer in any method signature.
    """

    # ---- Metadata ops (sync; cheap; bounded) ----
    def head(self, path: Path) raises -> ObjectMeta:
        """HEAD request — object size, etag, last-modified, version. No body."""
        ...

    def list_with_delimiter(self, prefix: Path) raises -> ListResult:
        """Hierarchical listing: returns (objects, common_prefixes) — the
        S3 `delimiter='/'` semantics. Used for directory-style discovery.
        """
        ...

    # ---- Tuning state ----
    def coalesce_policy(self) -> CoalescePolicy:
        """The store's CoalescePolicy — input to the coalescing
        planner. Allows per-store overrides of the default policy."""
        ...


# -----------------------------------------------------------------------------
# ConditionalWriteStore — refining trait for compare-and-swap writes
# -----------------------------------------------------------------------------
#
# The conditional-write contract.
#
# Pure object-store coordination is the platform default; this primitive is
# the foundation of the broker and search-engine surfaces.
# A `conditional_put` drives the server-side compare-and-swap so concurrent
# writers race safely — exactly one create-if-absent wins, the rest see a
# `StoreError.precondition` (412) and retry.
#
# Why a REFINING trait (not a method on the base `ObjectStore`): Mojo
# traits carry NO default method bodies, so adding `conditional_put` to the
# base `ObjectStore` trait would force-break every existing `ObjectStore`
# conformer (S3Store and any future GcsStore / AzureStore) — they would all
# fail to compile until they implemented the new verb. Refining keeps the
# addition strictly ADDITIVE: only the conformers that opt into
# `ConditionalWriteStore` carry the verb.
#
# Pointer discipline: ZERO UnsafePointer in any method signature — bytes flow
# as an owned `List[UInt8]`, the precondition is a value-passable POD, and the
# returned `ObjectMeta` carries the new committed etag/version by value.
#
# The version handle stays OPAQUE at the trait boundary: for S3 it is the
# response `ETag` string; the GCS integer-generation + Azure version-id forms
# map onto the same opaque handle (see the per-backend note below).
# -----------------------------------------------------------------------------


trait ConditionalWriteStore(ObjectStore):
    """An `ObjectStore` that additionally supports the full CAS-manifest
    object lifecycle: conditional (compare-and-swap) writes, unconditional
    `put`, ranged byte-fetch, and `delete`.

    SHARED SUBSTRATE — broker AND search-engine conform to this trait. The
    surface is intentionally vendor-neutral and lifecycle-complete (it is
    NOT broker-specific): every verb a CAS-manifest reader/writer needs at
    the object layer lives here, and the GCS / Azure conformers
    (komira_gcp_gcs / komira_azure_blob) implement the same verbs against
    their provider headers.

    Conflict semantics: a precondition that fails server-side (HTTP 412)
    raises `StoreError.precondition(...)` (via the backend's Error-message
    taxonomy). The caller catches it and retries with a fresh read of the
    current etag.

    Refines `ObjectStore`: a conformer must already provide
    `head` / `list_with_delimiter` / `coalesce_policy`.

    Verb set (the broker + search foundation):
      * `conditional_put`  — CAS / create-if-absent write.
      * `compare_and_swap` — `if_match`-shaped CAS update.
      * `put`              — unconditional single-shot write.
      * `get_range`        — ranged byte-fetch `[start, length)` (the
                             manifest / segment readers' core verb).
      * `get`              — full-object fetch convenience.
      * `delete`           — the `ScheduledForDelete` lifecycle.

    Pointer discipline: ZERO UnsafePointer in any method signature. Bytes
    flow as owned `List[UInt8]`; the precondition is a value-passable POD;
    the returned `ObjectMeta` carries the committed etag/version by value.

    Per-backend version handles: the opaque version handle is an S3 etag
    string for S3. The GCS
    integer-generation precondition (`x-goog-if-generation-match`) and the
    Azure version/ETag precondition (`If-Match` / `If-None-Match` with the
    Azure ETag shape) land in their own per-cloud conformers
    (komira_gcp_gcs / komira_azure_blob) — they conform to THIS trait
    with the same `WritePrecondition` surface but map the precondition to
    their provider-specific headers. Leave `version` opaque; do not assume
    an S3 etag shape at the trait boundary.
    """

    def conditional_put(
        self, path: Path, bytes: List[UInt8], precond: WritePrecondition
    ) raises -> ObjectMeta:
        """PUT `bytes` at `path`, conditioned on `precond`.

        On success, returns the new committed `ObjectMeta` (its `etag` /
        `version` reflect the just-written object so the caller can chain a
        subsequent CAS without an extra HEAD round-trip).

        On precondition conflict (HTTP 412), raises a `StoreError`-shaped
        Error carrying the `PRECONDITION` taxonomy arm. The caller retries.
        """
        ...

    def compare_and_swap(
        self, path: Path, bytes: List[UInt8], expected_version: String
    ) raises -> ObjectMeta:
        """Compare-and-swap: write `bytes` at `path` only if the object's
        current version (etag) equals `expected_version`.

        Thin wrapper over `conditional_put` with
        `WritePrecondition.if_match(expected_version)`. Returns the new
        committed `ObjectMeta` (with the post-swap etag/version). On a
        stale `expected_version`, raises `StoreError.precondition(...)`.
        """
        ...

    def put(self, path: Path, bytes: List[UInt8]) raises -> ObjectMeta:
        """Unconditional single-shot write of `bytes` at `path` (create or
        overwrite). Returns the committed `ObjectMeta` (etag/version set
        from the write response).

        For objects below the multipart threshold this is one PUT; large
        objects use the FileSystem multipart-write path (`S3Fs.open_write`)
        — `put` is the CAS-manifest small-object verb (manifests are small
        JSON blobs). Equivalent to `conditional_put(path, bytes,
        WritePrecondition.none())`.
        """
        ...

    def get_range(
        self, path: Path, start: Int64, length: Int64
    ) raises -> List[UInt8]:
        """Ranged byte-fetch: read `length` bytes starting at `start` from
        the object at `path`. Returns the response body bytes.

        The core read verb for the manifest / segment readers — they fetch
        a bounded window (a manifest record, an index block, a segment
        footer) without pulling the whole object. `start` is 0-based;
        `[start, start + length)` (half-open, caller-natural). Raises
        `StoreError.not_found` (404) if the object is absent, or a length
        mismatch if the server returns a short range.
        """
        ...

    def get(self, path: Path) raises -> List[UInt8]:
        """Full-object fetch (no Range header). Returns the whole object
        body. Convenience over `get_range(path, 0, <object-size>)` for
        small manifests where the size is not known up front.
        """
        ...

    def delete(self, path: Path) raises -> None:
        """DELETE the object at `path`. Idempotent per S3 semantics —
        deleting an absent key succeeds (204 No Content). Drives the
        `ScheduledForDelete` lifecycle: once a manifest marks a segment /
        message for deletion and the grace window elapses, the reaper
        issues this verb. Raises only on a real 4xx/5xx (auth / transport),
        NOT on already-absent.
        """
        ...


# -----------------------------------------------------------------------------
# CloneableConditionalWriteStore — refining trait for clone-shared handles
# -----------------------------------------------------------------------------
#
# A `ConditionalWriteStore` whose `clone()` returns a fresh handle SHARING the
# same underlying data (the Arc-backed map for the in-memory twin; the
# Arc-shared signing+config core bound to the same bucket for S3). This is the
# bound the Kafka-wire data plane (`KafkaDataBroker` / `KafkaMultiTopicData` /
# `GroupOffsetStore` / `GroupCoordinator`) parameterizes over so it can fan one
# store out into the per-partition segment + manifest handles WITHOUT pinning
# the concrete store type — letting the SAME Kafka server run EITHER in-memory
# (fast tests) OR `S3ConditionalStore[C]` (durable, S3-backed).
#
# Why a REFINING trait (not `clone()` on the base `ConditionalWriteStore`):
# identical rationale to `ConditionalWriteStore` itself — Mojo 1.0.0b1 traits
# carry no default method bodies, so adding `clone()` to the base trait would
# force-break every existing conformer (e.g. `in_memory_conditional_store`'s
# non-shared twin, which has no clone-shares-data semantics). Refining keeps
# the addition strictly ADDITIVE: only the clone-shared conformers
# (`SharedInMemoryConditionalStore`, `S3ConditionalStore[C]`) opt in.
#
# Pointer discipline: ZERO UnsafePointer in the signature — `clone()` returns
# an owned `Self` by value.
# -----------------------------------------------------------------------------


trait CloneableConditionalWriteStore(ConditionalWriteStore):
    """A `ConditionalWriteStore` whose `clone()` yields a handle sharing the
    same underlying data (Arc-backed in-memory map / Arc-shared S3 core bound
    to the same bucket).

    Refines `ConditionalWriteStore`: a conformer must already provide the full
    CAS-manifest verb set (`head` / `list_with_delimiter` / `coalesce_policy` /
    `conditional_put` / `compare_and_swap` / `put` / `get_range` / `get` /
    `delete`).
    """

    def clone(self) -> Self:
        """Return a fresh handle SHARING the same underlying data. INFALLIBLE:
        the in-memory twin Arc-copies its map; `S3ConditionalStore[C]`
        Arc-copies its signing+config core (same bucket => same S3 data) with a
        lazily-rebuilt per-pthread transport. The clone is what lets one store
        fan out into the per-partition segment + manifest handles."""
        ...


# -----------------------------------------------------------------------------
# RangeFetchStore — refining trait for CONCURRENT byte-range fetch
# -----------------------------------------------------------------------------
#
# Fills the byte-fetch hole
# (the `get_ranges` arm of the comment block at the top of this file) with
# the foundational CONCURRENT verb: N byte-ranges in flight on one worker's
# reactor so wall time is `1×RTT + N×transfer`, not `N×RTT`. Parquet, the
# broker, and the search engine all inherit it.
#
# Why a REFINING trait (not a method on base `ObjectStore`): identical
# rationale to `ConditionalWriteStore` above — Mojo 1.0.0b1 traits carry no
# default method bodies, so adding `get_ranges` to the base trait would
# force-break every existing metadata-only conformer. Refining keeps the
# addition strictly ADDITIVE: S3 opts in first; GCS / Azure follow.
#
# THE ENCAPSULATION CONTRACT. The fan-out's machinery — the `Reactor`, the op-handles, the
# `UnsafePointer` scatter-writes, the per-connection transport — is all
# unsafe-or-runtime-shaped, and ALL of it stays INSIDE the conformer
# (Option-A conformer-owns-runtime, proven by `S3Fs[C]`). The trait surface
# exposes ONLY:
#   * Input:  a `RangeSet` (parallel ranges + dst_offsets) + a caller-owned
#             mutable `dst` byte view + a `max_concurrency` Int.
#   * Output: bytes scattered into `dst` (order-preserving: bytes for input
#             range `i` land at `dst[dst_offsets[i] ..]`), plus a small typed
#             `RangeFetchResult` POD (per-range status / fetched-byte counts).
# NO `Reactor`, NO `OpHandle`, NO `UnsafePointer`, NO wildcard origin, NO
# `[RT]/[C]` in this signature. The `dst_origin` parameter is a CONCRETE
# mutable origin (`MutableOrigin`), NOT a wildcard — the same shape the
# in-tree `get_ranges_into[RT, O: Origin[mut=True]]` uses. This is the
# firewall the `S3Fs[C]` conformer already honors.
# -----------------------------------------------------------------------------


trait RangeFetchStore(ObjectStore):
    """An `ObjectStore` that additionally supports a CONCURRENT byte-range
    fetch (`get_ranges`).

    Refines `ObjectStore`: a conformer must already provide
    `head` / `list_with_delimiter` / `coalesce_policy`.

    The fan-out completes its N range requests out of order (await-ANY),
    but the bytes are scatter-written by absolute caller-offset so the
    `dst` buffer is order-faithful, and `RangeFetchResult` is indexed by
    INPUT-range order. See the design's order-preservation contract.

    Pointer discipline: ZERO UnsafePointer / Reactor / OpHandle / wildcard
    origin / `[RT]/[C]` in the signature. The conformer owns its runtime +
    connector + reactor internally (Option-A).
    """

    def get_ranges[
        dst_origin: Origin[mut=True]
    ](
        mut self,
        path: Path,
        ranges: RangeSet,
        dst: ByteView[mut=True, dst_origin],
        max_concurrency: Int = PREFETCH_DEPTH_S3_STANDARD,
    ) raises -> RangeFetchResult:
        """Concurrently fetch every byte-range in `ranges`, scatter-writing
        each range's bytes into `dst` at its `dst_offsets[i]` position.

        Args:
          path:            The object path within the bucket.
          ranges:          The input RangeSet (parallel `ranges` +
                           `dst_offsets`); range `i`'s bytes land at
                           `dst[dst_offsets[i] .. dst_offsets[i] + len_i)`.
          dst:             Caller-owned mutable byte view, pre-sized to hold
                           all ranges' bytes (the caller learns the size from
                           a prior `head` or from the sum of range lengths).
          max_concurrency: Max GETs in flight at once; defaults to
                           PREFETCH_DEPTH_S3_STANDARD (64).

        Returns:
          A `RangeFetchResult` — per-range status + fetched-byte counts,
          indexed parallel to INPUT `ranges` order (NOT completion order),
          plus a `total_fetched_bytes` rollup.

        Raises:
          On a transport / HTTP error for any range (the verb is all-or-
          nothing; the per-range `statuses` field is the seam the later
          partial-failure mode fills in).
        """
        ...


# -----------------------------------------------------------------------------
# AsyncCasStore — refining trait for a POLL-SHAPED (parkable) CAS round-trip
# -----------------------------------------------------------------------------
#
# The broker coordinator's parkable CAS serve needs this. The base
# `ConditionalWriteStore` surface is deliberately runtime-FREE (the
# "conformer-owns-runtime" — the verbs run the conformer's OWN reactor to
# completion, blocking the calling thread). That is fine for a worker that has
# nothing else to do, but it STALLS the broker coordinator's single-threaded
# serve reactor: while a rebalance's CAS write pumps the conformer's reactor to
# completion, the serve reactor's `accept()` cannot fire, so a rebalance BURST
# (rolling restart -> many back-to-back reassigns) starves new connections.
#
# THE FIX (this trait): expose the read + CAS-write as POLL-SHAPED ops that take
# the SERVE reactor and step ONE non-blocking advance at a time, so the serve
# loop multiplexes accept (bucket 1) WHILE a reassign's S3 round-trip is parked
# (bucket 2) — the burst-stall fix, structurally. Mirrors `RangeFetchStore`
# (the precedent that took the reactor INTO a refining trait while keeping the
# base sync surface untouched). ADDITIVE: non-broker callers keep the sync
# `ConditionalWriteStore` verbs; only the coordinator opts into the poll shape.
#
# THE OP STAYS INSIDE THE CONFORMER (the heap-reuse contract). A poll-shaped op holds
# an in-flight `PendingStreamingGet` across the park (it owns the dialed stream
# + the HttpClient pool's heap buffers). That in-flight op is held on a CONFORMER
# FIELD reached through the conformer's concrete-origin handle
# (`ArcPointer[Optional[transport]]` for S3 — NEVER a byte-`Slab` +
# `MutExternalOrigin` wildcard, which is the cross-process CAS crash's
# heap-reuse shape). The op NEVER crosses the trait boundary — the surface is
# start/poll/take of typed values only, so no transport-pool buffer is ever
# laundered through a wildcard origin. AT MOST ONE poll-shaped op is in flight
# per conformer at a time (the coordinator drives one reassign at a time).
#
# Pointer discipline: ZERO UnsafePointer in any signature. The reactor is a
# per-call `mut reactor: Reactor[S]` borrow (never stored as a field — matches
# the suspendable-handler discipline). The op_id is a plain biased Int64.
# -----------------------------------------------------------------------------


# Poll-shaped op states (mirror PG_READ_* / OUTBOUND_STEP_* sentinels).
comptime CAS_OP_PENDING: UInt8 = 0
comptime CAS_OP_READY: UInt8 = 1
comptime CAS_OP_ERR: UInt8 = 2


@fieldwise_init
struct CasOpProgress(Movable, Copyable, Deinitable):
    """The discriminated progress value a poll-shaped CAS op returns from
    `*_start` / `*_poll`. `state` is one of CAS_OP_PENDING / CAS_OP_READY /
    CAS_OP_ERR; `op_id` is the BIASED reactor op_id to park on while PENDING
    (>= OP_ID_ALLOC_BASE so the serve loop's bucket-2 demux routes the
    completion to `resume`), 0 when READY / ERR. POD — value-passable, no
    pointer.

    On READY the caller calls the op's `*_take` to move the typed result out;
    on ERR `err_text()` carries the diagnostic. On PENDING the caller parks the
    suspended frame on `op_id` and re-enters `*_poll` when that op_id completes.
    """

    var state: UInt8
    var op_id: Int64
    var err: String

    @staticmethod
    def pending(op_id: Int64) -> CasOpProgress:
        """Still in flight; park the frame on `op_id`."""
        return CasOpProgress(state=CAS_OP_PENDING, op_id=op_id, err=String(""))

    @staticmethod
    def ready() -> CasOpProgress:
        """The round-trip completed; the result is ready to `*_take`."""
        return CasOpProgress(state=CAS_OP_READY, op_id=Int64(0), err=String(""))

    @staticmethod
    def error(msg: String) -> CasOpProgress:
        """An unrecoverable transport/HTTP error."""
        return CasOpProgress(state=CAS_OP_ERR, op_id=Int64(0), err=msg)

    @always_inline
    def is_pending(self) -> Bool:
        return self.state == CAS_OP_PENDING

    @always_inline
    def is_ready(self) -> Bool:
        return self.state == CAS_OP_READY

    @always_inline
    def is_error(self) -> Bool:
        return self.state == CAS_OP_ERR

    @always_inline
    def err_text(self) -> String:
        return self.err


@fieldwise_init
struct CasReadResult(Movable, Deinitable):
    """The typed result of a completed poll-shaped READ: the object body bytes
    + its etag, OR an `absent` flag when the object did not exist (404 ->
    'no prior assignment'). Moved out of the conformer via `read_take`.

    Field layout:
      var absent: Bool        — True iff the object did not exist (404).
      var body: List[UInt8]   — the fetched body (empty when absent).
      var etag: String        — the CAS token (empty when absent).
    """

    var absent: Bool
    var body: List[UInt8]
    var etag: String


trait AsyncCasStore(ConditionalWriteStore):
    """A `ConditionalWriteStore` that ALSO exposes the read + CAS-write as
    POLL-SHAPED ops driven on a CALLER-SUPPLIED reactor (the broker
    coordinator's serve reactor), so a CAS round-trip never blocks the serve
    thread.

    Refines `ConditionalWriteStore`: a conformer must already provide the full
    sync CAS-manifest verb set; this adds the parkable variants. The two op
    families:

      READ  (the prior-assignment fetch):
        read_start[S](path, reactor)  -> CasOpProgress
        read_poll[S](reactor)         -> CasOpProgress
        read_take()                   -> CasReadResult

      CAS PUT (the assignment persist; create-if-absent OR If-Match update):
        cas_put_start[S](path, bytes, expected_etag, reactor) -> CasOpProgress
        cas_put_poll[S](reactor)                              -> CasOpProgress
        cas_put_take()                                        -> ObjectMeta

    Contract:
      * `*_start` kicks off the round-trip and attempts ONE immediate
        non-blocking advance. It returns READY on the immediate-completion
        fast path (no park), PENDING(op_id) when the round-trip would block
        (the caller parks the frame on `op_id`), or ERR.
      * `*_poll` (called when `op_id` completes) advances ONE more non-blocking
        step; READY / PENDING(op_id) / ERR.
      * `*_take` moves the typed result out (caller checks READY first).

    AT MOST ONE poll-shaped op (read OR cas_put) is in flight per conformer at
    a time — the coordinator drives a single reassign sequentially (read ->
    pure pass -> cas_put). The in-flight op is held on a CONFORMER FIELD reached
    via the conformer's concrete-origin handle; it never crosses this trait
    boundary (the heap-reuse contract — see the trait header).

    Pointer discipline: ZERO UnsafePointer in any signature; the reactor is a
    per-call `mut reactor: Reactor[S]` borrow (never stored); the op_id is a
    plain biased Int64. An `expected_etag` of length 0 means create-if-absent
    (If-None-Match), else If-Match on that etag.
    """

    def read_start[
        S: WakerSink & Movable & Deinitable,
    ](mut self, path: Path, mut reactor: Reactor[S]) raises -> CasOpProgress:
        ...

    def read_poll[
        S: WakerSink & Movable & Deinitable,
    ](mut self, mut reactor: Reactor[S]) raises -> CasOpProgress:
        ...

    def read_take(mut self) raises -> CasReadResult:
        ...

    def cas_put_start[
        S: WakerSink & Movable & Deinitable,
    ](
        mut self,
        path: Path,
        var bytes: List[UInt8],
        expected_etag: String,
        mut reactor: Reactor[S],
    ) raises -> CasOpProgress:
        ...

    def cas_put_poll[
        S: WakerSink & Movable & Deinitable,
    ](mut self, mut reactor: Reactor[S]) raises -> CasOpProgress:
        ...

    def cas_put_take(mut self) raises -> ObjectMeta:
        ...
