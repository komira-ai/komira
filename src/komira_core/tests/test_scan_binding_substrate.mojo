# =============================================================================
# Scan-binding substrate tests — ScanParams / PushdownGate /
# schema_identity_hash / ScanKindRegistry / ScanResolver.
# =============================================================================
#
# These pin the properties scan identity depends on, not merely the code that
# exists. The most likely way scan identity goes wrong quietly is a fingerprint
# whose VALUE drifts: nothing fails — plans just recompile forever and
# cross-run caches miss. So the folds are pinned here by property
# (order-independence, discrimination, aliasing), and by GOLDEN VALUE in the
# per-kind arm tests (`test_scan_binding_arrow_arm.mojo` and siblings).
# =============================================================================

from std.testing import (
    TestSuite,
    assert_equal,
    assert_true,
    assert_false,
    assert_not_equal,
    assert_raises,
)

from komira_core.arrow import (
    ArrowType,
    Field,
    Schema,
    SchemaBuilder,
)
from komira_core.arrow.schema_identity import schema_identity_hash
from komira_core.plan.expr import (
    Expr,
    ScalarValue,
    BIN_EQ,
    BIN_LT,
    BIN_LE,
    BIN_GE,
    BIN_AND,
    BIN_OR,
)
from komira_core.plan.logical_plan import (
    LogicalPlan,
    SOURCE_CSV,
    SOURCE_IN_MEMORY,
    SOURCE_NDJSON,
    SOURCE_ORC,
    SOURCE_PARQUET,
    SOURCE_KIND_UNSET,
    derive_source_layout,
)
from komira_core.plan.logical_plan_variants import (
    SOURCE_KIND_COLUMNAR,
    SOURCE_KIND_ROW,
)
from komira_core.source.pushdown_gate import (
    PushdownGate,
    gate_allows,
    arrow_type_has_column_stats,
    GATE_REJECT_ALL,
    GATE_ACCEPT_ALL,
    GATE_SHAPED,
)
from komira_core.source.scan_binding import (
    ScanBinding,
    scan_kind_id,
    SCAN_HANDLE_UNBOUND,
    SCAN_EPOCH_NONE,
    SCAN_ORIENTATION_COLUMNAR,
    SCAN_ORIENTATION_ROW,
    SNAPSHOT_NONE,
    SNAPSHOT_PINNED,
    SNAPSHOT_LIVE,
)
from komira_core.source.scan_kind_registry import (
    ScanKindDescriptor,
    ScanKindRegistry,
)
from komira_core.source.scan_params import (
    ParamValue,
    ScanParams,
    PARAM_BOOL,
    PARAM_I64,
    PARAM_U64,
)
from komira_core.source.scan_resolver import (
    ScanResolver,
    UnboundScanResolver,
    check_binding,
    resolve_for_execution,
)


# =============================================================================
# Helpers
# =============================================================================


def _schema_ab() -> Schema:
    var sb = SchemaBuilder()
    sb.add_field(Field("a", ArrowType.INT64, nullable=False))
    sb.add_field(Field("b", ArrowType.STRING, nullable=True))
    return sb.build()


def _col_op_lit(op: UInt8, name: String, v: Int) -> Expr:
    return Expr.binary(op, Expr.col_ref(name), Expr.literal(ScalarValue.from_int(v)))


def _lit_op_col(op: UInt8, v: Int, name: String) -> Expr:
    return Expr.binary(op, Expr.literal(ScalarValue.from_int(v)), Expr.col_ref(name))


def _binding(
    var name: String,
    var params: ScanParams,
    var gate: PushdownGate,
    snapshot_policy: UInt8 = SNAPSHOT_NONE,
    snapshot_token: UInt64 = UInt64(0),
    handle: Int = SCAN_HANDLE_UNBOUND,
    registry_epoch: UInt64 = SCAN_EPOCH_NONE,
) -> ScanBinding:
    return ScanBinding(
        kind_id=scan_kind_id(String("test.kind")),
        kind_name=String("test.kind"),
        name=name^,
        params=params^,
        schema=_schema_ab(),
        fingerprint=UInt64(0xAAAA),
        structural_id=UInt64(0xBBBB),
        gate=gate^,
        snapshot_policy=snapshot_policy,
        snapshot_token=snapshot_token,
        handle=handle,
        registry_epoch=registry_epoch,
    )


# A resolver that DOES bind, so the epoch check has something to fail against.
@fieldwise_init
struct _FakeResolver(ScanResolver, Movable, Deinitable):
    var _epoch: UInt64
    var _token: UInt64

    def epoch(self) -> UInt64:
        return self._epoch

    def is_bound(self, kind_id: UInt32, handle: Int) -> Bool:
        return handle == 0

    def resolve_snapshot(self, binding: ScanBinding) raises -> UInt64:
        return self._token


# =============================================================================
# ScanParams — the sorted-key invariant is the load-bearing one.
# =============================================================================


