# =============================================================================
# The CSV source arm, carried by `ScanBinding`.
# =============================================================================
#
# ORIENTATION. The CSV kind declares `SCAN_ORIENTATION_ROW`: orientation is
# intrinsic to the source FORMAT, and CSV is a ROW source. Everything that runs
# agrees — `LogicalPlan.scan(path, SOURCE_CSV, ...)` (the factory behind
# `ctx.read_csv`), both row-streaming path walkers, and the typed
# `CsvSource[FS]` conformer (`orientation = ROW()`). `ScanData.__init__` reads
# the declaration; there is no auto-promotion ladder keyed on the source type.
#
# =============================================================================
# THE THREE IDENTITY PROPERTIES THIS FILE PINS
# =============================================================================
#
# (1) THE DIALECT. Two CSV scans of ONE path parsed under GENUINELY DIFFERENT
#     DECODERS (RFC4180 vs Posix quoting) have DIFFERENT
#     `CsvSource.fingerprint()`s, and must have different
#     `LogicalPlan.structural_hash()`es too, or they share a plan-compile cache
#     key. `quote_style_tag` (and the `delimiter` / `has_header` options) are
#     therefore PARAMS of the binding. `QUOTE_COLLISION_*` below pins the pair.
#
# (2) THE LABEL. `ScanData.__init__` must label a CSV scan `SOURCE_CSV` with
#     its real path. Without a CSV arm the tag falls into the ladder's `else`,
#     and every CSV scan comes out labelled SOURCE_PARQUET with an EMPTY path —
#     so every CSV scan renders the same plan line and shares ONE plan-compile
#     cache key regardless of path, mtime or dialect, which also hides (1) and
#     (3).
#
# (3) THE MTIME. `CsvSource.fingerprint()` folds `_mtime_ns`; the plan text must
#     too, or two scans of one path across a file rewrite share a plan-compile
#     cache key. The binding declares `SNAPSHOT_PINNED` with the mtime as the
#     token.
#
# `fingerprint` and `structural_id` are pinned byte-identical below against an
# independently-derived literal.
# =============================================================================

from std.testing import (
    TestSuite,
    assert_equal,
    assert_true,
    assert_false,
    assert_not_equal,
    assert_raises,
)

from komira_arrow.arrow_types import ArrowType
from komira_arrow.schema import Field, Schema, SchemaBuilder
from komira_plan_expr.expr import Expr, ScalarValue, BIN_EQ
from komira_buffer.file_identity import set_file_mtime_ns
from komira_plan_ir.logical_plan import (
    LogicalPlan,
    derive_source_layout,
    SOURCE_BINDING,
    SOURCE_CSV,
    SOURCE_PARQUET,
)
from komira_plan_ir.logical_plan_variants import (
    ScanData,
    SOURCE_KIND_COLUMNAR,
    SOURCE_KIND_ROW,
    SOURCE_KIND_UNSET,
)
from komira_scan_source.csv_source import (
    CsvSource,
    CSV_DEFAULT_DELIMITER,
    CSV_DEFAULT_HAS_HEADER,
)
from komira_scan_source.pushdown_gate import GATE_REJECT_ALL, PushdownGate
from komira_scan_source.scan_binding import (
    ScanBinding,
    scan_kind_id,
    SCAN_KIND_NAME_CSV,
    SCAN_LEGACY_SOURCE_TYPE_NONE,
    SCAN_ORIENTATION_COLUMNAR,
    SCAN_ORIENTATION_ROW,
    SNAPSHOT_PINNED,
)
from komira_scan_source.scan_kind_registry import (
    ScanKindDescriptor,
    ScanKindRegistry,
)
from komira_scan_source.source_variant import (
    SourceVariant,
    SOURCE_VARIANT_CSV,
    LEGACY_SOURCE_TYPE_CSV,
    csv_scan_descriptor,
)


# =============================================================================
# GOLDEN LITERALS — an INDEPENDENT reference, not our own output.
# =============================================================================
#
# `CsvSource.__init__` computes:
#
#   h = FNV1A64_OFFSET
#   h = combine(h, len(path))
#   h = combine(h, fnv1a64(path))
#   h = combine(h, mtime_ns)
#   h = combine(h, quote_style_tag)      <- the term AvroSource does not have
#   h = combine(h, delimiter)
#   h = combine(h, 1 if has_header else 0)
#
# with combine(a, b) = (a ^ b) * FNV1A64_PRIME. It is the AVRO fold plus THREE
# dialect terms; transcribing the avro one for it is the mistake this pin exists
# to catch. `delimiter` and `has_header` are in the fold because two `read_csv`
# calls differing only in those options must not share a plan-compile cache key.
#
# These literals came from a standalone Python implementation of that spec,
# validated first by reproducing the other kinds' goldens (the `scan_kind_id`s,
# the ORC / AVRO / ARROW fingerprints and `bid=` goldens) before being used for
# any number below.
comptime GOLDEN_PATH: String = "/tmp/golden_csv_fp.csv"
comptime GOLDEN_FP_MTIME_0_Q0: UInt64 = 9865858099588087401
comptime GOLDEN_FP_MTIME_1234567890_Q0: UInt64 = 15403575544779683767
comptime GOLDEN_FP_MTIME_1234567890_Q2: UInt64 = 16583032663162278277

comptime GOLDEN_FP_MTIME_1234567890_Q0_PIPE: UInt64 = 15357659939194675207
"""The q=0 baseline with `delimiter = '|'` (124) — one term away."""

comptime GOLDEN_FP_MTIME_1234567890_Q0_NOHDR: UInt64 = 15403574445268055556
"""The q=0 baseline with `has_header = False` — one term away."""

