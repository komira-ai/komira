# =============================================================================
# komira_objectstore/types.mojo — request/response types + StoreError
# =============================================================================
#
# Direct analogues of Rust `object_store` crate types, Mojo-shaped per the
# type table.
#
# The type SHAPES are defined here (network-free). The async
# `IoOp[T]`-shaped `GetOp` / `GetRangeOp` / `GetRangesOp` / `PutOp` /
# `DeleteOp` carriers and the `ListStream[S]` async paginator live with the
# ObjectStore trait (`store.mojo`) — they are runtime-coupled (`Self.S` +
# `IoOp[...]`) so they need to land alongside whichever runtime stub they
# bind to. The coalesce planner consumes `RangeSet` + the StoreError-mapping;
# the HTTP-backed conformers add the live network.
#
# Encapsulation discipline:
#   * ZERO UnsafePointer in any public surface.
#   * ZERO wildcard origins.
# =============================================================================


# -----------------------------------------------------------------------------
# ObjectMeta — HEAD response / one entry per list page
# -----------------------------------------------------------------------------


@fieldwise_init
struct ObjectMeta(Movable, Copyable, Deinitable):
    """Object metadata — returned by `head`, and one per `list` entry.

    Field layout:
      var location: String       — the object's path within the bucket
      var size: Int64            — object size in bytes
      var etag: String           — opaque server-assigned ETag (may be empty)
      var last_modified_unix_ms: Int64
                                 — last-modified time as Unix epoch
                                   milliseconds (-1 if unknown / server didn't
                                   provide). Avoids carrying a heavy
                                   time type at this layer.
      var version: String        — object version id (S3 versioning / GCS
                                   generation / Azure version); empty if
                                   server did not return one.
    """

    var location: String
    var size: Int64
    var etag: String
    var last_modified_unix_ms: Int64
    var version: String


# -----------------------------------------------------------------------------
# GetRange — Bounded / Offset / Suffix tagged enum
# -----------------------------------------------------------------------------
#
# Matches Rust `object_store::GetRange`:
#   Bounded(start, end)    — closed-open [start, end) byte range
#   Offset(start)          — [start, ..) from start to end-of-object
#   Suffix(n)              — last n bytes of the object
#                            (load-bearing: Parquet/ORC footer read
#                            without a prior HEAD round-trip)
#
# Encoded as a tag + two Int64 fields. The two fields are used as:
#   Bounded -> v0 = start, v1 = end
#   Offset  -> v0 = start, v1 = 0  (unused)
#   Suffix  -> v0 = n,     v1 = 0  (unused)
# -----------------------------------------------------------------------------

comptime GET_RANGE_BOUNDED = UInt8(1)
comptime GET_RANGE_OFFSET = UInt8(2)
comptime GET_RANGE_SUFFIX = UInt8(3)


@fieldwise_init
struct GetRange(Copyable, ImplicitlyCopyable, Movable, Deinitable):
    """A byte-range request. POD (24 bytes), value-passable.

    Use the static factories `bounded`, `offset`, `suffix` — do NOT
    construct via the fieldwise init at callsites.
    """

    var tag: UInt8
    var v0: Int64
    var v1: Int64

    @staticmethod
    @always_inline
    def bounded(start: Int64, end: Int64) raises -> GetRange:
        """[start, end) — closed-open. start must be <= end and both >= 0."""
        if start < 0 or end < 0:
            raise Error("GetRange.bounded: negative start/end")
        if start > end:
            raise Error("GetRange.bounded: start > end")
        return GetRange(GET_RANGE_BOUNDED, start, end)

    @staticmethod
    @always_inline
    def offset(start: Int64) raises -> GetRange:
        """[start, ..) — from start to end-of-object. start must be >= 0."""
        if start < 0:
            raise Error("GetRange.offset: negative start")
        return GetRange(GET_RANGE_OFFSET, start, Int64(0))

    @staticmethod
    @always_inline
    def suffix(n: Int64) raises -> GetRange:
        """Last `n` bytes of the object. n must be > 0 (zero suffix is a
        no-op — caller should not issue such a request)."""
        if n <= 0:
            raise Error("GetRange.suffix: n must be > 0")
        return GetRange(GET_RANGE_SUFFIX, n, Int64(0))

    @always_inline
    def is_bounded(self) -> Bool:
        return self.tag == GET_RANGE_BOUNDED

    @always_inline
    def is_offset(self) -> Bool:
        return self.tag == GET_RANGE_OFFSET

    @always_inline
    def is_suffix(self) -> Bool:
        return self.tag == GET_RANGE_SUFFIX

    @always_inline
    def bounded_start(self) -> Int64:
        return self.v0

    @always_inline
    def bounded_end(self) -> Int64:
        return self.v1

    @always_inline
    def offset_start(self) -> Int64:
        return self.v0

    @always_inline
    def suffix_n(self) -> Int64:
        return self.v0