def test_scan_params_fold_is_insertion_order_independent() raises:
    """THE property that makes a param map safe as a cache key.

    Two constructions of the same source that insert keys in different orders
    MUST fold equal, or the plan cache silently misses forever — a perf cliff
    with no failing test anywhere. This is why `_keys` is sorted rather than
    append-ordered.
    """
    var p1 = ScanParams()
    p1.put_str(String("path"), String("/tmp/x.arrow"))
    p1.put_str(String("codec"), String("zstd"))
    p1.put_i64(String("estimated_rows"), Int64(17))

    var p2 = ScanParams()
    p2.put_i64(String("estimated_rows"), Int64(17))
    p2.put_str(String("codec"), String("zstd"))
    p2.put_str(String("path"), String("/tmp/x.arrow"))

    assert_equal(p1.hash_into(UInt64(0)), p2.hash_into(UInt64(0)))
    assert_equal(p1.render(), p2.render())


def test_scan_params_put_overwrites_rather_than_duplicates() raises:
    """A caller that sets a key twice must not fold differently from one that
    set it once — otherwise a defensive re-`put` changes a cache key."""
    var p1 = ScanParams()
    p1.put_str(String("codec"), String("lz4_frame"))
    p1.put_str(String("codec"), String("zstd"))

    var p2 = ScanParams()
    p2.put_str(String("codec"), String("zstd"))

    assert_equal(p1.num_params(), 1)
    assert_equal(p1.hash_into(UInt64(0)), p2.hash_into(UInt64(0)))


def test_scan_params_distinct_values_fold_apart() raises:
    var p1 = ScanParams()
    p1.put_str(String("codec"), String("zstd"))
    var p2 = ScanParams()
    p2.put_str(String("codec"), String("lz4_frame"))
    assert_not_equal(p1.hash_into(UInt64(0)), p2.hash_into(UInt64(0)))


def test_scan_params_same_value_different_key_folds_apart() raises:
    var p1 = ScanParams()
    p1.put_str(String("codec"), String("x"))
    var p2 = ScanParams()
    p2.put_str(String("path"), String("x"))
    assert_not_equal(p1.hash_into(UInt64(0)), p2.hash_into(UInt64(0)))


def test_param_value_tag_prevents_cross_type_aliasing() raises:
    """`of_i64(1)` and `of_bool(True)` share an `i` payload. The tag must
    participate in the fold or a `retries=1` param would alias `strict=true`."""
    var a = ParamValue.of_i64(Int64(1))
    var b = ParamValue.of_bool(True)
    assert_equal(a.i, b.i)
    assert_not_equal(a.hash_into(UInt64(0)), b.hash_into(UInt64(0)))


def test_param_value_u64_round_trips_above_int64_max() raises:
    """A broker offset or a search generation can exceed Int64.MAX. A
    saturating convert would silently truncate it INTO THE IDENTITY FOLD, which
    is the shape of a wrong cache hit. The storage is a bit-cast."""
    var big = UInt64(0xFFFF_FFFF_FFFF_FFF0)
    var v = ParamValue.of_u64(big)
    assert_equal(v.tag, PARAM_U64)
    assert_equal(v.as_u64(), big)

    var p = ScanParams()
    p.put_u64(String("offset"), big)
    assert_equal(p.get_u64(String("offset")), big)


def test_scan_params_get_missing_returns_none() raises:
    var p = ScanParams()
    p.put_str(String("codec"), String("zstd"))
    assert_true(p.has(String("codec")))
    assert_false(p.has(String("nope")))
    var v = p.get(String("nope"))
    assert_false(Bool(v))
    assert_equal(p.get_str(String("nope"), String("dflt")), String("dflt"))


def test_scan_params_render_is_readable_for_unknown_kinds() raises:
    """EXPLAIN must render a kind core has never registered. This is the
    concrete reason the param map beat an opaque byte blob."""
    var p = ScanParams()
    p.put_str(String("path"), String("/tmp/x"))
    p.put_i64(String("n"), Int64(3))
    assert_equal(p.render(), String("n=3, path=/tmp/x"))


# =============================================================================
# schema_identity_hash
# =============================================================================


def test_schema_identity_hash_equal_shapes_hash_equal() raises:
    assert_equal(schema_identity_hash(_schema_ab()), schema_identity_hash(_schema_ab()))


def test_schema_identity_hash_column_order_matters() raises:
    """Column order is part of a schema's identity — projection is positional
    downstream, so two orderings are two different schemas."""
    var sb = SchemaBuilder()
    sb.add_field(Field("b", ArrowType.STRING, nullable=True))
    sb.add_field(Field("a", ArrowType.INT64, nullable=False))
    assert_not_equal(schema_identity_hash(_schema_ab()), schema_identity_hash(sb.build()))


def test_schema_identity_hash_discriminates_type_and_nullability() raises:
    var sb_t = SchemaBuilder()
    sb_t.add_field(Field("a", ArrowType.INT32, nullable=False))
    sb_t.add_field(Field("b", ArrowType.STRING, nullable=True))

    var sb_n = SchemaBuilder()
    sb_n.add_field(Field("a", ArrowType.INT64, nullable=True))
    sb_n.add_field(Field("b", ArrowType.STRING, nullable=True))

    var base = schema_identity_hash(_schema_ab())
    assert_not_equal(base, schema_identity_hash(sb_t.build()))
    assert_not_equal(base, schema_identity_hash(sb_n.build()))


