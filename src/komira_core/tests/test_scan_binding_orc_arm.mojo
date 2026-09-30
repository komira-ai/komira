# =============================================================================
# The ORC source arm, carried by `ScanBinding`.
# =============================================================================
#
# ORC is a GENUINELY DIFFERENT KIND from arrow: its own carrier, its own
# identity inputs (path + mtime + an ORDER-SENSITIVE projection vector), its own
# file format — and it slots in with no core edit.
#
# THIS FILE PINS TWO THINGS:
#
#   THE FINGERPRINT VALUE. Pinned THREE ways:
#     1. against an independent Python FNV-1a/64 reference (golden literals
#        below), so the pin cannot silently follow a change in our own code;
#     2. against `OrcSource.fingerprint()`, the carrier's own value;
#     3. against `SourceVariant.structural_id()`, which for every file-path
#        source equals the fingerprint.
#
#   THE SEAM — a kind's params must reach the plan-cache key.
#
# =============================================================================
# THE SEAM
# =============================================================================
#
# `OrcSource.fingerprint()` folds the projection vector, ORDER-SENSITIVELY
# (`[0,2] != [2,0]`). That fingerprint must reach the plan hash too.
# `LogicalPlan.structural_hash()` is FNV-1a over the plan TEXT, and the
# OrcSource projection is a `List[Int]` INSIDE the source, distinct from
# `ScanData.projection`. If nothing rendered it, two ORC scans of ONE file
# projecting DIFFERENT columns would render the same text, hash the same, and
# collide in the plan-compile cache — query A's compiled plan returned for
# query B.
#
# It is the same class as the arrow codec
# (`test_two_codecs_over_one_path_do_not_share_a_plan_cache_key`): a kind's
# discriminating configuration stopping at the plan node. The binding handles
# it structurally rather than per-arm — the projection is `params`, and
# `_write_plan_node` emits `binding=` / `bsid=` / `bid=` for every
# binding-backed arm.
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
from komira_core.plan.expr import Expr, ScalarValue, BIN_EQ
from komira_core.plan.logical_plan import (
    LogicalPlan,
    SOURCE_ARROW,
    SOURCE_BINDING,
    SOURCE_ORC,
    SOURCE_PARQUET,
)
from komira_core.plan.logical_plan_variants import (
    ScanData,
    SOURCE_KIND_COLUMNAR,
    SOURCE_KIND_ROW,
    SOURCE_KIND_UNSET,
)
from komira_core.source.orc_source import OrcSource
from komira_core.source.pushdown_gate import GATE_REJECT_ALL, PushdownGate
from komira_core.source.scan_binding import (
    ScanBinding,
    scan_kind_id,
    SCAN_KIND_NAME_ORC,
    SCAN_LEGACY_SOURCE_TYPE_NONE,
    SCAN_ORIENTATION_COLUMNAR,
    SCAN_ORIENTATION_ROW,
    SNAPSHOT_PINNED,
)
from komira_core.source.scan_params import ScanParams
from komira_core.source.source_variant import (
    SourceVariant,
    SOURCE_VARIANT_ORC,
    LEGACY_SOURCE_TYPE_ARROW,
    LEGACY_SOURCE_TYPE_ORC,
)


# =============================================================================
# GOLDEN LITERALS — an INDEPENDENT reference, not our own output.
# =============================================================================
#
# `OrcSource.fingerprint()` is:
#
#   h = FNV1A64_OFFSET
#   h = combine(h, len(path))
#   h = combine(h, fnv1a64(path))
#   h = combine(h, mtime_ns)
#   h = combine(h, combine(combine(FNV1A64_OFFSET, len(proj)), proj[0]) ...)
#
# with combine(a, b) = (a ^ b) * FNV1A64_PRIME. These four literals were
# computed by a standalone Python implementation of that spec. If one of them
# ever has to change, a plan-cache key changed and the change is load-bearing —
# do not "fix" the literal.
comptime GOLDEN_PATH: String = "/tmp/golden_orc_fp.orc"
comptime GOLDEN_FP_MTIME_0_PROJ_ALL: UInt64 = 11872844518938157991
comptime GOLDEN_FP_MTIME_0_PROJ_02: UInt64 = 9653618057110631231
comptime GOLDEN_FP_MTIME_0_PROJ_20: UInt64 = 11614880719912628519
comptime GOLDEN_FP_MTIME_1234567890_PROJ_ALL: UInt64 = 4884101017425234953


def _schema_abc() -> Schema:
    var sb = SchemaBuilder()
    sb.add_field(Field("a", ArrowType.INT64, nullable=False))
    sb.add_field(Field("b", ArrowType.INT64, nullable=True))
    sb.add_field(Field("c", ArrowType.STRING, nullable=True))
    return sb.build()


