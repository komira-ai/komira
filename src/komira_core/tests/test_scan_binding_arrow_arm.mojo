# =============================================================================
# The three ARROW source arms, carried by `ScanBinding`.
# =============================================================================
#
# The three arrow arms are three TAGS over ONE `ArrowSource` carrier that differ
# only by codec, so the binding carries them as ONE `kind_id` plus a `codec`
# param. Every hard axis is off for this kind except the snapshot: gate =
# REJECT_ALL, orientation = COLUMNAR, snapshot = PINNED on the file mtime.
#
# =============================================================================
# THE FINGERPRINT PINS
# =============================================================================
#
# The quiet failure mode of a scan-identity change is NOT a wrong answer. It is
# a fingerprint whose VALUE drifts: nothing fails, plans just recompile forever
# and every cross-run cache misses. So this file pins the arrow fingerprint
# TWICE over:
#
#   1. Against `ArrowSource.fingerprint()` — the carrier's own value.
#   2. Against a GOLDEN LITERAL computed from an independent Python reference
#      (FNV-1a/64 of the path bytes, then combined with the mtime), so the pin
#      cannot silently follow a change in our own code.
#
# =============================================================================
# THE SCAN LABEL
# =============================================================================
#
# `ScanData.__init__`'s derivation ladder must give an arrow scan
# `source_type == SOURCE_ARROW` and its real path. Without an ARROW arm the
# tags fall into the ladder's `else`, which yields `derived_path = ""` and
# `derived_type = SOURCE_PARQUET` — an Arrow scan labelled a PARQUET scan with
# an empty path, and `source_type == SOURCE_PARQUET` is what several optimizer
# passes key on. `test_arrow_scan_is_not_labelled_parquet` pins it.
# =============================================================================

from std.testing import (
    TestSuite,
    assert_equal,
    assert_true,
    assert_false,
    assert_not_equal,
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
    SOURCE_PARQUET,
)
from komira_core.plan.logical_plan_variants import (
    ScanData,
    SOURCE_KIND_COLUMNAR,
)
from komira_core.source.arrow_source import ArrowSource
from komira_core.source.pushdown_gate import GATE_REJECT_ALL, PushdownGate
from komira_core.source.scan_params import ScanParams
from komira_core.source.scan_binding import (
    ScanBinding,
    scan_kind_id,
    SCAN_KIND_NAME_ARROW_IPC,
    SNAPSHOT_NONE,
    SNAPSHOT_PINNED,
    SCAN_ORIENTATION_COLUMNAR,
)
from komira_core.source.source_variant import (
    SourceVariant,
    SOURCE_VARIANT_ARROW_UNCOMPRESSED,
    SOURCE_VARIANT_ARROW_LZ4_FRAME,
    SOURCE_VARIANT_ARROW_ZSTD,
    SOURCE_VARIANT_BINDING,
)


comptime GOLDEN_PATH: String = "/tmp/golden_arrow_fp.arrow"
comptime GOLDEN_FP_MTIME_0: UInt64 = 15012656508847213963
comptime GOLDEN_FP_MTIME_1234567890: UInt64 = 7086693336528161761


def _schema_ab() -> Schema:
    var sb = SchemaBuilder()
    sb.add_field(Field("a", ArrowType.INT64, nullable=False))
    sb.add_field(Field("b", ArrowType.STRING, nullable=True))
    return sb.build()


def _arrow_src(var path: String, mtime: UInt64 = 0, rows: Int = -1) -> ArrowSource:
    return ArrowSource(path^, _schema_ab(), mtime_ns=mtime, estimated_rows=rows)


# =============================================================================
# GOLDEN: the fingerprint VALUE did not move.
# =============================================================================


def test_arrow_fingerprint_matches_the_independent_reference() raises:
    """PIN 2 — an independent Python FNV-1a/64 reference, not our own output.

    `ArrowSource.fingerprint()` is `fnv1a64(path)` combined with `mtime_ns`.
    If this literal ever has to change, a cache key changed and the change is
    load-bearing."""
    assert_equal(_arrow_src(String(GOLDEN_PATH)).fingerprint(), GOLDEN_FP_MTIME_0)
    assert_equal(
        _arrow_src(String(GOLDEN_PATH), UInt64(1234567890)).fingerprint(),
        GOLDEN_FP_MTIME_1234567890,
    )