def test_schema_identity_hash_discriminates_decimal_scale() raises:
    """DECIMAL128(10,2) and DECIMAL128(10,4) share an ArrowType id. Folding
    only the id would make two genuinely different schemas identical."""
    var sb2 = SchemaBuilder()
    sb2.add_field(Field.decimal128("d", 10, 2, nullable=False))
    var sb4 = SchemaBuilder()
    sb4.add_field(Field.decimal128("d", 10, 4, nullable=False))
    assert_not_equal(schema_identity_hash(sb2.build()), schema_identity_hash(sb4.build()))


def test_schema_identity_hash_prefix_does_not_alias() raises:
    var sb = SchemaBuilder()
    sb.add_field(Field("a", ArrowType.INT64, nullable=False))
    assert_not_equal(schema_identity_hash(sb.build()), schema_identity_hash(_schema_ab()))


def test_schema_identity_hash_empty_is_nonzero() raises:
    assert_not_equal(schema_identity_hash(Schema()), UInt64(0))


# =============================================================================
# PushdownGate — the three source behaviours.
# =============================================================================


def test_gate_reject_all_rejects_every_shape() raises:
    """Most union arms (json, csv, arrow x3, orc, avro) use the `SourceLike`
    trait default `return False`."""
    var g = PushdownGate.reject_all()
    assert_equal(g.mode, GATE_REJECT_ALL)
    var s = _schema_ab()
    var extra = List[String]()
    assert_false(gate_allows(g, s, extra, _col_op_lit(BIN_EQ, "a", 1)))
    assert_false(gate_allows(g, s, extra, Expr.col_ref("a")))


def test_gate_accept_all_accepts_every_shape() raises:
    """`InMemorySource` — every predicate becomes a deferred OP_FILTER, so it
    can honour anything."""
    var g = PushdownGate.accept_all()
    assert_equal(g.mode, GATE_ACCEPT_ALL)
    var s = _schema_ab()
    var extra = List[String]()
    assert_true(gate_allows(g, s, extra, _col_op_lit(BIN_EQ, "a", 1)))
    # Even a shape the parquet classifier rejects outright.
    assert_true(
        gate_allows(
            g,
            s,
            extra,
            Expr.binary(
                BIN_OR, _col_op_lit(BIN_EQ, "a", 1), _col_op_lit(BIN_EQ, "a", 2)
            ),
        )
    )


def test_gate_shaped_matches_the_parquet_classifier_shapes() raises:
    """The SHAPED gate is a behaviour-preserving generalisation of
    `ParquetSource._pushdown_supported`: comparisons
    against literals over stat-friendly cols, AND-recursion, IN-lists; NOT
    OR-trees, NOT col-vs-col, NOT a bare col-ref.
    """
    var g = PushdownGate.conjunctive_comparison()
    assert_equal(g.mode, GATE_SHAPED)
    var s = _schema_ab()
    var extra = List[String]()

    # Accepted: comparison against a literal, either operand order.
    assert_true(gate_allows(g, s, extra, _col_op_lit(BIN_EQ, "a", 1)))
    assert_true(gate_allows(g, s, extra, _lit_op_col(BIN_EQ, 1, "a")))
    assert_true(gate_allows(g, s, extra, _col_op_lit(BIN_LT, "a", 9)))
    # Accepted: AND of two accepted conjuncts.
    assert_true(
        gate_allows(
            g,
            s,
            extra,
            Expr.binary(
                BIN_AND, _col_op_lit(BIN_GE, "a", 1), _col_op_lit(BIN_LE, "a", 9)
            ),
        )
    )
    # Rejected: OR — never pushable in any source.
    assert_false(
        gate_allows(
            g,
            s,
            extra,
            Expr.binary(
                BIN_OR, _col_op_lit(BIN_EQ, "a", 1), _col_op_lit(BIN_EQ, "a", 2)
            ),
        )
    )
    # Rejected: AND where one side is not pushable.
    assert_false(
        gate_allows(
            g,
            s,
            extra,
            Expr.binary(
                BIN_AND,
                _col_op_lit(BIN_EQ, "a", 1),
                Expr.binary(
                    BIN_OR, _col_op_lit(BIN_EQ, "a", 2), _col_op_lit(BIN_EQ, "a", 3)
                ),
            ),
        )
    )
    # Rejected: col vs col (no literal side).
    assert_false(
        gate_allows(
            g, s, extra, Expr.binary(BIN_EQ, Expr.col_ref("a"), Expr.col_ref("b"))
        )
    )
    # Rejected: a bare col-ref is not a conjunct on its own.
    assert_false(gate_allows(g, s, extra, Expr.col_ref("a")))
    # Rejected: an off-schema column.
    assert_false(gate_allows(g, s, extra, _col_op_lit(BIN_EQ, "zzz", 1)))