def _proj(*idx: Int) -> List[Int]:
    var out = List[Int]()
    for i in range(len(idx)):
        out.append(idx[i])
    return out^


def _orc_src(
    var path: String, var projection: List[Int], mtime: UInt64 = 0
) -> OrcSource:
    return OrcSource(path^, _schema_abc(), projection^, mtime_ns=mtime)


def _row_kind_binding() -> ScanBinding:
    """An OPEN kind from a hypothetical upper package that DECLARES ROW.

    `komira.avro` is a real ROW kind. This fixture covers the OPEN-arm shape (a kind core has never heard of), which the AVRO
    tests do not — AVRO is a legacy arm and carries a `legacy_source_type`."""
    return ScanBinding(
        kind_id=scan_kind_id(String("example.row.kind")),
        kind_name=String("example.row.kind"),
        name=String("rows"),
        params=ScanParams(),
        schema=_schema_abc(),
        fingerprint=UInt64(0xB0B),
        structural_id=UInt64(0xB0B),
        gate=PushdownGate.reject_all(),
        orientation=SCAN_ORIENTATION_ROW,
    )


# =============================================================================
# SECTION 1 — the fingerprint pins.
# =============================================================================


def test_orc_fingerprint_matches_the_independent_reference() raises:
    """PIN 1 — the golden literals. Computed from an independent Python FNV-1a
    reference over the documented fold, so this pin cannot silently follow a
    change in our own hash code."""
    assert_equal(
        _orc_src(String(GOLDEN_PATH), _proj()).fingerprint(),
        GOLDEN_FP_MTIME_0_PROJ_ALL,
    )
    assert_equal(
        _orc_src(String(GOLDEN_PATH), _proj(0, 2)).fingerprint(),
        GOLDEN_FP_MTIME_0_PROJ_02,
    )
    assert_equal(
        _orc_src(String(GOLDEN_PATH), _proj(2, 0)).fingerprint(),
        GOLDEN_FP_MTIME_0_PROJ_20,
    )
    assert_equal(
        _orc_src(String(GOLDEN_PATH), _proj(), UInt64(1234567890)).fingerprint(),
        GOLDEN_FP_MTIME_1234567890_PROJ_ALL,
    )


def test_migrated_orc_arm_preserves_the_fingerprint_byte_for_byte() raises:
    """PIN 2 — the arm's values must stay EQUAL TO THE CARRIER'S, not merely
    stay distinct. A drift here invalidates every ORC plan-cache key with
    nothing going red."""
    var sv = SourceVariant(_orc_src(String(GOLDEN_PATH), _proj()))
    assert_equal(sv.fingerprint(), GOLDEN_FP_MTIME_0_PROJ_ALL)
    # `structural_id` for a file-path source IS its fingerprint (only IN_MEMORY
    # differs).
    assert_equal(sv.structural_id(), GOLDEN_FP_MTIME_0_PROJ_ALL)

    var sv_proj = SourceVariant(_orc_src(String(GOLDEN_PATH), _proj(0, 2)))
    assert_equal(sv_proj.fingerprint(), GOLDEN_FP_MTIME_0_PROJ_02)
    assert_equal(sv_proj.structural_id(), GOLDEN_FP_MTIME_0_PROJ_02)

    var sv_mtime = SourceVariant(
        _orc_src(String(GOLDEN_PATH), _proj(), UInt64(1234567890))
    )
    assert_equal(sv_mtime.fingerprint(), GOLDEN_FP_MTIME_1234567890_PROJ_ALL)


def test_orc_arm_keeps_its_legacy_tag_and_kind_name() raises:
    """The ORC tag VALUE and kind name are stable, so code asserting
    `sv.tag == SOURCE_VARIANT_ORC` and `kind_name() == "orc"` keeps working.
    `tag` is the legacy discriminant; preserving its values keeps every caller
    untouched."""
    var sv = SourceVariant(_orc_src(String(GOLDEN_PATH), _proj(1, 3)))
    assert_equal(sv.tag, SOURCE_VARIANT_ORC)
    assert_equal(sv.kind_name(), String("orc"))


def test_orc_accessors_answer_the_same_values() raises:
    """Schema / estimate_rows / supports_filter_pushdown are unchanged. ORC has
    no SourceLike-surfaced filter pushdown (`OrcSource` returns False for
    EVERY predicate — its stride-stats pruning happens inside the decoder),
    which `GATE_REJECT_ALL` declares instead of implementing."""
    var sv = SourceVariant(_orc_src(String(GOLDEN_PATH), _proj()))
    assert_equal(sv.schema().num_columns(), 3)
    assert_equal(sv.schema().field_name(0), String("a"))
    assert_equal(sv.schema().field_name(2), String("c"))
    # -1 == unknown without a footer read. ORC never reports a row estimate,
    # so no `estimated_rows` param is invented for it.
    assert_equal(sv.estimate_rows(), -1)
    var pred = Expr.binary(
        BIN_EQ, Expr.col_ref("a"), Expr.literal(ScalarValue.from_int(1))
    )
    assert_false(sv.supports_filter_pushdown(pred))