# -----------------------------------------------------------------------------
# RangeSet — input to coalesced get_ranges
# -----------------------------------------------------------------------------


@fieldwise_init
struct RangeSet(Movable, Deinitable):
    """A list of byte ranges + their corresponding dst-offsets.

    Used as input to `ObjectStore.get_ranges`. The dst-offset for
    range `i` is where the bytes for range `i` land in the caller's `dst`
    buffer (scatter-write semantics).

    The `coalesce.mojo` planner consumes this to merge nearby ranges
    into a minimal request batch.

    Invariants:
      * len(ranges) == len(dst_offsets)
      * dst_offsets[i] >= 0
    """

    var ranges: List[GetRange]
    var dst_offsets: List[Int]

    @staticmethod
    def empty() -> RangeSet:
        return RangeSet(List[GetRange](), List[Int]())

    def append(mut self, range: GetRange, dst_offset: Int) raises:
        """Append one (range, dst_offset) pair. dst_offset must be >= 0."""
        if dst_offset < 0:
            raise Error("RangeSet.append: dst_offset < 0")
        self.ranges.append(range)
        self.dst_offsets.append(dst_offset)

    @always_inline
    def num_ranges(self) -> Int:
        return len(self.ranges)


# -----------------------------------------------------------------------------
# RangeFetchResult — outcome of a concurrent get_ranges fan-out
# -----------------------------------------------------------------------------
#
# The small typed POD returned by
# `RangeFetchStore.get_ranges`. Order-preserving: `statuses[i]` and
# `fetched_bytes[i]` correspond to RANGE i in the INPUT `RangeSet`,
# regardless of the order in which the network completed the fan-out.
#
# This is DELIBERATELY narrower than the HTTP layer's `RangeFanoutResult`
# (`objectstore_http.mojo`), which carries a
# `Slab[ClientResponse[...]]` — fine inside komira_http, but the
# ObjectStore public surface must not leak a ClientResponse / reactor /
# handle. Here the bytes are already scattered into the caller's `dst`;
# the result just reports per-range status + byte counts.
#
# Encapsulation: pure POD — two parallel Lists of trivial scalars + a
# rollup. ZERO UnsafePointer, ZERO origin, ZERO reactor/handle. Crosses
# the trait boundary by value.
# -----------------------------------------------------------------------------

comptime RANGE_FETCH_STATUS_OK = Int(0)
comptime RANGE_FETCH_STATUS_ERROR = Int(1)