def test_gate_extra_cols_accept_off_schema_names() raises:
    """Parquet's Hive partition columns: a partition predicate is consumed by
    `partition_prune_scans` regardless of the inferred type, so those names are
    accepted unconditionally. Carried as DATA on the binding, not a callback."""
    var g = PushdownGate.conjunctive_comparison()
    var s = _schema_ab()
    var extra = List[String]()
    extra.append(String("part_dt"))
    assert_true(gate_allows(g, s, extra, _col_op_lit(BIN_EQ, "part_dt", 20260805)))
    assert_false(
        gate_allows(g, s, List[String](), _col_op_lit(BIN_EQ, "part_dt", 1))
    )


def test_gate_stat_friendly_requirement_is_a_bit_not_a_policy() raises:
    """A source with no statistics still wants "conjunctive comparison over my
    schema" — broker offset ranges, search field filters. That is the same
    grammar with the column test relaxed, which is one bit, not a new mode."""
    var sb = SchemaBuilder()
    sb.add_field(Field.list_of_string("tags", nullable=True))
    var s = sb.build()
    var extra = List[String]()

    assert_false(arrow_type_has_column_stats(s.field_arrow_type(0)))
    var strict = PushdownGate.conjunctive_comparison(require_stat_friendly_col=True)
    var relaxed = PushdownGate.conjunctive_comparison(require_stat_friendly_col=False)
    var pred = Expr.binary(
        BIN_EQ, Expr.col_ref("tags"), Expr.literal(ScalarValue.from_string("x"))
    )
    assert_false(gate_allows(strict, s, extra, pred))
    assert_true(gate_allows(relaxed, s, extra, pred))


def test_gate_hash_discriminates_capability() raises:
    """Two bindings differing ONLY in declared capability must not collide: the
    compiled plan depends on which conjuncts were pushed."""
    assert_not_equal(
        PushdownGate.reject_all().hash_into(UInt64(7)),
        PushdownGate.accept_all().hash_into(UInt64(7)),
    )
    assert_not_equal(
        PushdownGate.conjunctive_comparison(True).hash_into(UInt64(7)),
        PushdownGate.conjunctive_comparison(False).hash_into(UInt64(7)),
    )


# =============================================================================
# kind_id + ScanKindRegistry
# =============================================================================


def test_scan_kind_id_is_stable_and_discriminating() raises:
    """Stable ACROSS PROCESSES is the property a per-process counter (such as
    `InMemorySource._identity`) cannot have — it is what lets a binding
    serialize."""
    assert_equal(
        scan_kind_id(String("komira.arrow.ipc")),
        scan_kind_id(String("komira.arrow.ipc")),
    )
    assert_not_equal(
        scan_kind_id(String("komira.arrow.ipc")),
        scan_kind_id(String("komira.parquet")),
    )
    # PINNED AGAINST AN INDEPENDENT REFERENCE, not against our own output: this
    # is the textbook FNV-1a/32 of the ASCII bytes, cross-checked in Python. A
    # pin lifted from `print(scan_kind_id(...))` would only assert that the code
    # equals itself. A change here silently rebases every binding's kind.
    assert_equal(scan_kind_id(String("komira.arrow.ipc")), UInt32(2587754919))
    assert_equal(scan_kind_id(String("komira.parquet")), UInt32(691257958))


def test_registry_register_and_lookup() raises:
    var r = ScanKindRegistry()
    var kid = scan_kind_id(String("test.kind"))
    assert_false(r.describes(kid))
    r.register(
        ScanKindDescriptor(
            kind_name=String("test.kind"), gate=PushdownGate.reject_all()
        )
    )
    assert_true(r.describes(kid))
    assert_equal(r.descriptor(kid).kind_name, String("test.kind"))
    assert_equal(r.num_kinds(), 1)


def test_registry_reregistering_same_kind_is_idempotent() raises:
    """Two packages may legitimately both ensure a shared kind is present."""
    var r = ScanKindRegistry()
    r.register(
        ScanKindDescriptor(
            kind_name=String("test.kind"), gate=PushdownGate.reject_all()
        )
    )
    r.register(
        ScanKindDescriptor(
            kind_name=String("test.kind"), gate=PushdownGate.reject_all()
        )
    )
    assert_equal(r.num_kinds(), 1)


def test_registry_unknown_kind_raises() raises:
    var r = ScanKindRegistry()
    with assert_raises(contains="no descriptor for kind_id"):
        _ = r.descriptor(UInt32(1234))


def test_registry_validate_names_the_missing_param() raises:
    """The stated mitigation for stringly-typed keys: the failure moves to
    PLAN BUILD, naming the key, instead of a silent miss at execute time."""
    var r = ScanKindRegistry()
    var req = List[String]()
    req.append(String("path"))
    req.append(String("codec"))
    r.register(
        ScanKindDescriptor(
            kind_name=String("test.kind"),
            gate=PushdownGate.reject_all(),
            required_params=req^,
        )
    )
    var p = ScanParams()
    p.put_str(String("path"), String("/tmp/x"))
    with assert_raises(contains="codec"):
        r.validate(_binding(String("x"), p.copy(), PushdownGate.reject_all()))

    p.put_str(String("codec"), String("zstd"))
    r.validate(_binding(String("x"), p^, PushdownGate.reject_all()))