def test_orc_copy_preserves_identity_byte_for_byte() raises:
    var sv = SourceVariant(_orc_src(String(GOLDEN_PATH), _proj(0, 2)))
    var c = sv.copy()
    assert_equal(c.tag, SOURCE_VARIANT_ORC)
    assert_equal(c.fingerprint(), GOLDEN_FP_MTIME_0_PROJ_02)
    assert_equal(c.structural_id(), GOLDEN_FP_MTIME_0_PROJ_02)
    assert_equal(c.schema().num_columns(), 3)
    assert_equal(c.kind_name(), String("orc"))


def test_orc_projection_stays_order_sensitive() raises:
    """`read_orc_bytes_projected` has an ORDER-SENSITIVE output-column contract,
    so `[0,2]` and `[2,0]` are different scans. The binding carries this fold
    as `params` hashed by core rather than a `List[Int]` hashed by the source,
    and an order-INSENSITIVE param encoding would silently merge the two."""
    var a = SourceVariant(_orc_src(String(GOLDEN_PATH), _proj(0, 2)))
    var b = SourceVariant(_orc_src(String(GOLDEN_PATH), _proj(2, 0)))
    assert_not_equal(a.fingerprint(), b.fingerprint())
    var all_cols = SourceVariant(_orc_src(String(GOLDEN_PATH), _proj()))
    assert_not_equal(a.fingerprint(), all_cols.fingerprint())


def test_orc_scan_data_derivation_is_unchanged() raises:
    """The derived caches `ScanData.__init__` computes must come out IDENTICAL.
    `source_type == SOURCE_ORC` is what `_source_type_name` renders;
    `source_kind` must be COLUMNAR (ORC decodes columnar). These are DECLARED by
    the binding rather than derived by a per-type ladder arm."""
    var sd = ScanData(
        SourceVariant(_orc_src(String(GOLDEN_PATH), _proj(0, 2))),
        Optional[Schema](None),
        Optional[List[String]](None),
        Optional[Expr](None),
    )
    assert_equal(sd.source_type, SOURCE_ORC)
    assert_not_equal(sd.source_type, SOURCE_PARQUET)
    assert_equal(sd.source_path, String(GOLDEN_PATH))
    assert_equal(sd.source_kind, SOURCE_KIND_COLUMNAR)


def test_orc_plan_still_labels_itself_orc_in_explain() raises:
    """EXPLAIN must say `type=ORC`. `_source_type_name` has an arm for every
    `SOURCE_*` constant; this asserts the constant a binding-backed ORC scan
    actually carries is the one the ORC arm names."""
    var rendered = String(
        LogicalPlan.scan_from_source(
            SourceVariant(_orc_src(String(GOLDEN_PATH), _proj())), _schema_abc()
        )
    )
    assert_true("type=ORC" in rendered, "got: " + rendered)
    assert_false("type=UNKNOWN" in rendered, "got: " + rendered)


def test_orc_plan_survives_a_plan_copy() raises:
    """A plan clone must preserve the scan's identity. The derived caches must
    survive it — they are re-derived from the binding, so a drift shows up here rather than three optimizer passes
    later."""
    var plan = LogicalPlan.scan_from_source(
        SourceVariant(_orc_src(String(GOLDEN_PATH), _proj(0, 2), UInt64(7))),
        _schema_abc(),
    )
    var c = plan.copy()
    assert_true(Bool(c._scan))
    assert_equal(c._scan.value()[].source_type, SOURCE_ORC)
    assert_equal(c._scan.value()[].source_path, String(GOLDEN_PATH))
    assert_equal(
        c._scan.value()[].source.fingerprint(),
        plan._scan.value()[].source.fingerprint(),
    )
    assert_equal(c.structural_hash(), plan.structural_hash())


# =============================================================================
# SECTION 2 — THE SEAM.
# =============================================================================


