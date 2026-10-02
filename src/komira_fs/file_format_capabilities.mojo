# =============================================================================
# komira_fs.file_format_capabilities — Capability hook wrapper types
#
# =============================================================================
#
# v0.1 thin POD handles for capability-hook payloads carried on
# `SourceCapabilityConfig` / `DecodeOptions`. Used by the parquet source
# body's inline capability-dispatch branches and by the bytes-decode
# entry point (`decode_row_group_with_options`).
#
# Originally this file also declared 7 capability sub-traits
# (HasPredicatePushdown, HasDynamicJoinFilter, HasBloomFilter,
# HasDictPreservation, HasLateMaterialization, HasBypassColumns,
# HasCountOnly) that were preparatory surface for a v0.2+ cross-format
# dispatch shape. audit found that surface was
# unreachable in v0.1 (ZERO downstream consumers; the 7 raising bodies
# on `ParquetFormat` couldn't delegate without changing the trait
# signatures). ratified deletion to pre-empt
# v0.2 from being constrained to the v0.1 placeholder shape — v0.2
# will design the actual cross-format dispatch shape from scratch when
# capabilities go live.
#
# v0.1 actual capability dispatch lives in the source body
# (`ColumnarMultiConsumerSource.next_morsel` reads `caps.count_only` /
# `caps.pushed_predicate` / `caps.decode_filter_stages` /
# `caps.dynamic_filter_key_name` inline). The wrapper types below are
# the typed payloads carried on those caps fields.
#
# Pointer discipline:
#   * ZERO UnsafePointer in any public method signature.
#   * Wrapper handles are Movable + Deinitable POD.
# =============================================================================


# =============================================================================
# Capability hook wrapper types (v0.1 thin handles)
# =============================================================================
#
# These live in this file as the canonical home for capability-hook
# payload types. Each grows independently as engine integration wires
# the planner-side payloads.
# =============================================================================


@fieldwise_init
struct PhysicalPredicate(Movable, Copyable, Deinitable):
    """`v0.1` thin handle for a row-filter predicate.

    `_predicate_id: Int64` is an opaque handle into the planner's ExprPool
    (resolved at engine-side dispatch). v0.2+ lifts this to a typed
    expression handle. v0.1 ships the handle so trait elaboration
    exercises the surface; the actual evaluation is gated on the
    engine integration.

    Pointer discipline: POD; no heap; Deinitable.
    """

    var _predicate_id: Int64
    var _has_payload: Bool


@fieldwise_init
struct DynamicJoinFilterRef(Movable, Copyable, Deinitable):
    """`v0.1` thin handle for a dynamic join-filter summary.

    `_filter_id: Int64` is an opaque handle into the engine's
    DynamicJoinFilter registry. The actual filter (a hash-table summary
    of build-side keys) is owned by the join build sink; the source
    holds only this handle and probes via the engine's lookup at
    decode time.

    Pointer discipline: POD; no heap; Deinitable.
    """

    var _filter_id: Int64
    var _key_column_idx: Int32


@fieldwise_init
struct BloomFilterRef(Movable, Copyable, Deinitable):
    """`v0.1` thin handle for a static bloom filter (per-RG / per-page
    skip filter).

    `_filter_id: Int64` is an opaque handle into the format's bloom
    registry (Parquet: `BloomFilter` per column chunk). The source
    consults the registry at decode time; a hit allows skipping the
    page; a miss falls through to full decode + post-filter.

    Pointer discipline: POD; no heap; Deinitable.
    """

    var _filter_id: Int64
    var _column_idx: Int32


@fieldwise_init
struct DictSinkRef(Movable, Copyable, Deinitable):
    """`v0.1` thin handle for a dictionary-publish sink.

    When dict-preservation is enabled on the source, the format leaves
    dict-encoded columns dict-encoded in the output batch and publishes
    the dictionary to this sink. Downstream operators that consume
    dict-encoded morsels (group-by, filter) save the decode + scatter
    cost.

    `_sink_id: Int64` is an opaque handle into the engine's
    DictBypassRegistry. v0.1 ships the handle so the dispatch surface
    elaborates; engine-side dict union lands in v0.2+.

    Pointer discipline: POD; no heap; Deinitable.
    """

    var _sink_id: Int64