def test_registry_validate_catches_orientation_disagreement() raises:
    var r = ScanKindRegistry()
    r.register(
        ScanKindDescriptor(
            kind_name=String("test.kind"),
            gate=PushdownGate.reject_all(),
            orientation=SCAN_ORIENTATION_ROW,
        )
    )
    with assert_raises(contains="orientation"):
        r.validate(_binding(String("x"), ScanParams(), PushdownGate.reject_all()))


def test_registry_validate_catches_unregistered_kind() raises:
    var r = ScanKindRegistry()
    with assert_raises(contains="unregistered kind"):
        r.validate(_binding(String("x"), ScanParams(), PushdownGate.reject_all()))


# =============================================================================
# Orientation constants are PINNED to the plan layer's values.
# =============================================================================


def test_scan_orientation_matches_plan_source_kind() raises:
    """`ScanBinding` cannot import the plan layer (the plan layer imports it),
    so orientation is re-declared. This pin is what lets `ScanData.__init__`
    use a declared orientation with no mapping table — if these ever diverge, a
    binding-backed ROW source would silently plan as COLUMNAR."""
    assert_equal(SCAN_ORIENTATION_COLUMNAR, SOURCE_KIND_COLUMNAR)
    assert_equal(SCAN_ORIENTATION_ROW, SOURCE_KIND_ROW)


# =============================================================================
# ScanBinding
# =============================================================================


def test_binding_copy_is_deep_and_identity_stable() raises:
    var p = ScanParams()
    p.put_str(String("path"), String("/tmp/x.arrow"))
    var b = _binding(String("t"), p^, PushdownGate.accept_all())
    var c = b.copy()
    assert_equal(b.fingerprint, c.fingerprint)
    assert_equal(b.structural_id, c.structural_id)
    assert_equal(b.identity_hash(), c.identity_hash())
    assert_equal(c.params.get_str(String("path")), String("/tmp/x.arrow"))


def test_binding_pushdown_reads_the_gate_not_a_source() raises:
    var s_reject = _binding(String("t"), ScanParams(), PushdownGate.reject_all())
    var s_accept = _binding(String("t"), ScanParams(), PushdownGate.accept_all())
    var pred = _col_op_lit(BIN_EQ, "a", 1)
    assert_false(s_reject.supports_filter_pushdown(pred))
    assert_true(s_accept.supports_filter_pushdown(pred))


def test_binding_estimate_rows_defaults_to_unknown() raises:
    var b = _binding(String("t"), ScanParams(), PushdownGate.reject_all())
    assert_equal(b.estimate_rows(), -1)
    var p = ScanParams()
    p.put_i64(String("estimated_rows"), Int64(42))
    assert_equal(_binding(String("t"), p^, PushdownGate.reject_all()).estimate_rows(), 42)


def test_binding_render_names_the_kind_and_params() raises:
    var p = ScanParams()
    p.put_str(String("codec"), String("zstd"))
    var b = _binding(String("/tmp/x.arrow"), p^, PushdownGate.reject_all())
    assert_equal(b.render(), String("test.kind(/tmp/x.arrow, codec=zstd)"))


# =============================================================================
# The identity/freshness split — the one conditional in identity_hash.
# =============================================================================


def test_pinned_snapshot_token_is_identity() raises:
    """Parquet's `_mtime_ns`: two scans of the same path at different mtimes
    are different sources."""
    var a = _binding(
        String("t"), ScanParams(), PushdownGate.reject_all(), SNAPSHOT_PINNED, UInt64(1)
    )
    var b = _binding(
        String("t"), ScanParams(), PushdownGate.reject_all(), SNAPSHOT_PINNED, UInt64(2)
    )
    assert_not_equal(a.identity_hash(), b.identity_hash())


def test_live_snapshot_token_is_NOT_identity() raises:
    """A search generation or a broker offset. Folding it in is safe but
    thrashy: every publish changes every query's identity so the plan cache
    misses. Excluding it is what gives search stable
    identity ACROSS publishes; freshness comes from re-resolution, not from the
    cache key."""
    var a = _binding(
        String("t"), ScanParams(), PushdownGate.reject_all(), SNAPSHOT_LIVE, UInt64(1)
    )
    var b = _binding(
        String("t"), ScanParams(), PushdownGate.reject_all(), SNAPSHOT_LIVE, UInt64(999)
    )
    assert_equal(a.identity_hash(), b.identity_hash())


def test_snapshot_policy_itself_discriminates() raises:
    """A LIVE binding and a PINNED binding at token 0 are different sources —
    one is refreshed per execution and one is not."""
    var live = _binding(
        String("t"), ScanParams(), PushdownGate.reject_all(), SNAPSHOT_LIVE, UInt64(0)
    )
    var none = _binding(
        String("t"), ScanParams(), PushdownGate.reject_all(), SNAPSHOT_NONE, UInt64(0)
    )
    # Policy rides on the fold via the PINNED conditional only, so LIVE and
    # NONE at token 0 intentionally agree — both exclude the token. What must
    # NOT agree is PINNED at a real token.
    assert_equal(live.identity_hash(), none.identity_hash())
    var pinned = _binding(
        String("t"), ScanParams(), PushdownGate.reject_all(), SNAPSHOT_PINNED, UInt64(5)
    )
    assert_not_equal(pinned.identity_hash(), none.identity_hash())