comptime CSV_KIND_ID: UInt32 = 2103513342
"""`scan_kind_id("komira.csv")`, from the same reference."""

comptime CSV_BID_Q0_MTIME_1234567890: UInt64 = 16808591791830715772
"""`identity_hash()` of the csv binding for (GOLDEN_PATH, mtime=1234567890,
quote_style_tag=0, default dialect, empty schema). Derived independently; see the
note above."""

comptime CSV_BID_Q2_MTIME_1234567890: UInt64 = 1339002815895478814
"""The same binding with `quote_style_tag=2` (Posix). It differs from
`CSV_BID_Q0_MTIME_1234567890` ONLY because `quote_style_tag` is a PARAM — that
is property (1), pinned as a pair of numbers rather than only as an
inequality."""

comptime CSV_BID_Q0_MTIME_1234567890_PIPE: UInt64 = 13362953142101868588
"""The q=0 binding with `delimiter = '|'`. The dialect pair, as a number."""

comptime CSV_BID_Q0_MTIME_1234567890_NOHDR: UInt64 = 13919455049516436239
"""The q=0 binding with `has_header = False`. The dialect pair, as a number."""

# The collision pair for this arm: path "/t/x.csv", mtime 0, quote styles 0
# and 2, under the live fold.
comptime QUOTE_COLLISION_PATH: String = "/t/x.csv"
comptime QUOTE_COLLISION_FP_Q0: UInt64 = 11011340878414409327
"""The LIVE fold's value at (path="/t/x.csv", mtime=0, q=0, default dialect).
⚠ Not the same fixture as the corpus `baseline`, which is "/t/a.csv"."""
comptime QUOTE_COLLISION_FP_Q2: UInt64 = 12313239611690359997
"""The LIVE fold's value at q=2, same path/mtime/dialect."""


def _schema_abc() -> Schema:
    var sb = SchemaBuilder()
    sb.add_field(Field("a", ArrowType.INT64, nullable=False))
    sb.add_field(Field("b", ArrowType.INT64, nullable=True))
    sb.add_field(Field("c", ArrowType.STRING, nullable=True))
    return sb.build()


def _csv_src(
    var path: String, mtime: UInt64 = 0, quote_style_tag: Int = 0
) -> CsvSource:
    return CsvSource(
        path^, _schema_abc(), mtime_ns=mtime, quote_style_tag=quote_style_tag
    )


# =============================================================================
# SECTION 1 — the fingerprint pins.
# =============================================================================


def test_csv_fingerprint_matches_the_independent_reference() raises:
    """PIN 1 — the golden literals, against an independent Python FNV-1a
    reference over the documented fold, so the pin cannot silently follow a
    change in our own hash code."""
    assert_equal(_csv_src(String(GOLDEN_PATH)).fingerprint(), GOLDEN_FP_MTIME_0_Q0)
    assert_equal(
        _csv_src(String(GOLDEN_PATH), UInt64(1234567890)).fingerprint(),
        GOLDEN_FP_MTIME_1234567890_Q0,
    )
    assert_equal(
        _csv_src(
            String(GOLDEN_PATH), UInt64(1234567890), quote_style_tag=2
        ).fingerprint(),
        GOLDEN_FP_MTIME_1234567890_Q2,
    )


def test_the_audit_headers_measured_collision_pair_is_reproduced() raises:
    """PIN 2 — the quote-style collision pair for THIS arm (path "/t/x.csv",
    mtime 0, quote styles 0 and 2), distinct and pinned as a PAIR of numbers
    from the independent reference."""
    assert_equal(
        _csv_src(String(QUOTE_COLLISION_PATH)).fingerprint(), QUOTE_COLLISION_FP_Q0
    )
    assert_equal(
        _csv_src(String(QUOTE_COLLISION_PATH), quote_style_tag=2).fingerprint(),
        QUOTE_COLLISION_FP_Q2,
    )


def test_migrated_csv_arm_preserves_the_fingerprint_byte_for_byte() raises:
    """PIN 3 — the arm's values must stay EQUAL TO THE CARRIER'S, not merely
    stay distinct. A drift here invalidates every CSV plan-cache key with
    nothing going red."""
    var sv = SourceVariant(_csv_src(String(GOLDEN_PATH)))
    assert_equal(sv.fingerprint(), GOLDEN_FP_MTIME_0_Q0)
    # `structural_id` for a file-path source IS its fingerprint (only IN_MEMORY
    # differs).
    assert_equal(sv.structural_id(), GOLDEN_FP_MTIME_0_Q0)

    var sv_q2 = SourceVariant(
        _csv_src(String(GOLDEN_PATH), UInt64(1234567890), quote_style_tag=2)
    )
    assert_equal(sv_q2.fingerprint(), GOLDEN_FP_MTIME_1234567890_Q2)
    assert_equal(sv_q2.structural_id(), GOLDEN_FP_MTIME_1234567890_Q2)


def test_csv_arm_keeps_its_legacy_tag_and_kind_name() raises:
    """The CSV tag VALUE and kind name are stable, so every caller and test
    that reads `tag` (for example, one asserting `sv.tag == SOURCE_VARIANT_CSV`
    and `kind_name() == "csv"`) keeps working."""
    var sv = SourceVariant(_csv_src(String(GOLDEN_PATH)))
    assert_equal(sv.tag, SOURCE_VARIANT_CSV)
    assert_equal(sv.kind_name(), String("csv"))