@fieldwise_init
struct RangeFetchResult(Movable, Deinitable):
    """Per-range outcome of a `RangeFetchStore.get_ranges` fan-out.

    The bytes themselves were already scatter-written into the caller's
    `dst` buffer (at `RangeSet.dst_offsets[i]` for range `i`). This struct
    reports, for each input range `i`:

      * `statuses[i]`      — RANGE_FETCH_STATUS_OK (0) on success, or
                             RANGE_FETCH_STATUS_ERROR (1) if that range's
                             fetch failed (the current conformers raise on the first
                             fetch error, so on a returned result every
                             status is OK; the field is the seam the later
                             partial-failure mode fills in).
      * `fetched_bytes[i]` — the number of bytes materialized for range `i`.

    Plus a `total_fetched_bytes` rollup.

    Order-preservation contract: index `i` is the INPUT-order index
    (parallel to `RangeSet.ranges` / `RangeSet.dst_offsets`), NOT the
    network completion order. The drain executor restores order via the
    coalescer's `OriginalSlice.orig_index` scatter table.

    Field layout:
      var statuses: List[Int]            — per-range status, input-order
      var fetched_bytes: List[Int64]     — per-range byte count, input-order
      var total_fetched_bytes: Int64     — sum of fetched_bytes
    """

    var statuses: List[Int]
    var fetched_bytes: List[Int64]
    var total_fetched_bytes: Int64

    @staticmethod
    def with_capacity(n: Int) -> RangeFetchResult:
        """Build a result pre-sized for `n` ranges, all statuses OK and
        all byte counts 0 — the drain executor fills entries by
        `orig_index` as it scatters each completion."""
        var statuses = List[Int](capacity=n)
        var fetched = List[Int64](capacity=n)
        var i = 0
        while i < n:
            statuses.append(RANGE_FETCH_STATUS_OK)
            fetched.append(Int64(0))
            i = i + 1
        return RangeFetchResult(statuses^, fetched^, Int64(0))

    @always_inline
    def num_ranges(self) -> Int:
        return len(self.statuses)

    @always_inline
    def status_at(self, i: Int) -> Int:
        return self.statuses[i]

    @always_inline
    def fetched_bytes_at(self, i: Int) -> Int64:
        return self.fetched_bytes[i]

    def record(mut self, orig_index: Int, status: Int, nbytes: Int64):
        """Record range `orig_index`'s outcome (input-order indexed)."""
        self.statuses[orig_index] = status
        self.fetched_bytes[orig_index] = nbytes


# -----------------------------------------------------------------------------
# GetOptions — conditional GET predicates
# -----------------------------------------------------------------------------


@fieldwise_init
struct GetOptions(Movable, Deinitable):
    """Conditional-GET options for `ObjectStore.get_opts`.

    Field layout (all default to "not set"; empty string / -1 for "absent"):
      var if_match: String                — If-Match: <etag>
      var if_none_match: String           — If-None-Match: <etag>
      var if_modified_since_unix_ms: Int64
                                          — If-Modified-Since (epoch ms; -1=unset)
      var if_unmodified_since_unix_ms: Int64
                                          — If-Unmodified-Since (epoch ms; -1=unset)
      var version: String                 — explicit version-id (S3) / generation
                                            (GCS) / version (Azure); empty=latest
      var range: Optional[GetRange]       — optional byte range
    """

    var if_match: String
    var if_none_match: String
    var if_modified_since_unix_ms: Int64
    var if_unmodified_since_unix_ms: Int64
    var version: String
    var range: Optional[GetRange]

    @staticmethod
    def default() -> GetOptions:
        return GetOptions(
            String(""),
            String(""),
            Int64(-1),
            Int64(-1),
            String(""),
            Optional[GetRange](),
        )


# -----------------------------------------------------------------------------
# WritePrecondition — conditional-write predicate (CAS / create-if-absent)
# -----------------------------------------------------------------------------
#
# The precondition handle for
# `ConditionalWriteStore.conditional_put` / `compare_and_swap`. Pure-S3
# coordination primitive: every write carries one of these to drive the
# server-side compare-and-swap so concurrent writers race safely (exactly
# one wins; the loser sees `StoreError.precondition`).
#
# Encoded as a tag + an etag String. The etag is used as:
#   NONE              -> etag unused; unconditional write (no precondition)
#   IF_NONE_MATCH_STAR-> etag unused; "If-None-Match: *" create-if-absent
#   IF_MATCH          -> etag = the expected current etag (CAS update)
#   IF_NONE_MATCH     -> etag = an exact etag (MinIO create-if-absent
#                        variant — MinIO historically did not honor the
#                        `*` wildcard; the conformer rewrites IF_NONE_MATCH_STAR
#                        into this form when the MinIO branch is selected)
#
# Keep this a value-passable POD so it crosses the trait boundary with no
# pointer / origin involvement.
# -----------------------------------------------------------------------------

comptime WRITE_PRECOND_NONE = UInt8(0)
comptime WRITE_PRECOND_IF_NONE_MATCH_STAR = UInt8(1)
comptime WRITE_PRECOND_IF_MATCH = UInt8(2)
comptime WRITE_PRECOND_IF_NONE_MATCH = UInt8(3)