def test_with_snapshot_token_returns_a_copy_leaving_the_cached_plan_alone() raises:
    """INVARIANT, made testable: a LIVE token is written to a
    PER-EXECUTION copy, never back into the cached plan. The cached plan holds
    token 0 for every LIVE binding, so a non-zero LIVE token in a cached plan is
    a detectable bug."""
    var cached = _binding(
        String("t"), ScanParams(), PushdownGate.reject_all(), SNAPSHOT_LIVE, UInt64(0)
    )
    var per_exec = cached.with_snapshot_token(UInt64(77))
    assert_equal(cached.snapshot_token, UInt64(0))
    assert_equal(per_exec.snapshot_token, UInt64(77))
    # And the cache key did not move.
    assert_equal(cached.identity_hash(), per_exec.identity_hash())


# =============================================================================
# The ownership rule — the epoch check.
# =============================================================================


def test_unbound_resolver_is_the_no_op_default() raises:
    """`UnboundScanResolver` keeps every call site that binds nothing
    byte-identical — its answer is "no handle"."""
    var r = UnboundScanResolver()
    assert_equal(r.epoch(), SCAN_EPOCH_NONE)
    assert_false(r.is_bound(UInt32(1), 0))
    var b = _binding(String("t"), ScanParams(), PushdownGate.reject_all())
    # An UNBOUND binding is legal and must not raise.
    check_binding(r, b)


def test_epoch_mismatch_raises_instead_of_dangling() raises:
    """MECHANISM 2 OF THE OWNERSHIP RULE. `ArcPointer` in the IR was a
    compile-time keep-alive; `handle: Int` is not. This check is what turns a
    use-after-free into a named test assertion instead of a tcmalloc crash
    three frames later."""
    var live = _FakeResolver(_epoch=UInt64(7), _token=UInt64(0))
    var stale = _binding(
        String("t"),
        ScanParams(),
        PushdownGate.reject_all(),
        handle=0,
        registry_epoch=UInt64(6),
    )
    with assert_raises(contains="registry that minted it is gone"):
        check_binding(live, stale)

    var current = _binding(
        String("t"),
        ScanParams(),
        PushdownGate.reject_all(),
        handle=0,
        registry_epoch=UInt64(7),
    )
    check_binding(live, current)


def test_handle_not_bound_in_this_registry_raises() raises:
    var live = _FakeResolver(_epoch=UInt64(7), _token=UInt64(0))
    var b = _binding(
        String("t"),
        ScanParams(),
        PushdownGate.reject_all(),
        handle=5,
        registry_epoch=UInt64(7),
    )
    with assert_raises(contains="is not bound in this registry"):
        check_binding(live, b)


def test_resolve_for_execution_refreshes_only_live_tokens() raises:
    var r = _FakeResolver(_epoch=UInt64(7), _token=UInt64(1234))

    var live = _binding(
        String("t"), ScanParams(), PushdownGate.reject_all(), SNAPSHOT_LIVE, UInt64(0)
    )
    var resolved = resolve_for_execution(r, live)
    assert_equal(resolved.snapshot_token, UInt64(1234))
    assert_equal(live.snapshot_token, UInt64(0))

    var pinned = _binding(
        String("t"), ScanParams(), PushdownGate.reject_all(), SNAPSHOT_PINNED, UInt64(9)
    )
    assert_equal(resolve_for_execution(r, pinned).snapshot_token, UInt64(9))


def test_with_handle_returns_a_copy() raises:
    """Binding must not mutate in place: a binding inside a cached plan must
    never acquire a handle from a later execution."""
    var b = _binding(String("t"), ScanParams(), PushdownGate.reject_all())
    var bound = b.with_handle(3, UInt64(7))
    assert_equal(b.handle, SCAN_HANDLE_UNBOUND)
    assert_false(b.is_bound())
    assert_equal(bound.handle, 3)
    assert_true(bound.is_bound())
    assert_equal(bound.registry_epoch, UInt64(7))


# =============================================================================
# THE OTHER DOOR — the LEGACY `LogicalPlan.scan` factory.
# =============================================================================
#
# The orientation rule is split: `ScanData.__init__` ENFORCES the kind's
# declared `orientation` (silently, because it must stay non-raising) and
# `LogicalPlan.scan_from_source` REPORTS a contradicting `source_kind`. A split
# rule is only sound if every door into the error condition is the reported
# one. The legacy `LogicalPlan.scan` factory DOES build binding-backed variants
# (for example `LogicalPlan.scan(path, SOURCE_NDJSON, ...)` builds a
# `SourceVariant(JsonSource)`, and `komira.json` DECLARES ROW), so it must state
# nothing (`SOURCE_KIND_UNSET`) for every arm; the ctor's ladder then answers
# from the declaration.