def test_csv_accessors_answer_the_same_values() raises:
    """Schema / estimate_rows / supports_filter_pushdown are unchanged. CSV has
    no equivalent of Parquet's row-group zonemap (`CsvSource` returns False for
    EVERY predicate), which `GATE_REJECT_ALL` declares instead of
    implementing."""
    var sv = SourceVariant(_csv_src(String(GOLDEN_PATH)))
    assert_equal(sv.schema().num_columns(), 3)
    assert_equal(sv.schema().field_name(0), String("a"))
    assert_equal(sv.schema().field_name(2), String("c"))
    # -1 == unknown without a full file scan, so no `estimated_rows` param is
    # invented for this kind.
    assert_equal(sv.estimate_rows(), -1)
    var pred = Expr.binary(
        BIN_EQ, Expr.col_ref("a"), Expr.literal(ScalarValue.from_int(1))
    )
    assert_false(sv.supports_filter_pushdown(pred))


def test_csv_copy_preserves_identity_byte_for_byte() raises:
    var sv = SourceVariant(
        _csv_src(String(GOLDEN_PATH), UInt64(1234567890), quote_style_tag=2)
    )
    var c = sv.copy()
    assert_equal(c.tag, SOURCE_VARIANT_CSV)
    assert_equal(c.fingerprint(), GOLDEN_FP_MTIME_1234567890_Q2)
    assert_equal(c.structural_id(), GOLDEN_FP_MTIME_1234567890_Q2)
    assert_equal(c.schema().num_columns(), 3)
    assert_equal(c.kind_name(), String("csv"))


# =============================================================================
# SECTION 2 — THE THREE IDENTITY PROPERTIES.
# =============================================================================


def test_two_quote_styles_over_one_csv_file_do_not_share_a_plan_cache_key() raises:
    """Property (1): two quote dialects over one file must not share a
    plan-compile cache key.

    The precondition is asserted first: the two sources have DIFFERENT
    `fingerprint`s, because `CsvSource` folds `quote_style_tag` ("two queries
    with different dialects must not collide on the result cache"). The
    fingerprint must also reach the plan TEXT, which is what `structural_hash`
    folds — otherwise a Posix-quoted read reuses the plan compiled for an
    RFC4180-quoted one.

    ⚠ THIS IS NOT AN MTIME. `quote_style_tag` selects WHICH COMPTIME-
    MONOMORPHIZED SCANNER decodes the bytes, so the two scans do not merely read the same file at different times — they
    parse it into DIFFERENT VALUES. It is the same shape as arrow's `codec`
    (`test_two_codecs_over_one_path_do_not_share_a_plan_cache_key`), and it is
    handled the same way: `quote_style_tag` is a PARAM.
    """
    var a_src = _csv_src(String(GOLDEN_PATH), UInt64(0), quote_style_tag=0)
    var b_src = _csv_src(String(GOLDEN_PATH), UInt64(0), quote_style_tag=2)
    assert_not_equal(
        a_src.fingerprint(),
        b_src.fingerprint(),
        "CsvSource folds quote_style_tag",
    )
    var a = LogicalPlan.scan_from_source(SourceVariant(a_src^), _schema_abc())
    var b = LogicalPlan.scan_from_source(SourceVariant(b_src^), _schema_abc())
    # Same file, so `source_path` cannot be the discriminator.
    assert_equal(a._scan.value()[].source_path, b._scan.value()[].source_path)
    assert_not_equal(
        a.structural_hash(),
        b.structural_hash(),
        "two CSV scans of one path under DIFFERENT quote dialects share a"
        " plan-compile cache key; rendered as: " + String(a),
    )


def test_csv_scan_is_not_labelled_parquet() raises:
    """Property (2): a CSV scan is labelled SOURCE_CSV (1), not SOURCE_PARQUET
    (0) from the ladder's `else` fall-through, and carries its real path.

    Many optimizer passes key on `source_type == SOURCE_PARQUET`, and
    `source_path` is what the row-streaming dispatch recovers the file from.
    `optimizer_scan_dedup` is the sharpest — it groups scans by path, so an
    empty path would merge every CSV scan.
    """
    var sd = ScanData(
        SourceVariant(_csv_src(String(GOLDEN_PATH))),
        Optional[Schema](None),
        Optional[List[String]](None),
        Optional[Expr](None),
    )
    assert_equal(sd.source_type, SOURCE_CSV)
    assert_not_equal(sd.source_type, SOURCE_PARQUET)
    assert_equal(sd.source_path, String(GOLDEN_PATH))


def test_an_unstated_source_kind_over_csv_derives_row() raises:
    """An unstated `source_kind` over a CSV source derives ROW
    (SOURCE_KIND_ROW, 1), what the kind IS, not SOURCE_KIND_COLUMNAR (0).

    The orientation comes from the kind's DECLARATION: `derived_type` reaches
    SOURCE_CSV only via a binding's declared `legacy_source_type`, and a
    binding-backed source takes that branch, so there is no auto-promotion
    ladder keyed on the source type. (NDJSON routes through `JsonSource` and
    derives SOURCE_JSON.)
    """
    var sd = ScanData(
        SourceVariant(_csv_src(String(GOLDEN_PATH))),
        Optional[Schema](None),
        Optional[List[String]](None),
        Optional[Expr](None),
    )
    assert_equal(sd.source_kind, SOURCE_KIND_ROW)
    assert_not_equal(sd.source_kind, SOURCE_KIND_COLUMNAR)


def test_two_mtimes_of_one_csv_file_do_not_share_a_plan_cache_key() raises:
    """Property (3): the render must carry the mtime, or a rewritten file
    reuses the plan compiled against the old bytes.

    The binding declares `SNAPSHOT_PINNED` with the mtime as the token, exactly
    as ORC and AVRO do. Dropping the mtime from `CsvSource.fingerprint()`
    instead would move the fingerprint VALUE and break the stale-cache
    contract.
    """
    var a_src = _csv_src(String(GOLDEN_PATH), UInt64(1))
    var b_src = _csv_src(String(GOLDEN_PATH), UInt64(2))
    assert_not_equal(
        a_src.fingerprint(), b_src.fingerprint(), "CsvSource folds the mtime"
    )
    var a = LogicalPlan.scan_from_source(SourceVariant(a_src^), _schema_abc())
    var b = LogicalPlan.scan_from_source(SourceVariant(b_src^), _schema_abc())
    assert_equal(a._scan.value()[].source_path, b._scan.value()[].source_path)
    assert_not_equal(
        a.structural_hash(),
        b.structural_hash(),
        "two CSV scans of one file at different mtimes share a plan-compile"
        " cache key; rendered as: " + String(a),
    )