@fieldwise_init
struct WritePrecondition(
    Copyable, ImplicitlyCopyable, Movable, Deinitable
):
    """A conditional-write predicate for `conditional_put` / `compare_and_swap`.

    Construct via the static factories — do NOT use the fieldwise init at
    callsites:
      * `WritePrecondition.none()`              — unconditional write.
      * `WritePrecondition.if_none_match_star()`— create-if-absent
                                                  (`If-None-Match: *`).
      * `WritePrecondition.if_match(etag)`      — CAS update (`If-Match: <etag>`).
      * `WritePrecondition.if_none_match(etag)` — exact-etag create variant
                                                  (`If-None-Match: <etag>`);
                                                  the MinIO no-`*` form.

    Field layout:
      var tag: UInt8       — one of the WRITE_PRECOND_* arms
      var etag: String     — the expected etag (IF_MATCH / IF_NONE_MATCH);
                             empty for NONE / IF_NONE_MATCH_STAR
    """

    var tag: UInt8
    var etag: String

    @staticmethod
    def none() -> WritePrecondition:
        return WritePrecondition(WRITE_PRECOND_NONE, String(""))

    @staticmethod
    def if_none_match_star() -> WritePrecondition:
        """Create-if-absent: write only if the object does NOT already
        exist. Maps to `If-None-Match: *` on the S3 PUT."""
        return WritePrecondition(WRITE_PRECOND_IF_NONE_MATCH_STAR, String(""))

    @staticmethod
    def if_match(etag: String) -> WritePrecondition:
        """Compare-and-swap: write only if the object's current etag
        equals `etag`. Maps to `If-Match: <etag>` on the S3 PUT. On a
        stale etag the server returns 412 -> StoreError.precondition."""
        return WritePrecondition(WRITE_PRECOND_IF_MATCH, String(etag))

    @staticmethod
    def if_none_match(etag: String) -> WritePrecondition:
        """Exact-etag create variant: write only if no object with the
        given etag exists. Maps to `If-None-Match: <etag>`. This is the
        MinIO create-if-absent form (MinIO does not honor the `*`
        wildcard on some releases)."""
        return WritePrecondition(WRITE_PRECOND_IF_NONE_MATCH, String(etag))

    @always_inline
    def is_none(self) -> Bool:
        return self.tag == WRITE_PRECOND_NONE

    @always_inline
    def is_if_none_match_star(self) -> Bool:
        return self.tag == WRITE_PRECOND_IF_NONE_MATCH_STAR

    @always_inline
    def is_if_match(self) -> Bool:
        return self.tag == WRITE_PRECOND_IF_MATCH

    @always_inline
    def is_if_none_match(self) -> Bool:
        return self.tag == WRITE_PRECOND_IF_NONE_MATCH

    @always_inline
    def is_create(self) -> Bool:
        """True iff this precondition is a create-if-absent form (either
        the `*` wildcard or the exact-etag MinIO variant)."""
        return (
            self.tag == WRITE_PRECOND_IF_NONE_MATCH_STAR
            or self.tag == WRITE_PRECOND_IF_NONE_MATCH
        )


# -----------------------------------------------------------------------------
# ListResult — list_with_delimiter result
# -----------------------------------------------------------------------------


@fieldwise_init
struct ListResult(Movable, Deinitable):
    """Hierarchical listing result — `list_with_delimiter` output.

    Field layout:
      var objects: List[ObjectMeta]     — objects directly under the prefix
      var common_prefixes: List[String] — subdirectory-style prefixes
                                          (S3 `CommonPrefixes`)
    """

    var objects: List[ObjectMeta]
    var common_prefixes: List[String]

    @staticmethod
    def empty() -> ListResult:
        return ListResult(List[ObjectMeta](), List[String]())


# -----------------------------------------------------------------------------
# CoalescePolicy — get_ranges tuning knobs
# -----------------------------------------------------------------------------


@fieldwise_init
struct CoalescePolicy(
    Copyable, ImplicitlyCopyable, Movable, Deinitable
):
    """Tuning knobs for the range-coalescing planner. POD.

    Field layout:
      var max_gap_bytes: Int64       — merge two ranges separated by <=
                                       this many bytes into one larger
                                       request (over-reads the gap; cheap
                                       when the gap is small).
      var max_request_bytes: Int64   — never produce a coalesced request
                                       larger than this.
      var max_concurrency: Int       — max parallel HTTP requests in a
                                       single `get_ranges` fan-out.
    """

    var max_gap_bytes: Int64
    var max_request_bytes: Int64
    var max_concurrency: Int

    @staticmethod
    def default() -> CoalescePolicy:
        # Defaults aligned with Rust object_store + DataFusion empirics
        # Not load-bearing; conformers may override.
        return CoalescePolicy(
            Int64(1 * 1024 * 1024),     # 1 MiB gap
            Int64(8 * 1024 * 1024),     # 8 MiB max single request
            8,                          # 8-way concurrency
        )