def test_migrated_arrow_arms_preserve_the_fingerprint_byte_for_byte() raises:
    """PIN 1 — the values must stay EQUAL TO THE CARRIER'S, not merely stay
    distinct. A drift here invalidates every plan-cache key with nothing going
    red."""
    var uc = SourceVariant.from_arrow_uncompressed(_arrow_src(String(GOLDEN_PATH)))
    var lz4 = SourceVariant.from_arrow_lz4_frame(_arrow_src(String(GOLDEN_PATH)))
    var zstd = SourceVariant.from_arrow_zstd(_arrow_src(String(GOLDEN_PATH)))
    assert_equal(uc.fingerprint(), GOLDEN_FP_MTIME_0)
    assert_equal(lz4.fingerprint(), GOLDEN_FP_MTIME_0)
    assert_equal(zstd.fingerprint(), GOLDEN_FP_MTIME_0)
    # structural_id for a file source IS its fingerprint (only IN_MEMORY
    # differs).
    assert_equal(uc.structural_id(), GOLDEN_FP_MTIME_0)


def test_migrated_arrow_arms_keep_their_legacy_tags() raises:
    """The three arrow tag VALUES are stable, so code that switches on them
    keeps working. `tag` is the legacy discriminant; `_binding` is the payload
    for every binding-backed arm."""
    assert_equal(
        SourceVariant.from_arrow_uncompressed(_arrow_src(String("/x.arrow"))).tag,
        SOURCE_VARIANT_ARROW_UNCOMPRESSED,
    )
    assert_equal(
        SourceVariant.from_arrow_lz4_frame(_arrow_src(String("/x.arrow"))).tag,
        SOURCE_VARIANT_ARROW_LZ4_FRAME,
    )
    assert_equal(
        SourceVariant.from_arrow_zstd(_arrow_src(String("/x.arrow"))).tag,
        SOURCE_VARIANT_ARROW_ZSTD,
    )


def test_three_arms_collapse_to_one_kind_plus_a_codec_param() raises:
    """THE PARAMS THESIS, proven on the cheapest ground. Three union arms over
    ONE carrier become ONE `kind_id` plus a `codec` param — which is exactly
    what a new source kind gets to do without editing core."""
    var uc = SourceVariant.from_arrow_uncompressed(_arrow_src(String("/x.arrow")))
    var lz4 = SourceVariant.from_arrow_lz4_frame(_arrow_src(String("/x.arrow")))
    var zstd = SourceVariant.from_arrow_zstd(_arrow_src(String("/x.arrow")))

    var kid = scan_kind_id(String(SCAN_KIND_NAME_ARROW_IPC))
    assert_equal(uc.binding_ref().kind_id, kid)
    assert_equal(lz4.binding_ref().kind_id, kid)
    assert_equal(zstd.binding_ref().kind_id, kid)

    assert_equal(
        uc.binding_ref().params.get_str(String("codec")), String("uncompressed")
    )
    assert_equal(
        lz4.binding_ref().params.get_str(String("codec")), String("lz4_frame")
    )
    assert_equal(zstd.binding_ref().params.get_str(String("codec")), String("zstd"))
    assert_equal(uc.binding_ref().params.get_str(String("path")), String("/x.arrow"))


def test_arrow_binding_declares_the_axes_the_design_said_were_off() raises:
    """The arrow kind's axes: gate = REJECT_ALL, orientation = COLUMNAR, and
    snapshot = PINNED.

    The snapshot axis is NOT off: `ArrowSource.fingerprint()` folds
    `_mtime_ns`, so the mtime is part of this kind's identity, and it must
    reach core's derived `identity_hash()` too — otherwise two arrow scans of
    one path at different mtimes share a plan-compile cache key. The
    declaration is `SNAPSHOT_PINNED` with `_mtime_ns` as the token. The audit
    that enforces it for EVERY kind is
    `komira_core/source/scan_identity_audit.mojo`; `komira_broker`'s
    scan-identity coverage test is its falsifier.
    """
    var b = SourceVariant.from_arrow_uncompressed(
        _arrow_src(String("/x.arrow"), UInt64(4242))
    ).binding_ref().copy()
    assert_equal(b.pushdown_gate.mode, GATE_REJECT_ALL)
    assert_equal(b.orientation, SCAN_ORIENTATION_COLUMNAR)
    assert_not_equal(b.snapshot_policy, SNAPSHOT_NONE)
    assert_equal(b.snapshot_policy, SNAPSHOT_PINNED)
    assert_equal(b.snapshot_token, UInt64(4242))


def test_arrow_accessors_answer_from_data_not_from_a_source() raises:
    """schema / estimate_rows / supports_filter_pushdown / kind_name all still
    answer, and now answer out of the binding — no `ArrowSource` is reachable
    from the plan node."""
    var sv = SourceVariant.from_arrow_lz4_frame(
        _arrow_src(String("/x.arrow"), UInt64(0), 77)
    )
    assert_equal(sv.schema().num_columns(), 2)
    assert_equal(sv.schema().field_name(0), String("a"))
    assert_equal(sv.estimate_rows(), 77)
    assert_equal(sv.kind_name(), String("arrow[lz4_frame]"))
    # Arrow IPC has no decode-time pruning — `ArrowSource
    # .supports_filter_pushdown` returned False for every predicate, and
    # GATE_REJECT_ALL reproduces that exactly.
    var pred = Expr.binary(
        BIN_EQ, Expr.col_ref("a"), Expr.literal(ScalarValue.from_int(1))
    )
    assert_false(sv.supports_filter_pushdown(pred))