def test_two_projections_of_one_orc_file_do_not_share_a_plan_cache_key() raises:
    """Two projections of one ORC file must not share a plan-compile cache key.

    The precondition is asserted first: the two sources have DIFFERENT
    `fingerprint`s, because `OrcSource` folds the projection. The fingerprint
    must also reach the plan TEXT, which is what `structural_hash` folds —
    otherwise one scan's compiled plan is handed to the other.
    """
    var a_src = _orc_src(String(GOLDEN_PATH), _proj(0, 2))
    var b_src = _orc_src(String(GOLDEN_PATH), _proj(2, 0))
    var a_fp = a_src.fingerprint()
    var b_fp = b_src.fingerprint()
    # PRECONDITION — the source-level identity already discriminates.
    assert_not_equal(a_fp, b_fp, "OrcSource folds the projection")

    var a = LogicalPlan.scan_from_source(SourceVariant(a_src^), _schema_abc())
    var b = LogicalPlan.scan_from_source(SourceVariant(b_src^), _schema_abc())
    # Same file, so `source_path` cannot be the discriminator.
    assert_equal(a._scan.value()[].source_path, b._scan.value()[].source_path)
    assert_not_equal(
        a.structural_hash(),
        b.structural_hash(),
        "two ORC scans of one file projecting [0,2] vs [2,0] share a"
        " plan-compile cache key; rendered as: " + String(a),
    )


def test_two_mtimes_of_one_orc_file_do_not_share_a_plan_cache_key() raises:
    """The same seam for the OTHER identity input `OrcSource` folds. `_mtime_ns`
    is the stale-cache-invalidation input, and it is the reason the binding
    declares `SNAPSHOT_PINNED` — "the token IS identity", which is exactly what
    a file mtime is. A re-written ORC file's scan must not render identically
    to the pre-write scan."""
    var a = LogicalPlan.scan_from_source(
        SourceVariant(_orc_src(String(GOLDEN_PATH), _proj(), UInt64(1))),
        _schema_abc(),
    )
    var b = LogicalPlan.scan_from_source(
        SourceVariant(_orc_src(String(GOLDEN_PATH), _proj(), UInt64(2))),
        _schema_abc(),
    )
    assert_not_equal(
        a.structural_hash(),
        b.structural_hash(),
        "two ORC scans of one file at different mtimes share a plan-compile"
        " cache key; rendered as: " + String(a),
    )


# =============================================================================
# SECTION 3 — the binding's contents and declarations.
# =============================================================================


def test_orc_is_binding_backed_and_carries_the_orc_kind() raises:
    """The arm's payload is a `ScanBinding`, not an `Optional[OrcSource]`.
    No `OrcSource` is reachable from a plan node — which is the
    property that lets a source live outside `komira_core` at all."""
    var sv = SourceVariant(_orc_src(String(GOLDEN_PATH), _proj(0, 2)))
    assert_true(sv.is_binding_backed(), "ORC arm is binding-backed")
    ref b = sv.binding_ref()
    assert_equal(b.kind_id, scan_kind_id(String(SCAN_KIND_NAME_ORC)))
    assert_equal(b.kind_name, String("komira.orc"))
    assert_equal(b.name, String(GOLDEN_PATH))


def test_orc_params_are_exactly_what_the_kind_has() raises:
    """`path` + one `projection.N` per output column index, and NOTHING ELSE.

    No `codec` param: per-codec dispatch (None/Zlib/Snappy/Lzo/Lz4/Zstd) is
    INTERNAL to the ORC decoder, so one carrier handles every codec and there is
    nothing for a codec param to discriminate. Arrow needed one only because it
    had three TAGS. No `estimated_rows` either — `OrcSource.estimate_rows()` is
    unconditionally -1, and `ScanBinding` already answers -1 for an absent param.

    Inventing params a kind does not have is how a param map turns back into a
    per-kind schema, so this is asserted rather than assumed."""
    var sv = SourceVariant(_orc_src(String(GOLDEN_PATH), _proj(0, 2)))
    ref b = sv.binding_ref()
    assert_equal(b.params.num_params(), 3)
    assert_equal(b.params.get_str(String("path")), String(GOLDEN_PATH))
    assert_equal(b.params.get_i64(String("projection.0")), Int64(0))
    assert_equal(b.params.get_i64(String("projection.1")), Int64(2))
    assert_false(b.params.has(String("codec")))
    assert_false(b.params.has(String("estimated_rows")))

    # All-columns == no projection keys at all.
    var all_cols = SourceVariant(_orc_src(String(GOLDEN_PATH), _proj()))
    assert_equal(all_cols.binding_ref().params.num_params(), 1)