def test_two_paths_do_not_share_a_plan_cache_key() raises:
    """The path, the first input `CsvSource.fingerprint()` folds, must reach the
    render. If the ladder's `else` fall-through set `source_path` to the EMPTY
    STRING, every CSV scan would be one plan-cache key, whatever its path."""
    var a = LogicalPlan.scan_from_source(
        SourceVariant(_csv_src(String("/tmp/a.csv"))), _schema_abc()
    )
    var b = LogicalPlan.scan_from_source(
        SourceVariant(_csv_src(String("/tmp/b.csv"))), _schema_abc()
    )
    assert_not_equal(a.structural_hash(), b.structural_hash())


# =============================================================================
# SECTION 3 — the binding's contents and declarations.
# =============================================================================


def test_csv_is_binding_backed_and_carries_the_csv_kind() raises:
    """The arm's payload is a `ScanBinding`, not an `Optional[CsvSource]`.
    No `CsvSource` is reachable from a plan node — which is the
    property that lets a source live outside `komira_core` at all."""
    var sv = SourceVariant(_csv_src(String(GOLDEN_PATH)))
    assert_true(sv.is_binding_backed(), "CSV arm is binding-backed")
    ref b = sv.binding_ref()
    assert_equal(b.kind_id, scan_kind_id(String(SCAN_KIND_NAME_CSV)))
    assert_equal(b.kind_id, CSV_KIND_ID)
    assert_equal(b.kind_name, String("komira.csv"))
    assert_equal(b.name, String(GOLDEN_PATH))


def test_csv_params_are_exactly_what_the_kind_has() raises:
    """`path` AND `quote_style_tag`, AND NOTHING ELSE.

    `quote_style_tag` is the dialect param. It is the only field
    on `CsvSource` beyond (path, schema, mtime) and it selects the decoder, so
    it belongs in `params` for the same reason arrow's `codec` did — and
    `codec` is the precedent, not an analogy: both are "a knob that changes
    what the bytes mean".

    Specifically NOT params:
      * `estimated_rows`. `CsvSource.estimate_rows()` returns -1
        unconditionally (a real count needs a full file scan), and
        `ScanBinding.estimate_rows()` already answers -1 for an absent param.
      * The SCHEMA — it is the `schema` FIELD, and it is deliberately not
        folded into `CsvSource.fingerprint()` either (a freshly-constructed
        CsvSource has an EMPTY schema that the chassis fills during scan, so
        folding it would make identity depend on when you asked).
      * The MTIME — it is the `snapshot_token`.

    Inventing params a kind does not have is how a param map turns back into a
    per-kind schema, so this is asserted rather than assumed.
    """
    var sv = SourceVariant(
        _csv_src(String(GOLDEN_PATH), UInt64(0), quote_style_tag=2)
    )
    ref b = sv.binding_ref()
    # FOUR: `delimiter` and `has_header` are params for the same reason
    # `quote_style_tag` is — they change what the bytes MEAN. The COUNT is asserted so a fifth param cannot be added without
    # this test and the docstring above being reconciled.
    assert_equal(b.params.num_params(), 4)
    assert_equal(b.params.get_str(String("path")), String(GOLDEN_PATH))
    assert_equal(b.params.get_i64(String("quote_style_tag")), Int64(2))
    assert_equal(
        b.params.get_i64(String("delimiter")), Int64(CSV_DEFAULT_DELIMITER)
    )
    assert_equal(b.params.get_i64(String("has_header")), Int64(1))
    assert_false(b.params.has(String("codec")))
    assert_false(b.params.has(String("estimated_rows")))
    assert_false(b.params.has(String("mtime_ns")))


def test_the_derived_identity_covers_every_input_the_kind_folds() raises:
    """Core's DERIVED `identity_hash()` is the fold a kind author cannot
    forget, so it must cover every input CSV has: the path, the mtime, the
    quote style, the delimiter and the header flag.

    The three dialect terms are covered because they are PARAMS; the mtime
    because the binding declares `SNAPSHOT_PINNED`. Leave any off and two
    different CSV reads share a plan-compile cache key."""
    var base = SourceVariant(_csv_src(String(GOLDEN_PATH)))
    var other_path = SourceVariant(_csv_src(String("/tmp/other.csv")))
    var other_mtime = SourceVariant(_csv_src(String(GOLDEN_PATH), UInt64(99)))
    var other_quote = SourceVariant(
        _csv_src(String(GOLDEN_PATH), UInt64(0), quote_style_tag=1)
    )
    var other_delim = SourceVariant(
        CsvSource(
            String(GOLDEN_PATH), _schema_abc(), delimiter=UInt8(ord("\t"))
        )
    )
    var other_hdr = SourceVariant(
        CsvSource(String(GOLDEN_PATH), _schema_abc(), has_header=False)
    )

    var h = base.binding_ref().identity_hash()
    assert_not_equal(h, other_path.binding_ref().identity_hash(), "path")
    assert_not_equal(h, other_mtime.binding_ref().identity_hash(), "mtime")
    assert_not_equal(h, other_quote.binding_ref().identity_hash(), "quote_style")
    assert_not_equal(h, other_delim.binding_ref().identity_hash(), "delimiter")
    assert_not_equal(h, other_hdr.binding_ref().identity_hash(), "has_header")


