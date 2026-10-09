# =============================================================================
# komira_objectstore/sublineage_shard_keys.mojo
#   The NEUTRAL, low-level shard-id + sub-lineage PATH KERNEL.
# =============================================================================
#
# WHAT THIS IS (and what it deliberately is NOT)
# ---------------------------------------------------------------------------
# These are the PURE String/LIST shard-id + sub-lineage path builders. They are
# substrate-agnostic — they operate on plain `ConditionalWriteStore`, `Path`,
# `ListResult`, `String`, and `List` only. NOTHING here is search-specific;
# nothing here decodes a search `SplitSummary` or a columnar-adapter `ColumnarFileEntry`.
# They live low in the dependency graph, in `komira_objectstore` (which both
# `komira_search_s3` AND the pgsql/table-store path depend on), so the SAME helpers
# serve:
#   * the search writer / compactor (via a re-export in
#     `komira_search_s3.metastore`);
#   * the broker drain/flush log-index writers (also via that re-export);
#   * the serverless Postgres secondary-index sharding read/write path (which
#     imports ONLY this neutral module, NEVER `komira_search_s3`).
#
# DEPENDENCY DIRECTION (cycle-free):
#   komira_objectstore's deps never reach back into komira_search_s3 /
#   komira_pgsql / komira_table_store and its adapters. So the pgsql/table-store path imports this
#   module DIRECTLY without pulling in the SEARCH packages. The runtime
#   `ShardedLineage` kernel lives in `sharded_lineage.mojo` and builds on these
#   helpers.
#
# ENCAPSULATION / SAFETY
# ---------------------------------------------------------------------------
#   * ZERO UnsafePointer in ANY signature (public or private).
#   * ZERO wildcard origins (MutAnyOrigin / ImmutAnyOrigin / MutExternalOrigin).
#   * ZERO unsafe_from_address, ZERO take_pointee.
#   * Every value is a plain owned String / List[String] / List[UInt8] / Int /
#     Int64 / Bool — POD-of-scalars + owned collections, no byte-slab, no Movable
# struct stored in a byte container. heap-reuse is structurally N/A here.
#   * `[Storage: ConditionalWriteStore]` is the comptime backend selector;
#     `Storage` NEVER crosses a boundary as a raw handle — it is taken `read`
#     and only its `list_with_delimiter` verb is called.
# =============================================================================

from std.ffi import external_call

from komira_objectstore.path import Path
from komira_objectstore.store import ConditionalWriteStore
from komira_objectstore.types import ListResult


# =============================================================================
# reserved-lineage constants + the path segment
# =============================================================================

comptime _LINEAGE_SEGMENT: String = "_lineage"
"""The path segment inserted between `<index>/meta` and `<shard_id>` for a
sharded sub-lineage. The read-side enumeration LISTs `<index>/meta/_lineage/`."""

comptime _LINEAGE_BASE_SHARD: String = "_base"
"""The reserved shard_id of the compactor's fold-target sub-lineage. The read
path treats it as one more shard; it is written ONLY by the compactor
(single-writer-per-index). Public alias `LINEAGE_BASE_SHARD` for the compactor."""

comptime LINEAGE_BASE_SHARD: String = _LINEAGE_BASE_SHARD
"""The public name of the compactor-reserved fold-target sub-lineage shard_id
(`_base`). The compactor publishes every merged split into
`shard_manifest_prefix(<index>/meta, LINEAGE_BASE_SHARD)` — the sole writer of
`_base`, contention-free (its single-writer-per-index contract). A writer NEVER
mints this id (`is_reserved_shard_id` / `make_shard_id` enforce)."""


# =============================================================================
# not-found classifier (self-contained — the neutral module must not
# reach back UP into komira_search_s3 for its private `_is_not_found`; this is
# a byte-identical local copy of that classifier, used only by
# `_discover_shard_ids` to tolerate an empty / absent enum prefix on backends
# that surface it as not-found).
# =============================================================================


@always_inline
def _shard_keys_is_not_found(msg: String) -> Bool:
    return (
        msg.find("not_found") >= 0
        or msg.find("NotFound") >= 0
        or msg.find("404") >= 0
        or msg.find("NoSuchKey") >= 0
    )


@always_inline
def _str_in(xs: List[String], v: String) -> Bool:
    for i in range(len(xs)):
        if xs[i] == v:
            return True
    return False


# =============================================================================
# the process nonce + shard-id mint / reserved guard
# =============================================================================


@always_inline
def _proc_nonce() -> Int64:
    """The current process id (POSIX `getpid`, a vsyscall — no alloc). Folded
    into every writer's `shard_id` so two writer processes on the same node
    (same `node_id`) never share a sub-lineage `_HEAD` slot."""
    return Int64(external_call["getpid", Int32]())