def test_the_derived_identity_covers_every_param_the_kind_has() raises:
    """A kind can forget one of its own params in its SUPPLIED `structural_id`
    (for example, folding only (topic, partition) so two scans differing only
    in `start_offset` carry an identical value) and nothing goes red. Core's
    DERIVED `identity_hash()` is the fold a kind author cannot
    forget, so it must cover every identity input ORC has: path, projection
    ORDER, and mtime.

    The mtime is covered because the binding declares `SNAPSHOT_PINNED` — "the
    token IS identity" — which is the one conditional in `identity_hash()`. At
    `SNAPSHOT_NONE`, the derived fold would be blind to a re-written file and
    only the kind-supplied value would catch it."""
    var base = SourceVariant(_orc_src(String(GOLDEN_PATH), _proj(0, 2)))
    var other_path = SourceVariant(_orc_src(String("/tmp/other.orc"), _proj(0, 2)))
    var other_order = SourceVariant(_orc_src(String(GOLDEN_PATH), _proj(2, 0)))
    var other_len = SourceVariant(_orc_src(String(GOLDEN_PATH), _proj(0)))
    var other_mtime = SourceVariant(
        _orc_src(String(GOLDEN_PATH), _proj(0, 2), UInt64(99))
    )

    var h = base.binding_ref().identity_hash()
    assert_not_equal(h, other_path.binding_ref().identity_hash(), "path")
    assert_not_equal(h, other_order.binding_ref().identity_hash(), "proj order")
    assert_not_equal(h, other_len.binding_ref().identity_hash(), "proj length")
    assert_not_equal(h, other_mtime.binding_ref().identity_hash(), "mtime")


def test_the_binding_declares_the_axes_it_is_asked_to_declare() raises:
    """`orientation` and `legacy_source_type` are DECLARED, and the
    `ScanData.__init__` ladder reads them instead of testing the tag. If
    either drifts, `source_kind` / `source_type` drift with it and the assertion
    in `test_orc_scan_data_derivation_is_unchanged` is what catches it."""
    var sv = SourceVariant(_orc_src(String(GOLDEN_PATH), _proj()))
    ref b = sv.binding_ref()
    assert_equal(b.orientation, SCAN_ORIENTATION_COLUMNAR)
    assert_equal(b.legacy_source_type, LEGACY_SOURCE_TYPE_ORC)
    assert_equal(b.pushdown_gate.mode, GATE_REJECT_ALL)
    # SNAPSHOT_PINNED, and the token IS the mtime.
    assert_equal(b.snapshot_policy, SNAPSHOT_PINNED)
    assert_equal(b.snapshot_token, UInt64(0))
    var sv7 = SourceVariant(_orc_src(String(GOLDEN_PATH), _proj(), UInt64(7)))
    assert_equal(sv7.binding_ref().snapshot_token, UInt64(7))


def test_the_declared_legacy_source_types_equal_the_plan_layer_constants() raises:
    """THE PIN THE TYPE SYSTEM CANNOT PROVIDE.

    `source_variant.mojo` spells `SOURCE_ORC` / `SOURCE_ARROW` as NUMBERS
    because `logical_plan.mojo` imports it, so importing the plan layer back is
    a cycle — the same constraint that makes `scan_binding.mojo` re-declare
    `SCAN_ORIENTATION_*` instead of importing `SOURCE_KIND_*`. A test file can
    import both, so the equality is checked here or nowhere. If someone
    renumbers a `SOURCE_*` constant, THIS is what goes red — otherwise an ORC
    scan would silently start reporting some other source type."""
    assert_equal(LEGACY_SOURCE_TYPE_ORC, SOURCE_ORC)
    assert_equal(LEGACY_SOURCE_TYPE_ARROW, SOURCE_ARROW)
    # The sentinel must not collide with any real value. 255 vs the plan
    # layer's 0..8.
    assert_true(SCAN_LEGACY_SOURCE_TYPE_NONE > SOURCE_BINDING)


def test_a_kind_with_no_legacy_enum_value_still_yields_source_binding() raises:
    """The ladder collapse must not change what an OPEN kind derives. A kind
    from an upper package leaves `legacy_source_type` at the sentinel and gets
    `SOURCE_BINDING` — "consult `kind_id`"."""
    var b = ScanBinding(
        kind_id=scan_kind_id(String("example.no.legacy.kind")),
        kind_name=String("example.no.legacy.kind"),
        name=String("mytable"),
        params=ScanParams(),
        schema=_schema_abc(),
        fingerprint=UInt64(0xBEEF),
        structural_id=UInt64(0xBEEF),
        gate=PushdownGate.reject_all(),
    )
    assert_equal(b.legacy_source_type, SCAN_LEGACY_SOURCE_TYPE_NONE)
    var sd = ScanData(
        SourceVariant.from_binding(b^),
        Optional[Schema](None),
        Optional[List[String]](None),
        Optional[Expr](None),
    )
    assert_equal(sd.source_type, SOURCE_BINDING)
    assert_equal(sd.source_path, String("mytable"))