def test_the_binding_declares_the_axes_it_is_asked_to_declare() raises:
    """`orientation` and `legacy_source_type` are DECLARED, and the
    `ScanData.__init__` ladder reads them instead of testing the tag."""
    var sv = SourceVariant(_csv_src(String(GOLDEN_PATH)))
    ref b = sv.binding_ref()
    assert_equal(b.orientation, SCAN_ORIENTATION_ROW)
    assert_not_equal(b.orientation, SCAN_ORIENTATION_COLUMNAR)
    assert_equal(b.legacy_source_type, LEGACY_SOURCE_TYPE_CSV)
    assert_equal(b.pushdown_gate.mode, GATE_REJECT_ALL)
    # SNAPSHOT_PINNED, and the token IS the mtime.
    assert_equal(b.snapshot_policy, SNAPSHOT_PINNED)
    assert_equal(b.snapshot_token, UInt64(0))
    var sv7 = SourceVariant(_csv_src(String(GOLDEN_PATH), UInt64(7)))
    assert_equal(sv7.binding_ref().snapshot_token, UInt64(7))


def test_the_declared_csv_legacy_type_equals_the_plan_layer_constant() raises:
    """THE PIN THE TYPE SYSTEM CANNOT PROVIDE. `source_variant.mojo` spells
    `SOURCE_CSV` as a NUMBER because `logical_plan.mojo` imports it, so
    importing the plan layer back is a cycle. A test file can import both, so
    the equality is checked here or nowhere."""
    assert_equal(LEGACY_SOURCE_TYPE_CSV, SOURCE_CSV)
    assert_true(SCAN_LEGACY_SOURCE_TYPE_NONE > SOURCE_BINDING)


def test_the_registry_agrees_with_the_binding_about_row() raises:
    """CSV is the SECOND kind to declare ROW, which is what makes
    `ScanKindRegistry.validate`'s orientation comparison stay exercised rather
    than reverting to a single-valued check. Both halves are asserted: the
    production pair AGREES, and a deliberately-mismatched descriptor is
    REFUSED."""
    var sv = SourceVariant(_csv_src(String(GOLDEN_PATH)))
    var reg = ScanKindRegistry()
    reg.register(csv_scan_descriptor())
    assert_equal(csv_scan_descriptor().orientation, SCAN_ORIENTATION_ROW)
    reg.validate(sv.binding_ref())

    var wrong = ScanKindRegistry()
    wrong.register(
        ScanKindDescriptor(
            kind_name=String(SCAN_KIND_NAME_CSV),
            gate=PushdownGate.reject_all(),
            orientation=SCAN_ORIENTATION_COLUMNAR,
            snapshot_policy=SNAPSHOT_PINNED,
        )
    )
    with assert_raises(contains="declares orientation"):
        wrong.validate(sv.binding_ref())


# =============================================================================
# SECTION 4 — declared orientation is enforced, over the second ROW kind.
# =============================================================================


def test_a_plan_built_the_way_production_builds_one_is_row() raises:
    """`source_factories.file_source()` builds `SourceVariant(CsvSource(...))`
    and states no `source_kind` — this is that call, and the ROW comes from the
    kind.

    If someone re-adds the argument "for clarity", this test still passes; if
    someone removes the DECLARATION, it fails. That asymmetry is the point."""
    var plan = LogicalPlan.scan_from_source(
        SourceVariant(_csv_src(String(GOLDEN_PATH))), _schema_abc()
    )
    assert_equal(plan._scan.value()[].source_kind, SOURCE_KIND_ROW)
    assert_true("source_kind=ROW" in String(plan), "got: " + String(plan))
    assert_true("type=CSV" in String(plan), "got: " + String(plan))


def test_a_caller_cannot_demote_the_csv_kind_to_columnar() raises:
    """The refusal. A caller who overrules CSV into COLUMNAR routes a
    row-decoded file at the column executor."""
    with assert_raises(contains="DECLARES orientation"):
        var p = LogicalPlan.scan_from_source(
            SourceVariant(_csv_src(String(GOLDEN_PATH))),
            _schema_abc(),
            source_kind=SOURCE_KIND_COLUMNAR,
        )
        _ = p.structural_hash()


def test_an_agreeing_explicit_source_kind_is_accepted() raises:
    """Agreeing is not contradicting. `optimizer_filter.push_predicates_down`
    RE-THREADS the `source_kind` it read off the old ScanData when it rebuilds
    a scan, so a CSV scan that survives predicate pushdown arrives here with an
    explicit ROW. It must not fail."""
    var p = LogicalPlan.scan_from_source(
        SourceVariant(_csv_src(String(GOLDEN_PATH))),
        _schema_abc(),
        source_kind=SOURCE_KIND_ROW,
    )
    assert_equal(p._scan.value()[].source_kind, SOURCE_KIND_ROW)


def test_the_declaration_is_enforced_even_where_it_is_not_reported() raises:
    """ENFORCEMENT AND DIAGNOSTIC LIVE IN DIFFERENT PLACES, and this pins
    the half with no diagnostic. `ScanData.__init__` must stay NON-RAISING —
    `copy()` reaches it and a deep clone cannot fail — so the refusal lives in
    `scan_from_source`."""
    var sd = ScanData(
        SourceVariant(_csv_src(String(GOLDEN_PATH))),
        Optional[Schema](None),
        Optional[List[String]](None),
        Optional[Expr](None),
        source_kind=SOURCE_KIND_COLUMNAR,
    )
    assert_equal(sd.source_kind, SOURCE_KIND_ROW)
    assert_not_equal(SOURCE_KIND_UNSET, SOURCE_KIND_ROW)