def _factory_arm_states_no_contradiction(
    source_type: UInt8, var path: String
) raises:
    """Run the PRODUCTION refusal over what the legacy factory ACTUALLY builds.

    Not a re-implementation of the rule: `scan_from_source` is the function that
    calls `_require_orientation_agreement`, so handing it the variant the legacy
    factory produced, together with the `source_kind` the legacy factory stated,
    asks the live check the exact question the split rule depends on.
    """
    var plan = LogicalPlan.scan(path^, source_type, _schema_ab())
    # ⚠ `source_kind=` IS OMITTED, AND THAT IS THE POINT: the legacy factory
    # passes nothing, and so does this echo. Hand `scan_from_source` (the function that
    # calls `_require_orientation_agreement`) exactly what the legacy factory
    # builds and exactly what it states, and see whether it refuses.
    var echoed = LogicalPlan.scan_from_source(
        plan._scan.value()[].source.copy(),
        _schema_ab(),
    )
    # And the two doors agree on the ANSWER, not merely on not-raising.
    assert_equal(
        echoed._scan.value()[].source_kind,
        plan._scan.value()[].source_kind,
    )
    # ⭐ AND THE ANSWER IS THE DERIVATION'S: the leaf carries what its own SOURCE implies, which is what makes a
    # caller-stated layout unnecessary rather than merely unused.
    # ⚠ ONE `ref`, NOT TWO `.value()[]`. Taking the interior reference twice in
    # one expression is `error: use of invalidated interior reference
    # 'plan._scan._value["value"]'` on Mojo 1.0.0 — the second borrow kills the
    # first, and the two are arguments of the SAME call here.
    ref sd = plan.scan_data_ref()
    assert_equal(sd.source_kind, derive_source_layout(sd.source))


def test_the_legacy_factory_never_states_a_kind_that_contradicts_a_declaration() raises:
    """THE RULE: for every `source_type` the legacy factory routes, the
    `source_kind` it STATES must be acceptable to the same check the canonical
    factory applies to the variant it BUILDS. `SOURCE_KIND_UNSET` — stating
    nothing — is always acceptable; a stated value is acceptable only when the
    source is not binding-backed or agrees.

    ⚠ IT WALKS THE ARMS RATHER THAN ASSERTING ONE CASE. The factory states
    nothing for any arm, so the loop cannot fail from the factory's side, and it
    stays a loop anyway: (i) the arms it walks are also asserted against
    `_require_orientation_agreement`, so a KIND that changed its declared
    orientation would still be caught here whatever the factory says; (ii) the
    property wanted is "no arm contradicts a declaration", and a test that
    asserted only one arm would have to be rewritten every time an arm becomes
    binding-backed.

    ⚠ THE LIST BELOW MUST TRACK THE FACTORY'S LADDER. There is nothing to derive
    it from — the arms are a hand-written `if/elif/else` — so `SOURCE_ORC` is
    included as a stand-in for the `else` fall-through that any unrecognised
    type takes.
    """
    _factory_arm_states_no_contradiction(SOURCE_PARQUET, String("/t/a.parquet"))
    _factory_arm_states_no_contradiction(SOURCE_IN_MEMORY, String("__t__"))
    _factory_arm_states_no_contradiction(SOURCE_NDJSON, String("/t/a.json"))
    _factory_arm_states_no_contradiction(SOURCE_CSV, String("/t/a.csv"))
    _factory_arm_states_no_contradiction(SOURCE_ORC, String("/t/a.orc"))


def _factory_arm_derives_its_layout(source_type: UInt8, var path: String) raises:
    """One legacy-factory arm: the leaf's layout IS `derive_source_layout` of
    the source the arm built. Nothing states it; the format decides."""
    var plan = LogicalPlan.scan(path^, source_type, _schema_ab())
    # ⚠ ONE `ref`, NOT TWO `.value()[]`. Taking the interior reference twice in
    # one expression is `error: use of invalidated interior reference
    # 'plan._scan._value["value"]'` on Mojo 1.0.0 — the second borrow kills the
    # first, and the two are arguments of the SAME call here.
    ref sd = plan.scan_data_ref()
    assert_equal(sd.source_kind, derive_source_layout(sd.source))


def test_the_legacy_factory_states_nothing_where_it_means_nothing() raises:
    """The mechanism, stated directly: `SOURCE_KIND_UNSET` for EVERY arm.

    The sentinel is what makes "I state nothing" expressible at all, and it is
    the difference between a property that holds BY CONSTRUCTION and one that
    holds because of a claim about which variants the factory happens to build.
    CSV needs no carve-out: its ROW comes from `komira.csv`'s own declaration,
    which a caller cannot get wrong.
    """
    # The factory passes no `source_kind`, so "UNSET for every arm" is true BY
    # CONSTRUCTION. What is NOT true by construction, and is what these arms
    # are really for, is that each arm's leaf carries the layout ITS OWN SOURCE
    # implies; a kind that changed its declared `orientation`, or an arm that
    # started building a different variant, still surfaces here.
    _factory_arm_derives_its_layout(SOURCE_PARQUET, String("/t/a.parquet"))
    _factory_arm_derives_its_layout(SOURCE_IN_MEMORY, String("__t__"))
    _factory_arm_derives_its_layout(SOURCE_NDJSON, String("/t/a.json"))
    _factory_arm_derives_its_layout(SOURCE_ORC, String("/t/a.orc"))
    _factory_arm_derives_its_layout(SOURCE_CSV, String("/t/a.csv"))