# =============================================================================
# SECTION 4 — IS THE DECLARATION AN AUTHORITY, OR ONLY A DEFAULT?
# =============================================================================
#
# For a binding-backed source the DECLARATION DECIDES, and the caller CANNOT
# overrule it. If the parameter's default were `SOURCE_KIND_COLUMNAR` and the
# declaration applied only on that value, "the caller said nothing" and "the
# caller said COLUMNAR" would be the same byte, and the result would be
# incoherent in BOTH directions:
#
#   * a caller stating ROW over a kind that DECLARES COLUMNAR would silently
#     overrule the kind;
#   * a caller stating COLUMNAR over a kind that DECLARES ROW would be silently
#     overruled BY the kind — the caller's explicit argument vanishing.
#
# `orientation` is one of the two values a kind declares about itself;
# `ScanKindRegistry.validate` ALREADY raises when a binding's orientation
# disagrees with its descriptor's, so letting a CALLER disagree silently would
# be two answers to one question. It is also what lets ROW kinds (AVRO, CSV)
# declare `orientation = ROW` instead of relying on an auto-promotion ladder,
# which is only sound if nothing else can decide it.
#
# ⚠ ENFORCEMENT AND DIAGNOSTIC LIVE IN DIFFERENT PLACES, ON PURPOSE.
# `ScanData.__init__` ENFORCES the rule by not reading `source_kind` at all for a
# binding-backed source; `LogicalPlan.scan_from_source` REPORTS a contradiction.
# The ctor must stay non-raising — `ScanData.copy()` reaches it and a deep clone
# cannot fail — and raising from it would force `raises` onto the LEGACY
# `scan()` factory, which can never build a binding-backed variant, and from
# there transitively through every caller.
# `test_the_declaration_is_enforced_even_where_it_is_not_reported` pins the half
# that has no diagnostic, so the split cannot rot into a hole.


def test_an_explicit_source_kind_cannot_contradict_the_kinds_declaration() raises:
    """A caller stating ROW over the ORC kind, which DECLARES COLUMNAR, must
    raise rather than silently discard the declaration.

    This is the direction that matters for correctness: `source_kind` picks the
    execution hierarchy (A columnar vs B row-mode Expr), so a caller who
    overrules a columnar kind into ROW routes an ORC scan at the row executor.
    """
    with assert_raises(contains="DECLARES orientation"):
        var p = LogicalPlan.scan_from_source(
            SourceVariant(_orc_src(String(GOLDEN_PATH), _proj())),
            _schema_abc(),
            source_kind=SOURCE_KIND_ROW,
        )
        _ = p.structural_hash()


def test_a_row_kinds_declaration_is_not_silently_overruled_by_a_caller() raises:
    """The OTHER direction: an explicit `SOURCE_KIND_COLUMNAR` over a kind that
    DECLARES ROW must raise, not be silently dropped in favour of the
    declaration. The explicit value must be DISTINGUISHABLE from the default.

    A ROW-declaring kind is not hypothetical: AVRO and CSV are exactly this, and
    so is an upper package's row source.
    """
    with assert_raises(contains="DECLARES orientation"):
        var p = LogicalPlan.scan_from_source(
            SourceVariant.from_binding(_row_kind_binding()),
            _schema_abc(),
            source_kind=SOURCE_KIND_COLUMNAR,
        )
        _ = p.structural_hash()


def test_the_declaration_is_enforced_even_where_it_is_not_reported() raises:
    """THE ENFORCEMENT AND THE DIAGNOSTIC ARE IN DIFFERENT PLACES, AND THIS PINS
    THE ENFORCEMENT HALF.

    `ScanData.__init__` must stay NON-RAISING — `ScanData.copy()` reaches it and
    a deep clone cannot fail — so the refusal lives in `scan_from_source`. That
    split is only safe if the ctor still makes a contradiction IMPOSSIBLE rather
    than merely undiagnosed. It does: for a binding-backed source the ctor does
    not read `source_kind` at all.

    So the direct-ctor path, which is where the optimizer's rebuild sites live,
    cannot route a scan at the wrong executor even though it cannot complain.
    """
    var sd = ScanData(
        SourceVariant(_orc_src(String(GOLDEN_PATH), _proj())),
        Optional[Schema](None),
        Optional[List[String]](None),
        Optional[Expr](None),
        source_kind=SOURCE_KIND_ROW,
    )
    assert_equal(sd.source_kind, SOURCE_KIND_COLUMNAR)

    var row = ScanData(
        SourceVariant.from_binding(_row_kind_binding()),
        Optional[Schema](None),
        Optional[List[String]](None),
        Optional[Expr](None),
        source_kind=SOURCE_KIND_COLUMNAR,
    )
    assert_equal(row.source_kind, SOURCE_KIND_ROW)