def test_csv_plan_survives_a_plan_copy() raises:
    """A plan clone must preserve the scan's identity. The derived caches must
    survive it — they are re-derived from the binding, so a drift shows up here rather than three optimizer passes later.
    """
    var plan = LogicalPlan.scan_from_source(
        SourceVariant(_csv_src(String(GOLDEN_PATH), UInt64(7), quote_style_tag=1)),
        _schema_abc(),
    )
    var c = plan.copy()
    assert_true(Bool(c._scan))
    assert_equal(c._scan.value()[].source_type, SOURCE_CSV)
    assert_equal(c._scan.value()[].source_path, String(GOLDEN_PATH))
    assert_equal(c._scan.value()[].source_kind, SOURCE_KIND_ROW)
    assert_equal(
        c._scan.value()[].source.fingerprint(),
        plan._scan.value()[].source.fingerprint(),
    )
    assert_equal(c.structural_hash(), plan.structural_hash())


# =============================================================================
# SECTION 5 — GOLDENS on `identity_hash()` AND the rendered plan text.
# =============================================================================
#
# Both derived independently and ASSEMBLED from declared field order rather
# than pasted from program output, so a changed VALUE and a changed FORMAT are
# separately red. Every scan kind carries both goldens.


def _golden_csv_binding(quote_style_tag: Int) -> ScanBinding:
    """Built through the PRODUCTION path — `SourceVariant`'s own constructor —
    so the golden cannot drift from what a plan actually carries. The schema is
    EMPTY, matching the arrow / orc / avro goldens, because `schema` is not an
    input `CsvSource.fingerprint()` folds."""
    return SourceVariant(
        CsvSource(
            String(GOLDEN_PATH),
            Schema(),
            mtime_ns=UInt64(1234567890),
            quote_style_tag=quote_style_tag,
        )
    ).binding_ref().copy()


def test_golden_identity_hash_csv() raises:
    """⚠ TWO literals, not one. `quote_style_tag` is a param, so it is inside
    the `params.hash_into` fold — and a golden on ONE dialect would be green if
    the param were dropped entirely. The PAIR is what pins the discrimination:
    if `quote_style_tag` stopped being a param both numbers would move AND
    become equal."""
    assert_equal(
        _golden_csv_binding(0).identity_hash(), CSV_BID_Q0_MTIME_1234567890
    )
    assert_equal(
        _golden_csv_binding(2).identity_hash(), CSV_BID_Q2_MTIME_1234567890
    )
    assert_not_equal(
        CSV_BID_Q0_MTIME_1234567890, CSV_BID_Q2_MTIME_1234567890
    )


def test_golden_rendered_plan_text_csv() raises:
    """THE RENDERED PLAN TEXT, pinned whole. `LogicalPlan.structural_hash()` is
    FNV-1a over exactly this string and `EngineContext` uses it as
    `factory_hash`, so this line IS the plan-compile cache key.

    ASSEMBLED, NOT TRANSCRIBED: built from the independently-derived literals
    plus the field order `plan_display.mojo` declares. Params render in SORTED
    KEY ORDER (`ScanParams.render`) — which is
    `delimiter, has_header, path, quote_style_tag`, NOT declaration order. That
    sort is why adding two params reorders the whole rendering and is worth
    pinning rather than inferring.
    """
    var expected = String('Scan(path="') + String(GOLDEN_PATH) + String('"')
    expected += String(", type=CSV")
    expected += String(", binding=") + String(SCAN_KIND_NAME_CSV)
    expected += String("(") + String(GOLDEN_PATH)
    expected += String(", delimiter=44")
    expected += String(", has_header=1")
    expected += String(", path=") + String(GOLDEN_PATH)
    expected += String(", quote_style_tag=2)")
    # `bsid` is the KIND-supplied identity (== fingerprint for a file source);
    # `bid` is CORE's derived one. Both are emitted because neither subsumes
    # the other.
    expected += String(", bsid=") + String(GOLDEN_FP_MTIME_1234567890_Q2)
    expected += String(", bid=") + String(CSV_BID_Q2_MTIME_1234567890)
    expected += String(", source_kind=ROW)")

    var rendered = String(
        LogicalPlan.scan_from_source(
            SourceVariant(
                CsvSource(
                    String(GOLDEN_PATH),
                    Schema(),
                    mtime_ns=UInt64(1234567890),
                    quote_style_tag=2,
                )
            ),
            Schema(),
        )
    )
    assert_equal(rendered.strip(), expected)


# =============================================================================
# SECTION 6 — THE LEGACY FACTORY BUILDS THE CSV ARM.
# =============================================================================
#
# `LogicalPlan.scan(path, SOURCE_CSV, ...)` is the call every production CSV
# read makes. It must build the CSV binding arm (not a ParquetSource with
# `SOURCE_KIND_ROW` threaded over it by hand), so that SECTION 1-5 above test
# the arm production actually authors.


def test_the_legacy_csv_factory_builds_the_csv_binding_arm() raises:
    """★ The CSV arm (SOURCE_VARIANT_CSV, 4), not SOURCE_VARIANT_PARQUET (0),
    at the one call every production CSV read makes.

    The four assertions are deliberately separate rather than one plan-text
    compare: `source_type` is what many `source_type == SOURCE_PARQUET` sites
    key on, `source_path` is what
    `optimizer_scan_dedup` groups by, and `source_kind` is what
    `route_plan_shape_row_streaming` routes on. A single golden string would go
    red for all three at once and name none of them."""
    var plan = LogicalPlan.scan(
        String(GOLDEN_PATH), SOURCE_CSV, _schema_abc()
    )
    assert_true(Bool(plan._scan))
    ref sd = plan._scan.value()[]
    assert_equal(sd.source.tag, SOURCE_VARIANT_CSV)
    assert_equal(sd.source_type, SOURCE_CSV)
    assert_equal(sd.source_path, String(GOLDEN_PATH))
    assert_equal(sd.source_kind, SOURCE_KIND_ROW)
    assert_true("type=CSV" in String(plan), "got: " + String(plan))
    assert_true(
        "binding=komira.csv" in String(plan), "got: " + String(plan)
    )