def test_arrow_copy_round_trips_through_the_binding() raises:
    var sv = SourceVariant.from_arrow_zstd(
        _arrow_src(String(GOLDEN_PATH), UInt64(1234567890), 5)
    )
    var c = sv.copy()
    assert_equal(c.tag, SOURCE_VARIANT_ARROW_ZSTD)
    assert_equal(c.fingerprint(), GOLDEN_FP_MTIME_1234567890)
    assert_equal(c.estimate_rows(), 5)
    assert_equal(c.schema().num_columns(), 2)
    assert_equal(c.binding_ref().params.get_str(String("codec")), String("zstd"))


def test_structural_id_reads_the_binding_field_not_the_fingerprint() raises:
    """`SourceVariant.structural_id()` must read the binding's own field, not
    fall through to `fingerprint()`.

    For arrow the two are equal, so a fall-through would be invisible here. A
    kind with a CONTENT hash (the reason `structural_id` exists as a concept
    distinct from `fingerprint`) would then silently get a per-construction id
    where a content id is required, breaking CSE of a self-join over it.

    This asserts the two are read from DIFFERENT places by constructing a
    binding where they DISAGREE — the only way to catch the fall-through
    before a real kind depends on it.
    """
    var b = ScanBinding(
        kind_id=scan_kind_id(String("example.content.kind")),
        kind_name=String("example.content.kind"),
        name=String("t"),
        params=ScanParams(),
        schema=_schema_ab(),
        fingerprint=UInt64(0x1111),
        structural_id=UInt64(0x2222),
        gate=PushdownGate.reject_all(),
    )
    var sv = SourceVariant.from_binding(b^)
    assert_equal(sv.fingerprint(), UInt64(0x1111))
    assert_equal(sv.structural_id(), UInt64(0x2222))
    assert_not_equal(sv.structural_id(), sv.fingerprint())


def test_distinct_arrow_paths_stay_distinct() raises:
    var a = SourceVariant.from_arrow_uncompressed(_arrow_src(String("/a.arrow")))
    var b = SourceVariant.from_arrow_uncompressed(_arrow_src(String("/b.arrow")))
    assert_not_equal(a.fingerprint(), b.fingerprint())


# =============================================================================
# THE SCAN LABEL.
# =============================================================================


def test_arrow_scan_is_not_labelled_parquet() raises:
    """`ScanData.__init__`'s ladder needs an ARROW arm: without it the three
    arrow tags fall into `else: derived_path = ""; derived_type =
    SOURCE_PARQUET` — an Arrow scan wearing a Parquet label and an empty path,
    which is what several optimizer passes key on.
    """
    var sd = ScanData(
        SourceVariant.from_arrow_uncompressed(_arrow_src(String(GOLDEN_PATH))),
        Optional[Schema](None),
        Optional[List[String]](None),
        Optional[Expr](None),
    )
    assert_not_equal(sd.source_type, SOURCE_PARQUET)
    assert_equal(sd.source_type, SOURCE_ARROW)
    assert_equal(sd.source_path, String(GOLDEN_PATH))
    assert_equal(sd.source_kind, SOURCE_KIND_COLUMNAR)


def test_two_codecs_over_one_path_do_not_share_a_plan_cache_key() raises:
    """Two codecs over one path must render, and hash, differently.

    `test_migrated_arrow_arms_preserve_the_fingerprint_byte_for_byte` above
    asserts, correctly, that all three codecs over one path carry the SAME
    `fingerprint` AND the same `structural_id` (`GOLDEN_FP_MTIME_0` three
    times) — the codec lives in a PARAM, which is the whole params thesis. But
    if `_write_plan_node` emitted neither the params nor a type name, an
    UNCOMPRESSED arrow scan and a ZSTD arrow scan of the same path would render
    the same text and hash the same. The engine keys its compiled-plan cache on
    `plan.structural_hash()`, so the plan compiled for one decoder would be
    returned for the other.

    ⚠ EMITTING `structural_id` WOULD NOT BE ENOUGH: the two bindings'
    `structural_id`s are asserted EQUAL right here.
    Only core's derived `identity_hash()` — which folds `params` — separates
    them.
    """
    var uc = LogicalPlan.scan_from_source(
        SourceVariant.from_arrow_uncompressed(_arrow_src(String(GOLDEN_PATH))),
        _schema_ab(),
    )
    var zstd = LogicalPlan.scan_from_source(
        SourceVariant.from_arrow_zstd(_arrow_src(String(GOLDEN_PATH))),
        _schema_ab(),
    )
    # The precondition: the kind-SUPPLIED identity does not discriminate.
    assert_equal(
        uc._scan.value()[].source.structural_id(),
        zstd._scan.value()[].source.structural_id(),
    )
    assert_equal(uc._scan.value()[].source_path, zstd._scan.value()[].source_path)
    assert_not_equal(
        uc.structural_hash(),
        zstd.structural_hash(),
        "uncompressed and zstd arrow scans of one path share a plan-compile"
        " cache key; rendered as: " + String(uc),
    )