def test_stating_nothing_is_behaviour_identical_to_the_columnar_it_replaced() raises:
    """Stating nothing must move no answer, or every legacy scan's
    `source_kind=` render moves and with it every plan-compile cache key.

    The ctor's ladder makes it identical, and this pins the four answers rather
    than the reasoning: binding-backed reads the DECLARATION and ignores the
    argument (so UNSET and COLUMNAR agree), and NOT-binding-backed maps UNSET to
    COLUMNAR through the `SOURCE_KIND_UNSET` branch (so they agree there too).
    """
    var p = LogicalPlan.scan(String("/t/a.parquet"), SOURCE_PARQUET, _schema_ab())
    assert_equal(p._scan.value()[].source_kind, SOURCE_KIND_COLUMNAR)
    var m = LogicalPlan.scan(String("__t__"), SOURCE_IN_MEMORY, _schema_ab())
    assert_equal(m._scan.value()[].source_kind, SOURCE_KIND_COLUMNAR)
    var c = LogicalPlan.scan(String("/t/a.csv"), SOURCE_CSV, _schema_ab())
    assert_equal(c._scan.value()[].source_kind, SOURCE_KIND_ROW)
    # ⚠ ROW, not COLUMNAR — the JSON kind DECLARES it.
    var j = LogicalPlan.scan(String("/t/a.json"), SOURCE_NDJSON, _schema_ab())
    assert_equal(j._scan.value()[].source_kind, SOURCE_KIND_ROW)


def main() raises:
    var suite = TestSuite()
    # ScanParams
    suite.test[test_scan_params_fold_is_insertion_order_independent]()
    suite.test[test_scan_params_put_overwrites_rather_than_duplicates]()
    suite.test[test_scan_params_distinct_values_fold_apart]()
    suite.test[test_scan_params_same_value_different_key_folds_apart]()
    suite.test[test_param_value_tag_prevents_cross_type_aliasing]()
    suite.test[test_param_value_u64_round_trips_above_int64_max]()
    suite.test[test_scan_params_get_missing_returns_none]()
    suite.test[test_scan_params_render_is_readable_for_unknown_kinds]()
    # schema_identity_hash
    suite.test[test_schema_identity_hash_equal_shapes_hash_equal]()
    suite.test[test_schema_identity_hash_column_order_matters]()
    suite.test[test_schema_identity_hash_discriminates_type_and_nullability]()
    suite.test[test_schema_identity_hash_discriminates_decimal_scale]()
    suite.test[test_schema_identity_hash_prefix_does_not_alias]()
    suite.test[test_schema_identity_hash_empty_is_nonzero]()
    # PushdownGate
    suite.test[test_gate_reject_all_rejects_every_shape]()
    suite.test[test_gate_accept_all_accepts_every_shape]()
    suite.test[test_gate_shaped_matches_the_parquet_classifier_shapes]()
    suite.test[test_gate_extra_cols_accept_off_schema_names]()
    suite.test[test_gate_stat_friendly_requirement_is_a_bit_not_a_policy]()
    suite.test[test_gate_hash_discriminates_capability]()
    # kind_id + registry
    suite.test[test_scan_kind_id_is_stable_and_discriminating]()
    suite.test[test_registry_register_and_lookup]()
    suite.test[test_registry_reregistering_same_kind_is_idempotent]()
    suite.test[test_registry_unknown_kind_raises]()
    suite.test[test_registry_validate_names_the_missing_param]()
    suite.test[test_registry_validate_catches_orientation_disagreement]()
    suite.test[test_registry_validate_catches_unregistered_kind]()
    suite.test[test_scan_orientation_matches_plan_source_kind]()
    # ScanBinding
    suite.test[test_binding_copy_is_deep_and_identity_stable]()
    suite.test[test_binding_pushdown_reads_the_gate_not_a_source]()
    suite.test[test_binding_estimate_rows_defaults_to_unknown]()
    suite.test[test_binding_render_names_the_kind_and_params]()
    # identity / freshness split
    suite.test[test_pinned_snapshot_token_is_identity]()
    suite.test[test_live_snapshot_token_is_NOT_identity]()
    suite.test[test_snapshot_policy_itself_discriminates]()
    suite.test[test_with_snapshot_token_returns_a_copy_leaving_the_cached_plan_alone]()
    # ownership rule
    suite.test[test_unbound_resolver_is_the_no_op_default]()
    suite.test[test_epoch_mismatch_raises_instead_of_dangling]()
    suite.test[test_handle_not_bound_in_this_registry_raises]()
    suite.test[test_resolve_for_execution_refreshes_only_live_tokens]()
    suite.test[test_with_handle_returns_a_copy]()

    suite.test[test_the_legacy_factory_never_states_a_kind_that_contradicts_a_declaration]()
    suite.test[test_the_legacy_factory_states_nothing_where_it_means_nothing]()
    suite.test[test_stating_nothing_is_behaviour_identical_to_the_columnar_it_replaced]()
    suite^.run()