def test_the_legacy_csv_factory_no_longer_states_a_source_kind() raises:
    """The legacy factory states NO layout at all, BY CONSTRUCTION — it passes
    no `source_kind` argument.

    A plan built through the factory answers ROW whether or not an argument is
    passed (the ctor reads `komira.csv`'s DECLARATION), so the plan alone
    cannot tell the two apart. What CAN be asserted, and is the real property,
    is that the SOURCE decides: the
    factory's leaf carries exactly what `derive_source_layout` says of its own
    source, for both the CSV arm and the columnar control."""
    var csv_plan = LogicalPlan.scan(
        String("/t/legacy.csv"), SOURCE_CSV, _schema_abc()
    )
    # ⚠ ONE `ref`, NOT TWO `.value()[]`. Taking the interior reference twice in
    # one expression is `error: use of invalidated interior reference
    # 'plan._scan._value["value"]'` on Mojo 1.0.0 — the second borrow kills the
    # first, and the two are arguments of the SAME call here.
    ref csv_sd = csv_plan.scan_data_ref()
    assert_equal(csv_sd.source_kind, derive_source_layout(csv_sd.source))
    assert_equal(csv_sd.source_kind, SOURCE_KIND_ROW)

    var pq_plan = LogicalPlan.scan(
        String("/t/legacy.parquet"), SOURCE_PARQUET, _schema_abc()
    )
    ref pq_sd = pq_plan.scan_data_ref()
    assert_equal(pq_sd.source_kind, derive_source_layout(pq_sd.source))
    assert_equal(pq_sd.source_kind, SOURCE_KIND_COLUMNAR)


def test_the_legacy_csv_factory_pins_the_file_mtime_as_its_snapshot() raises:
    """`komira.csv` declares SNAPSHOT_PINNED with the mtime AS the token, so a
    leaf built with `mtime_ns=0` over a real file claims a pin it does not have.

    Writes the file, then rewrites it with a DIFFERENT mtime, and asserts the
    two plans do not share a cache key: both plans must carry the file's
    mtime."""
    var p = String("/tmp/csvarm_mtime_probe.csv")
    with open(p, "w") as f:
        f.write(String("a,b,c\n1,2,x\n"))
    _ = set_file_mtime_ns(p, 1_500_000_000_000_000_000)
    var early = LogicalPlan.scan(String(p), SOURCE_CSV, _schema_abc())
    _ = set_file_mtime_ns(p, 1_600_000_000_000_000_000)
    var late = LogicalPlan.scan(String(p), SOURCE_CSV, _schema_abc())
    assert_equal(
        early._scan.value()[].source.binding_ref().snapshot_policy,
        SNAPSHOT_PINNED,
    )
    assert_not_equal(
        early._scan.value()[].source.fingerprint(),
        late._scan.value()[].source.fingerprint(),
    )
    assert_not_equal(
        early._scan.value()[].source.binding_ref().identity_hash(),
        late._scan.value()[].source.binding_ref().identity_hash(),
    )


def test_a_missing_path_stats_to_zero_rather_than_raising() raises:
    """Callers that name a `/tmp/*.csv` fixture they never create must keep
    working. `FileIdentity.stat_path` never raises; the invalid identity's
    `mtime_ns` is 0."""
    var plan = LogicalPlan.scan(
        String("/tmp/csvarm_definitely_not_present_9e4b.csv"),
        SOURCE_CSV,
        _schema_abc(),
    )
    assert_equal(
        plan._scan.value()[].source.binding_ref().snapshot_token, UInt64(0)
    )


# =============================================================================
# SECTION 7 — `delimiter` AND `has_header` ENTER PLAN IDENTITY.
# =============================================================================
#
# Both are options the SQL `read_csv` binder threads into schema INFERENCE, so
# they must also reach the plan: two `read_csv` calls that differ only in
# `delimiter` produce different SCHEMAS and must not share one plan-compile
# cache key.


# ⚠ THE "core defaults == chassis defaults" PIN IS **NOT** HERE, AND CANNOT BE.
# `CSV_DEFAULT_DELIMITER` / `CSV_DEFAULT_HAS_HEADER` are core's own copy of
# `CsvReadOptions`' defaults, because `komira_core` cannot import `komira_csv`
# (the chassis depends on core, not the reverse) — and this test inherits that
# layering, so it cannot import `komira_csv.csv_options`. The pin lives at the
# first layer that can see both (the SQL `read_csv` dialect plan-identity test,
# `test_the_core_dialect_defaults_equal_the_chassis_defaults`).
# It matters: a drift would mean a plan whose IDENTITY describes a dialect the
# READER is not using — self-consistent, and wrong.


def test_two_delimiters_over_one_csv_file_do_not_share_a_plan_cache_key() raises:
    """`delimiter` must be both a fold term and a param, or both
    `structural_hash()` and `identity_hash()` are EQUAL across delimiters."""
    var comma = LogicalPlan.scan_from_source(
        SourceVariant(
            CsvSource(String(GOLDEN_PATH), Schema(), mtime_ns=UInt64(7))
        ),
        Schema(),
    )
    var pipe = LogicalPlan.scan_from_source(
        SourceVariant(
            CsvSource(
                String(GOLDEN_PATH),
                Schema(),
                mtime_ns=UInt64(7),
                delimiter=UInt8(ord("|")),
            )
        ),
        Schema(),
    )
    assert_not_equal(comma.structural_hash(), pipe.structural_hash())
    assert_not_equal(
        comma._scan.value()[].source.fingerprint(),
        pipe._scan.value()[].source.fingerprint(),
    )
    assert_true("delimiter=44" in String(comma), "got: " + String(comma))
    assert_true("delimiter=124" in String(pipe), "got: " + String(pipe))