def test_an_unstated_source_kind_derives_the_declaration() raises:
    """The derive path, which is what every caller uses. It guards the
    `SOURCE_KIND_UNSET` default: a sentinel that broke derivation would silently
    route every binding-backed scan at the wrong hierarchy."""
    var orc = ScanData(
        SourceVariant(_orc_src(String(GOLDEN_PATH), _proj())),
        Optional[Schema](None),
        Optional[List[String]](None),
        Optional[Expr](None),
    )
    assert_equal(orc.source_kind, SOURCE_KIND_COLUMNAR)

    var row = ScanData(
        SourceVariant.from_binding(_row_kind_binding()),
        Optional[Schema](None),
        Optional[List[String]](None),
        Optional[Expr](None),
    )
    # DERIVED from the declaration with no caller argument and no ladder arm —
    # this is the property the ROW kinds depend on.
    assert_equal(row.source_kind, SOURCE_KIND_ROW)
    assert_not_equal(SOURCE_KIND_UNSET, SOURCE_KIND_COLUMNAR)
    assert_not_equal(SOURCE_KIND_UNSET, SOURCE_KIND_ROW)


def test_an_agreeing_explicit_source_kind_is_accepted() raises:
    """The refusal is not "the argument is banned". A caller that states what
    the kind declares is agreeing, not contradicting, and must not raise —
    otherwise a rebuild site that faithfully re-threads the value it read off
    the old ScanData would start failing."""
    var p = LogicalPlan.scan_from_source(
        SourceVariant(_orc_src(String(GOLDEN_PATH), _proj())),
        _schema_abc(),
        source_kind=SOURCE_KIND_COLUMNAR,
    )
    assert_equal(p._scan.value()[].source_kind, SOURCE_KIND_COLUMNAR)




# =============================================================================
# SECTION 5 — GOLDENS on `identity_hash()` AND the rendered plan text.
# =============================================================================
#
# Every scan kind carries a golden on `identity_hash()` (`bid=`) AND on the
# rendered plan text. The other goldens in this file pin `fingerprint` /
# `structural_id` — the kind-SUPPLIED values. Neither is the part core DERIVES,
# and the derived part is half of what the plan-compile cache keys on.
#
# THE FIXTURE VARIES THE PROJECTION ON PURPOSE: `proj=[0,2]` with a non-zero
# mtime puts both of ORC's identity inputs (the order-sensitive projection
# params and the PINNED mtime token) inside the one string that IS the key.

comptime GOLDEN_FP_MTIME_1234567890_PROJ_02: UInt64 = 9952905095515662865
"""`OrcSource.fingerprint()` for (GOLDEN_PATH, mtime=1234567890, proj=[0,2]),
from the same independent Python FNV-1a reference as the four literals above —
which reproduces all four of them, plus the arrow / avro / broker `bid` goldens."""

comptime ORC_BID_PROJ_02_MTIME_1234567890: UInt64 = 8166241870439200987
"""`identity_hash()` of the ORC binding for (GOLDEN_PATH, proj=[0,2],
mtime=1234567890, EMPTY schema), from an INDEPENDENT Python transcription of
`param_hash_*` + `schema_identity_hash` + `PushdownGate.hash_into` — not lifted
from our own output. The reference was validated first by reproducing the other
kinds' `identity_hash` literals (arrow, avro, broker).

⚠ THE MTIME IS IN THIS VALUE AND SO IS THE PROJECTION. `snapshot_policy` is
`SNAPSHOT_PINNED`, so `identity_hash` folds the token; the projection arrives as
the `projection.0` / `projection.1` params. If this literal ever has to move,
every ORC plan-compile cache key moved with it — do not "fix" the number."""


def _golden_orc_binding() -> ScanBinding:
    """Built through the PRODUCTION path — `SourceVariant`'s own constructor —
    so the golden cannot drift from what a plan actually carries.

    The schema is EMPTY, matching the arrow / avro / broker goldens: `schema` is
    not an input `OrcSource.fingerprint()` folds, and the independent reference
    computes `schema_identity_hash(Schema())` in closed form."""
    return SourceVariant(
        OrcSource(
            String(GOLDEN_PATH), Schema(), _proj(0, 2), mtime_ns=UInt64(1234567890)
        )
    ).binding_ref().copy()


def test_golden_fingerprint_orc_proj_02_mtime() raises:
    """The fingerprint pin for the fixture the two goldens below use. Pinned separately so
    a `bsid=` drift and a `bid=` drift are distinguishable."""
    assert_equal(
        _golden_orc_binding().fingerprint, GOLDEN_FP_MTIME_1234567890_PROJ_02
    )