# -----------------------------------------------------------------------------
# StoreError — typed error taxonomy
# -----------------------------------------------------------------------------
#
# Construction: backends raise `Error(<message-with-tag>)` (Mojo's exception
# model has no native tagged-union exceptions). The CALLER pattern
# is to construct a `StoreError` POD that carries the typed taxonomy + a
# human-readable message for downstream branching (retry / propagate /
# user-facing diagnostic). The retry classifier maps
# HTTP client `HttpError` arms into these.
#
# Taxonomy arms:
#   NotFound          — 404 / object missing
#   PermissionDenied  — 401 / 403 / TLS verify failure
#   Throttled         — 429 / 503 SlowDown / GCS exponential-quota
#   Precondition      — 412 / If-Match conflict
#   Transport         — connection reset, retryable transport-layer error
#   Malformed         — malformed URI / malformed response body
# -----------------------------------------------------------------------------

comptime STORE_ERR_NOT_FOUND = UInt8(1)
comptime STORE_ERR_PERMISSION_DENIED = UInt8(2)
comptime STORE_ERR_THROTTLED = UInt8(3)
comptime STORE_ERR_PRECONDITION = UInt8(4)
comptime STORE_ERR_TRANSPORT = UInt8(5)
comptime STORE_ERR_MALFORMED = UInt8(6)


@fieldwise_init
struct StoreError(Movable, Copyable, Deinitable):
    """Typed object-store error.

    Field layout:
      var kind: UInt8           — one of the STORE_ERR_* arms
      var message: String       — human-readable detail
      var http_status: Int      — original HTTP status code if available
                                   (0 if not HTTP-sourced)
    """

    var kind: UInt8
    var message: String
    var http_status: Int

    @always_inline
    def is_not_found(self) -> Bool:
        return self.kind == STORE_ERR_NOT_FOUND

    @always_inline
    def is_permission_denied(self) -> Bool:
        return self.kind == STORE_ERR_PERMISSION_DENIED

    @always_inline
    def is_throttled(self) -> Bool:
        return self.kind == STORE_ERR_THROTTLED

    @always_inline
    def is_precondition(self) -> Bool:
        return self.kind == STORE_ERR_PRECONDITION

    @always_inline
    def is_transport(self) -> Bool:
        return self.kind == STORE_ERR_TRANSPORT

    @always_inline
    def is_malformed(self) -> Bool:
        return self.kind == STORE_ERR_MALFORMED

    @always_inline
    def is_retryable(self) -> Bool:
        """True iff this error class is safe to retry.

        Per : ONLY transient classes retry — never auth (403) or
        not-found (404) or precondition (412).
        """
        return self.kind == STORE_ERR_THROTTLED or self.kind == STORE_ERR_TRANSPORT

    @staticmethod
    @always_inline
    def not_found(var message: String) -> StoreError:
        return StoreError(STORE_ERR_NOT_FOUND, message^, 404)

    @staticmethod
    @always_inline
    def permission_denied(var message: String, http_status: Int = 403) -> StoreError:
        return StoreError(STORE_ERR_PERMISSION_DENIED, message^, http_status)

    @staticmethod
    @always_inline
    def throttled(var message: String, http_status: Int = 429) -> StoreError:
        return StoreError(STORE_ERR_THROTTLED, message^, http_status)

    @staticmethod
    @always_inline
    def precondition(var message: String) -> StoreError:
        return StoreError(STORE_ERR_PRECONDITION, message^, 412)

    @staticmethod
    @always_inline
    def transport(var message: String) -> StoreError:
        return StoreError(STORE_ERR_TRANSPORT, message^, 0)

    @staticmethod
    @always_inline
    def malformed(var message: String) -> StoreError:
        return StoreError(STORE_ERR_MALFORMED, message^, 0)