def test_two_header_settings_over_one_csv_file_do_not_share_a_plan_cache_key() raises:
    """The sharper of the dialect pair. `has_header` does not merely retype a column
    — it decides whether row 0 is DATA, so a cache hit across it returns a
    different ROW COUNT."""
    var hdr = LogicalPlan.scan_from_source(
        SourceVariant(
            CsvSource(String(GOLDEN_PATH), Schema(), mtime_ns=UInt64(7))
        ),
        Schema(),
    )
    var nohdr = LogicalPlan.scan_from_source(
        SourceVariant(
            CsvSource(
                String(GOLDEN_PATH),
                Schema(),
                mtime_ns=UInt64(7),
                has_header=False,
            )
        ),
        Schema(),
    )
    assert_not_equal(hdr.structural_hash(), nohdr.structural_hash())
    assert_not_equal(
        hdr._scan.value()[].source.fingerprint(),
        nohdr._scan.value()[].source.fingerprint(),
    )
    assert_true("has_header=1" in String(hdr), "got: " + String(hdr))
    assert_true("has_header=0" in String(nohdr), "got: " + String(nohdr))


def test_golden_dialect_fingerprints_and_identity_hashes() raises:
    """The dialect pair as NUMBERS, from the independent reference, not
    only as inequalities — an inequality is green if the two terms are folded
    into the WRONG positions, and position is what makes a golden portable."""
    assert_equal(
        CsvSource(
            String(GOLDEN_PATH),
            Schema(),
            mtime_ns=UInt64(1234567890),
            delimiter=UInt8(ord("|")),
        ).fingerprint(),
        GOLDEN_FP_MTIME_1234567890_Q0_PIPE,
    )
    assert_equal(
        CsvSource(
            String(GOLDEN_PATH),
            Schema(),
            mtime_ns=UInt64(1234567890),
            has_header=False,
        ).fingerprint(),
        GOLDEN_FP_MTIME_1234567890_Q0_NOHDR,
    )
    assert_equal(
        SourceVariant(
            CsvSource(
                String(GOLDEN_PATH),
                Schema(),
                mtime_ns=UInt64(1234567890),
                delimiter=UInt8(ord("|")),
            )
        ).binding_ref().identity_hash(),
        CSV_BID_Q0_MTIME_1234567890_PIPE,
    )
    assert_equal(
        SourceVariant(
            CsvSource(
                String(GOLDEN_PATH),
                Schema(),
                mtime_ns=UInt64(1234567890),
                has_header=False,
            )
        ).binding_ref().identity_hash(),
        CSV_BID_Q0_MTIME_1234567890_NOHDR,
    )


def main() raises:
    var suite = TestSuite()
    suite.test[test_csv_fingerprint_matches_the_independent_reference]()
    suite.test[test_the_audit_headers_measured_collision_pair_is_reproduced]()
    suite.test[test_migrated_csv_arm_preserves_the_fingerprint_byte_for_byte]()
    suite.test[test_csv_arm_keeps_its_legacy_tag_and_kind_name]()
    suite.test[test_csv_accessors_answer_the_same_values]()
    suite.test[test_csv_copy_preserves_identity_byte_for_byte]()
    suite.test[test_two_quote_styles_over_one_csv_file_do_not_share_a_plan_cache_key]()
    suite.test[test_csv_scan_is_not_labelled_parquet]()
    suite.test[test_an_unstated_source_kind_over_csv_derives_row]()
    suite.test[test_two_mtimes_of_one_csv_file_do_not_share_a_plan_cache_key]()
    suite.test[test_two_paths_do_not_share_a_plan_cache_key]()
    suite.test[test_csv_is_binding_backed_and_carries_the_csv_kind]()
    suite.test[test_csv_params_are_exactly_what_the_kind_has]()
    suite.test[test_the_derived_identity_covers_every_input_the_kind_folds]()
    suite.test[test_the_binding_declares_the_axes_it_is_asked_to_declare]()
    suite.test[test_the_declared_csv_legacy_type_equals_the_plan_layer_constant]()
    suite.test[test_the_registry_agrees_with_the_binding_about_row]()
    suite.test[test_a_plan_built_the_way_production_builds_one_is_row]()
    suite.test[test_a_caller_cannot_demote_the_csv_kind_to_columnar]()
    suite.test[test_an_agreeing_explicit_source_kind_is_accepted]()
    suite.test[test_the_declaration_is_enforced_even_where_it_is_not_reported]()
    suite.test[test_csv_plan_survives_a_plan_copy]()
    suite.test[test_golden_identity_hash_csv]()
    suite.test[test_golden_rendered_plan_text_csv]()
    suite.test[test_the_legacy_csv_factory_builds_the_csv_binding_arm]()
    suite.test[test_the_legacy_csv_factory_no_longer_states_a_source_kind]()
    suite.test[test_the_legacy_csv_factory_pins_the_file_mtime_as_its_snapshot]()
    suite.test[test_a_missing_path_stats_to_zero_rather_than_raising]()
    suite.test[test_two_delimiters_over_one_csv_file_do_not_share_a_plan_cache_key]()
    suite.test[test_two_header_settings_over_one_csv_file_do_not_share_a_plan_cache_key]()
    suite.test[test_golden_dialect_fingerprints_and_identity_hashes]()
    suite^.run()