def test_explain_labels_an_arrow_scan_and_names_its_codec() raises:
    """`_source_type_name` needs a `SOURCE_ARROW` arm, or every arrow scan
    prints `type=UNKNOWN`."""
    var rendered = String(
        LogicalPlan.scan_from_source(
            SourceVariant.from_arrow_lz4_frame(_arrow_src(String(GOLDEN_PATH))),
            _schema_ab(),
        )
    )
    assert_true("type=ARROW" in rendered, "got: " + rendered)
    assert_false("type=UNKNOWN" in rendered, "got: " + rendered)
    assert_true("codec=lz4_frame" in rendered, "got: " + rendered)


def test_arrow_scan_survives_a_plan_copy() raises:
    """A plan clone must preserve the scan's identity. The derived
    caches must survive it — they are re-derived from the binding, so a drift
    would show up here rather than three optimizer passes later."""
    var plan = LogicalPlan.scan_from_source(
        SourceVariant.from_arrow_zstd(_arrow_src(String(GOLDEN_PATH), UInt64(7), 3)),
        _schema_ab(),
    )
    var c = plan.copy()
    assert_true(Bool(c._scan))
    assert_equal(c._scan.value()[].source_type, SOURCE_ARROW)
    assert_equal(c._scan.value()[].source_path, String(GOLDEN_PATH))
    assert_equal(c._scan.value()[].source.fingerprint(), plan._scan.value()[].source.fingerprint())
    assert_equal(c.structural_hash(), plan.structural_hash())


# =============================================================================
# THE OPEN ARM — tag 9, for a kind core has never heard of.
# =============================================================================


def test_binding_arm_carries_an_unknown_kind_end_to_end() raises:
    """`SOURCE_VARIANT_BINDING` is the OPEN door: a kind whose name core has
    never seen still gets a schema, a fingerprint, EXPLAIN rendering and a
    pushdown answer."""
    var b = ScanBinding(
        kind_id=scan_kind_id(String("example.unknown.kind")),
        kind_name=String("example.unknown.kind"),
        name=String("mytable"),
        params=ScanParams(),
        schema=_schema_ab(),
        fingerprint=UInt64(0xFEED),
        structural_id=UInt64(0xFEED),
        gate=PushdownGate.reject_all(),
    )
    var sv = SourceVariant.from_binding(b^)
    assert_equal(sv.tag, SOURCE_VARIANT_BINDING)
    assert_equal(sv.fingerprint(), UInt64(0xFEED))
    assert_equal(sv.kind_name(), String("example.unknown.kind"))
    assert_equal(sv.schema().num_columns(), 2)

    var sd = ScanData(
        sv^,
        Optional[Schema](None),
        Optional[List[String]](None),
        Optional[Expr](None),
    )
    assert_equal(sd.source_path, String("mytable"))
    assert_equal(sd.source_kind, SOURCE_KIND_COLUMNAR)


def main() raises:
    var suite = TestSuite()
    suite.test[test_arrow_fingerprint_matches_the_independent_reference]()
    suite.test[test_migrated_arrow_arms_preserve_the_fingerprint_byte_for_byte]()
    suite.test[test_migrated_arrow_arms_keep_their_legacy_tags]()
    suite.test[test_three_arms_collapse_to_one_kind_plus_a_codec_param]()
    suite.test[test_arrow_binding_declares_the_axes_the_design_said_were_off]()
    suite.test[test_arrow_accessors_answer_from_data_not_from_a_source]()
    suite.test[test_arrow_copy_round_trips_through_the_binding]()
    suite.test[test_distinct_arrow_paths_stay_distinct]()
    suite.test[test_structural_id_reads_the_binding_field_not_the_fingerprint]()
    suite.test[test_arrow_scan_is_not_labelled_parquet]()
    suite.test[test_two_codecs_over_one_path_do_not_share_a_plan_cache_key]()
    suite.test[test_explain_labels_an_arrow_scan_and_names_its_codec]()
    suite.test[test_arrow_scan_survives_a_plan_copy]()
    suite.test[test_binding_arm_carries_an_unknown_kind_end_to_end]()
    suite^.run()