@always_inline
def is_reserved_shard_id(shard_id: String) -> Bool:
    """True iff `shard_id` is the COMPACTOR-RESERVED fold-target lineage `_base`
    (`_LINEAGE_BASE_SHARD`). A WRITER must NEVER mint this id — `_base` is
    written ONLY by the compactor (single-writer-per-index), so a writer landing
    in `_base` would re-introduce the cross-writer `_HEAD` contention the
    sharding eliminates AND race the compactor's fold publishes. `make_shard_id`
    enforces the invariant (a writer's `<node>-<pid>-<worker>` shape can never
    structurally equal the bare `_base` literal, but the guard is
    belt-and-suspenders per the design's invariant assert)."""
    return shard_id == _LINEAGE_BASE_SHARD


def make_shard_id(
    node_id: String, worker_idx: Int, role: String = String("")
) raises -> String:
    """Build a writer's collision-free `shard_id`
    = "<node_id>-<pid>-<role><worker_idx>". The `pid` is resolved via
    `_proc_nonce()` (getpid). Computed ONCE per dispatcher at construction
    (stable for the dispatcher's lifetime), so all of a writer's splits accrete
    into ONE shard lineage (fewer, larger shards than per-request). A node_id of
    "" still yields a per-(pid,role,worker) distinct id; the caller resolves a
    sensible node_id from session config.

    WRITER-ROLE AXIS. A drain/flush writer's ring-index domain `[0, num_workers)`
    and a search-server pthread index domain are DISJOINT counting domains.
    Without a role discriminant, a drain writer and a search server co-located in
    ONE process (same node_id + pid) both mint `<node>-<pid>-0`, `…-1`, … and
    COLLIDE on the same sub-lineage `_HEAD` — re-introducing the 412-storm AND
    interleaving two distinct schemas into one lineage. The `role` prefix on the
    worker segment (e.g. `"drain"` vs `"srv"`) keeps the two writer roles in
    disjoint sub-lineages. `role=""` (the default) preserves the EXACT legacy id
    shape `<node>-<pid>-<worker>` for existing search-server callers —
    byte-identical, no migration.

    The read enumeration (`_discover_shard_ids`) flat-scans `<index>/meta/_lineage/`
    and extracts the segment between `_lineage/` and the next `/`, so a new
    `<role><worker>` id shape folds in transparently (ZERO read-path change).

    RESERVED-NAME INVARIANT: the produced shard_id can NEVER equal the
    compactor-reserved `_base` lineage — the `<node>-<pid>-<role><worker>` shape
    always carries the `-<pid>-` infix, so it is structurally distinct from the
    bare `_base` literal. The fail-loud assert below is defense-in-depth: if a
    future grain change ever made a writer able to mint `_base`, this raises
    rather than silently corrupting the fold target."""
    var sid = (
        node_id
        + "-"
        + String(_proc_nonce())
        + "-"
        + role
        + String(worker_idx)
    )
    if is_reserved_shard_id(sid):
        raise Error(  # cov: unreachable a minted id holds '-<pid>-', so it never equals _base
            "make_shard_id: produced the COMPACTOR-RESERVED shard_id '"  # cov: unreachable see the line above
            + _LINEAGE_BASE_SHARD  # cov: unreachable see the line above
            + "' (node_id='"  # cov: unreachable see the line above
            + node_id  # cov: unreachable see the line above
            + "', worker_idx="  # cov: unreachable see the line above
            + String(worker_idx)  # cov: unreachable see the line above
            + ") — a writer must never write the _base fold-target lineage"  # cov: unreachable see the line above
        )
    return sid^


# =============================================================================
# sub-lineage path builders
# =============================================================================


def shard_manifest_prefix(index_meta_prefix: String, shard_id: String) -> String:
    """The CAS-manifest lineage prefix for one writer shard:
    `<index_meta_prefix>/_lineage/<shard_id>`. The caller passes
    `<key_prefix>/<index>/meta` as `index_meta_prefix` (the EXISTING
    `_manifest_prefix` output) and the dispatcher's stable `shard_id`."""
    return index_meta_prefix + "/" + _LINEAGE_SEGMENT + "/" + shard_id


def _lineage_enum_prefix(index_meta_prefix: String) -> String:
    """The LIST prefix under which all of an index's sub-lineages live:
    `<index_meta_prefix>/_lineage/`. A LIST of this prefix (flat-key scan, see
    `_discover_shard_ids`) yields one distinct `<shard_id>` per writer/base
    sub-lineage."""
    return index_meta_prefix + "/" + _LINEAGE_SEGMENT + "/"