def test_golden_identity_hash_orc() raises:
    """The golden on ORC's DERIVED identity."""
    assert_equal(
        _golden_orc_binding().identity_hash(), ORC_BID_PROJ_02_MTIME_1234567890
    )


def test_golden_rendered_plan_text_orc() raises:
    """THE RENDERED PLAN TEXT, pinned whole. `LogicalPlan.structural_hash()` is
    FNV-1a over exactly this string and
    `EngineContext` uses it as `factory_hash`, so this line IS the plan-compile
    cache key — an unreviewed change to it silently repartitions every cache.

    ASSEMBLED, NOT TRANSCRIBED: built from the independently-derived literals
    plus the field order `plan_display.mojo` declares, so a changed VALUE
    and a changed FORMAT are separately red and neither pin is circular.

    ⚠ THE `projection.0=0, projection.1=2` PAIR IS THE SEAM IN ONE LINE. If the
    projection reached only the kind's own fingerprint and NOT this text,
    `[0,2]` and `[2,0]` would share a cache key
    (`test_two_projections_of_one_orc_file_do_not_share_a_plan_cache_key`).
    Sorted-key order is `path` < `projection.0` < `projection.1`, and that order
    is `ScanParams`' stated contract, not an accident of insertion.
    """
    var expected = String('Scan(path="') + String(GOLDEN_PATH) + String('"')
    expected += String(", type=ORC")
    expected += String(", binding=") + String(SCAN_KIND_NAME_ORC)
    expected += String("(") + String(GOLDEN_PATH)
    expected += String(", path=") + String(GOLDEN_PATH)
    expected += String(", projection.0=0, projection.1=2)")
    # `bsid` is the KIND-supplied identity (== fingerprint for a file source);
    # `bid` is CORE's derived one. Both are emitted because neither subsumes the
    # other — see `plan_display.mojo` "WHY THREE VALUES AND NOT ONE".
    expected += String(", bsid=") + String(GOLDEN_FP_MTIME_1234567890_PROJ_02)
    expected += String(", bid=") + String(ORC_BID_PROJ_02_MTIME_1234567890)
    expected += String(", source_kind=COLUMNAR)")

    var rendered = String(
        LogicalPlan.scan_from_source(
            SourceVariant(
                OrcSource(
                    String(GOLDEN_PATH),
                    Schema(),
                    _proj(0, 2),
                    mtime_ns=UInt64(1234567890),
                )
            ),
            Schema(),
        )
    )
    assert_equal(rendered.strip(), expected)


def main() raises:
    var suite = TestSuite()
    suite.test[test_orc_fingerprint_matches_the_independent_reference]()
    suite.test[test_migrated_orc_arm_preserves_the_fingerprint_byte_for_byte]()
    suite.test[test_orc_arm_keeps_its_legacy_tag_and_kind_name]()
    suite.test[test_orc_accessors_answer_the_same_values]()
    suite.test[test_orc_copy_preserves_identity_byte_for_byte]()
    suite.test[test_orc_projection_stays_order_sensitive]()
    suite.test[test_orc_scan_data_derivation_is_unchanged]()
    suite.test[test_orc_plan_still_labels_itself_orc_in_explain]()
    suite.test[test_orc_plan_survives_a_plan_copy]()
    suite.test[test_two_projections_of_one_orc_file_do_not_share_a_plan_cache_key]()
    suite.test[test_two_mtimes_of_one_orc_file_do_not_share_a_plan_cache_key]()
    suite.test[test_orc_is_binding_backed_and_carries_the_orc_kind]()
    suite.test[test_orc_params_are_exactly_what_the_kind_has]()
    suite.test[test_the_derived_identity_covers_every_param_the_kind_has]()
    suite.test[test_the_binding_declares_the_axes_it_is_asked_to_declare]()
    suite.test[test_the_declared_legacy_source_types_equal_the_plan_layer_constants]()
    suite.test[test_a_kind_with_no_legacy_enum_value_still_yields_source_binding]()
    suite.test[test_an_explicit_source_kind_cannot_contradict_the_kinds_declaration]()
    suite.test[test_a_row_kinds_declaration_is_not_silently_overruled_by_a_caller]()
    suite.test[test_the_declaration_is_enforced_even_where_it_is_not_reported]()
    suite.test[test_an_unstated_source_kind_derives_the_declaration]()
    suite.test[test_an_agreeing_explicit_source_kind_is_accepted]()
    suite.test[test_golden_fingerprint_orc_proj_02_mtime]()
    suite.test[test_golden_identity_hash_orc]()
    suite.test[test_golden_rendered_plan_text_orc]()
    suite^.run()