# =============================================================================
# shard discovery (backend-agnostic flat LIST)
# =============================================================================


def _discover_shard_ids[
    Storage: ConditionalWriteStore
](storage: Storage, index_meta_prefix: String) raises -> List[String]:
    """Enumerate the DISTINCT shard_ids present under
    `<index_meta_prefix>/_lineage/` by a flat-key LIST scan.

    BACKEND-AGNOSTIC ENUMERATION (the load-bearing detail): the in-memory test
    backends IGNORE the delimiter and return ALL matching keys flat in
    `objects` with EMPTY `common_prefixes`, while S3 honors the delimiter and
    returns each `<shard_id>/` as a `common_prefix`. To work IDENTICALLY on both
    (and to not depend on a delimiter being honored), we LIST the enum prefix and
    derive each shard_id from the object keys: the segment between
    `_lineage/` and the NEXT `/`. We ALSO fold in any `common_prefixes` the
    backend returned (S3), de-duplicating — so the function is correct whether
    the backend folds or not.

    Returns the distinct shard_ids (writer shards + the reserved `_base` if
    present), in first-seen order. An index with NO sub-lineages (a legacy
    single-lineage index, or an index with no publishes) returns empty — the
    caller ALSO replays the legacy `<index>/meta` lineage for back-compat."""
    var enum_prefix = _lineage_enum_prefix(index_meta_prefix)
    var listed: ListResult
    try:
        listed = storage.list_with_delimiter(Path.parse(enum_prefix))
    except e:
        # An empty bucket / absent prefix may surface as not-found on some
        # backends — treat as "no shards" (the legacy replay still serves).
        if _shard_keys_is_not_found(String(e)):
            return List[String]()
        raise e^
    var out = List[String]()
    var plen = enum_prefix.byte_length()
    # (a) Derive shard_ids from flat object keys (the in-memory path + a
    #     belt-and-suspenders for any S3 page that returned objects too).
    for i in range(len(listed.objects)):
        var key = listed.objects[i].location
        var sid = _shard_id_from_key(key, enum_prefix, plen)
        if sid.byte_length() > 0 and not _str_in(out, sid):
            out.append(sid)
    # (b) Fold in any backend-returned common_prefixes (S3 delimiter path). Each
    #     is `<enum_prefix><shard_id>/`; strip the prefix + the trailing '/'.
    for j in range(len(listed.common_prefixes)):
        var cp = listed.common_prefixes[j]
        var sid = _shard_id_from_common_prefix(cp, enum_prefix, plen)
        if sid.byte_length() > 0 and not _str_in(out, sid):
            out.append(sid)
    return out^


@always_inline
def _shard_id_from_key(key: String, enum_prefix: String, plen: Int) -> String:
    """Extract the `<shard_id>` from a flat object key
    `<enum_prefix><shard_id>/manifest/...` (or `.../_HEAD`). The shard_id is the
    segment between the enum prefix and the NEXT '/'. Returns "" if `key` does
    not start with `enum_prefix` or has no following '/'."""
    var kb = key.as_bytes()
    if len(kb) <= plen:
        return String("")
    # Confirm the key starts with the enum prefix (it should — it was LISTed
    # under it — but be defensive).
    var pb = enum_prefix.as_bytes()
    for i in range(plen):
        if kb[i] != pb[i]:
            return String("")
    # Scan from plen to the next '/'.
    var seg = List[UInt8]()
    var i = plen
    while i < len(kb):
        if kb[i] == UInt8(47):  # '/'
            break
        seg.append(kb[i])
        i += 1
    if len(seg) == 0:
        return String("")
    return String(StringSlice(unsafe_from_utf8=Span(seg)))


@always_inline
def _shard_id_from_common_prefix(
    cp: String, enum_prefix: String, plen: Int
) -> String:
    """Extract the `<shard_id>` from an S3 common_prefix `<enum_prefix><shard_id>/`
    — strip the enum prefix and a single trailing '/'. Returns "" on a
    non-matching prefix."""
    var cb = cp.as_bytes()
    if len(cb) <= plen:
        return String("")
    var pb = enum_prefix.as_bytes()
    for i in range(plen):
        if cb[i] != pb[i]:
            return String("")
    var seg = List[UInt8]()
    var i = plen
    while i < len(cb):
        if cb[i] == UInt8(47):  # '/'
            break
        seg.append(cb[i])
        i += 1
    if len(seg) == 0:
        return String("")
    return String(StringSlice(unsafe_from_utf8=Span(seg)))
