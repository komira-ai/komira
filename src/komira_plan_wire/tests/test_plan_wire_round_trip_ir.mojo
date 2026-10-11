# =============================================================================
# test_plan_wire_round_trip_ir.mojo — THE ROUND TRIP, at IR level.
# =============================================================================
#
#     plan -> bytes -> plan'   with   structural_hash(plan) == structural_hash(plan')
#
# ⚠ THIS FILE IS LEGS 1, 2 AND 3 — everything except EXECUTION. An executing
# round trip (the decoded plan run and every cell compared) belongs with the
# engine; this one exists beside it for two reasons, and neither is "it is
# easier":
#
#   1. IT COVERS THE `ScanBinding` ARM. A parquet-facade corpus's scan leaf is
#      a `ParquetSource` — one of the TWO concrete arms in `SourceVariant`.
#      This file's leaf is a `ScanBinding`, the PURE-DATA shape JSON, CSV,
#      ARROW x3, ORC and AVRO use and that every future kind uses.
#
#   2. IT COSTS SECONDS. Executing a plan comptime-instantiates the engine's
#      whole row dispatch tree. Nothing here touches the engine, the SDK, or
#      parquet: the imports are the core packages and the codec. So any
#      falsification of the codec runs here.
#
# A THREE-LEG TEST THAT NOBODY CAN AFFORD TO RUN IS NOT A STRONGER GATE THAN A
# TWO-LEG TEST THAT RUNS. This is the one you iterate on.
#
# WHY LEG 2 IS NOT REDUNDANT WITH LEG 1. `structural_hash` is FNV-1a over the
# plan's TEXT RENDER, and the render does NOT emit `output_schema` — two plans
# that disagree about their output columns render byte-identically and hash
# equal. Fields that reach a plan without reaching the render are a recurring
# hazard, not a hypothetical one.
#
# WHY LEG 3 IS NOT REDUNDANT WITH EITHER. LEG 2 compares the output schema's
# NAME, TYPE and NULLABILITY and stops. `Field` declares twelve more `var`s,
# and no leg above reads one of them at any value. LEG 3 reads the `*Data`
# payloads directly, so it also sees the fields the render deliberately
# SUPPRESSES at their derived default. The audit below is what it is for.
#
# ============================ THE DEFAULTS AUDIT =============================
#
# ★ A CORPUS BUILT FROM DEFAULT VALUES CANNOT SEE THE FIELD IT IS TESTING.
#
# The canonical case: with `desc=[True,False]` and `nulls_first=[False,True]` —
# bit for bit what `_resolve_nulls_first` derives — `_write_nulls_first`
# SUPPRESSES the render at exactly that value, so dropping `d.nulls_first`
# from the Sort encoder leaves every leg green.
#
# It is a CLASS, not a field. Over the fields the codec carries, these are the
# ones a naive corpus leaves at their derived default or on an arm no corpus
# plan reaches (`ParquetSource`'s fields are out of this file's scope):
#
#   Field           dtype (DERIVED from arrow_type, and `Schema.field_at`
#                   re-derives it too), decimal_precision, decimal_scale,
#                   _tz, _dict_index_type, _union_type_ids, _flags, both
#                   metadata lists, all three child lists
#   ScalarValue     a corpus of `from_int64` sets dtype, int_val and _kind;
#                   every other slot sits at the no-arg ctor's value
#   ScanData        projection, filter, row_count, table_stats, source_kind
#   ScanBinding     stats, pushdown_extra_cols, legacy_source_type,
#                   orientation (the ctor default AND engine value 0)
#   AggExpr         child1, child2, child3 — the sparse slots
#   AggregateData   estimated_groups, udf
#   ProjectData     is_cse_introduced, udf
#   JoinData        algo_hint (JOIN_ALGO_AUTO is 0), residual
#   SortData        nulls_first   <- the canonical case above
#   TopNData        nulls_first   <- worse: a factory call with no override
#                   at all, and SQL with no NULLS FIRST/LAST never sets it
#   DistinctData    estimated_groups
#   FilterData      udf
#   UnionData       children — PLAN_UNION needs a corpus plan of its own
#
#   NOT default-equal: PushdownGate (`conjunctive_comparison()` is a shaped
#   gate), LimitData (`offset=2` is deliberate and its docstring says why).
#
# TWO SUB-CLASSES, AND THEY NEED DIFFERENT FIXES:
#
#   (a) THE RENDER SUPPRESSES THE DEFAULT — `nulls_first`. An ADVERSARIAL
#       CORPUS fixes it: at a deviating value `_write_nulls_first` emits, and
#       LEG 1 sees the drop. `_assert_nulls_first_deviates` keeps it deviating.
#
#   (b) NO LEG READS THE FIELD AT ANY VALUE — the eleven `Field` parameter
#       slots. `_schema_text` compares name/type/nullability and stops; the
#       plan render emits no schema at all. An adversarial corpus does NOT fix
#       these, because there is no value at which either leg looks: deleting
#       `_tz`, `_dict_index_type`, `_union_type_ids`, `_flags` and the
#       metadata pair from the encoder leaves LEGS 1 and 2 green. LEG 3 is
#       what fixes them.
#
# Both fixes need a check that asks the field universe TWO questions — is it
# in the CODEC, and is it COMPARED here.
#
# --------------------------- A THIRD SUB-CLASS ------------------------------
#
# (c) THE FIELD IS UNOBSERVABLE BECAUSE NO CONSTRUCTIBLE STATE CAN DISTURB IT.
#     Not "the render suppresses it" (a) and not "no leg looks" (b) — this one
#     is a field the wire could carry, LEG 3 would compare, and NOTHING CAN
#     MAKE WRONG. `ViewRefData.output_schema` and `CseRefData.output_schema`
#     sit BESIDE the node's `LogicalPlan.output_schema`, and each factory fills
#     the pair from ONE argument; no producer reassigns a plan node's schema
#     after construction. So the two are equal always, and a second
#     `WireSchema` on the wire would be a forgeable duplicate: an encoder that
#     wrote `p.output_schema` where the payload's belonged — a codec that
#     merely ASSUMED the two were aliases — would leave this file GREEN. A slot
#     no mutation can disturb tests nothing, however many legs read it.
#
#     The fix is NOT a better corpus and NOT a fourth leg: it is to STOP
#     CARRYING THE FIELD and derive it at decode — the same treatment
#     `ScanData.source_path` has. Sub-class (c) shrinks the wire instead of
#     growing the test.
#
# ------------------------- MUTATIONS AND THEIR LEGS -------------------------
#
# Two mutations fire on DIFFERENT LEGS — which is the property worth
# recording, because which leg covers an arm is a fact about `plan_display`,
# not about the codec.
#
#   MUT-A (render-invisible): the four ASOF pre-sort hint lists emptied in the
#   encoder AND both `AsofTolerance` payload numbers zeroed. Every failure is
#   LEG 3, none is LEG 1 — the six fields reach no render at any value:
#       left:  ... tolerance=(1,0,0.0)    left_sort_keys=[]     ...
#       right: ... tolerance=(1,5000,2.5) left_sort_keys=[s,a]  ...
#
#   MUT-C (operand crossing): the two ASOF child plans swapped in the encoder.
#   Every failure is LEG 1. LEG 2 is blind here BY CONSTRUCTION — both
#   children are `_schema()`-shaped, so the join's output schema is identical
#   under the swap.
#
# Encapsulation: no UnsafePointer crosses a signature here, no wildcard
# origins, no unsafe_from_address, no take_pointee.
# =============================================================================

from std.memory import OwnedPointer
from std.testing import TestSuite, assert_equal, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow_ipc.c_data_interface import (
    ARROW_FLAG_DICTIONARY_ORDERED, ARROW_FLAG_MAP_KEYS_SORTED,
)
from komira_arrow.schema import Field, Schema, SchemaBuilder
from komira_collections.slab import Slab
from komira_plan_expr.agg_expr import (
    AggExpr, AGG_SUM, AGG_COUNT, AGG_MIN, AGG_MAX, AGG_MEAN,
    AGG_COUNT_DISTINCT, AGG_FIRST, AGG_LAST, AGG_STDDEV_SAMP, AGG_CORR,
    AGG_MEDIAN, AGG_LARGEST_K, AGG_VAR_SAMP,
    AGG_COVAR_POP, AGG_COVAR_SAMP, AGG_REGR_AVGX, AGG_REGR_AVGY,
    AGG_REGR_COUNT, AGG_REGR_SXX, AGG_REGR_SXY, AGG_REGR_SYY,
    AGG_REGR_SLOPE, AGG_REGR_INTERCEPT, AGG_REGR_R2,
    AGG_VAR_POP, AGG_STDDEV_POP, AGG_SEM,
    AGG_COUNT_IF, AGG_BOOL_AND, AGG_BOOL_OR, AGG_PRODUCT, AGG_ANY_VALUE,
    AGG_KAHAN_SUM, AGG_KAHAN_AVG, AGG_SKEWNESS, AGG_KURTOSIS, AGG_KURTOSIS_POP,
)
from komira_plan_expr.expr import (
    Expr, WhenCaseData, BIN_GT, BIN_AND, BIN_LT, UN_NOT,
    UN_NEGATE, UN_IS_NULL, UN_IS_NOT_NULL,
    UN_ABS, UN_SIGN, UN_TRUNC, UN_ROUND, UN_BIT_COUNT,
    EXPR_COL_REF, EXPR_COL_IDX, EXPR_LITERAL, EXPR_BINARY_OP, EXPR_UNARY_OP,
    EXPR_ALIAS, EXPR_IN_LIST, EXPR_CAST, EXPR_CORRELATED_SUBQUERY,
    EXPR_WHEN, EXPR_AGG_FN, EXPR_EXTRACT, EXPR_MATH_FN, EXPR_MATH_FN2,
    EXPR_SUBSTRING,
    EXPR_STRING_OP, EXPR_REGEXP, EXPR_STRUCT_FIELD, EXPR_STRUCT_FIELD_IDX,
    EXPR_MAP_GET, EXPR_JSON_EXTRACT, EXPR_WINDOW_FN,
    EXPR_BETWEEN, EXPR_SORT_KEY, EXPR_UDF_CALL,
    MATH_SIN, MATH_COS, MATH_SQRT, MATH_ASIN, MATH_RADIANS,
    MATH_CEIL, MATH_FLOOR, MATH_LN, MATH_EXP, MATH_LOG10, MATH_LOG2,
    MATH_TAN, MATH_ATAN, MATH_ACOS, MATH_COT, MATH_DEGREES, MATH_CBRT,
    MATH_SINH, MATH_COSH, MATH_TANH,
    MATH_ACOSH, MATH_ASINH, MATH_ATANH, MATH_GAMMA,
    MATH2_ATAN2, MATH2_POW,
    EXTRACT_YEAR, EXTRACT_QUARTER, EXTRACT_MONTH, EXTRACT_DAY, EXTRACT_HOUR,
    EXTRACT_MINUTE, EXTRACT_SECOND,
    EXTRACT_TRUNC_YEAR, EXTRACT_TRUNC_QUARTER, EXTRACT_TRUNC_MONTH,
    EXTRACT_TRUNC_WEEK, EXTRACT_TRUNC_DAY,
    STR_CONTAINS, STR_STARTS_WITH, STR_ENDS_WITH, STR_LIKE,
    EXPR_STRING_FN,
    EXPR_STRING_FN_N,
    STRFN_UPPER, STRFN_LOWER, STRFN_TRIM, STRFN_LTRIM, STRFN_RTRIM,
    STRFN_LENGTH, STRFN_REVERSE,
    STRFN_ASCII, STRFN_UNICODE, STRFN_STRLEN, STRFN_BIT_LENGTH,
    STRFN_HEX, STRFN_BIN, STRFN_URL_ENCODE, STRFN_URL_DECODE,
    STRFN_REGEXP_ESCAPE,
    STRFN_MD5, STRFN_SHA1, STRFN_SHA256,
    STRFNN_CONCAT, STRFNN_CONCAT_WS, STRFNN_REPLACE, STRFNN_LPAD,
    STRFNN_RPAD, STRFNN_REPEAT, STRFNN_STRPOS,
    STRFNN_LEVENSHTEIN, STRFNN_DAMERAU_LEVENSHTEIN, STRFNN_HAMMING,
    STRFNN_TRANSLATE,
    STRFNN_JARO, STRFNN_JARO_WINKLER, STRFNN_JACCARD,
    string_fn_n_arity,
    REGEXP_LIKE, REGEXP_MATCH, REGEXP_REPLACE, REGEXP_EXTRACT,
    EXTRACT_DAYOFWEEK, EXTRACT_ISODOW, EXTRACT_DAYOFYEAR,
    EXTRACT_WEEK, EXTRACT_ISOYEAR, EXTRACT_YEARWEEK,
    EXTRACT_MILLISECOND, EXTRACT_MICROSECOND,
    REGEXP_SPLIT_TO_ARRAY, REGEXP_EXTRACT_ALL, REGEXP_COUNT, REGEXP_INSTR,
    REGEXP_SUBSTR, REGEXP_FULL_MATCH,
)
from komira_plan_wire.plan_wire_vocabulary import (
    AGG_FN_WIRE_MEMBERS,
    MATH_FN1_WIRE_MEMBERS,
    MATH_FN2_WIRE_MEMBERS,
    EXTRACT_FIELD_WIRE_MEMBERS,
    STRING_OP_WIRE_MEMBERS,
    UNARY_OP_WIRE_MEMBERS,
    STRING_FN_WIRE_MEMBERS,
    STRING_FN_N_WIRE_MEMBERS,
    REGEXP_OP_WIRE_MEMBERS,
    WINDOW_FN_WIRE_MEMBERS,
    extract_field_is_declared,
    window_fn_is_declared,
)
from komira_plan_ir.logical_plan import (
    LogicalPlan, ExprArray, AggExprArray, JOIN_INNER, JOIN_LEFT,
    JOIN_ALGO_AUTO, JOIN_ALGO_SORT_MERGE, SOURCE_ORC, SOURCE_PARQUET,
    PLAN_SCAN, PLAN_FILTER, PLAN_PROJECT, PLAN_AGGREGATE, PLAN_JOIN,
    PLAN_SORT, PLAN_LIMIT, PLAN_DISTINCT, PLAN_TOPN, PLAN_UNION,
    PLAN_PARTITION_BY, PLAN_PARTITION_TOPN,
    PLAN_ASOF_JOIN, PLAN_VIEW_REF, PLAN_CSE_REF, PLAN_CAST_TO_VARCHAR,
    AsofTolerance, ASOF_BACKWARD, ASOF_FORWARD, ASOF_NEAREST,
    ASOF_TOL_NONE, ASOF_TOL_INT64, ASOF_TOL_FLOAT64,
    CORR_KIND_EXISTS, CORR_KIND_SCALAR, CORR_KIND_IN_CORRELATED,
)
from komira_plan_ir.corr_subquery import corr_subq_inner_plan_ref
from komira_scan_source.parquet_source import ParquetSource
from komira_plan_expr.partition_expr import (
    PartitionExpr, PartitionFrame, PF_LAG,
    PF_ROW_NUMBER, PF_RANK, PF_LEAD, PF_NTILE, PF_SUM, PF_MIN,
    FRAME_UNITS_ROWS, FRAME_UNITS_RANGE,
    FRAME_BOUND_UNBOUNDED_PRECEDING, FRAME_BOUND_PRECEDING,
    FRAME_BOUND_CURRENT_ROW, FRAME_BOUND_FOLLOWING,
    FRAME_BOUND_UNBOUNDED_FOLLOWING,
)
from komira_plan_expr.scalar_value import (
    ScalarValue, SCALAR_TIME_UNIT_SECOND, SCALAR_TIME_UNIT_MILLI,
    SCALAR_TIME_UNIT_MICRO, SCALAR_TIME_UNIT_NANO,
)
from komira_scan_source.pushdown_gate import PushdownGate
from komira_scan_source.scan_binding import (
    ScanBinding, scan_kind_id, SCAN_ORIENTATION_COLUMNAR,
    SCAN_ORIENTATION_ROW, SNAPSHOT_PINNED, SNAPSHOT_LIVE,
)
from komira_scan_source.scan_params import (
    ScanParams, PARAM_STR, PARAM_I64, PARAM_U64, PARAM_F64, PARAM_BOOL,
    PARAM_BYTES,
)
from komira_scan_source.source_variant import (
    SourceVariant, SOURCE_VARIANT_ORC, SOURCE_VARIANT_PARQUET,
)

from komira_arrow.write_target import (
    WriteTarget,
    WFMT_CSV,
    WFMT_PARQUET,
    WCOMP_GZIP,
    WCOMP_SNAPPY,
)
from komira_plan_wire import (
    plan_to_bytes,
    plan_to_bytes_with_write_target,
    plan_from_bytes,
    plan_envelope_from_bytes,
    PLAN_WIRE_AGG_ARG_DROPPED,
)
from komira_plan_wire.plan_wire_codec import PLAN_WIRE_FORMAT_VERSION

# ⚠ THE HOSTILE-ENCODER TESTS BELOW NEED THE GENERATED MESSAGE TYPES, because a
# hostile encoder is defined by what it puts ON THE WIRE and nothing reachable
# through `LogicalPlan` can express an out-of-range type id. `WireField.
# arrow_type_id` is a `uint32`; `ArrowType.type_id` is a `UInt8`.
from komira_proto_codec import encode_proto, decode_proto
from komira_plan_proto.plan import (
    WireExpr,
    WireField,
    WirePartitionValueRow,
    WirePlanEnvelope,
)


# =============================================================================
# The corpus's leaf — a BINDING, i.e. pure data
# =============================================================================


def _schema() raises -> Schema:
    """★ ADVERSARIAL TO DEFAULTS, COLUMN BY COLUMN.

    A CORPUS BUILT FROM DEFAULT VALUES CANNOT SEE THE FIELD IT IS TESTING.
    `Field` declares FIFTEEN `var`s and a plain three-column schema leaves
    ELEVEN of them at the ctor's default — `decimal_precision`,
    `decimal_scale`, `_tz`, `_dict_index_type`, `_union_type_ids`, `_flags`,
    both metadata lists and all three child lists. proto3 omits zero-valued
    scalars and empty repeated fields, so an encoder that never wrote any of
    them would emit BYTE-IDENTICAL bytes and the decoder would re-supply the
    same zeros. Neither leg can tell the difference:
    `_schema_text` compares name/type/nullability and the plan render emits no
    schema at all.

    So every parameter slot gets a column that USES it, in the shape the slot
    is FOR — a tz on a timestamp, (p,s) on a decimal, an index type on a
    dictionary, children on a struct, type ids on a union — rather than an
    arbitrary non-zero, because a slot exercised in its real shape also proves
    the engine's own Schema round-trips it.
    """
    var sb = SchemaBuilder()

    # a — metadata (two parallel lists, and the codec CHECKS they agree)
    var a = Field("a", ArrowType.INT64, False)
    a._metadata_keys = [String("unit"), String("origin")]
    a._metadata_values = [String("cents"), String("ledger")]
    sb.add_field(a^)

    sb.add_field(Field("b", ArrowType.INT64, True))
    sb.add_field(Field("s", ArrowType.STRING, True))

    # ts — the timezone slot, non-empty
    var ts = Field("ts", ArrowType.TIMESTAMP_US, True)
    ts._tz = String("America/New_York")
    sb.add_field(ts^)

    # dec — decimal (p,s), both non-zero and DIFFERENT from each other, so a
    # codec that wrote one slot into the other still goes red
    var dec = Field("dec", ArrowType.DECIMAL128, True)
    dec.decimal_precision = 18
    dec.decimal_scale = 4
    sb.add_field(dec^)

    # dic — the dictionary index type, deviating from the INT32 default, plus
    # the flag word (bits 1 and 4; bit 2 is the `nullable` mirror)
    var dic = Field("dic", ArrowType.DICTIONARY, True)
    dic._dict_index_type = ArrowType.INT16
    dic._flags = ARROW_FLAG_DICTIONARY_ORDERED | ARROW_FLAG_MAP_KEYS_SORTED
    sb.add_field(dic^)

    # st — the three parallel CHILD lists, with a nullable and a non-nullable
    # child so a codec that wrote one flag for all of them goes red
    var st = Field("st", ArrowType.STRUCT, True)
    st._child_names = [String("k"), String("v")]
    st._child_types = [ArrowType.INT32.type_id, ArrowType.STRING.type_id]
    st._child_nullables = [False, True]
    sb.add_field(st^)

    # un — the union type-id buffer
    var un = Field("un", ArrowType.UNION_DENSE, True)
    un._union_type_ids = [7, 11]
    sb.add_field(un^)

    # mp — a MAP, so `EXPR_MAP_GET` reaches a parent of its real type rather
    # than the `ArrowType.NULL` placeholder `_infer_expr_field` hands back for
    # an out-of-shape parent. The Schema-level convention for MAP is TWO FLAT
    # CHILDREN (`child[0]` = key, `child[1]` = value) — not the Arrow runtime
    # layout, which nests them under an `entries` STRUCT — and the value
    # child's type is what `map[key]` infers as, so making it INT64 while the
    # key is STRING means a codec that read `child[0]` instead of `child[1]`
    # produces a different output schema rather than the same one twice.
    var mp = Field("mp", ArrowType.MAP, True)
    mp._child_names = [String("key"), String("value")]
    mp._child_types = [ArrowType.STRING.type_id, ArrowType.INT64.type_id]
    mp._child_nullables = [False, True]
    sb.add_field(mp^)

    # js — JSON text lives in a STRING column; `EXPR_JSON_EXTRACT`'s parent.
    sb.add_field(Field("js", ArrowType.STRING, True))

    var s = sb.build()
    # ★ THE ELEVENTH FIELD — TABLE-level metadata, which is NOT column `a`'s.
    # `Schema._metadata_keys`/`_metadata_values` describe the table; `Field`'s
    # pair of the SAME NAME (set on column `a` above) describes one column. A
    # codec can drop the table pair on every round trip with nothing red,
    # because `SchemaBuilder` — the type `_schema_from_wire` rebuilds through —
    # has no channel for it at all.
    #
    # Two pairs, and the KEYS deviate from the VALUES so a codec that wrote one
    # list into the other is red rather than lucky.
    s.set_metadata(String("table"), String("lineitem"))
    s.set_metadata(String("catalog"), String("tpch"))
    return s^


def _gate_c() raises -> PushdownGate:
    """★ THE THIRD `PushdownGate` VALUE — `(and_recurse, in_list, stat) =
    (T, T, F)`. See `_gate_d` for why three is not enough and four is."""
    var g = PushdownGate.conjunctive_comparison()
    g.allow_and_recurse = True
    g.allow_in_list = True
    g.require_stat_friendly_col = False
    return g^


def _gate_d() raises -> PushdownGate:
    """★ THE FOURTH `PushdownGate` VALUE — `(T, F, T)`, AND THE COUNTING
    ARGUMENT FOR WHY IT IS NEEDED.

    With only TWO gate values, `conjunctive_comparison()` = (T,T,T) and
    `reject_all()` = (F,F,F), all three of `WirePushdownGate`'s booleans are
    the SAME BIT at every instance the corpus encodes. Writing
    `g.allow_and_recurse` into the `require_stat_friendly_col` slot of
    `_gate_to_wire` then leaves every test GREEN, while hardcoding that slot to
    `False` goes RED everywhere. The field is compared and read; it simply
    cannot be told apart from a neighbour.

    THREE VALUES CANNOT FIX IT. Three boolean slots need three pairwise-distinct
    bit-vectors; a third gate contributes one bit to each slot, so the vectors
    become (T,F,c1) / (T,F,c2) / (T,F,c3) and two of them collide by pigeonhole
    whatever c is. FOUR is the minimum, and these two are chosen so the added
    suffixes are (T,T) / (T,F) / (F,T) — pairwise distinct, hence all three
    traces are.

    ⚠ THE MODE AND THE OP MASK ARE DELIBERATELY LEFT AT `conjunctive_comparison`'s.
    They are not what this value is about, and moving them would change which
    slots the slot probe's CENSUS half reports for an unrelated reason."""
    var g = PushdownGate.conjunctive_comparison()
    g.allow_and_recurse = True
    g.allow_in_list = False
    g.require_stat_friendly_col = True
    return g^


def _binding(name: String, path: String) raises -> ScanBinding:
    """A binding-backed leaf with a NON-EMPTY param map, a PINNED snapshot and
    a SHAPED pushdown gate."""
    return _binding_gated(
        name, path, PushdownGate.conjunctive_comparison()
    )


def _binding_gated(
    name: String, path: String, var gate: PushdownGate
) raises -> ScanBinding:
    """`_binding` with the pushdown gate named by the caller.

    ★ THE GATE IS A PARAMETER BECAUSE THE FORGERY HALF NEEDS FOUR OF THEM. It
    was hardcoded to `conjunctive_comparison()` here, and `_binding_b` is the
    only other gate the corpus carries — two values, which is not enough to
    tell `WirePushdownGate`'s three booleans apart. See `_gate_d`.

    Every field below is one a lazier corpus would leave at its default and
    therefore fail to test: an all-defaults binding round-trips through a codec
    that encodes nothing at all, because proto3 omits zeros on the way out and
    re-supplies them on the way in."""
    var p = ScanParams()
    p.put_str(String("path"), String(path))
    p.put_i64(String("stripe_count"), Int64(7))
    p.put_bool(String("has_footer"), True)
    p.put_f64(String("selectivity"), Float64(0.25))
    p.put_u64(String("bytes"), UInt64(4096))
    return ScanBinding(
        kind_id=scan_kind_id(String("komira.orc")),
        kind_name=String("komira.orc"),
        name=name,
        params=p^,
        schema=_schema(),
        fingerprint=UInt64(0xDEADBEEF),
        structural_id=UInt64(0xFEEDFACE),
        gate=gate^,
        snapshot_policy=SNAPSHOT_PINNED,
        snapshot_token=UInt64(1234567890),
        # ⚠ NOT `SCAN_ORIENTATION_COLUMNAR` — that is the CTOR DEFAULT, and it
        # is also engine value 0. ROW deviates from the default on both axes,
        # and because the kind's declared orientation DECIDES `source_kind`,
        # it also carries `ScanData.source_kind` off its own default in the
        # same move.
        orientation=SCAN_ORIENTATION_ROW,
        # The ctor default is the SENTINEL (255), which sets `has_legacy=False`
        # and leaves the whole `legacy_source_type` arm of the codec — the
        # presence bit AND the SourceType mapping — unexercised.
        legacy_source_type=SOURCE_ORC,
        # The ctor default is an EMPTY list, and proto3 omits empty repeated
        # fields, so an encoder that never wrote this one was byte-identical.
        pushdown_extra_cols=[String("dic"), String("ts")],
    )


def _scan(name: String, path: String) raises -> LogicalPlan:
    return LogicalPlan.scan_from_source(
        SourceVariant(tag=SOURCE_VARIANT_ORC, binding=_binding(name, path)),
        _schema(),
    )



# =============================================================================
# LEG 3 — IR FIELD EQUALITY. The leg that does not depend on a render.
# =============================================================================
#
# ⚠ THE HAZARD THIS EXISTS TO CLOSE.
#
# LEG 1 compares the plan's TEXT RENDER. LEG 2 compares the output SCHEMA's
# name/type/nullability. Between them they can see a lot — and they are BLIND
# to a whole class of field, in two distinct ways:
#
#   (a) THE RENDER SUPPRESSES A DEFAULT. `_write_nulls_first` emits
#       ` NULLS FIRST` / ` NULLS LAST` ONLY when the value DEVIATES from
#       `not descending[i]` — deliberately, so explicit null placement does
#       not move every existing sort plan's `structural_hash`. A corpus that
#       uses `desc=[True,False]` with `nulls_first=[False,True]`, EXACTLY what
#       `_resolve_nulls_first` derives, has the render print nothing and the
#       decoder re-derive the same list, so `d.nulls_first.copy()` ->
#       `List[Bool]()` in the Sort encoder stays GREEN under legs 1 and 2.
#       `TopNData.nulls_first` is worse: a corpus can pass no override at all.
#
#   (b) THE RENDER NEVER EMITS THE FIELD AT ALL, AT ANY VALUE. `Field._tz`,
#       `_flags`, `_dict_index_type`, `_union_type_ids`, the metadata pair and
#       the three child lists are emitted by NEITHER leg — `_schema_text` reads
#       name, type and nullability and stops. An adversarial corpus alone does
#       NOT fix these: there is no value at which either leg looks.
#
# So the corpus is adversarial to defaults AND this third leg reads the
# fields DIRECTLY off the `*Data` payloads. Every field the codec claims to
# carry appears here by name — the same field universe, asked in both
# directions: is it in the CODEC, and is it COMPARED.
#
# ⚠ WHAT THIS LEG DOES NOT DO. It cannot make a field non-vacuous on its own:
# naming `ParquetSource.paths` here does nothing until a corpus plan carries a
# parquet leaf (this file's does not). Arm coverage is a
# separate axis from field coverage, and the per-node tests below are what
# carry it. Stated rather than assumed, because a gate that quietly credits an
# unreachable arm is the failure one level up from the one being fixed here.
#
# It is TOTAL and RAISES on an arm it does not know, exactly like the codec: a
# walk that silently returns "" for an unmodelled node is the fail-quiet shape
# this whole format is built against.


def _b(v: Bool) -> String:
    if v:
        return String("1")
    return String("0")


def _bools(v: List[Bool]) -> String:
    var out = String("[")
    for i in range(len(v)):
        if i > 0:
            out += ","
        out += _b(v[i])
    out += "]"
    return out^


def _strs(v: List[String]) -> String:
    var out = String("[")
    for i in range(len(v)):
        if i > 0:
            out += ","
        out += v[i]
    out += "]"
    return out^


def _ints(v: List[Int]) -> String:
    var out = String("[")
    for i in range(len(v)):
        if i > 0:
            out += ","
        out += String(v[i])
    out += "]"
    return out^


def _u8s(v: List[UInt8]) -> String:
    var out = String("[")
    for i in range(len(v)):
        if i > 0:
            out += ","
        out += String(Int(v[i]))
    out += "]"
    return out^


def _frame_ir(f: PartitionFrame) -> String:
    """All FIVE `var`s on `PartitionFrame`, and this is the ONLY leg that reads
    any of them, on any arm, at any value.

    `Expr.write_to`'s WINDOW_FN arm does not mention the frame;
    `plan_display`'s PartitionBy arm prints a `<n> funcs` COUNT and never
    descends into a `PartitionExpr`; `partition_expr_output_field` reads func /
    column / has_default / alias_name and derives a name and a type from those
    four. So a codec that dropped the frame — or, worse, re-derived it from
    `func` and `offset`, which is right for every plan the ~20 `ColExpr`
    factories build — is invisible everywhere but here."""
    return (
        String("F(units=") + String(Int(f.units))
        + ",start=" + String(Int(f.start_tag)) + "@" + String(f.start_offset)
        + ",end=" + String(Int(f.end_tag)) + "@" + String(f.end_offset) + ")"
    )


def _partition_expr_ir(x: PartitionExpr) raises -> String:
    """All SEVEN `var`s on `PartitionExpr`, and NO RENDER READS ANY OF THEM.

    `plan_display`'s PartitionBy arm prints `<n> funcs` — a COUNT — so LEG 1
    knows how many partition expressions a node holds and nothing about one.
    LEG 2 sees four of the seven lossily, through
    `partition_expr_output_field`: the output Field's NAME comes from
    `alias_name` (or from `func` and the expr index), its TYPE from `func` and
    `column`, its NULLABILITY from `func`, `column` and `has_default`. So
    `offset`, `default_value` and the whole `frame` reach NEITHER other leg at
    ANY value, and this is where they are compared.

    `has_default` is printed BESIDE `default_value` rather than gating it,
    because the pair has three states and not two — absent, present-and-null,
    present-and-set — and only the flag distinguishes the first two."""
    return (
        String("P(func=") + String(Int(x.func))
        + ",column=" + x.column
        + ",offset=" + String(x.offset)
        + ",default_value=" + _scalar_ir(x.default_value)
        + ",has_default=" + _b(x.has_default)
        + ",frame=" + _frame_ir(x.frame)
        + ",alias_name=" + x.alias_name + ")"
    )


def _field_ir(f: Field) raises -> String:
    """All FIFTEEN `var`s on `Field`. Eleven of them are read by no other leg
    at any value."""
    return (
        String("F(name=") + f.name
        + " arrow_type=" + String(Int(f.arrow_type.type_id))
        + " dtype=" + String(f.dtype)
        + " nullable=" + _b(f.nullable)
        + " decimal_precision=" + String(f.decimal_precision)
        + " decimal_scale=" + String(f.decimal_scale)
        + " _tz=" + f._tz
        + " _dict_index_type=" + String(Int(f._dict_index_type.type_id))
        + " _union_type_ids=" + _ints(f._union_type_ids)
        + " _flags=" + String(Int(f._flags))
        + " _metadata_keys=" + _strs(f._metadata_keys)
        + " _metadata_values=" + _strs(f._metadata_values)
        + " _child_names=" + _strs(f._child_names)
        + " _child_types=" + _u8s(f._child_types)
        + " _child_nullables=" + _bools(f._child_nullables)
        + ")"
    )


def _schema_ir(s: Schema) raises -> String:
    """The field list AND `Schema`'s OWN kv metadata — the ELEVENTH FIELD.

    ⚠ `Schema._metadata_keys` / `_metadata_values` describe THE TABLE and are a
    different `var` from `Field._metadata_keys` / `_metadata_values`, which
    `_field_ir` above already prints per column. The shared name is what hid the
    table pair: a field-coverage check that credits by NAME sees
    `_field_to_wire` mention `f._metadata_keys`, and a leg that read only the
    per-field pair would let the codec drop the table's on every round trip
    with nothing going red."""
    var out = String("S[")
    for i in range(s.num_columns()):
        if i > 0:
            out += " "
        out += _field_ir(s.field_at(i))
    out += "]{"
    out += _strs(s._metadata_keys)
    out += "="
    out += _strs(s._metadata_values)
    out += "}"
    return out^


def _scalar_ir(v: ScalarValue) -> String:
    """All TWENTY `var`s on `ScalarValue`. It is a flat union whose live arm is
    (`_kind`, `dtype`) and every other slot is zero — which is exactly why a
    single-kind corpus leaves seventeen of them untested."""
    return (
        String("V(dtype=") + String(v.dtype)
        + " int_val=" + String(Int(v.int_val))
        + " float_val=" + String(v.float_val)
        + " string_val=" + v.string_val
        + " bool_val=" + _b(v.bool_val)
        + " _kind=" + String(Int(v._kind))
        + " dec128_high=" + String(Int(v.dec128_high))
        + " dec128_low=" + String(Int(v.dec128_low))
        + " dec128_precision=" + String(v.dec128_precision)
        + " dec128_scale=" + String(v.dec128_scale)
        + " date32_val=" + String(Int(v.date32_val))
        + " ts_micros=" + String(Int(v.ts_micros))
        + " null_dtype=" + String(v.null_dtype)
        + " iv_months=" + String(Int(v.iv_months))
        + " iv_days=" + String(Int(v.iv_days))
        + " iv_nanos=" + String(Int(v.iv_nanos))
        + " time_unit=" + String(Int(v.time_unit))
        + " dec256_high_lo=" + String(Int(v.dec256_high_lo))
        + " dec256_high_hi=" + String(Int(v.dec256_high_hi))
        + ")"
    )


def _expr_ir(e: Expr) raises -> String:
    """TOTAL over the twenty-one modelled Expr arms; RAISES on any other, so an
    arm that acquires an encoder without acquiring a comparison is red here."""
    if e.tag == EXPR_COL_REF:
        return (
            String("E:col(") + e.col_ref_name() + ","
            + String(Int(e.col_ref_side())) + ")"
        )
    if e.tag == EXPR_COL_IDX:
        return String("E:idx(") + String(e.col_idx_index()) + ")"
    if e.tag == EXPR_LITERAL:
        return String("E:lit(") + _scalar_ir(e.literal_value()) + ")"
    if e.tag == EXPR_BINARY_OP:
        return (
            String("E:bin(") + String(Int(e.binary_op())) + ","
            + _expr_ir(e.binary_left()) + "," + _expr_ir(e.binary_right()) + ")"
        )
    if e.tag == EXPR_UNARY_OP:
        return (
            String("E:un(") + String(Int(e.unary_op())) + ","
            + _expr_ir(e.unary_child()) + ")"
        )
    if e.tag == EXPR_ALIAS:
        return (
            String("E:as(") + e.alias_name() + "," + _expr_ir(e.alias_child())
            + ")"
        )
    if e.tag == EXPR_IN_LIST:
        var out = String("E:in(") + _expr_ir(e.in_list_child()) + ",["
        for i in range(e.in_list_len()):
            if i > 0:
                out += ","
            out += _scalar_ir(e.in_list_values_ref()[i])
        out += "])"
        return out^
    if e.tag == EXPR_CAST:
        # ★ FOUR OF THESE SIX ARE READ BY NO OTHER LEG AT ANY VALUE.
        # `Expr.write_to` prints `Cast(<child>, <target>)` and stops, so
        # `target_arrow`, `decimal_precision`, `decimal_scale` and `try_cast`
        # are invisible to LEG 1 and therefore to `structural_hash`. They are
        # also invisible to LEG 2 whenever the cast sits somewhere that does
        # not feed the output schema — a filter predicate, which is where the
        # deviating corpus below puts them ON PURPOSE.
        return (
            String("E:cast(") + _expr_ir(e.cast_child())
            + ",target=" + String(e.cast_target())
            + ",target_arrow=" + String(Int(e.cast_target_arrow().type_id))
            + ",decimal_precision=" + String(e.cast_decimal_precision())
            + ",decimal_scale=" + String(e.cast_decimal_scale())
            + ",try_cast=" + _b(e.cast_is_try()) + ")"
        )
    if e.tag == EXPR_CORRELATED_SUBQUERY:
        # ★ THE CROSS-EDGE, WALKED. `_expr_ir` calling `_plan_ir` here is the
        # mutual recursion the codec itself has on exactly this arm, and it is
        # the ONLY leg that crosses it: the plan render prints
        # `inner_tag=<Int>` without recursing, so LEG 1 cannot distinguish two
        # inner plans that share a root tag — Filter(Filter(Scan)) from
        # Filter(Scan), for instance. It also prints `outer_refs=#<count>`
        # rather than the NAMES.
        return (
            String("E:corr(kind=") + String(Int(e.corr_subq_kind()))
            + ",outer_refs=" + _strs(e.corr_subq_outer_refs())
            + ",in_lhs_col=" + e.corr_subq_in_lhs_col()
            + ",in_rhs_col=" + e.corr_subq_in_rhs_col()
            + ",inner_plan=" + _plan_ir(corr_subq_inner_plan_ref(e)) + ")"
        )
    if e.tag == EXPR_WHEN:
        # ★ THE VALUE-LEVEL CHECK FOR A CASE. The render prints every case and
        # the ELSE, so LEG 1 looks too; a render that emitted only the literal
        # `When(...)` would leave LEG 1 and `structural_hash` unable to tell ANY
        # two CASE expressions apart. LEG 2 is nearly as blind: `_infer_expr_field` types
        # a CASE as the type of its FIRST THEN clause, so cases 1..n reach no
        # output schema either — and the corpus puts its When in a FILTER
        # PREDICATE, where even the first one does not.
        #
        # The case INDEX is in the text because ORDER IS SEMANTIC: a CASE
        # returns the first matching branch, so two cases swapped is a
        # different expression and must not compare equal.
        var out = String("E:when(cases=[")
        for i in range(e.when_num_cases()):
            if i > 0:
                out += " "
            out += String(i) + ":"
            out += _expr_ir(e.when_case_condition_ref(i))
            out += "->"
            out += _expr_ir(e.when_case_result_ref(i))
        out += "],default=" + _expr_ir(e.when_default_ref()) + ")"
        return out^
    if e.tag == EXPR_AGG_FN:
        # `AggFnData`'s two `var`s. Both ARE rendered — `AggFn(<op>, <child>)` —
        # so LEG 1 covers this arm; it is read here anyway because the coverage
        # gate's second half asks whether a carried field is COMPARED, and
        # "LEG 1 happens to print it today" is a property of `write_to`, not a
        # property this file states.
        return (
            String("E:aggfn(op=") + String(Int(e.agg_fn_op()))
            + "," + _expr_ir(e.agg_fn_child_ref()) + ")"
        )
    if e.tag == EXPR_EXTRACT:
        # `ExtractData`'s two `var`s. BOTH are rendered — `Extract(unit=<n>,
        # <child>)` — so LEG 1 covers this arm; read here anyway, because "the
        # render happens to print it" is a property of `write_to` and not one
        # this file states. The unit is printed as its ENGINE value, which is
        # what makes the sparse-run structure visible in a diff: 18 is
        # TRUNC_MONTH, and 12 is nothing at all.
        return (
            String("E:extract(unit=") + String(Int(e.extract_unit()))
            + "," + _expr_ir(e.extract_child_ref()) + ")"
        )
    if e.tag == EXPR_MATH_FN:
        return (
            String("E:math1(op=") + String(Int(e.math_fn_op()))
            + "," + _expr_ir(e.math_fn_child_ref()) + ")"
        )
    if e.tag == EXPR_STRING_FN:
        # `StringFnData`'s two `var`s. BOTH are rendered — `StringFn(op=<n>,
        # <child>)` — so LEG 1 covers this arm; read here anyway for the same
        # reason as the arms above, and for one more: this family's `op`
        # decides the OUTPUT TYPE, so a dropped op is a column of the wrong
        # type rather than a wrong value in a right-typed one.
        return (
            String("E:strfn(op=") + String(Int(e.string_fn_op()))
            + "," + _expr_ir(e.string_fn_child_ref()) + ")"
        )
    if e.tag == EXPR_STRING_FN_N:
        # `StringFnNData`'s two `var`s: `op` and `args`.
        #
        # ⛔ THE ARGUMENT COUNT IS WRITTEN OUT, NOT LEFT IMPLICIT IN THE JOINED
        # CHILDREN. `args` is `repeated` on the wire and `repeated` has no
        # length prefix — occurrences ARE the count — so a codec that drops the
        # LAST argument produces a well-formed message. Without `n=` here,
        # `concat(a,b)` and a truncated `concat(a,b,c)` would produce IR that
        # differs only inside the joined children, and for a dropped EMPTY
        # argument they would not differ at all.
        var sfnn_ir = (
            String("E:strfnn(op=") + String(Int(e.string_fn_n_op()))
            + ",n=" + String(e.string_fn_n_num_args())
        )
        for i in range(e.string_fn_n_num_args()):
            sfnn_ir += "," + _expr_ir(e.string_fn_n_arg_ref(i))
        return sfnn_ir + ")"
    if e.tag == EXPR_UDF_CALL:
        # `UdfCallData`'s five `var`s, and the IR
        # states FOUR of them plus the ABSENCE of the fifth.
        #
        # ★ `handle=` IS WRITTEN OUT AS `-` FOR AN UNBOUND NODE, AND WRITING IT
        # IS THE POINT. `UdfCallData.handle` is the one field the wire
        # deliberately does not carry, so LEG 3 must be able to SEE that it did
        # not survive — an IR that omitted the handle would agree with itself
        # whether the codec stripped it or carried it, which is the shape of an
        # assertion that cannot fail. It is the mirror image of `n=` on the
        # `strfnn` arm above: there, the count; here, an absence.
        #
        # ⚠ AND BOTH DTYPES ARE STATED SEPARATELY RATHER THAN JOINED.
        # `UdfCallData.in_type` and `UdfCallData.out_type` are the one place an
        # encoder can SWAP two fields of the same wire type and produce a
        # well-formed message — `plan.proto`'s two
        # `uint32`s are adjacent and interchangeable to protoc — so the corpus
        # carries an `in != out` entry and this IR keeps them apart. Joining
        # them ("types=5/5") would make the swap invisible on every
        # type-preserving UDF, which is what every other cell in this file is.
        var uc_ir = String("E:udf(name=") + e.udf_call_name() + ",handle="
        var uc_h = e.udf_call_handle()
        if uc_h:
            uc_ir += String(uc_h.value())
        else:
            uc_ir += "-"
        return (
            uc_ir
            + ",in=" + String(Int(e.udf_call_in_type().type_id))
            + ",out=" + String(Int(e.udf_call_out_type().type_id))
            + "," + _expr_ir(e.udf_call_child_ref()) + ")"
        )
    if e.tag == EXPR_MATH_FN2:
        # ★ THE OPERANDS ARE POSITIONAL AND THE TEXT SAYS SO. `atan2(y, x)` and
        # `pow(base, exp)` are non-commutative and both operands are FLOAT64,
        # so `left=`/`right=` in the IR is what turns a crossed pair into a
        # diff rather than into a plan that computes a different number.
        return (
            String("E:math2(op=") + String(Int(e.math_fn2_op()))
            + ",left=" + _expr_ir(e.math_fn2_left_ref())
            + ",right=" + _expr_ir(e.math_fn2_right_ref()) + ")"
        )
    if e.tag == EXPR_SUBSTRING:
        return (
            String("E:substr(") + _expr_ir(e.substring_child_ref())
            + ",start=" + String(e.substring_start())
            + ",length=" + String(e.substring_length()) + ")"
        )
    if e.tag == EXPR_STRING_OP:
        # `StringOpData`'s three `var`s. All three ARE rendered —
        # `StringOp(<OPNAME>, <child>, "<pattern>")`, and `_write_strop` prints
        # a distinct name for each of the four members — so LEG 1 covers this
        # arm. Read here anyway: "the render happens to print it" is a property
        # of `expr_helpers._write_strop`, not one this file states.
        return (
            String("E:strop(op=") + String(Int(e.string_op_type()))
            + "," + _expr_ir(e.string_op_child_ref())
            + ",pattern=" + e.string_op_pattern() + ")"
        )
    if e.tag == EXPR_REGEXP:
        # ★ SEVEN FIELDS, AND FOUR OF THEM ARE RENDERED *CONDITIONALLY* — the
        # third kind of render hole this file has met, after "always printed"
        # (Extract / MathFn / Substring) and "never printed" (Cast's four,
        # When's everything). `Expr.write_to` gates `replacement` on
        # `op == REGEXP_REPLACE`, `group` on EXTRACT / EXTRACT_ALL, and
        # `flags` / `group_name` on being non-empty. So LEG 1 covers each of
        # the four on SOME ops and is blind to it on the rest, which is worse
        # than being blind everywhere: a corpus that only used REPLACE would
        # "prove" `replacement` was covered.
        #
        # LEG 2 is blind to six of the seven on ALL ten ops —
        # `_infer_expr_field`'s EXPR_REGEXP arm branches on `op` and reads
        # nothing else.
        return (
            String("E:regexp(op=") + String(Int(e.regexp_op()))
            + "," + _expr_ir(e.regexp_child_ref())
            + ",pattern=" + e.regexp_pattern()
            + ",replacement=" + e.regexp_replacement()
            + ",flags=" + e.regexp_flags()
            + ",group=" + String(e.regexp_group())
            + ",group_name=" + e.regexp_group_name() + ")"
        )
    if e.tag == EXPR_STRUCT_FIELD:
        # The BY-NAME half of a bound twin. The `E:sfield` / `E:sfieldidx`
        # prefixes differ on purpose: folding one variant into the other is a
        # plan that EXECUTES differently (linear scan of `_field_names` vs a
        # direct `_children` index), and this leg must call that a diff.
        return (
            String("E:sfield(") + _expr_ir(e.struct_field_parent_ref())
            + ",name=" + e.struct_field_name() + ")"
        )
    if e.tag == EXPR_STRUCT_FIELD_IDX:
        return (
            String("E:sfieldidx(") + _expr_ir(e.struct_field_idx_parent_ref())
            + ",idx=" + String(e.struct_field_index()) + ")"
        )
    if e.tag == EXPR_MAP_GET:
        # ★ TWO CHILDREN OF THE SAME TYPE IN A NON-INTERCHANGEABLE ORDER, and
        # the text says which is which — the `MathFn2` discipline in a new
        # place. `parent=`/`key=` is what turns a crossed pair into a diff
        # rather than into a plan that looks up the wrong thing.
        return (
            String("E:mapget(parent=") + _expr_ir(e.map_get_parent_ref())
            + ",key=" + _expr_ir(e.map_get_key_ref()) + ")"
        )
    if e.tag == EXPR_JSON_EXTRACT:
        # ★ `output_type` IS READ BY NO OTHER LEG AT ANY VALUE ON ANY OP. The
        # render prints parent, path and `mode=->`/`mode=->>` and stops, and
        # `_infer_expr_field` has NO EXPR_JSON_EXTRACT arm at all — the tag
        # falls to the `else` and types as ArrowType.NULL — so LEG 2 sees the
        # same thing whatever this field says. This line is the only place in
        # the repository where a wrong `output_type` becomes a diff.
        #
        # `path_segments` is printed with an INDEX and a separator that cannot
        # occur inside one, not joined into `$.a.b`: the joined form is what
        # the render uses and it cannot distinguish `["a.b"]` from
        # `["a", "b"]`.
        #
        # All four `var`s of `JsonExtractData` are read here — `parent`,
        # `path_segments`, `output_type` and `preserve_extension_metadata` —
        # through the accessors that prefix each with `json_extract_`.
        var segs = e.json_extract_path_segments()
        var out = String("E:json(") + _expr_ir(e.json_extract_parent_ref())
        out += ",path=["
        for i in range(len(segs)):
            if i > 0:
                out += " "
            out += String(i) + ":" + segs[i]
        out += "],output_type=" + String(Int(e.json_extract_output_type().type_id))
        out += ",preserve_ext=" + _b(
            e.json_extract_preserve_extension_metadata()
        ) + ")"
        return out^
    if e.tag == EXPR_WINDOW_FN:
        # ★ THE VALUE-LEVEL CHECK FOR A WINDOW FUNCTION. The render prints
        # every field (both lists by name, `descending=[T/F..]`, `frame=`), so
        # LEG 1 sees them too; a render that printed only counts would be a
        # plan-cache-key hole (two windows differing only in a name or a frame
        # bound would share one compiled plan). `_infer_expr_field` has
        # no EXPR_WINDOW_FN arm at all, so LEG 2 is blind to the whole node
        # wherever it sits.
        #
        # The two string lists are printed IN ORDER, so a reorder is a diff and
        # not just a membership change: `partition_by=["a","b"]` and
        # `["b","a"]` are different windows and the render prints `#2` for
        # both.
        ref w = e.window_fn_data_ref()
        return (
            String("E:win(func=") + String(Int(w.func))
            + ",col=" + w.arg_col
            + ",offset=" + String(w.arg_offset)
            + ",frame=" + _frame_ir(w.frame)
            + ",partition_by=" + _strs(w.partition_by)
            + ",order_by=" + _strs(w.order_by)
            + ",descending=" + _bools(w.descending) + ")"
        )
    raise Error(
        "LEG 3: no IR comparison for Expr tag " + String(Int(e.tag))
        + ". An arm the codec encodes and this walk does not read is an arm"
        + " whose fields no leg compares."
    )


def _opt_expr_ir(e: Optional[Expr]) raises -> String:
    if e:
        return _expr_ir(e.value())
    return String("-")


def _agg_expr_ir(a: AggExpr) raises -> String:
    """All SIX `var`s. The four child slots are SPARSE — `num_children()` stops
    at the first empty one — so they are read as four, never walked."""
    # `alias` is still a reserved word (the pre-`comptime` spelling), so the
    # local cannot be named for the field.
    var alias_txt = String("-")
    if a.alias_name:
        alias_txt = a.alias_name.value()
    return (
        String("A(func=") + String(Int(a.func))
        + " child=" + _opt_expr_ir(a.child)
        + " child1=" + _opt_expr_ir(a.child1)
        + " child2=" + _opt_expr_ir(a.child2)
        + " child3=" + _opt_expr_ir(a.child3)
        + " alias_name=" + alias_txt + ")"
    )


def _gate_ir(g: PushdownGate) -> String:
    return (
        String("G(mode=") + String(Int(g.mode))
        + " allowed_binary_ops=" + String(Int(g.allowed_binary_ops))
        + " allow_and_recurse=" + _b(g.allow_and_recurse)
        + " allow_in_list=" + _b(g.allow_in_list)
        + " require_stat_friendly_col=" + _b(g.require_stat_friendly_col) + ")"
    )


def _params_ir(p: ScanParams) raises -> String:
    var out = String("P[")
    for i in range(p.num_params()):
        if i > 0:
            out += " "
        var v = p.value_at(i)
        out += p.key_at(i) + "=" + String(Int(v.tag)) + ":"
        if v.tag == PARAM_STR or v.tag == PARAM_BYTES:
            out += v.s
        elif v.tag == PARAM_F64:
            out += String(v.f)
        else:
            out += String(Int(v.i))
    out += "]"
    return out^


def _binding_ir(b: ScanBinding) raises -> String:
    """FOURTEEN carried `var`s. `handle` and `registry_epoch` are ledgered as
    process-local and are deliberately NOT compared — a decoded binding is
    UNBOUND by construction, which is the case the epoch gate passes."""
    var stats = String("-")
    if b.stats:
        stats = String("SOME")
    return (
        String("B(kind_id=") + String(Int(b.kind_id))
        + " kind_name=" + b.kind_name
        + " name=" + b.name
        + " params=" + _params_ir(b.params)
        + " schema=" + _schema_ir(b.schema)
        + " stats=" + stats
        + " fingerprint=" + String(Int(b.fingerprint))
        + " structural_id=" + String(Int(b.structural_id))
        + " snapshot_policy=" + String(Int(b.snapshot_policy))
        + " snapshot_token=" + String(Int(b.snapshot_token))
        + " pushdown_gate=" + _gate_ir(b.pushdown_gate)
        + " pushdown_extra_cols=" + _strs(b.pushdown_extra_cols)
        + " orientation=" + String(Int(b.orientation))
        + " legacy_source_type=" + String(Int(b.legacy_source_type)) + ")"
    )


def _parquet_ir(q: ParquetSource) raises -> String:
    """NINE carried `var`s. Reached only by a corpus with a parquet leaf —
    not this file's. Named here
    so the coverage gate is total over the codec's field universe; see the
    header's note on why that is field coverage and not arm coverage."""
    var nm = String("-")
    if q.name:
        nm = q.name.value()
    var pcols = String("[")
    for i in range(len(q.partition_cols)):
        if i > 0:
            pcols += " "
        pcols += _field_ir(q.partition_cols[i])
    pcols += "]"
    var pvals = String("[")
    for i in range(len(q.partition_values)):
        if i > 0:
            pvals += " "
        pvals += _strs(q.partition_values[i])
    pvals += "]"
    return (
        String("Q(paths=") + _strs(q.paths)
        + " schema_cached=" + _schema_ir(q.schema_cached)
        + " name=" + nm
        + " _mtime_ns=" + String(Int(q._mtime_ns))
        + " partition_cols=" + pcols
        + " partition_values=" + pvals
        + " hive_dir_scan=" + _b(q.hive_dir_scan) + ")"
    )


def _source_ir(s: SourceVariant) raises -> String:
    if s.is_binding_backed():
        return String("src:") + String(Int(s.tag)) + ":" + _binding_ir(s.binding_ref())
    if s.tag == SOURCE_VARIANT_PARQUET:
        return String("src:parquet:") + _parquet_ir(s._parquet.value())
    raise Error(
        "LEG 3: no IR comparison for SourceVariant tag " + String(Int(s.tag))
    )


def _plan_ir(p: LogicalPlan) raises -> String:
    """TOTAL over the sixteen modelled plan arms; RAISES on any other."""
    # ⛔ THERE IS NO `orient=` TERM: a plan carries no orientation. BOTH
    # readers of this IR are self-differentials that compare a plan against
    # ITSELF across the wire (`_assert_round_trips` LEG 3, and `_obs` for the
    # mutation probes). Neither compares against a committed golden, so no
    # recorded string depends on the term set.
    var head = (
        String("[") + String(Int(p.tag)) + " out=" + _schema_ir(p.output_schema)
        + " "
    )
    if p.tag == PLAN_SCAN:
        ref d = p.scan_data_ref()
        var sch = String("-")
        if d.schema:
            sch = _schema_ir(d.schema.value())
        var proj = String("-")
        if d.projection:
            proj = _strs(d.projection.value())
        var rc = String("-")
        if d.row_count:
            rc = String(d.row_count.value())
        var stats = String("-")
        if d.table_stats:
            stats = String("SOME")
        return (
            head + "SCAN source=" + _source_ir(d.source)
            + " schema=" + sch
            + " projection=" + proj
            + " filter=" + _opt_expr_ir(d.filter)
            + " row_count=" + rc
            + " table_stats=" + stats
            + " source_kind=" + String(Int(d.source_kind)) + "]"
        )
    if p.tag == PLAN_FILTER:
        ref d = p.filter_data_ref()
        return (
            head + "FILTER predicate=" + _expr_ir(d.predicate)
            + " udf=" + _b(Bool(d.udf.__bool__()))
            + " child=" + _plan_ir(d.child[]) + "]"
        )
    if p.tag == PLAN_PROJECT:
        ref d = p.project_data_ref()
        var xs = String("[")
        for i in range(len(d.exprs)):
            if i > 0:
                xs += " "
            xs += _expr_ir(d.exprs[i])
        xs += "]"
        return (
            head + "PROJECT exprs=" + xs
            + " is_cse_introduced=" + _b(d.is_cse_introduced)
            + " udf=" + _b(Bool(d.udf.__bool__()))
            + " child=" + _plan_ir(d.child[]) + "]"
        )
    if p.tag == PLAN_AGGREGATE:
        ref d = p.aggregate_data_ref()
        var gb = String("[")
        for i in range(len(d.group_by)):
            if i > 0:
                gb += " "
            gb += _expr_ir(d.group_by[i])
        gb += "]"
        var ax = String("[")
        for i in range(len(d.agg_exprs)):
            if i > 0:
                ax += " "
            ax += _agg_expr_ir(d.agg_exprs[i])
        ax += "]"
        var eg = String("-")
        if d.estimated_groups:
            eg = String(d.estimated_groups.value())
        return (
            head + "AGGREGATE group_by=" + gb + " agg_exprs=" + ax
            + " estimated_groups=" + eg
            + " udf=" + _b(Bool(d.udf.__bool__()))
            + " child=" + _plan_ir(d.child[]) + "]"
        )
    if p.tag == PLAN_JOIN:
        ref d = p.join_data_ref()
        var res = String("-")
        if d.residual:
            res = _expr_ir(d.residual.value()[])
        return (
            head + "JOIN left_on=" + _strs(d.left_on)
            + " right_on=" + _strs(d.right_on)
            + " join_type=" + String(Int(d.join_type))
            + " algo_hint=" + String(Int(d.algo_hint))
            + " residual=" + res
            + " left=" + _plan_ir(d.left[])
            + " right=" + _plan_ir(d.right[]) + "]"
        )
    if p.tag == PLAN_SORT:
        ref d = p.sort_data_ref()
        return (
            head + "SORT keys=" + _strs(d.keys)
            + " descending=" + _bools(d.descending)
            + " nulls_first=" + _bools(d.nulls_first)
            + " child=" + _plan_ir(d.child[]) + "]"
        )
    if p.tag == PLAN_LIMIT:
        ref d = p.limit_data_ref()
        return (
            head + "LIMIT n=" + String(d.n) + " offset=" + String(d.offset)
            + " child=" + _plan_ir(d.child[]) + "]"
        )
    if p.tag == PLAN_DISTINCT:
        ref d = p.distinct_data_ref()
        var cols = String("-")
        if d.columns:
            cols = _strs(d.columns.value())
        var eg = String("-")
        if d.estimated_groups:
            eg = String(d.estimated_groups.value())
        return (
            head + "DISTINCT columns=" + cols + " estimated_groups=" + eg
            + " child=" + _plan_ir(d.child[]) + "]"
        )
    if p.tag == PLAN_TOPN:
        ref d = p.topn_data_ref()
        return (
            head + "TOPN keys=" + _strs(d.keys)
            + " descending=" + _bools(d.descending)
            + " nulls_first=" + _bools(d.nulls_first)
            + " n=" + String(d.n)
            + " child=" + _plan_ir(d.child[]) + "]"
        )
    if p.tag == PLAN_UNION:
        ref d = p.union_data_ref()
        var out = head + "UNION children=["
        for i in range(len(d.children)):
            if i > 0:
                out += " "
            out += _plan_ir(d.children[i][])
        out += "]]"
        return out^
    if p.tag == PLAN_PARTITION_BY:
        # ★ THE RENDER PRINTS A COUNT WHERE THE PAYLOAD IS: `PartitionBy(
        # partition=[…], order=[…], <n> funcs)`. LEG 1 covers the two key
        # lists and knows only HOW MANY `PartitionExpr`s there are — nothing
        # about any one of them — and `descending` is not in the render at any
        # value. This walk is what reads the exprs.
        ref d = p.partition_by_data_ref()
        var pxs = String("[")
        for i in range(len(d.partition_exprs)):
            if i > 0:
                pxs += " "
            pxs += _partition_expr_ir(d.partition_exprs[i])
        pxs += "]"
        return (
            head + "PARTITIONBY partition_keys=" + _strs(d.partition_keys)
            + " order_keys=" + _strs(d.order_keys)
            + " descending=" + _bools(d.descending)
            + " partition_exprs=" + pxs
            + " child=" + _plan_ir(d.child[]) + "]"
        )
    if p.tag == PLAN_PARTITION_TOPN:
        # `func` is printed as its ENGINE NUMBER, not through the render's
        # two-name map: `plan_display` prints `ROW_NUMBER` for 0, `RANK` for 1
        # and `FUNC_<n>` for the other fourteen, so LEG 1 cannot tell PF_SUM
        # from PF_MIN. This line can.
        ref d = p.partition_topn_data_ref()
        var rc = String("-")
        if d.output_rank_col_name:
            rc = d.output_rank_col_name.value().copy()
        return (
            head + "PARTITIONTOPN partition_keys=" + _strs(d.partition_keys)
            + " sort_keys=" + _strs(d.sort_keys)
            + " descending=" + _bools(d.descending)
            + " k=" + String(d.k)
            + " func=" + String(Int(d.func))
            + " over_fetch_k=" + String(d.over_fetch_k)
            + " output_rank_col_name=" + rc
            + " child=" + _plan_ir(d.child[]) + "]"
        )
    if p.tag == PLAN_ASOF_JOIN:
        # `plan_display` prints strategy, the on-pair, the by-pairs, the
        # tolerance kind with its SELECTED slot (nothing at NONE) and each
        # non-empty pre-sort hint. The tolerance's off-kind slot reaches no
        # other leg, so `tolerance` is printed here as all three parts.
        ref d = p.asof_join_data_ref()
        return (
            head + "ASOFJOIN left_keys=" + _strs(d.left_keys)
            + " right_keys=" + _strs(d.right_keys)
            + " left_asof=" + d.left_asof
            + " right_asof=" + d.right_asof
            + " strategy=" + String(Int(d.strategy))
            + " tolerance=(" + String(Int(d.tolerance.tag))
            + "," + String(d.tolerance.int_val)
            + "," + String(d.tolerance.float_val) + ")"
            + " left_sort_keys=" + _strs(d.left_sort_keys)
            + " left_sort_desc=" + _bools(d.left_sort_desc)
            + " right_sort_keys=" + _strs(d.right_sort_keys)
            + " right_sort_desc=" + _bools(d.right_sort_desc)
            + " left=" + _plan_ir(d.left[])
            + " right=" + _plan_ir(d.right[]) + "]"
        )
    if p.tag == PLAN_VIEW_REF:
        # ⚠ `output_schema` HERE IS THE PAYLOAD'S OWN COPY, AND IT IS NOT ON
        # THE WIRE — it is DERIVED at decode from `WirePlan.output_schema`,
        # because `view_ref` fills both from one argument and a duplicate slot
        # was MEASURED unobservable (see the `_UNCARRIED` row). So this line is
        # not a carried-field comparison; it is a check that the derivation put
        # the schema in BOTH places the way the factory does, which is a weaker
        # claim and is said out loud rather than left to look like the other
        # lines in this walk.
        ref d = p.view_ref_data_ref()
        return (
            head + "VIEWREF view_name=" + d.view_name
            + " output_schema=" + _schema_ir(d.output_schema) + "]"
        )
    if p.tag == PLAN_CSE_REF:
        # `canonical_hash` IS this node's `structural_hash` (the plan-level hash
        # special-cases the tag), so LEG 1 covers it twice over on a bare leaf.
        # `output_schema` is the same derived-not-carried situation as VIEWREF's.
        ref d = p.cse_ref_data_ref()
        return (
            head + "CSEREF canonical_hash=" + String(d.canonical_hash)
            + " output_schema=" + _schema_ir(d.output_schema) + "]"
        )
    if p.tag == PLAN_CAST_TO_VARCHAR:
        # The render is `CastToVarchar()` — fifteen characters and no field.
        # There is only the child, and the node's meaning is in the DERIVED
        # output schema `head` prints.
        ref d = p.cast_to_varchar_data_ref()
        return head + "CASTTOVARCHAR child=" + _plan_ir(d.child[]) + "]"
    raise Error(
        "LEG 3: no IR comparison for plan tag " + String(Int(p.tag))
        + ". An arm the codec encodes and this walk does not read is an arm"
        + " whose fields no leg compares."
    )


# =============================================================================
# The three legs
# =============================================================================


def _schema_text(s: Schema) raises -> String:
    var out = String("[")
    for i in range(s.num_columns()):
        if i > 0:
            out += ", "
        out += s.field_name(i)
        out += ":"
        out += String(s.field_arrow_type(i))
        if s.field_nullable(i):
            out += "?"
    out += "]"
    return out^


def _assert_round_trips(q: String, var plan: LogicalPlan) raises:
    var text = String(plan)
    var h = plan.structural_hash()
    var sch = _schema_text(plan.output_schema)
    var ir = _plan_ir(plan)

    var bytes = plan_to_bytes(plan)
    assert_true(
        len(bytes) > 0,
        q + ": the encoder produced ZERO bytes. Without this, a codec that"
        + " encoded nothing and decoded a default plan could satisfy both legs.",
    )
    var back = plan_from_bytes(bytes^)

    assert_equal(
        String(back), text,
        q + ": LEG 1 — the decoded plan RENDERS DIFFERENTLY. Every field the"
        + " render emits is part of plan identity; this diff names the one that"
        + " did not survive the wire.",
    )
    assert_equal(
        String(back.structural_hash()), String(h),
        q + ": LEG 1 — plan TEXT is equal but structural_hash is NOT. The hash"
        + " is FNV-1a over that text, so this can only mean the render has"
        + " stopped being the sole input to plan identity.",
    )
    assert_equal(
        _schema_text(back.output_schema), sch,
        q + ": LEG 2 — the decoded plan promises DIFFERENT output columns. The"
        + " render does not emit output_schema, so LEG 1 cannot see this.",
    )
    assert_equal(
        _plan_ir(back), ir,
        q + ": LEG 3 — a field the codec CARRIES did not survive, and neither"
        + " the render nor the output schema can see it. This leg reads the"
        + " *Data payloads directly, so it is the one that catches a field the"
        + " render SUPPRESSES at its default (nulls_first) and a field the"
        + " render never emits at any value (_tz, _flags, _dict_index_type,"
        + " the metadata pair, the three child lists).",
    )
    _ = plan^


def _assert_refuses(q: String, var plan: LogicalPlan, token: String) raises:
    var raised = False
    var text = String("")
    try:
        var b = plan_to_bytes(plan)
        _ = len(b)
    except e:
        raised = True
        text = String(e)
    assert_true(
        raised,
        q + ": the encoder ACCEPTED a shape the coverage ledger says it"
        + " refuses. A codec that silently encodes around an unsupported shape"
        + " produces bytes that decode into a DIFFERENT plan.",
    )
    assert_true(
        token in text,
        q + ": the encoder raised, but not with '" + token + "'. got: " + text,
    )
    _ = plan^


# =============================================================================
# The corpus — one test per node kind, then the compositions
# =============================================================================


def test_scan_leaf_round_trips() raises:
    """★ THE LEAF THAT MAKES THE GOAL REACHABLE.

    A binding carries kind_id, kind_name, name, a sorted param map, a schema,
    a fingerprint, a content structural_id, a pushdown gate, a snapshot policy
    + token, an orientation and the legacy source type — and NOT a handle or a
    registry epoch, which are process-local by construction. The plan render
    emits `binding=<render()>`, `bsid=` and `bid=<identity_hash()>`, so LEG 1
    covers the params and the derived identity; a param dropped on the wire
    changes `bid` even when it changes nothing else."""
    _assert_round_trips(String("scan(binding)"), _scan(String("t"), String("/x.orc")))


def test_filter_round_trips() raises:
    _assert_round_trips(
        String("filter"),
        LogicalPlan.filter(
            Expr.binary(
                BIN_GT, Expr.col_ref("a"), Expr.literal(ScalarValue.from_int64(Int64(3)))
            ),
            _scan(String("t"), String("/x.orc")),
        ),
    )


def test_a_nested_expression_tree_round_trips() raises:
    """`(a > 3) AND (b < 9)` — a BinaryOp whose operands are BinaryOps. The
    recursion box on the oneof arm is what makes this expressible."""
    _assert_round_trips(
        String("filter(AND)"),
        LogicalPlan.filter(
            Expr.binary(
                BIN_AND,
                Expr.binary(
                    BIN_GT, Expr.col_ref("a"),
                    Expr.literal(ScalarValue.from_int64(Int64(3))),
                ),
                Expr.binary(
                    BIN_LT, Expr.col_ref("b"),
                    Expr.literal(ScalarValue.from_int64(Int64(9))),
                ),
            ),
            _scan(String("t"), String("/x.orc")),
        ),
    )


def test_project_round_trips() raises:
    var e = ExprArray()
    e.append(Expr.col_ref("a"))
    e.append(Expr.alias(Expr.col_ref("b"), String("bee")))
    _assert_round_trips(
        String("project"),
        LogicalPlan.project(e^, _scan(String("t"), String("/x.orc"))),
    )


def test_aggregate_round_trips() raises:
    """AGGREGATE carries the SPARSE four-slot `AggExpr`. The wire carries the
    four slots as four, not as a `repeated` list: `num_children()` stops at the
    first empty slot and cannot enumerate a sparse payload — the same shape
    that made the plan VALIDATOR read only slot 0."""
    var gb = ExprArray()
    gb.append(Expr.col_ref("a"))
    var ax = AggExprArray()
    ax.append(
        AggExpr(AGG_SUM, Optional(Expr.col_ref("b")), Optional(String("total")))
    )
    _assert_round_trips(
        String("aggregate"),
        LogicalPlan.aggregate(gb^, ax^, _scan(String("t"), String("/x.orc"))),
    )


def _assert_nulls_first_deviates(
    what: String, descending: List[Bool], nulls_first: List[Bool]
) raises:
    """★ THE CORPUS MUST BE ADVERSARIAL TO THE DEFAULT, AND SAY SO OUT LOUD.

    `_resolve_nulls_first` derives `derived_nulls_first(descending[i])` when the
    caller passes no override, and `_write_nulls_first` SUPPRESSES the render at
    exactly that value. A corpus sitting on the derived default therefore cannot
    distinguish a codec that CARRIES the field from one that DROPS it: deleting
    `d.nulls_first` from the Sort encoder leaves such a corpus GREEN.

    So the deviation is ASSERTED, not intended. Without this, the next edit to
    tidy up the corpus quietly restores the hole and nothing goes red."""
    assert_equal(
        len(nulls_first), len(descending),
        what + ": the corpus's nulls_first and descending differ in length",
    )
    var deviates = False
    for i in range(len(descending)):
        if nulls_first[i] != (not descending[i]):
            deviates = True
    assert_true(
        deviates,
        what + ": the corpus's nulls_first is EXACTLY what"
        + " _resolve_nulls_first derives from descending, so the render"
        + " suppresses it and dropping the field from the codec is invisible."
        + " Pick a placement that deviates on at least one key.",
    )


def test_sort_round_trips() raises:
    """SORT carries THREE PARALLEL LISTS. A codec that carried `keys` and
    dropped `descending` would render differently, which is what LEG 1 is for.

    ⚠ `nulls_first` IS THE ONE A NAIVE CORPUS DOES NOT COVER. With
    `desc=[True,False]` / `nf=[False,True]` — bit for bit what
    `_resolve_nulls_first` derives — the render prints nothing and the decoder
    re-derives the same list from `descending`. It is DEVIATING on both keys,
    and `_assert_nulls_first_deviates` refuses to let it drift back."""
    var keys: List[String] = [String("a"), String("b")]
    var desc: List[Bool] = [True, False]
    # DEVIATING on both keys: the derived default here is [False, True].
    var nf: List[Bool] = [True, False]
    _assert_nulls_first_deviates(String("sort"), desc, nf)
    _assert_round_trips(
        String("sort"),
        LogicalPlan.sort(
            keys^, desc^, _scan(String("t"), String("/x.orc")), Optional(nf^)
        ),
    )


def test_limit_with_a_nonzero_offset_round_trips() raises:
    """THE OFFSET IS NON-ZERO ON PURPOSE. `LimitData.offset` defaults to 0, and
    proto3 omits zero-valued scalars, so a codec that never wrote the field at
    all would round-trip a `Limit(n, offset=0)` perfectly."""
    _assert_round_trips(
        String("limit"),
        LogicalPlan.limit(5, _scan(String("t"), String("/x.orc")), 2),
    )


def test_distinct_round_trips() raises:
    var cols: List[String] = [String("a")]
    _assert_round_trips(
        String("distinct"),
        LogicalPlan.distinct(
            Optional(cols^), _scan(String("t"), String("/x.orc"))
        ),
    )


def test_topn_round_trips() raises:
    """`TopNData.nulls_first` was WORSE than SortData's: the corpus passed no
    override AT ALL, so the value was the derivation itself and the SDK corpus —
    SQL with no NULLS FIRST/LAST clause — could not reach it either."""
    var keys: List[String] = [String("b")]
    var desc: List[Bool] = [True]
    # DEVIATING: the derived default for descending=[True] is [False].
    var nf: List[Bool] = [True]
    _assert_nulls_first_deviates(String("topn"), desc, nf)
    _assert_round_trips(
        String("topn"),
        LogicalPlan.topn(
            keys^, desc^, 3, _scan(String("t"), String("/x.orc")),
            Optional(nf^),
        ),
    )


def test_join_round_trips() raises:
    """THE TWO BINDINGS DIFFER. A join over one leaf twice would round-trip
    identically for a codec that encoded `left` twice and never read `right`."""
    var lo: List[String] = [String("a")]
    var ro: List[String] = [String("a")]
    _assert_round_trips(
        String("join(INNER)"),
        LogicalPlan.join(
            _scan(String("l"), String("/l.orc")),
            _scan(String("r"), String("/r.orc")),
            lo^, ro^, JOIN_INNER, JOIN_ALGO_AUTO,
        ),
    )


def test_a_join_with_a_residual_and_an_algo_hint_round_trips() raises:
    """`JoinData.residual` defaults to None and `algo_hint` to `JOIN_ALGO_AUTO`,
    which is engine value 0. Both are carried by the corpus above at exactly
    those defaults, so neither the residual box nor a non-AUTO algo mapping was
    reached by any plan in either file."""
    var lo: List[String] = [String("a")]
    var ro: List[String] = [String("a")]
    _assert_round_trips(
        String("join(residual, SORT_MERGE)"),
        LogicalPlan.join(
            _scan(String("l"), String("/l.orc")),
            _scan(String("r"), String("/r.orc")),
            lo^, ro^, JOIN_INNER, JOIN_ALGO_SORT_MERGE,
            Optional(
                OwnedPointer(
                    Expr.binary(
                        BIN_LT,
                        Expr.left("b"),
                        Expr.right("b"),
                    )
                )
            ),
        ),
    )


def test_left_join_round_trips_as_left() raises:
    """★ THE mxframe FAILURE, ON THE WIRE.

    mxframe executes every SQL outer join as an INNER join because nothing
    compares the two. A codec that dropped `join_type` would decode this LEFT
    join as `JOIN_INNER` (wire 0 -> the `*_from_wire` RAISE, or worse, a
    silent 0), and the plan render emits `type=` — so LEG 1 refuses it."""
    var lo: List[String] = [String("a")]
    var ro: List[String] = [String("a")]
    _assert_round_trips(
        String("join(LEFT)"),
        LogicalPlan.join(
            _scan(String("l"), String("/l.orc")),
            _scan(String("r"), String("/r.orc")),
            lo^, ro^, JOIN_LEFT, JOIN_ALGO_AUTO,
        ),
    )


def test_union_round_trips() raises:
    """★ AN ARM NEITHER CORPUS REACHED. `PLAN_UNION` has an encoder, a decoder
    and a `WireUnionNode`, and no plan in this file or in the SDK file carried
    one — so `UnionData.children` was CARRIED-AND-UNTESTED, which is the same
    hole as a default-valued field one level up.

    UNION is also the ONE node whose factory takes its output schema rather
    than deriving it, so `_check_output_schema` is a tautology for this arm
    alone (the codec says so). LEG 3 is what actually compares it here."""
    var kids = List[OwnedPointer[LogicalPlan]]()
    kids.append(OwnedPointer(_scan(String("l"), String("/l.orc"))))
    kids.append(OwnedPointer(_scan(String("r"), String("/r.orc"))))
    kids.append(OwnedPointer(_scan(String("m"), String("/m.orc"))))
    _assert_round_trips(
        String("union(3)"), LogicalPlan.union(kids^, _schema())
    )


def test_a_scan_with_every_optional_populated_round_trips() raises:
    """`ScanData.projection`, `.filter` and `.row_count` are all
    `Optional[...]` defaulting to None, and every scan in the corpus left all
    three at None — so the presence bit, the payload and the decode branch were
    unreached for each. `source_kind` is the fourth: its ctor default is
    `SOURCE_KIND_UNSET` (255) and the binding's declared ROW orientation is
    what carries it off that."""
    var proj: List[String] = [String("a"), String("b"), String("s")]
    _assert_round_trips(
        String("scan(projection, filter, row_count)"),
        LogicalPlan.scan_from_source(
            SourceVariant(
                tag=SOURCE_VARIANT_ORC,
                binding=_binding(String("t"), String("/x.orc")),
            ),
            _schema(),
            Optional(proj^),
            Optional(
                Expr.binary(
                    BIN_GT,
                    Expr.col_ref("a"),
                    Expr.literal(ScalarValue.from_int64(Int64(11))),
                )
            ),
            Optional(4242),
        ),
    )


def test_a_cse_introduced_project_round_trips() raises:
    """`ProjectData.is_cse_introduced` is a Bool defaulting to False, i.e. the
    proto3 zero, so an encoder that never wrote it was byte-identical over the
    whole corpus."""
    var e = ExprArray()
    e.append(Expr.col_ref("a"))
    _assert_round_trips(
        String("project(cse)"),
        LogicalPlan.project(
            e^, _scan(String("t"), String("/x.orc")), True
        ),
    )


def test_every_scalar_kind_round_trips() raises:
    """★ SIXTEEN OF `ScalarValue`'s NINETEEN SLOTS WERE AT ZERO.

    The whole corpus used `from_int64`, which sets `dtype`, `int_val` and
    `_kind` and leaves everything else at the type's zero — and proto3 omits
    zeros, so an encoder that wrote none of the other sixteen produced
    identical bytes. One literal per kind, each with a DISTINCT non-zero
    payload, so a codec that crossed two slots goes red rather than lucky.

    LEG 3 is what compares them: the plan render prints a literal's DISPLAY
    form, which for several kinds does not include every slot that defines it
    (a decimal's precision and scale, an interval's three components).

    ⛔ EIGHT OF THESE TWELVE CANNOT BE BARE PROJECTION EXPRESSIONS. The value
    gate grades every plan position, and a BARE literal in a PROJECTION is
    refused unless `compiler_helpers.broadcast_scalar` has an arm that carries
    it. Every other kind falls to that function's `else: create a zero int64
    column` tail while `_infer_expr_field` declares the literal's OWN type, so
    the batch produced is one whose Schema does not describe its Columns
    (`column_arrow_type` raises `PHYSICAL LAYOUT CONFLICT ... the Column
    carries int64 but the Schema says ...`).

    ⇒ The eight travel in the spelling the refusal itself recommends —
    `<column> OP <literal of that column's own domain>` — and the bool, whose
    only working reader is the PREDICATE one, travels as an `AND` operand.
    Same twelve kinds, same distinct payloads, same slots; only the position
    differs. `Expr.col_idx` is treated the same way for the same reason: this
    corpus may not assert that a plan the door refuses decodes."""
    var e = ExprArray()
    # ---- kinds a bare projection slot CAN carry -----------------------------
    e.append(Expr.alias(Expr.literal(ScalarValue.from_int64(Int64(-7))), String("i")))
    e.append(Expr.alias(Expr.literal(ScalarValue.from_float(1.5)), String("f")))
    e.append(Expr.alias(Expr.literal(ScalarValue.from_string(String("hi"))), String("s")))
    e.append(Expr.alias(Expr.literal(ScalarValue.null(DType.int32)), String("n")))

    # ---- the bool: a PREDICATE operand, the one reader that carries it -------
    # `_literal_is_a_predicate` admits a BOOL and nothing else, and the shape is
    # one that answers CORRECTLY (`(id > 3) AND TRUE`).
    e.append(
        Expr.alias(
            Expr.binary(
                BIN_AND,
                Expr.literal(ScalarValue.from_bool(True)),
                Expr.binary(
                    BIN_GT, Expr.col_ref("a"),
                    Expr.literal(ScalarValue.from_int64(Int64(1))),
                ),
            ),
            String("b"),
        )
    )

    # ---- decimal against the DECIMAL128 column --------------------------------
    e.append(
        Expr.alias(
            Expr.binary(
                BIN_LT, Expr.col_ref("dec"),
                Expr.literal(ScalarValue.decimal128(Int64(3), Int64(9), 18, 4)),
            ),
            String("d128"),
        )
    )

    # ---- the temporal family against the TIMESTAMP column ---------------------
    # `_comparison_domain_of_column(TIMESTAMP_US)` and
    # `_comparison_domain_of_literal` for date32 / timestamp / time / duration /
    # interval are all "temporal", which is the whole domain this engine
    # dispatches on. ONE column serves all five; `_schema()` has no DATE32 /
    # TIME / DURATION column and adding four would be four more things every
    # per-field assertion in this file has to keep in step.
    e.append(
        Expr.alias(
            Expr.binary(
                BIN_LT, Expr.col_ref("ts"),
                Expr.literal(ScalarValue.date32(Int32(19000))),
            ),
            String("dt"),
        )
    )
    e.append(
        Expr.alias(
            Expr.binary(
                BIN_GT, Expr.col_ref("ts"),
                Expr.literal(
                    ScalarValue.timestamp_micros(Int64(1700000000000000))
                ),
            ),
            String("ts"),
        )
    )
    e.append(
        Expr.alias(
            Expr.binary(
                BIN_LT, Expr.col_ref("ts"),
                Expr.literal(
                    ScalarValue.interval_month_day_nano(
                        Int32(3), Int32(5), Int64(7)
                    )
                ),
            ),
            String("iv"),
        )
    )
    e.append(
        Expr.alias(
            Expr.binary(
                BIN_GT, Expr.col_ref("ts"),
                Expr.literal(ScalarValue.time_of_day(Int64(123456))),
            ),
            String("tod"),
        )
    )
    e.append(
        Expr.alias(
            Expr.binary(
                BIN_LT, Expr.col_ref("ts"),
                Expr.literal(ScalarValue.duration(Int64(999))),
            ),
            String("dur"),
        )
    )

    # ---- binary: NO column domain exists for it ------------------------------
    # ⚠ IT IS ADMITTED BY THE CARVE-OUT, NOT BY A MATCH, AND SAYING SO IS THE
    # POINT. `_comparison_domain_of_literal` returns the UNKNOWN sentinel for a
    # BINARY literal, and `_comparison_pair_is_evaluable` answers TRUE whenever
    # either side is unknown — "not judged here". So this position is where it
    # is carried, not where it is proven; the column
    # chosen is `s` because a STRING column is the closest thing this engine has
    # to a byte column and a reader looking for the arm would look there first.
    e.append(
        Expr.alias(
            Expr.binary(
                BIN_LT, Expr.col_ref("s"),
                Expr.literal(ScalarValue.from_binary(String("\x01\x02"))),
            ),
            String("bin"),
        )
    )
    _assert_round_trips(
        String("project(every scalar kind)"),
        LogicalPlan.project(e^, _scan(String("t"), String("/x.orc"))),
    )


def test_an_in_list_and_a_unary_round_trip() raises:
    """`EXPR_IN_LIST` and `EXPR_UNARY_OP` are modelled arms of the codec that
    no plan in either corpus carried — the same carried-and-untested shape as
    PLAN_UNION. IN_LIST is the one with a repeated scalar payload alongside its
    child."""
    var vals: List[ScalarValue] = [
        ScalarValue.from_int64(Int64(1)),
        ScalarValue.from_int64(Int64(2)),
        ScalarValue.from_int64(Int64(3)),
    ]
    _assert_round_trips(
        String("filter(NOT (a IN (1,2,3)))"),
        LogicalPlan.filter(
            Expr.unary(
                UN_NOT, Expr.in_list_node(Expr.col_ref("a"), vals^)
            ),
            _scan(String("t"), String("/x.orc")),
        ),
    )


def _cast_arrow_deviates(e: Expr) raises -> Bool:
    """True when this cast's `target_arrow` is NOT what the engine would DERIVE
    from its `target` — i.e. a decoder that re-derived the Arrow type instead
    of reading the wire would land on a DIFFERENT type.

    The derivation is taken from the ENGINE'S OWN factory (`Expr.cast`, whose
    two-argument `CastData` ctor sets `target_arrow = ArrowType.from_dtype
    (target)`) rather than restated here. A restated derivation is a second
    copy of the rule, and a corpus assertion that drifts from the rule it is
    asserting about is worse than no assertion."""
    var derived = Expr.cast(Expr.col_idx(0), e.cast_target())
    return derived.cast_target_arrow().type_id != e.cast_target_arrow().type_id


def test_a_positional_column_reference_is_refused_at_the_door() raises:
    """★★ ENCODED, AND REFUSED ON THE WAY BACK IN — the one shape in this file
    whose refusal is on the DECODE side.

    ⚠ SO IT CANNOT USE `_assert_refuses`, WHICH ASKS THE ENCODER. `EXPR_COL_IDX`
    keeps its arm in BOTH ladders and its slot in `plan.proto`: the format
    carries it, so bytes already written stay decodable and a future build that
    executes ordinals needs no format change. What refuses is
    `plan_wire_check_values`, which is a statement about what THIS BUILD RUNS.
    (That distinction is also why a refusal-coverage check must NOT see this
    as a refused TAG — a tag with an arm that is asserted refused would be a
    stale rule.)

    Unchecked, `col_idx: 1` against the plan-endpoint fixture's three-column
    schema — a plan meaning exactly `qty > 25`, correct in every particular,
    257 bytes — ends the process through `execute_plan_bytes`. A stack dump,
    not a catchable error. The index bound is necessary and not sufficient.

    ⚠ THE OUT-OF-RANGE CASE MUST STILL LAND ON ITS OWN TOKEN, which is why both
    are asserted here: they are different fixes for the producer, and a gate
    that collapsed them would tell an author with a genuine off-by-one to go and
    rewrite a reference that was fine."""
    var e = ExprArray()
    e.append(Expr.alias(Expr.col_idx(0), String("ci")))
    var plan = LogicalPlan.project(e^, _scan(String("t"), String("/x.orc")))
    var bytes = plan_to_bytes(plan)
    assert_true(
        len(bytes) > 0,
        "the ENCODER must still write a `WireColIdx` — the format carries the"
        " tag, and an encoder that refused it would make bytes an older"
        " producer wrote unreproducible",
    )
    var raised = False
    var text = String("")
    try:
        var _p = plan_from_bytes(bytes^)
    except err:
        raised = True
        text = String(err)
    assert_true(
        raised,
        "★ a plan addressing a column by ORDINAL decoded without complaint."
        " That is the 257-byte SIGSEGV back: this engine does not execute"
        " positional references at any index, and the door is the only place"
        " that can say so before the process is gone.",
    )
    assert_true(
        "PLAN_WIRE_UNSUPPORTED_COL_IDX" in text,
        "the decoder refused, but not by the name a frontend branches on."
        " got: " + text,
    )
    assert_true(
        "col_ref" in text and "'a'" in text,
        "★ THE MESSAGE MUST NAME THE REPLACEMENT. A producer that sent"
        " `col_idx: 0` has already serialized the schema it indexes, so the"
        " whole fix is to send `WireSchema.fields[0].name` instead — and a"
        " refusal that does not say so sends its reader to guess. got: " + text,
    )


def test_an_out_of_range_ordinal_keeps_its_own_token() raises:
    """★ THE ORDER OF THE TWO REFUSALS, ASSERTED. `_check_expr` runs the RANGE
    check first, so an out-of-range ordinal is still
    `PLAN_WIRE_COLUMN_INDEX_OUT_OF_RANGE` and a deployed frontend branching on
    endpoint code 23 goes on seeing it. Swap the two and every out-of-range
    index silently becomes code 28 — which tells the author to send a name, for
    a column that does not exist."""
    var e = ExprArray()
    e.append(Expr.alias(Expr.col_idx(9999), String("ci")))
    var plan = LogicalPlan.project(e^, _scan(String("t"), String("/x.orc")))
    var bytes = plan_to_bytes(plan)
    var text = String("")
    try:
        var _p = plan_from_bytes(bytes^)
    except err:
        text = String(err)
    assert_true(
        text.byte_length() > 0,
        "an out-of-range ordinal decoded without complaint — the 261-byte"
        " SIGSEGV is back",
    )
    assert_true(
        text.startswith("PLAN_WIRE_COLUMN_INDEX_OUT_OF_RANGE")
        or text.startswith("PLAN_WIRE_OUTPUT_SCHEMA_DIVERGED"),
        "an out-of-range ordinal must be refused as an INDEX defect (or, on a"
        " PROJECT, by the earlier derived-schema check), never as"
        " UNSUPPORTED_COL_IDX — the two send the author to different places."
        " got: " + text,
    )


def test_a_cast_round_trips() raises:
    """EXPR_CAST, in the shape every facade actually emits: a projected
    `CAST(b AS DOUBLE)`.

    This one IS visible to LEG 1 (`Cast(ColRef(b), float64)`) and to LEG 2 (the
    project's output schema is derived FROM the cast target), which is exactly
    why it is not sufficient on its own — see the next test."""
    var e = ExprArray()
    e.append(Expr.alias(Expr.cast(Expr.col_ref("b"), DType.float64), String("bf")))
    _assert_round_trips(
        String("project(cast(b AS float64))"),
        LogicalPlan.project(e^, _scan(String("t"), String("/x.orc"))),
    )


def test_every_render_invisible_cast_part_deviates_and_round_trips() raises:
    """★ THE CAST CORPUS THAT IS ADVERSARIAL TO ITS OWN DERIVATION.

    `CastData` has SIX fields and `Expr.write_to` emits TWO of them
    (`Cast(<child>, <target>)`). The other four — `target_arrow`,
    `decimal_precision`, `decimal_scale`, `try_cast` — reach NO render at ANY
    value, which is sub-class (b) of the defaults audit at the top of this
    file: an adversarial corpus alone cannot fix them, because there is no
    value at which LEG 1 looks. LEG 3 is what reads them.

    And they are not merely unrendered, they are DERIVABLE — which is the
    trap. `Expr.cast(child, target)` sets `target_arrow` from `target` and pins
    the decimal pair to (0, 0), so a decoder that re-derived instead of reading
    the wire produces a plan that is IDENTICAL for every ordinary numeric cast.
    That is precisely the `cast_preserving_arrow` bug (`Expr.cast(child^,
    src.cast_target())` silently dropping DATE32 / TIMESTAMP_* / DECIMAL128),
    and a corpus of ordinary numeric casts cannot tell the two apart.

    So every one of the four deviates HERE, and the deviation is ASSERTED:

      try_cast        `try_cast(a AS int32)`      True, vs the ctor default
      decimal pair    `cast(dec AS DECIMAL(18,4))` non-zero AND unequal, so a
                      codec that wrote one slot into the other still goes red
      target_arrow    `cast(ts AS TIMESTAMP_US)`   DType alone cannot express
                      the unit — `_arrow_to_physical_dtype` gives int64, whose
                      DERIVED ArrowType is INT64, not TIMESTAMP_US
      all six at once `cast_from_parts(...)`       a TRY_CAST to DECIMAL(7,3)
                      whose physical DType is int16 — the combination NO
                      query-facing factory can build, which is the case that
                      makes the decoder's totality load-bearing, over a NESTED
                      cast child so the recursion box is exercised too

    They sit in a FILTER PREDICATE, not a projection, deliberately: a projected
    cast feeds the output schema, so `_check_output_schema` and LEG 2 would
    catch a dropped `target_arrow` BY ACCIDENT and with the wrong token. In a
    predicate nothing but LEG 3 is looking."""
    var try_c = Expr.try_cast(Expr.col_ref("a"), DType.int32)
    var dec_c = Expr.cast_to_decimal(Expr.col_ref("dec"), 18, 4)
    var ts_c = Expr.cast_to_arrow(Expr.col_ref("ts"), ArrowType.TIMESTAMP_US)
    var all_c = Expr.cast_from_parts(
        Expr.cast(Expr.col_ref("b"), DType.int16),
        DType.int16,
        ArrowType.DECIMAL128,
        7,
        3,
        True,
    )

    assert_true(
        try_c.cast_is_try() and all_c.cast_is_try(),
        "the corpus's TRY_CAST is not a try cast — `try_cast` defaults to"
        + " False, which is the proto3 zero, so a corpus that never sets it"
        + " cannot distinguish a codec that carries the flag from one that"
        + " drops it.",
    )
    assert_true(
        dec_c.cast_decimal_precision() != 0
        and dec_c.cast_decimal_scale() != 0
        and dec_c.cast_decimal_precision() != dec_c.cast_decimal_scale(),
        "the corpus's DECIMAL cast must carry a precision and a scale that are"
        + " both non-zero AND different from each other: zeros are omitted by"
        + " proto3 entirely, and equal values cannot catch a codec that wrote"
        + " one slot into the other.",
    )
    assert_true(
        _cast_arrow_deviates(dec_c)
        and _cast_arrow_deviates(ts_c)
        and _cast_arrow_deviates(all_c),
        "a cast in this corpus has a `target_arrow` EQUAL to what the engine"
        + " derives from its `target`. At that value a decoder that ignored"
        + " the wire and re-derived is indistinguishable from one that read"
        + " it — which is the `cast_preserving_arrow` bug, unfalsifiable.",
    )

    _assert_round_trips(
        String("filter(four deviating casts)"),
        LogicalPlan.filter(
            Expr.binary(
                BIN_AND,
                Expr.binary(BIN_AND, try_c^, dec_c^),
                Expr.binary(BIN_AND, ts_c^, all_c^),
            ),
            _scan(String("t"), String("/x.orc")),
        ),
    )


def _case_expr() raises -> Expr:
    """`CASE WHEN a > 3 THEN 100 WHEN b < 9 THEN 200 ELSE 300 END`.

    ★ ADVERSARIAL BY CONSTRUCTION, BECAUSE NO LEG BUT LEG 3 IS LOOKING. Every
    part below is chosen so that a codec which crossed two slots, or carried
    only the first case, or dropped the ELSE, produces a DIFFERENT IR string:

      two cases       a one-case corpus cannot see a codec that carries only
                      `cases[0]` — and `_infer_expr_field` types a CASE from
                      the FIRST THEN clause, so cases 1..n change no schema
                      either, at any placement
      cond != result  within each case, so writing the condition into the
                      result slot (or the reverse) is red rather than lucky
      case0 != case1  and in BOTH halves, so a codec that wrote case 0 twice
                      is red
      default unique  distinct from every THEN result, so dropping the ELSE and
                      re-using a result is red
    """
    var cases = List[WhenCaseData]()
    cases.append(
        WhenCaseData(
            Expr.binary(
                BIN_GT, Expr.col_ref("a"),
                Expr.literal(ScalarValue.from_int64(Int64(3))),
            ),
            Expr.literal(ScalarValue.from_int64(Int64(100))),
        )
    )
    cases.append(
        WhenCaseData(
            Expr.binary(
                BIN_LT, Expr.col_ref("b"),
                Expr.literal(ScalarValue.from_int64(Int64(9))),
            ),
            Expr.literal(ScalarValue.from_int64(Int64(200))),
        )
    )
    return Expr.when(
        cases^, Expr.literal(ScalarValue.from_int64(Int64(300)))
    )


def test_a_case_expression_round_trips() raises:
    """★ THE ARM THE PLAN RENDER DOES NOT DESCRIBE AT ALL.

    ⚠ The render prints every case and the ELSE, because the render is the
    plan-compile cache key; a render stub such as `When(...)` would let two
    CASE queries share a compiled plan. Under such a stub LEG 1 and
    `structural_hash` could not distinguish `CASE WHEN a>3 THEN 100 ... END`
    from `CASE WHEN b<9 THEN 7 ELSE 7 END`, and a codec that encoded a WHEN as
    nothing at all would round-trip byte-identically as far as the render is
    concerned. This is sub-class (b) of the defaults audit at the top of this
    file in its purest form: there is no value at which LEG 1 looks, so an
    adversarial corpus alone cannot fix it and LEG 3 is the whole gate.

    The CASE sits in a FILTER PREDICATE deliberately, for the same reason the
    cast corpus does: in a projection `_infer_expr_field` would type the node
    from its FIRST THEN clause and `_check_output_schema` would catch a
    first-case drop BY ACCIDENT, with the wrong token, while still seeing
    nothing at all of cases 1..n or the ELSE."""
    var case_expr = _case_expr()
    assert_true(
        case_expr.when_num_cases() >= 2,
        "the corpus's CASE has fewer than two WHEN branches. With one branch, a"
        + " codec that carries only `cases[0]` is indistinguishable from a"
        + " correct one — and the render prints no case count, so nothing else"
        + " would notice.",
    )
    assert_true(
        _expr_ir(case_expr.when_case_condition_ref(0))
        != _expr_ir(case_expr.when_case_result_ref(0))
        and _expr_ir(case_expr.when_case_condition_ref(1))
        != _expr_ir(case_expr.when_case_result_ref(1)),
        "a WHEN branch in this corpus has a condition equal to its result, so a"
        + " codec that wrote one slot into the other would still compare equal.",
    )
    assert_true(
        _expr_ir(case_expr.when_case_condition_ref(0))
        != _expr_ir(case_expr.when_case_condition_ref(1))
        and _expr_ir(case_expr.when_case_result_ref(0))
        != _expr_ir(case_expr.when_case_result_ref(1)),
        "the corpus's two WHEN branches are equal in one half, so a codec that"
        + " encoded case 0 twice would still compare equal.",
    )
    assert_true(
        _expr_ir(case_expr.when_default_ref())
        != _expr_ir(case_expr.when_case_result_ref(0))
        and _expr_ir(case_expr.when_default_ref())
        != _expr_ir(case_expr.when_case_result_ref(1)),
        "the corpus's ELSE equals one of its THEN results, so a codec that"
        + " dropped the ELSE and re-used a result would still compare equal.",
    )
    _assert_round_trips(
        String("filter(CASE WHEN ... ELSE ...)"),
        LogicalPlan.filter(case_expr^, _scan(String("t"), String("/x.orc"))),
    )


def test_a_nested_case_expression_round_trips() raises:
    """A CASE inside a CASE's THEN, and another inside its ELSE.

    `WireWhenCase.condition` / `.result` are plain `Optional[WireExpr]` while
    `WireWhen.default_expr` is a `List[WireExpr]` RECURSION BOX — protoc-gen-mojo
    boxed the back-edge it found and left the others inline, which is a
    generated decision this file reads off `plan.mojo` rather than assumes. The
    two paths are therefore DIFFERENT code on both sides of the codec, and a
    nested CASE is what exercises both at depth."""
    var inner_then = _case_expr()
    var inner_else = _case_expr()
    var outer = List[WhenCaseData]()
    outer.append(
        WhenCaseData(
            Expr.binary(
                BIN_GT, Expr.col_ref("b"),
                Expr.literal(ScalarValue.from_int64(Int64(1))),
            ),
            inner_then^,
        )
    )
    _assert_round_trips(
        String("filter(CASE WHEN ... THEN CASE(...) ELSE CASE(...) END)"),
        LogicalPlan.filter(
            Expr.when(outer^, inner_else^),
            _scan(String("t"), String("/x.orc")),
        ),
    )


def test_a_case_with_no_when_branches_round_trips() raises:
    """★ ZERO CASES IS A LEGAL ENGINE STATE, AND THE CODEC MUST NOT INVENT A
    RULE THE ENGINE DOES NOT HAVE.

    `WhenData.cases` is a plain `List` with no non-empty invariant, and
    `_infer_expr_field` has an explicit no-cases branch that types the node from
    `default` — so `Expr.when([], default)` is buildable and typeable. A decoder
    that refused it would refuse a plan the engine can construct, which is the
    mirror-image failure of accepting one it cannot.

    `default` is what is NOT optional: `WhenData.default` is a non-Optional
    `OwnedPointer[Expr]`, and an absent `default_expr` on the wire is refused by
    `_one_expr`."""
    _assert_round_trips(
        String("filter(CASE ELSE 7 END)"),
        LogicalPlan.filter(
            Expr.when(
                List[WhenCaseData](),
                Expr.literal(ScalarValue.from_int64(Int64(7))),
            ),
            _scan(String("t"), String("/x.orc")),
        ),
    )


def test_every_agg_fn_member_round_trips() raises:
    """★ THIRTEEN MEMBERS, AND THE ENGINE HAS NO COUNT CONSTANT FOR THE SPACE.

    `agg_expr.mojo` declares the aggregate tags as free `comptime`s and
    nothing anywhere asserts how many there are — a drift hazard, and the
    plan-wire vocabulary generator's AggFn section says so out loud
    ("count_const is empty here rather than guessed").

    So the total is PINNED HERE, as a literal 13, against the DERIVED
    `AGG_FN_WIRE_MEMBERS`. Deriving both sides of that comparison would make it
    true by construction and it would never fire. As written, adding
    `comptime AGG_P99: UInt8 = 13` to the engine moves the derived constant,
    this assertion goes RED, and whoever added the member is told to extend the
    corpus — which is the red-on-good-news signal, one space over.

    Each op is also asserted to BE its index, so a renumbering of the engine
    space (which would silently retype every encoded aggregate, since the wire
    number is engine+1) is red here too.

    AGG_SUM IS ENGINE VALUE 0, which is the whole reason the wire numbering is
    offset: proto3 cannot distinguish an absent enum from an explicit zero, so
    a SUM encoded at wire 0 would be indistinguishable from a field nobody
    wrote."""
    var ops: List[UInt8] = [
        AGG_SUM, AGG_COUNT, AGG_MIN, AGG_MAX, AGG_MEAN, AGG_COUNT_DISTINCT,
        AGG_FIRST, AGG_LAST, AGG_STDDEV_SAMP, AGG_CORR, AGG_MEDIAN,
        AGG_LARGEST_K, AGG_VAR_SAMP,
        # ⭐ The eleven BIVARIATE tags, appended in declaration order (13..23)
        # so the `Int(ops[i]) == i` check below still pins the numbering.
        AGG_COVAR_POP, AGG_COVAR_SAMP, AGG_REGR_AVGX, AGG_REGR_AVGY,
        AGG_REGR_COUNT, AGG_REGR_SXX, AGG_REGR_SXY, AGG_REGR_SYY,
        AGG_REGR_SLOPE, AGG_REGR_INTERCEPT, AGG_REGR_R2,
        # ⭐ The three POPULATION-FINALIZE tags (24..26).
        AGG_VAR_POP, AGG_STDDEV_POP, AGG_SEM,
        # ⭐ The four MONOID-FOLD tags (27..30).
        AGG_COUNT_IF, AGG_BOOL_AND, AGG_BOOL_OR, AGG_PRODUCT,
        # ⭐ The ARRIVAL-ORDER PICK family's third tag, `AGG_ANY_VALUE` (31).
        # Its two siblings `AGG_FIRST` (6) and `AGG_LAST` (7) are at the head
        # of this list.
        AGG_ANY_VALUE,
        # ⭐ The KAHAN-COMPENSATED pair (32, 33) and the HIGHER-MOMENT trio
        # (34..36). ⛔ `AGG_KAHAN_SUM`
        # carries THREE SQL spellings (`fsum` / `kahan_sum` / `sumkahan`, per
        # DuckDB's own `alias_of`) and `AGG_KAHAN_AVG` one; the WIRE space
        # counts TAGS, not names, which is why seven served names add five
        # members here.
        AGG_KAHAN_SUM, AGG_KAHAN_AVG,
        AGG_SKEWNESS, AGG_KURTOSIS, AGG_KURTOSIS_POP,
    ]
    assert_equal(
        len(ops), 37,
        "the corpus does not carry thirteen AggFn members. The engine has no"
        + " count constant for this space, so this list IS the enumeration and"
        + " a short one silently stops testing the members it omits.",
    )
    assert_equal(
        AGG_FN_WIRE_MEMBERS, 37,
        "the DERIVED AggFn vocabulary no longer has thirty-seven members, and this"
        + " corpus still enumerates thirteen. `agg_expr.mojo` declares its"
        + " AGG_* constants free-standing with NO count constant — the stated"
        + " drift hazard — so this literal is the only thing that notices. Add"
        + " the new member to `ops` above and bump both numbers together.",
    )
    for i in range(len(ops)):
        assert_equal(
            Int(ops[i]), i,
            "AggFn engine values are not 0..36 in declaration order. The wire"
            + " number is engine+1, so a renumbering silently retypes every"
            + " encoded aggregate; it must not happen quietly.",
        )
        # A HAVING-shaped predicate: the aggregate-as-expression compared
        # against a literal, which is where `optimizer_scalar_broadcast`
        # actually finds one. `Expr.agg_fn`'s child is a col_ref, and the render
        # prints `AggFn(<op>, <child>)` — so LEG 1 covers this arm; LEG 3
        # compares it anyway, because "the render happens to print it" is a
        # property of `write_to`, not one this file states.
        _assert_round_trips(
            String("filter(AggFn(") + String(i) + String(") > 5)"),
            LogicalPlan.filter(
                Expr.binary(
                    BIN_GT,
                    Expr.agg_fn(ops[i], Expr.col_ref("b")),
                    Expr.literal(ScalarValue.from_int64(Int64(5))),
                ),
                _scan(String("t"), String("/x.orc")),
            ),
        )


def test_an_agg_fn_over_a_case_round_trips() raises:
    """★ WHAT TPC-H Q1 IS MADE OF, AND THE COMPOSITION OF TWO ARMS.

    Q1's `sum(l_extendedprice * (1 - l_discount))` is an aggregate over a
    computed expression, and its `sum(case when ... then ... end)` siblings put
    a CASE under one. Composing them here is not decoration: `AggFnData.child`
    is a RECURSION BOX (`List[WireExpr]`) and `WhenData.default` is another, so
    this plan nests one box inside the other — a shape neither single-arm test
    reaches.

    The aggregate's child is the ONLY place the CASE appears, so a codec that
    dropped `AggFnData.child` would take the whole CASE with it. The render
    prints every case, so LEG 1 sees both the child vanish and the CASE's
    contents change."""
    _assert_round_trips(
        String("filter(SUM(CASE WHEN ... END) > 5)"),
        LogicalPlan.filter(
            Expr.binary(
                BIN_GT,
                Expr.agg_fn(AGG_SUM, _case_expr()),
                Expr.literal(ScalarValue.from_int64(Int64(5))),
            ),
            _scan(String("t"), String("/x.orc")),
        ),
    )


def test_every_math_fn1_member_round_trips() raises:
    """★ EVERY MEMBER, AND MATH_SIN IS ENGINE VALUE 0.

    The same shape as the AggFn sweep one screen up, and for the same reason:
    a corpus that carries ONE member cannot see a codec that pins the op, and
    a corpus that carries only member 0 cannot see one that writes a constant
    zero — which is exactly the value proto3 omits and the +1 wire offset
    exists to keep distinguishable from "absent".

    Unlike AggFn, this space DOES have a derived count, so the literal count is
    pinned against `MATH_FN1_WIRE_MEMBERS`: adding a `comptime MATH_*` to
    `expr.mojo` moves the derived constant, this assertion goes RED, and
    whoever added the member is told to extend the corpus.

    ★ The list below is written out
    member by member rather than generated — the loop's second assertion pins
    `ops[i] == i`, i.e. that the DECLARATION ORDER in `expr.mojo` is the
    engine numbering, and a generated list would satisfy that by construction
    while proving nothing about the constants."""
    var ops: List[UInt8] = [
        MATH_SIN, MATH_COS, MATH_SQRT, MATH_ASIN, MATH_RADIANS,
        MATH_CEIL, MATH_FLOOR, MATH_LN, MATH_EXP, MATH_LOG10, MATH_LOG2,
        MATH_TAN, MATH_ATAN, MATH_ACOS, MATH_COT, MATH_DEGREES, MATH_CBRT,
        MATH_SINH, MATH_COSH, MATH_TANH,
        MATH_ACOSH, MATH_ASINH, MATH_ATANH, MATH_GAMMA,
    ]
    assert_equal(
        len(ops), 24,
        "the corpus does not carry twenty-four MathFn1 members; a short list"
        + " silently stops testing the members it omits.",
    )
    assert_equal(
        MATH_FN1_WIRE_MEMBERS, 24,
        "the DERIVED MathFn1 vocabulary no longer has twenty-four members and"
        + " this corpus still enumerates twenty-four. Add the new MATH_* to"
        + " `ops` above and bump both numbers together.",
    )
    for i in range(len(ops)):
        assert_equal(
            Int(ops[i]), i,
            "MathFn1 engine values are not 0..23 in declaration order. The"
            + " wire number is engine+1, so a renumbering silently re-points"
            + " every encoded scalar-math call at a different libm function.",
        )
        _assert_round_trips(
            String("filter(MathFn(") + String(i) + String(")(a) > 5)"),
            LogicalPlan.filter(
                Expr.binary(
                    BIN_GT,
                    Expr.math_fn(ops[i], Expr.col_ref("a")),
                    Expr.literal(ScalarValue.from_int64(Int64(5))),
                ),
                _scan(String("t"), String("/x.orc")),
            ),
        )


def test_every_string_fn_member_round_trips() raises:
    """★ EVERY STRING-FUNCTION MEMBER — and STRFN_UPPER IS ENGINE VALUE 0.

    The same shape as the MathFn1 sweep one screen up, and for the same
    reason: a corpus that carries ONE member cannot see a codec that pins the
    op, and a corpus carrying only member 0 cannot see one that writes a
    constant zero — the value proto3 omits, which is what the +1 wire offset
    exists to keep distinguishable from "absent".

    ⚠ AND THE STAKE IS HIGHER HERE THAN FOR MathFn1. Every MathFn1 member
    returns FLOAT64, so a dropped op is a wrong NUMBER in a right-typed column.
    This family's op decides the OUTPUT TYPE (`string_fn_returns_int`), so a
    dropped op can be a column of the wrong TYPE: a codec that dropped the op
    would encode `length(s)` as `upper(s)` and hand the caller a Utf8 column
    where an INT64 was promised. Several members return INT64 (`length`,
    `ascii`, `unicode`, `strlen`, `bit_length`) and the rest are Utf8, so a
    dropped op can land on either side of that line.

    `STRING_FN_WIRE_MEMBERS` is the DERIVED count: adding `comptime
    STRFN_LOWER` to `expr.mojo` moves it, this assertion goes RED, and whoever
    added the member is told to extend the corpus."""
    var sfn_ops: List[UInt8] = [
        STRFN_UPPER, STRFN_LOWER, STRFN_TRIM, STRFN_LTRIM, STRFN_RTRIM,
        STRFN_LENGTH, STRFN_REVERSE,
        STRFN_ASCII, STRFN_UNICODE, STRFN_STRLEN, STRFN_BIT_LENGTH,
        STRFN_HEX, STRFN_BIN, STRFN_URL_ENCODE, STRFN_URL_DECODE,
        STRFN_REGEXP_ESCAPE,
        STRFN_MD5, STRFN_SHA1, STRFN_SHA256,
    ]
    assert_equal(
        len(sfn_ops), 19,
        "the corpus does not carry nineteen StringFn members; a short list"
        + " silently stops testing the members it omits.",
    )
    assert_equal(
        STRING_FN_WIRE_MEMBERS, 19,
        "the DERIVED StringFn vocabulary no longer has nineteen members and"
        + " this corpus still enumerates nineteen. Add the new STRFN_* to"
        + " `sfn_ops` above and bump both numbers together.",
    )
    for i in range(len(sfn_ops)):
        assert_equal(
            Int(sfn_ops[i]), i,
            "StringFn engine values are not 0..N in declaration order. The"
            + " wire number is engine+1, so a renumbering silently re-points"
            + " every encoded string call at a different function.",
        )
        _assert_round_trips(
            String("filter(StringFn(") + String(i) + String(")(a) > 5)"),
            LogicalPlan.filter(
                Expr.binary(
                    BIN_GT,
                    Expr.string_fn(sfn_ops[i], Expr.col_ref("a")),
                    Expr.literal(ScalarValue.from_int64(Int64(5))),
                ),
                _scan(String("t"), String("/x.orc")),
            ),
        )


def test_every_string_fn_n_member_round_trips() raises:
    """★ EVERY N-ARY STRING-FUNCTION MEMBER, AND EVERY ARGUMENT IS DISTINCT.

    The same shape as the `StringFn` sweep one screen up, plus TWO hazards
    that family does not have:

    1. **THE ARITY IS PER-OP.** Each node is built at the arity
       `string_fn_n_arity` declares, read from the ENGINE rather than written
       here, so a member whose arity changes takes this test red instead of
       round-tripping a node nothing else would accept.

    2. **`repeated` CARRIES NO LENGTH PREFIX.** A codec that drops the LAST
       argument still produces a well-formed message, so LEG 2 (IR equality)
       is the only leg that can see it — and only if the arguments DIFFER.
       Every operand below is a distinct column name for exactly that reason,
       the rule `test_every_math_fn2_member_round_trips_with_asymmetric_
       operands` states for its non-commutative pair.

    ⚠ AND THE OP DECIDES THE OUTPUT TYPE HERE TOO
    (`string_fn_n_returns_int`): `strpos` is INT64 and others are Utf8,
    so a dropped op is a column of the WRONG TYPE and not merely a wrong
    value."""
    var sfnn_ops: List[UInt8] = [
        STRFNN_CONCAT, STRFNN_CONCAT_WS, STRFNN_REPLACE, STRFNN_LPAD,
        STRFNN_RPAD, STRFNN_REPEAT, STRFNN_STRPOS,
        STRFNN_LEVENSHTEIN, STRFNN_DAMERAU_LEVENSHTEIN, STRFNN_HAMMING,
        STRFNN_TRANSLATE,
        STRFNN_JARO, STRFNN_JARO_WINKLER, STRFNN_JACCARD,
    ]
    assert_equal(
        len(sfnn_ops), 14,
        "the corpus does not carry fourteen StringFnN members; a short list"
        + " silently stops testing the members it omits.",
    )
    assert_equal(
        STRING_FN_N_WIRE_MEMBERS, 14,
        "the DERIVED StringFnN vocabulary no longer has fourteen members and"
        + " this corpus still enumerates fourteen. Add the new STRFNN_* to"
        + " `sfnn_ops` above and bump both numbers together.",
    )
    # ⭐ THE TWO NUMBERS MUST AGREE, NOT ONLY EACH MATCH A LITERAL. Two
    # independent literal pins pass when the corpus enumerates fewer members
    # than the vocabulary (say ten against eleven), and the missing member
    # round-trips through nothing with a green test naming it. The `== i`
    # assertion below cannot see the gap either: it checks the members the
    # list HAS.
    assert_equal(
        len(sfnn_ops), STRING_FN_N_WIRE_MEMBERS,
        "this corpus enumerates fewer StringFnN members than the DERIVED"
        + " vocabulary declares, so the members past the end of the list are"
        + " ENCODED BY NOTHING and the two assertions above both pass. Only"
        + " comparing the two numbers catches that; pinning each to a literal"
        + " does not.",
    )
    # ⚠ REAL COLUMNS OF `_schema()`, AND ALL FOUR DISTINCT. `LogicalPlan.
    # project` resolves every name against the scan's schema and refuses an
    # unknown one by name (`PLAN_WIRE_UNRESOLVED_COLUMN`), so invented names
    # like `c`/`d` fail here long before the codec is reached — and it is the
    # right refusal: a dropped column reference
    # returns wrong rows with nothing saying so.
    #
    # ⛔ AND THEY MUST STAY DISTINCT. This plan is ENCODED and compared, never
    # executed, so the TYPES do not have to be strings — but two equal
    # operands would round-trip cleanly through a codec that wrote `args[0]`
    # into every slot, which is the bug this sweep exists to catch.
    var arg_names: List[String] = [
        String("a"), String("b"), String("s"), String("ts"),
    ]
    for i in range(len(sfnn_ops)):
        assert_equal(
            Int(sfnn_ops[i]), i,
            "StringFnN engine values are not 0..N in declaration order. The"
            + " wire number is engine+1, so a renumbering silently re-points"
            + " every encoded call at a different function.",
        )
        # ⚠ THE ARITY COMES FROM THE ENGINE'S OWN TABLE, never from a number
        # written here — and a VARIADIC member is built at its floor PLUS ONE,
        # so the corpus carries more arguments than the minimum. A codec bug
        # that reads a fixed number of arguments hides at exactly the minimum.
        var want = string_fn_n_arity(sfnn_ops[i])
        var n = want if want > 0 else (-want) + 1
        assert_true(
            n >= 1 and n <= len(arg_names),
            String("StringFnN member ") + String(i) + " wants " + String(n)
            + " arguments and the corpus supplies at most "
            + String(len(arg_names)) + " distinct names. Extend `arg_names`;"
            + " reusing one would let a codec that duplicates an argument"
            + " round-trip cleanly.",
        )
        var args = List[Expr]()
        for k in range(n):
            args.append(Expr.col_ref(arg_names[k]))
        var e = ExprArray()
        e.append(
            Expr.alias(Expr.string_fn_n(sfnn_ops[i], args^), String("o"))
        )
        _assert_round_trips(
            String("project(StringFnN(") + String(i) + String(")/")
            + String(n) + String(" args))"),
            LogicalPlan.project(
                e^, _scan(String("t"), String("/x.orc"))
            ),
        )


def test_every_math_fn2_member_round_trips_with_asymmetric_operands() raises:
    """★ TWO MEMBERS, AND THE OPERANDS ARE NEVER EQUAL.

    `MathFn2Data` is the only arm in this group with TWO children of the SAME
    type in a NON-COMMUTATIVE position. `atan2(y, x)` and `pow(base, exponent)`
    both change VALUE when their operands swap; both produce FLOAT64 either
    way, so LEG 2 and `_check_output_schema` cannot tell — and `write_to`
    prints them in order, so LEG 1 can, but only if they DIFFER.

    A corpus of `atan2(a, a)` would round-trip identically through a codec that
    wrote `left` into both slots. So every operand pair below is distinct, and
    the assertion says so rather than leaving it to a reader to notice."""
    var ops: List[UInt8] = [MATH2_ATAN2, MATH2_POW]
    assert_equal(
        len(ops), 2,
        "the corpus does not carry two MathFn2 members; a short list silently"
        + " stops testing the members it omits.",
    )
    assert_equal(
        MATH_FN2_WIRE_MEMBERS, 2,
        "the DERIVED MathFn2 vocabulary no longer has two members and this"
        + " corpus still enumerates two. Add the new MATH2_* to `ops` above"
        + " and bump both numbers together.",
    )
    for i in range(len(ops)):
        assert_equal(
            Int(ops[i]), i,
            "MathFn2 engine values are not 0..1 in declaration order. The wire"
            + " number is engine+1; a renumbering silently turns every atan2"
            + " into a pow.",
        )
        # The two operands are DIFFERENT EXPRESSIONS, not merely different
        # columns: `sin(a)` on the left and a bare `b` on the right, so a codec
        # that wrote one box into the other produces a visibly different tree
        # rather than a same-shaped one with the columns swapped.
        var node = Expr.math_fn2(
            ops[i], Expr.math_fn(MATH_SIN, Expr.col_ref("a")), Expr.col_ref("b")
        )
        assert_true(
            _expr_ir(node.math_fn2_left_ref())
            != _expr_ir(node.math_fn2_right_ref()),
            "this MathFn2's two operands compare EQUAL. atan2 and pow are"
            + " non-commutative and both operands are FLOAT64, so at equal"
            + " operands a codec that crossed the two recursion boxes is"
            + " indistinguishable from a correct one — by any leg.",
        )
        _assert_round_trips(
            String("filter(MathFn2(") + String(i) + String(")(sin(a), b) > 0)"),
            LogicalPlan.filter(
                Expr.binary(
                    BIN_GT, node^,
                    Expr.literal(ScalarValue.from_int64(Int64(0))),
                ),
                _scan(String("t"), String("/x.orc")),
            ),
        )


def test_every_declared_extract_unit_round_trips() raises:
    """★ TWENTY-FIVE UNITS ACROSS TWO DISJOINT RUNS, WITH A ONE-VALUE HOLE.

    `EXTRACT_*` is the sparsest space in the format: fields are 0..14,
    truncations are 16..25, and **15 alone is declared by NOTHING**. A corpus
    that swept `range(EXTRACT_FIELD_WIRE_MEMBERS)` would therefore be testing
    units 0..24 — one of which does not exist and nine of which (16..24) are
    real — so the sweep enumerates the CONSTANTS, and the count is pinned
    against the derived `EXTRACT_FIELD_WIRE_MEMBERS` so a new unit cannot
    arrive untested.

    ⚠ THE FIELD RUN IS 0..14 AND THE HOLE IS ONE VALUE. A new unit arrives
    with a new line here because the assertion below goes RED, not because
    anyone remembered — that is the event this count exists to force a reader
    through.

    ⛔ THE RESERVED SPACE IS FULL. A further field unit cannot simply take
    16+ — that is the truncation run, and `_is_trunc_unit` is an OPEN-ENDED
    `>= 16` that the type ladder, the capability gate and both executors
    DELEGATE to. See the note in `expr.mojo`; it is a decision, not a step.

    ⚠ `_infer_expr_field` HAS NO EXTRACT ARM — it falls through to
    `Field("expr", NULL, True)` — so LEG 2 types every one of these the same
    way and is blind to the unit at every value. That is an engine gap, not
    this codec's, and it is exactly why the unit is compared by LEG 1 (the
    render prints `Extract(unit=<n>, ...)`) and by LEG 3."""
    var units: List[UInt8] = [
        EXTRACT_YEAR, EXTRACT_QUARTER, EXTRACT_MONTH, EXTRACT_DAY,
        EXTRACT_HOUR, EXTRACT_MINUTE, EXTRACT_SECOND,
        EXTRACT_DAYOFWEEK, EXTRACT_ISODOW, EXTRACT_DAYOFYEAR,
        EXTRACT_WEEK, EXTRACT_ISOYEAR, EXTRACT_YEARWEEK,
        EXTRACT_MILLISECOND, EXTRACT_MICROSECOND,
        EXTRACT_TRUNC_YEAR, EXTRACT_TRUNC_QUARTER, EXTRACT_TRUNC_MONTH,
        EXTRACT_TRUNC_WEEK, EXTRACT_TRUNC_DAY,
    ]
    # The five remaining truncations are declared but have no named import
    # above; they are swept by value so the enumeration is complete without
    # this file restating five constants it does not otherwise use.
    for u in range(21, 26):
        units.append(UInt8(u))
    assert_equal(
        len(units), EXTRACT_FIELD_WIRE_MEMBERS,
        "the corpus does not sweep every DECLARED ExtractField unit. The space"
        + " is SPARSE — 0..6 and 16..25 — so `range(count)` is the wrong"
        + " enumeration and this list is the right one; a member added to"
        + " either run must be added here too.",
    )
    for i in range(len(units)):
        assert_true(
            extract_field_is_declared(units[i]),
            "the corpus sweeps an ExtractField unit the engine does not"
            + " declare. The encoder REFUSES those (see the hole test below),"
            + " so such an entry would fail for the wrong reason.",
        )
        _assert_round_trips(
            String("filter(extract(unit=") + String(Int(units[i]))
            + String(")(ts) > 5)"),
            LogicalPlan.filter(
                Expr.binary(
                    BIN_GT,
                    Expr.extract(units[i], Expr.col_ref("ts")),
                    Expr.literal(ScalarValue.from_int64(Int64(5))),
                ),
                _scan(String("t"), String("/x.orc")),
            ),
        )


def test_an_extract_unit_in_the_sparse_hole_is_refused() raises:
    """★ THE HOLE IS REACHABLE FROM THE ENGINE'S OWN FACTORY.

    ⚠⚠ THE VALUE IS 15: the ONLY value between the field run (0..14) and the
    truncation run (16..25). If a unit ever takes it, this test would exercise
    a unit that round-trips — a green assertion about the opposite of its own
    subject — so the assertion immediately below refuses that in its message.
    When 15 is taken this test has to be re-founded, not re-pointed, because a
    value ABOVE the whole space is refused by a range check too and would stop
    discriminating.

    `Expr.extract(unit, child)` and `Expr.date_trunc(unit, child)` take a raw
    `UInt8`, so a caller can build an `ExtractData` whose unit is 15 — between
    the field run and the truncation run — and the engine will
    happily hold it. It is not a `date_trunc` to anything.

    A codec that range-checked would ACCEPT it: 15 narrows into a `UInt8`
    losslessly. This is the same distinction the ArrowType narrowing turns on
    (50 narrows fine and is still not a type), and the refusal names the SPACE
    so a caller learns which vocabulary rejected it.

    ⚠ THE TOKEN HERE IS NOT A `PLAN_WIRE_*` ONE, AND THAT IS CORRECT. The
    refusal comes from `extract_field_to_wire` in the DERIVED vocabulary, one
    layer below this codec — the same generated function every other space uses
    — so asserting a `PLAN_WIRE_*` token would mean this codec had restated a
    membership rule the generator already owns."""
    assert_true(
        not extract_field_is_declared(UInt8(15)),
        "engine unit 15 is now a DECLARED ExtractField. The sparse hole this"
        + " test is about has closed, and there is NO other value between the"
        + " two runs to move to — the field run is 0..14 and the truncation"
        + " run starts at 16. Re-found this test on whatever the new"
        + " between-runs value is after the unit space is restructured; do NOT"
        + " re-point it at a value ABOVE the whole space, which a range check"
        + " would refuse too and which therefore tests nothing.",
    )
    _assert_refuses(
        String("extract(unit=15)"),
        LogicalPlan.filter(
            Expr.binary(
                BIN_GT,
                Expr.extract(UInt8(15), Expr.col_ref("ts")),
                Expr.literal(ScalarValue.from_int64(Int64(5))),
            ),
            _scan(String("t"), String("/x.orc")),
        ),
        String("ExtractField"),
    )


def test_a_substring_round_trips_with_both_length_forms() raises:
    """★ THE ONE SCALAR IN THIS GROUP WHOSE ENGINE DEFAULT IS NOT THE PROTO3
    DEFAULT.

    `Expr.substring(child, start)` is the two-argument SQL form and the engine
    spells "to end of string" as `length = -1`. So the field has TWO values a
    lazy corpus lands on for opposite reasons: 0, which proto3 omits entirely,
    and -1, which is the factory default. Both forms are here.

      three-arg   start=3, length=4 — both non-zero AND DIFFERENT from each
                  other, so a codec that wrote one slot into the other is red
                  rather than lucky
      two-arg     start=2, length=-1 — the open-ended form. An encoder that
                  dropped `length` yields 0 at decode, which is not a smaller
                  substring; it is a plan that returns empty strings.
      shortfall   start=1, length=-3 — a NEGATIVE THAT IS NOT -1. ⛔ IT IS THE ONLY ONE OF
                  THE THREE THAT CAN CATCH A CLAMP.

    Both sit in a PROJECT, so LEG 2 and `_check_output_schema` also run over
    them (`_infer_expr_field` types a substring STRING at any start/length,
    which is precisely why they cannot see either scalar move)."""
    var three = Expr.substring(Expr.col_ref("s"), 3, 4)
    var two = Expr.substring(Expr.col_ref("s"), 2)
    # ⛔⛔ THE SENTINEL IS A FAMILY, AND THE TWO CASES ABOVE CANNOT TELL A
    # CLAMP FROM A CORRECT CODEC. A `length` of -k for k >= 2 means "to end,
    # dropping k-1 trailing
    # CHARACTERS" — the encoding `left(s, NEGATIVE)` desugars to, resolved
    # against the string's own character count in
    # `compiler_eval_column._sql_substring_bytes`. A decoder that normalised
    # every negative to -1 would still satisfy `two.substring_length() < 0`
    # below, and would silently turn `left('abcde', -3)` from `'ab'` into
    # `'abcde'`: a WRONG ANSWER on a plan that crossed the wire, not a
    # refusal. `shortfall` is the only member of this test that goes red for
    # it, which is why it carries -3 and not -2 — -2 is one step from -1 and
    # an off-by-one in a clamp would survive it.
    var shortfall = Expr.substring(Expr.col_ref("s"), 1, -3)

    assert_true(
        three.substring_start() != 0
        and three.substring_length() != 0
        and three.substring_start() != three.substring_length(),
        "the three-argument substring must carry a start and a length that are"
        + " both non-zero AND different from each other: proto3 omits zeros"
        + " entirely, and equal values cannot catch a codec that wrote one"
        + " slot into the other.",
    )
    assert_true(
        shortfall.substring_length() == -3,
        "the shortfall substring's length is not -3. This is the member of the"
        + " family that is NEGATIVE BUT NOT THE FACTORY DEFAULT, so it is the"
        + " only one a decoder that clamps every negative to -1 (or lets the"
        + " -1 default supply it) cannot pass. `-3` means `left(s, -2)` ="
        + " 'all but the last two characters'; clamped to -1 it becomes 'the"
        + " whole string'.",
    )
    assert_true(
        two.substring_length() < 0,
        "the two-argument substring's length is not NEGATIVE. `length < 0` is"
        + " how this engine spells `substring(s, start)`, and it is the"
        + " factory DEFAULT — a decoder that let the default supply it instead"
        + " of reading the wire would be indistinguishable from a correct one"
        + " over a corpus that only used this form.",
    )

    var e = ExprArray()
    e.append(Expr.alias(three^, String("s34")))
    e.append(Expr.alias(two^, String("s2end")))
    e.append(Expr.alias(shortfall^, String("sshort")))
    _assert_round_trips(
        String("project(substring(s,3,4), substring(s,2), substring(s,1,-3))"),
        LogicalPlan.project(e^, _scan(String("t"), String("/x.orc"))),
    )


def test_the_four_scalar_arms_compose_round_trips() raises:
    """★ ALL FOUR OF THIS GROUP'S ARMS IN ONE TREE, NESTED THROUGH EACH OTHER.

    Each single-arm test above reaches its arm with a col_ref child, so none of
    them exercises an arm's recursion box holding ANOTHER of this group's arms.
    Here `atan2` takes a `radians(...)` on the left and a `sqrt(extract(...))`
    on the right — one recursion box inside another, with the operands still
    asymmetric — and the substring rides alongside so the plan carries all four
    tags at once.

    The nesting is not decoration: `_one_expr` refuses a box holding 0 or 2,
    and a box that has only ever held a leaf has never been asked to carry a
    subtree whose own encode can raise."""
    var nested = Expr.math_fn2(
        MATH2_ATAN2,
        Expr.math_fn(MATH_RADIANS, Expr.col_ref("a")),
        Expr.math_fn(
            MATH_SQRT,
            Expr.extract(EXTRACT_TRUNC_MONTH, Expr.col_ref("ts")),
        ),
    )
    assert_true(
        _expr_ir(nested.math_fn2_left_ref())
        != _expr_ir(nested.math_fn2_right_ref()),
        "the composed MathFn2's operands compare EQUAL, so a crossed pair"
        + " would be invisible here too.",
    )
    _assert_round_trips(
        String("filter(atan2(radians(a), sqrt(trunc_month(ts))) > substring(s,3,4))"),
        LogicalPlan.filter(
            Expr.binary(
                BIN_AND,
                Expr.binary(
                    BIN_GT, nested^,
                    Expr.literal(ScalarValue.from_int64(Int64(0))),
                ),
                Expr.binary(
                    BIN_GT,
                    Expr.substring(Expr.col_ref("s"), 3, 4),
                    Expr.literal(ScalarValue.from_string(String("ab"))),
                ),
            ),
            _scan(String("t"), String("/x.orc")),
        ),
    )


# =============================================================================
# The string-and-struct group — six arms
# =============================================================================


def test_every_string_op_member_round_trips() raises:
    """All FOUR members, each with its own pattern.

    `STR_CONTAINS` IS ENGINE VALUE 0, which is the reason the wire is offset by
    one: proto3 cannot distinguish an absent enum from an explicit zero, so a
    `contains` written at wire 0 and a field nobody wrote are the same bytes.
    Enumerating from the DERIVED member count rather than from a hand-written
    list is what makes "all four" true — a fifth member added to the engine
    lands in `STRING_OP_WIRE_MEMBERS` and this loop covers it with no edit."""
    assert_equal(
        STRING_OP_WIRE_MEMBERS, 4,
        "the derived StringOp vocabulary no longer has four members. If the"
        + " engine grew one, this loop already covers it — update the count."
        + " If it SHRANK, a wire number has been reused.",
    )
    var ops: List[UInt8] = [
        STR_CONTAINS, STR_STARTS_WITH, STR_ENDS_WITH, STR_LIKE,
    ]
    assert_equal(
        len(ops), STRING_OP_WIRE_MEMBERS,
        "the hand-written op list and the derived member count disagree.",
    )
    for i in range(len(ops)):
        # A DIFFERENT pattern per op, so a codec that wrote a constant — or
        # that wrote the op into the pattern slot — cannot be lucky.
        var pat = String("p") + String(i) + String("%")
        _assert_round_trips(
            String("filter(string_op(op=") + String(Int(ops[i])) + "))",
            LogicalPlan.filter(
                Expr.string_op(ops[i], Expr.col_ref("s"), pat),
                _scan(String("t"), String("/x.orc")),
            ),
        )


def test_every_unary_op_member_round_trips() raises:
    """All EIGHT members of the `UnaryOp` space, in ONE project.

    ⭐ EVERY OP SPACE WITH A `*_WIRE_MEMBERS` CONSTANT NEEDS A CORPUS READING
    IT. Carried by a single hand-written `UN_NOT` node, a codec that shifted the
    unary op by one would have a small chance of being noticed and zero chance
    for any member above `UN_NOT`.

    ⚠ THE COUNT AND THE LIST ARE BOTH PINNED, and the list is written out
    MEMBER BY MEMBER on purpose. The loop asserts nothing about `ops[i] == i`
    here — the space is DENSE from 0 and the vocabulary generator already
    pins the engine range — but writing the members out is what makes a
    RENUMBERING red: a generated `range(8)` would satisfy this test by
    construction while every encoded call silently re-pointed.

    LEG 2 discriminates `UN_SIGN` from the other numeric members ALL BY
    ITSELF: it is the one member of this space whose output type is neither
    BOOL nor the child's, so a codec that confused it with `UN_ABS` changes
    the project's declared output type from INT64 to INT8. LEG 1 separates the
    rest through `_write_unop`, and LEG 3 through the raw op integer."""
    assert_equal(
        UNARY_OP_WIRE_MEMBERS, 9,
        "the derived UnaryOp vocabulary no longer has nine members. If the"
        + " engine grew one, ADD IT TO `ops` below — this loop does NOT cover"
        + " it automatically, deliberately. If it SHRANK, a wire number has"
        + " been reused and every encoded plan carrying it now decodes to a"
        + " different operator.",
    )
    var ops: List[UInt8] = [
        UN_NOT, UN_NEGATE, UN_IS_NULL, UN_IS_NOT_NULL,
        UN_ABS, UN_SIGN, UN_TRUNC, UN_ROUND,
        # Added BY HAND, as the message above demands. `b` is the NULLABLE
        # INT64 column, which is the operand
        # width this member's kernel is instantiated at on the far side.
        UN_BIT_COUNT,
    ]
    assert_equal(
        len(ops), UNARY_OP_WIRE_MEMBERS,
        "the hand-written op list and the derived member count disagree.",
    )
    var e = ExprArray()
    for i in range(len(ops)):
        var op = ops[i]
        # UN_NOT is the ONE member whose child must be a PREDICATE (see
        # `plan_wire_values`' note on it); every other member takes a value.
        # `b` is the NULLABLE INT64 column, so the type-preserving members
        # carry nullability across the wire as well as width.
        var child: Expr
        if op == UN_NOT:
            child = Expr.binary(
                BIN_LT,
                Expr.col_ref("b"),
                Expr.literal(ScalarValue.from_int64(Int64(7) + Int64(i))),
            )
        else:
            child = Expr.col_ref("b")
        e.append(
            Expr.alias(Expr.unary(op, child^), String("u") + String(i))
        )
    _assert_round_trips(
        String("project(every unary op, incl. the type-preserving numerics)"),
        LogicalPlan.project(e^, _scan(String("t"), String("/x.orc"))),
    )


def _regexp_render_hides(e: Expr) raises -> Bool:
    """True when `Expr.write_to` prints NEITHER `group` NOR `replacement` for
    this node even though it carries both at a non-default value.

    This is the assertion that makes the deviation below real rather than
    asserted-in-a-comment: the render's REGEXP arm gates `replacement` on
    `op == REGEXP_REPLACE` and `group` on EXTRACT / EXTRACT_ALL, so a node on
    any OTHER op carries both invisibly."""
    var txt = String(e)
    return (
        e.regexp_group() != 0
        and e.regexp_replacement().byte_length() > 0
        and "group=" not in txt
        and "replacement=" not in txt
    )


def test_every_regexp_op_member_round_trips() raises:
    """All TEN members, each carrying a DIFFERENT pattern and flags.

    `REGEXP_LIKE` is engine value 0 — the offset-by-one reason again. The op
    also DECIDES the output type (`_infer_expr_field` returns BOOL for LIKE /
    FULL_MATCH, List<Utf8> for MATCH / SPLIT / EXTRACT_ALL, STRING for
    REPLACE / SUBSTR, INT64 for COUNT / INSTR), so putting these in a PROJECT
    makes LEG 2 discriminate the op as well — a codec that shifted the op by
    one would land on a different output type, not merely a different name."""
    assert_equal(
        REGEXP_OP_WIRE_MEMBERS, 10,
        "the derived RegexpOp vocabulary no longer has ten members.",
    )
    var ops: List[UInt8] = [
        REGEXP_LIKE, REGEXP_MATCH, REGEXP_REPLACE, REGEXP_EXTRACT,
        REGEXP_SPLIT_TO_ARRAY, REGEXP_EXTRACT_ALL, REGEXP_COUNT,
        REGEXP_INSTR, REGEXP_SUBSTR, REGEXP_FULL_MATCH,
    ]
    assert_equal(
        len(ops), REGEXP_OP_WIRE_MEMBERS,
        "the hand-written op list and the derived member count disagree.",
    )
    var e = ExprArray()
    for i in range(len(ops)):
        # Every one of the six non-op fields DEVIATES from its default, and
        # from the others', on every node:
        #   pattern      — distinct per op
        #   replacement  — non-empty (the default is "")
        #   flags        — non-empty (the default is "")
        #   group        — non-zero AND different from the index it would be
        #                  confused with (i + 3, so never equal to `i`)
        #   group_name   — non-empty (the default is "")
        e.append(
            Expr.alias(
                Expr.regexp(
                    ops[i],
                    Expr.col_ref("s"),
                    String("^a") + String(i) + String("(?P<g>b+)$"),
                    String("R") + String(i),
                    String("i"),
                    i + 3,
                    String("g"),
                ),
                String("r") + String(i),
            )
        )
    _assert_round_trips(
        String("project(every regexp op, all six scalars deviating)"),
        LogicalPlan.project(e^, _scan(String("t"), String("/x.orc"))),
    )


def test_the_regexp_fields_the_render_hides_deviate_and_round_trip() raises:
    """★ THE RENDER COVERS A REGEXP FIELD ON SOME
    OPS AND NOT OTHERS, SO A CORPUS THAT ONLY USED THE COVERED OPS WOULD
    "PROVE" A FIELD TESTED THAT NOTHING TESTS.

    This is a third kind of render hole, and it is nastier than the two this
    file already documents. `Cast`'s four parts reach NO render at ANY value
    and `When` renders nothing at all — both are uniform, and both are obvious
    once looked at. `Regexp` prints:

        replacement   only when op == REGEXP_REPLACE
        group         only when op is REGEXP_EXTRACT or REGEXP_EXTRACT_ALL
        flags         only when non-empty
        group_name    only when non-empty

    So `test_every_regexp_op_member_round_trips` above, which does include
    REPLACE and EXTRACT, would let a reader conclude LEG 1 covers all four.
    It does not: on the other seven ops it covers none of them. This test
    pins a node on REGEXP_COUNT — an op that renders NEITHER `group` nor
    `replacement` — carrying both at non-default values, and ASSERTS that the
    render hides them, so the day someone widens `write_to` this test says so
    rather than silently becoming a weaker duplicate of the one above.

    LEG 2 is blind on every op: `_infer_expr_field`'s EXPR_REGEXP arm branches
    on `op` and reads nothing else. LEG 3 is the only thing looking."""
    var hidden = Expr.regexp(
        REGEXP_COUNT,
        Expr.col_ref("s"),
        String("x+"),
        String("REPLACEMENT-THE-RENDER-DOES-NOT-PRINT"),
        String(""),
        9,
        String(""),
    )
    assert_true(
        _regexp_render_hides(hidden),
        "the REGEXP render now prints `group` and/or `replacement` on"
        + " REGEXP_COUNT. That is GOOD NEWS and this test is the red that"
        + " reports it: rewrite the assertion to name whichever fields the"
        + " render still hides, or delete it if it hides none. Render text: "
        + String(hidden),
    )
    # ⚠ THE HIDDEN NODE GOES IN A PLAN BY ITSELF, AND IN A TEST BY ITSELF.
    # Putting it beside the shown node below would make every mutation red on
    # LEG 1 through the shown half, and the claim being made here is precisely
    # that the hidden half is red on LEG 3 *alone*. Two tests is what makes
    # that a controlled comparison instead of a slogan.
    _assert_round_trips(
        String("filter(regexp_count with a group and a replacement LEG 1 hides)"),
        LogicalPlan.filter(
            Expr.binary(
                BIN_GT, hidden^,
                Expr.literal(ScalarValue.from_int64(Int64(0))),
            ),
            _scan(String("t"), String("/x.orc")),
        ),
    )


def test_the_regexp_fields_the_render_shows_are_the_control() raises:
    """THE OTHER HALF OF THE CONTROLLED PAIR ABOVE — the SAME two fields on an
    op that DOES render them.

    The pair is what turns "LEG 3 alone sees the hidden node" into a
    measurement rather than a claim: one drop-a-field mutation applied to the
    encoder must make THIS test red on LEG 1 (the plan TEXT) and the test
    above red on LEG 3 (the IR walk). Same mutation, two different legs,
    decided entirely by which op `Expr.write_to` is looking at."""
    var shown = Expr.regexp(
        REGEXP_EXTRACT,
        Expr.col_ref("s"),
        String("(a)(b)"),
        String(""),
        String("im"),
        2,
        String("second"),
    )
    assert_true(
        "group=" in String(shown),
        "REGEXP_EXTRACT no longer renders `group`, so the controlled half of"
        + " this comparison has stopped being controlled.",
    )
    _assert_round_trips(
        String("filter(regexp_extract with a group LEG 1 shows)"),
        LogicalPlan.filter(
            Expr.binary(
                BIN_GT, shown^,
                Expr.literal(ScalarValue.from_string(String("a"))),
            ),
            _scan(String("t"), String("/x.orc")),
        ),
    )


def test_the_struct_field_twins_round_trip_as_two_different_nodes() raises:
    """BOTH HALVES OF A BOUND TWIN, IN ONE PLAN, WITH THE SAME ANSWER.

    `st` declares children `k` (INT32, non-nullable) and `v` (STRING,
    nullable), so `field("v")` and `field_idx(1)` name the SAME column and
    infer the SAME output Field. That is exactly why they belong in one test:
    a codec that decoded one tag into the other would produce a plan with an
    IDENTICAL output schema, so LEG 2 cannot see the fold and only the render
    (`StructField` vs `StructFieldIdx`) and LEG 3 (`E:sfield` vs
    `E:sfieldidx`) can.

    The index is 1 and not 0 for the ordinary proto3 reason: 0 is omitted on
    the wire, so an encoder that never wrote `field_idx` and one that wrote 0
    emit identical bytes. It also picks the child whose type and nullability
    both DIFFER from child 0's, so a codec that resolved the wrong child is a
    schema diff and not a name diff."""
    var by_name = Expr.struct_field(Expr.col_ref("st"), String("v"))
    var by_idx = Expr.struct_field_idx(Expr.col_ref("st"), 1)
    assert_true(
        by_idx.struct_field_index() != 0,
        "the by-index twin must not use index 0 — proto3 omits a zero-valued"
        + " scalar, so an encoder that never wrote the field is"
        + " byte-identical to one that wrote 0.",
    )
    assert_true(
        _expr_ir(by_name) != _expr_ir(by_idx),
        "the two twins compare EQUAL in the IR leg, so a codec that folded"
        + " one into the other would be invisible to the only leg that can"
        + " see it.",
    )
    var e = ExprArray()
    e.append(Expr.alias(by_name^, String("vn")))
    e.append(Expr.alias(by_idx^, String("vi")))
    _assert_round_trips(
        String("project(st.field(\"v\"), st.field_idx(1))"),
        LogicalPlan.project(e^, _scan(String("t"), String("/x.orc"))),
    )


def test_a_map_get_round_trips_with_asymmetric_children() raises:
    """★ THE `MathFn2` OPERAND TRAP IN A NEW PLACE.

    `MapGetData.parent` and `.key` are both `Expr`, and the wire carries them
    as two separate recursion boxes, so a codec that wrote one into the
    other's slot emits a structurally valid message. Both a LITERAL key (the
    constant-key form, `col("mp").get(lit("city"))`) and a COLUMN key (the
    per-row form) are here, because they are different shapes on the wire —
    the second is the one where a crossed pair would still be two column
    references and still type-check.

    `mp` is a MAP whose Schema-level children are `key` (STRING) and `value`
    (INT64), so `_infer_expr_field` resolves the projection to child[1]'s
    INT64 — a codec that read child[0] instead would be a LEG 2 diff."""
    var const_key = Expr.map_get(
        Expr.col_ref("mp"), Expr.literal(ScalarValue.from_string(String("city")))
    )
    var row_key = Expr.map_get(Expr.col_ref("mp"), Expr.col_ref("s"))
    assert_true(
        _expr_ir(row_key.map_get_parent_ref())
        != _expr_ir(row_key.map_get_key_ref()),
        "the per-row MapGet's parent and key compare EQUAL, so a crossed pair"
        + " would be invisible. Both slots are `Expr`; only an asymmetric"
        + " corpus can tell them apart.",
    )
    var e = ExprArray()
    e.append(Expr.alias(const_key^, String("mc")))
    e.append(Expr.alias(row_key^, String("mr")))
    _assert_round_trips(
        String("project(mp[lit(\"city\")], mp[col(s)])"),
        LogicalPlan.project(e^, _scan(String("t"), String("/x.orc"))),
    )


def test_the_json_extract_field_no_render_reads_deviates_and_round_trips() raises:
    """★ `output_type` IS READ BY NO OTHER LEG AT ANY VALUE ON ANY OP, AND BOTH
    QUERY-FACING FACTORIES DERIVE IT. This is the `cast_preserving_arrow` bug
    one node over, and it is the reason `Expr.json_extract_from_parts` exists.

    THE TWO BLINDNESSES, both driven rather than assumed:
      LEG 1  `Expr.write_to`'s JSON_EXTRACT arm prints the parent, the path
             rebuilt as `$.a.b`, and `mode=->` / `mode=->>`. `output_type` is
             not in it. Asserted below by checking the render text.
      LEG 2  `_infer_expr_field` has NO EXPR_JSON_EXTRACT arm — the tag falls
             through to the final `else` and types as `ArrowType.NULL`
             regardless of what the node says. Asserted below by checking that
             two nodes with DIFFERENT output types produce the SAME projected
             column type.

    So a decoder that called `json_extract_json` and let it re-derive
    `ArrowType.STRING` would agree with a correct one on every plan that
    the factories build — they produce STRING only — and would silently
    truncate a typed `json_extract[Int64]`. The corpus deviates:
    one node carries INT64, which only `json_extract_from_parts` can build,
    and which a re-deriving decoder turns back into STRING.

    THE PATH IS ALSO CARRIED AS SEGMENTS AND NOT AS THE JOINED STRING, and
    this test pins why: `["a", "b"]` and `["a.b"]` are different paths, and a
    decoder that re-parsed a joined `$.a.b` would silently split the second in
    two. The render escapes a `.` inside a segment (`$.a\\.b`), so LEG 1 tells
    them apart as well as LEG 3."""
    # ★ LEG 1 SEES `output_type`: the render prints `type=<t>` when the target
    # is not the STRING both query factories pin. This pins the visibility, so
    # a render that drops the field is red here.
    var as_string = Expr.json_extract_json(Expr.col_ref("js"), String("$.user.id"))
    assert_true(
        "type=" not in String(as_string),
        "a STRING extract prints no type (the default is not rendered): "
        + String(as_string),
    )
    var as_int = Expr.json_extract_from_parts(
        Expr.col_ref("js"),
        [String("user"), String("id")],
        ArrowType.INT64,
        True,
    )
    assert_true(
        String(as_int) != String(as_string),
        "two JSON_EXTRACT nodes differing ONLY in `output_type` must render"
        + " DIFFERENTLY (the render is the plan-compile cache key). STRING: "
        + String(as_string) + "  INT64: " + String(as_int),
    )
    assert_true(
        _expr_ir(as_int) != _expr_ir(as_string),
        "LEG 3 cannot tell an INT64 json_extract from a STRING one, which"
        + " means NOTHING here can. `_expr_ir`'s"
        + " EXPR_JSON_EXTRACT arm must print `output_type`.",
    )
    # One segment that CONTAINS the separator. The render escapes it
    # (`$.user\.id`), so it is distinguishable from the two-segment path
    # above in the render (the render is plan identity) as well as on the
    # segment-carrying wire.
    var dotted = Expr.json_extract_from_parts(
        Expr.col_ref("js"), [String("user.id")], ArrowType.STRING, False
    )
    var split = Expr.json_extract_string(Expr.col_ref("js"), String("$.user.id"))
    assert_true(
        String(dotted) != String(split),
        "a one-segment path containing a `.` renders like the two-segment"
        + " path it joins to, so the two share a plan-compile cache key: "
        + String(dotted),
    )
    assert_true(
        _expr_ir(dotted) != _expr_ir(split),
        "LEG 3 cannot tell `[\"user.id\"]` from `[\"user\", \"id\"]`. The"
        + " segment separator in `_expr_ir` must be one that cannot occur"
        + " inside a segment.",
    )
    var e = ExprArray()
    e.append(Expr.alias(as_string^, String("js_str")))
    e.append(Expr.alias(as_int^, String("js_int")))
    e.append(Expr.alias(dotted^, String("js_dotted")))
    e.append(Expr.alias(split^, String("js_split")))
    # The WHOLE-DOCUMENT path — zero segments, which proto3 omits entirely as
    # an empty repeated field, and which is a legal plan (`$` means the whole
    # document). It is here so the empty case is not the untested one.
    e.append(
        Expr.alias(
            Expr.json_extract_json(Expr.col_ref("js"), String("$")),
            String("js_whole"),
        )
    )
    _assert_round_trips(
        String("project(json ->, json_extract INT64, dotted segment, ->>, $)"),
        LogicalPlan.project(e^, _scan(String("t"), String("/x.orc"))),
    )


def test_the_six_string_and_struct_arms_compose_round_trips() raises:
    """ALL SIX OF THIS GROUP'S ARMS IN ONE TREE, NESTED THROUGH EACH OTHER.

    Each single-arm test above reaches its arm with a `col_ref` child, so none
    of them exercises an arm's recursion box holding ANOTHER of this group's
    arms. Here the string ops take a `struct_field` for a child, the regexp
    takes a `struct_field_idx`, the map_get's KEY is itself a `struct_field`
    (a per-row key computed from a nested column, which is the shape the
    per-row form exists for), and the json_extract's parent is a `map_get`.

    The nesting is not decoration: `_one_expr` refuses a box holding 0 or 2,
    and a box that has only ever held a leaf has never been asked to carry a
    subtree whose own encode can raise."""
    var nested_key = Expr.struct_field(Expr.col_ref("st"), String("v"))
    var mg = Expr.map_get(Expr.col_ref("mp"), nested_key^)
    var e = ExprArray()
    e.append(
        Expr.alias(
            Expr.string_op(
                STR_STARTS_WITH,
                Expr.struct_field(Expr.col_ref("st"), String("v")),
                String("pre"),
            ),
            String("c1"),
        )
    )
    e.append(
        Expr.alias(
            Expr.regexp(
                REGEXP_REPLACE,
                Expr.struct_field_idx(Expr.col_ref("st"), 1),
                String("(a+)"),
                String("Z"),
                String("g"),
                4,
                String("grp"),
            ),
            String("c2"),
        )
    )
    e.append(Expr.alias(mg^, String("c3")))
    e.append(
        Expr.alias(
            Expr.json_extract_from_parts(
                Expr.col_ref("js"),
                [String("a"), String("b"), String("c")],
                ArrowType.STRING,
                False,
            ),
            String("c4"),
        )
    )
    _assert_round_trips(
        String(
            "project(startswith(st.v), regexp_replace(st[1]), mp[st.v],"
            " json_extract(js, $.a.b.c))"
        ),
        LogicalPlan.project(e^, _scan(String("t"), String("/x.orc"))),
    )


def _two_level_inner_plan() raises -> LogicalPlan:
    """★ TWO FILTER LEVELS, AND THE SECOND ONE IS THE WHOLE POINT.

    `Expr.write_to` renders a correlated subquery as
    `CorrelatedSubquery(..., inner_tag=<Int>)` — it prints the inner plan's
    ROOT TAG and does not recurse. So an encoder that dropped one Filter level
    from the inner plan renders BYTE-IDENTICALLY (the root is still a FILTER),
    hashes identically, and promises the same output schema. A one-level inner
    plan cannot expose that: dropping its only Filter changes `inner_tag` and
    LEG 1 catches it by accident."""
    return LogicalPlan.filter(
        Expr.binary(
            BIN_GT, Expr.col_ref("a"),
            Expr.literal(ScalarValue.from_int64(Int64(41))),
        ),
        LogicalPlan.filter(
            Expr.binary(
                BIN_LT, Expr.col_ref("b"),
                Expr.literal(ScalarValue.from_int64(Int64(99))),
            ),
            _scan(String("inner"), String("/i.orc")),
        ),
    )


def test_an_in_correlated_subquery_round_trips() raises:
    """★ THE ARM THAT MAKES THE CODEC MUTUALLY RECURSIVE.

    `CorrelatedSubqueryData.inner_plan` is the ONLY `LogicalPlan`-typed field
    outside a plan node's own child slot, so this is the one arm on which
    `_expr_to_wire` calls `_plan_to_wire`. Declaring it in `plan.proto` also
    closed the cycle in the MESSAGE graph, which moved protoc-gen-mojo's
    recursion-box decision onto four other edges — if the generated boxing had
    a hole left in it, it would surface here and nowhere else.

    ADVERSARIAL TO DEFAULTS, FIELD BY FIELD:
      kind          CORR_KIND_IN_CORRELATED, the only kind for which the two
                    column names are legal at all
      outer_refs    TWO names, so a codec carrying the right COUNT of wrong
                    names still goes red — the render prints `#2`, not the
                    names, so only LEG 3 can see it
      in_lhs / rhs  DIFFERENT from each other, so a codec that wrote one slot
                    into the other goes red
      inner_plan    TWO Filter levels over a DIFFERENT scan leaf than the
                    outer plan's — see `_two_level_inner_plan`"""
    var outer_refs: List[String] = [String("a"), String("b")]
    _assert_round_trips(
        String("filter(a IN (correlated subquery))"),
        LogicalPlan.filter(
            Expr.in_correlated_subquery(
                _two_level_inner_plan(),
                outer_refs^,
                String("a"),
                String("b"),
            ),
            _scan(String("outer"), String("/o.orc")),
        ),
    )


def test_a_scalar_correlated_subquery_round_trips() raises:
    """The two NON-IN kinds, ANDed, so the empty-`in_lhs_col` decode branch is
    reached and `CORR_KIND_EXISTS` — which is ENGINE VALUE 0 — is carried.

    ⚠ ENGINE 0 IS WHY THE WIRE NUMBERING IS OFFSET. proto3 cannot distinguish
    an absent enum from an explicit zero, and `CORR_KIND_EXISTS` is a real
    kind, so `correlated_kind_to_wire` maps it to 1 and reserves 0 for "the
    field was not written". A corpus that only carried SCALAR would never
    exercise the arm where that distinction matters."""
    var exists_refs: List[String] = [String("a")]
    var scalar_refs: List[String] = [String("b"), String("s")]
    _assert_round_trips(
        String("filter(EXISTS(...) AND SCALAR(...))"),
        LogicalPlan.filter(
            Expr.binary(
                BIN_AND,
                Expr.correlated_subquery(
                    _two_level_inner_plan(), exists_refs^, CORR_KIND_EXISTS
                ),
                Expr.correlated_subquery(
                    LogicalPlan.limit(1, _scan(String("q"), String("/q.orc"))),
                    scalar_refs^,
                    CORR_KIND_SCALAR,
                ),
            ),
            _scan(String("outer"), String("/o.orc")),
        ),
    )


def test_a_non_in_kind_carrying_in_columns_is_refused_by_name() raises:
    """★ A DECODE-SIDE REFUSAL, DRIVEN BY A HOSTILE ENCODER.

    `in_lhs_col` / `in_rhs_col` are populated ONLY for
    CORR_KIND_IN_CORRELATED — that is `CorrelatedSubqueryData`'s own stated
    invariant, and the engine has NO factory for the pair (non-IN kind,
    non-empty column). A decoder handed those bytes therefore has exactly two
    fail-quiet options — drop the columns, or change the kind — and one loud
    one.

    This build's encoder cannot produce these bytes, which is precisely why the
    fixture goes through the generated message types: a decoder faces a
    version-skewed peer and a hostile one, not only itself. Every step RAISES
    rather than returning its input unchanged, because a tamper that silently
    fails to tamper makes its test vacuously green."""
    var refs: List[String] = [String("a")]
    var good = plan_to_bytes(
        LogicalPlan.filter(
            Expr.correlated_subquery(
                _two_level_inner_plan(), refs^, CORR_KIND_SCALAR
            ),
            _scan(String("outer"), String("/o.orc")),
        )
    )
    var env = decode_proto[WirePlanEnvelope](good.copy())
    if not env.plan:
        raise Error("fixture: the envelope carries no plan")
    var plan = env.plan.value().copy()
    if not plan.filter:
        raise Error("fixture: the plan root is not a FILTER")
    var node = plan.filter[0].copy()
    if len(node.predicate) != 1:
        raise Error("fixture: the filter carries no predicate")
    var pred = node.predicate[0].copy()
    if not pred.correlated_subquery:
        raise Error("fixture: the predicate is not a correlated subquery")
    var cs = pred.correlated_subquery[0].copy()
    assert_equal(
        cs.in_lhs_col.byte_length(), 0,
        "fixture: a SCALAR subquery already carries an in_lhs_col, so setting"
        + " one below tampers with nothing and this test is vacuous.",
    )
    cs.in_lhs_col = String("s_suppkey")
    # RECURSION BOX (1.0.0): this is an INLINING edge on a cyclic
    # message, so the emitter boxes it as `List[T]` -- 1.0.0's
    # `Deinitable` is no longer co-inductive, so an `Optional[T]`
    # self-edge has no synthesizable destructor (see lower.rs).
    #
    # ⚠ REPLACE SLOT 0 -- NEVER `append`. The box is SINGULAR: the decode
    # above already put the original in `[0]` (the `if not ...` guard is
    # what proves it), and the encoder writes slot 0 only. `append` puts the
    # tampered copy in `[1]`, where the wire never sees it, and the tamper
    # silently does nothing -- which is this file's whole failure class.
    pred.correlated_subquery[0] = cs^
    var preds = List[WireExpr]()
    preds.append(pred^)
    node.predicate = preds^
    # RECURSION BOX (1.0.0): see the note above -- singular box, replace
    # slot 0, never `append`.
    plan.filter[0] = node^
    env.plan = Optional(plan^)
    var bad = encode_proto[WirePlanEnvelope](env)
    assert_true(
        bad != good,
        "the tamper produced BYTE-IDENTICAL output. The message shape moved"
        + " and this test is no longer testing what it says it is.",
    )

    var raised = False
    var text = String("")
    try:
        var p = plan_from_bytes(bad^)
        _ = p.structural_hash()
    except e:
        raised = True
        text = String(e)
    assert_true(
        raised,
        "the decoder ACCEPTED a CORR_KIND_SCALAR subquery carrying an"
        + " in_lhs_col. There is no engine factory for that state, so"
        + " accepting it means one of the two fields was silently thrown"
        + " away — a decoded plan that is not the plan the bytes describe.",
    )
    assert_true(
        String("PLAN_WIRE_MALFORMED") in text,
        "the decoder raised, but not with PLAN_WIRE_MALFORMED. got: " + text,
    )
    # THE CONTROL. Without it a decoder that refused every input would pass
    # every assertion above with full marks.
    var ok = plan_from_bytes(good^)
    _ = ok.structural_hash()


def test_a_four_slot_agg_expr_round_trips() raises:
    """`AggExpr` has FOUR child slots. The slots are SPARSE — `num_children()`
    stops at the first empty one — so a codec that walked them instead of
    carrying four would lose 2 and 3 silently, which is the easy mistake for
    any reader of this payload.

    ⚠⚠ A 4-SLOT `count` IS INADMISSIBLE — not by this test's choice.
    `plan_from_bytes` runs `plan_wire_check_values` inside `_decode_envelope`
    (deliberately: "a safety property that depends on which entry point the
    caller chose is not a safety property"), so a round trip here is an
    ADMISSION as well as a codec assertion, and the door refuses a populated
    argument slot the aggregate does not read — `PLAN_WIRE_AGG_ARG_DROPPED`.
    `count` reads ONE slot; the other three would be expressions the engine
    DISCARDS, a silently wrong answer.

    ⛔ THE CODEC PROPERTY IS THEREFORE SPLIT. This half keeps an IDENTITY round
    trip over the two slots an admissible plan can use — `corr` is bivariate —
    and the sparse carriage of slots 2 and 3 is in
    `test_the_two_unread_agg_slots_are_carried_and_refused` below, which is a
    STRONGER statement about the decoder: the refusal NAMES the slot it found,
    so a decoder that silently dropped slot 3 could not produce it.
    """
    var gb = ExprArray()
    gb.append(Expr.col_ref("a"))
    var ax = AggExprArray()
    ax.append(
        AggExpr(
            AGG_CORR,
            Optional(Expr.col_ref("b")),
            Optional(Expr.col_ref("a")),
            Optional(String("wide")),
        )
    )
    _assert_round_trips(
        String("aggregate(bivariate AggExpr, slots 0+1)"),
        LogicalPlan.aggregate(gb^, ax^, _scan(String("t"), String("/x.orc"))),
    )


def test_the_two_unread_agg_slots_are_carried_and_refused() raises:
    """★★ SLOTS 2 AND 3 ARE CARRIED BY THE CODEC AND READ BY NOTHING.

    The format declares four `AggExpr` argument slots for a multi-argument
    aggregate this build does not have; the bivariate aggregates read slot 1
    and no member of the vocabulary reads 2 or 3. An expression in one of them
    is therefore DISCARDED — the engine answers the query without it and
    reports nothing, which is the silent wrong answer
    `PLAN_WIRE_AGG_ARG_DROPPED` names.

    ★ THIS IS ALSO THE SPARSE-CARRIAGE ASSERTION, AND IT IS STRONGER THAN THE
    ROUND TRIP IT REPLACES. Each case leaves the slots BELOW the one under test
    EMPTY, so `num_children()` answers 1 for all three; a codec that enumerated
    the slots by walking would never bind slot 2 or slot 3 and the door could
    not name them. The refusal message quotes the slot NUMBER, so the assertion
    is that the decoder bound exactly that field.
    """
    var cases: List[Int] = [1, 2, 3]
    for i in range(len(cases)):
        var which = cases[i]
        var gb = ExprArray()
        gb.append(Expr.col_ref("a"))
        var ax = AggExprArray()
        var wide = AggExpr(
            AGG_COUNT,
            Optional(Expr.col_ref("b")),
            Optional(String("wide")),
        )
        if which == 1:
            wide.child1 = Optional(Expr.col_ref("s"))
        elif which == 2:
            wide.child2 = Optional(Expr.col_ref("ts"))
        else:
            wide.child3 = Optional(Expr.col_ref("dec"))
        ax.append(wide^)
        var bytes = plan_to_bytes(
            LogicalPlan.aggregate(
                gb^, ax^, _scan(String("t"), String("/x.orc"))
            )
        )
        var refused = False
        try:
            var back = plan_from_bytes(bytes^)
            _ = back^
        except e:
            refused = True
            var msg = String(e)
            assert_true(
                msg.startswith(PLAN_WIRE_AGG_ARG_DROPPED),
                "agg slot " + String(which) + ": refused, but not by the"
                " ARITY rule — a slot nothing reads must be refused BY NAME,"
                " not by whatever check happens to trip next: " + msg,
            )
            assert_true(
                (String("argument slot ") + String(which)) in msg,
                "agg slot " + String(which) + ": the refusal names a"
                " DIFFERENT slot, which means the decoder did not bind the"
                " one this case populated — the sparse-carriage defect: "
                + msg,
            )
        assert_true(
            refused,
            "agg slot " + String(which) + ": ⛔ ADMITTED. `count` reads slot"
            " 0 alone, so the expression in slot " + String(which) + " is"
            " discarded and the query is answered without it, with no error.",
        )


def test_a_deep_composition_round_trips() raises:
    """Limit(Sort(Aggregate(Filter(Scan)))) — five levels. Each single-node
    test above could pass for a codec that handled only the ROOT and dropped
    its child; this cannot."""
    var gb = ExprArray()
    gb.append(Expr.col_ref("a"))
    var ax = AggExprArray()
    ax.append(
        AggExpr(AGG_SUM, Optional(Expr.col_ref("b")), Optional(String("total")))
    )
    var keys: List[String] = [String("total")]
    var desc: List[Bool] = [True]
    _assert_round_trips(
        String("limit(sort(aggregate(filter(scan))))"),
        LogicalPlan.limit(
            2,
            LogicalPlan.sort(
                keys^, desc^,
                LogicalPlan.aggregate(
                    gb^, ax^,
                    LogicalPlan.filter(
                        Expr.binary(
                            BIN_GT, Expr.col_ref("a"),
                            Expr.literal(ScalarValue.from_int64(Int64(1))),
                        ),
                        _scan(String("t"), String("/x.orc")),
                    ),
                ),
            ),
            1,
        ),
    )


def test_a_bigger_plan_encodes_to_more_bytes() raises:
    """THE ANTI-VACUITY CONTROL FOR THE WHOLE FILE.

    Every assertion above compares the decoded plan to the original. A codec
    whose `plan_to_bytes` returned an empty buffer and whose `plan_from_bytes`
    returned an identical default would satisfy all of them, forever."""
    var small = plan_to_bytes(_scan(String("t"), String("/x.orc")))
    var big = plan_to_bytes(
        LogicalPlan.limit(
            5,
            LogicalPlan.filter(
                Expr.binary(
                    BIN_GT, Expr.col_ref("a"),
                    Expr.literal(ScalarValue.from_int64(Int64(3))),
                ),
                _scan(String("t"), String("/x.orc")),
            ),
            2,
        )
    )
    assert_true(len(small) > 0, "a scan encoded to zero bytes")
    assert_true(
        len(big) > len(small),
        "a Limit(Filter(Scan)) did not encode LARGER than the bare Scan —"
        + " small=" + String(len(small)) + " big=" + String(len(big))
        + ". Either the codec is not walking the tree, or the bytes are not"
        + " carrying it.",
    )


# =============================================================================
# EXPR_WINDOW_FN — the arm whose render prints two COUNTS and no list
# =============================================================================


def _deviating_frame() -> PartitionFrame:
    """A frame in which ALL FIVE `var`s differ from the proto3 default AND from
    every frame the engine's own factories build.

    `default_ordered()` is (ROWS=0, UNBOUNDED_PRECEDING=0, 0, CURRENT_ROW=2, 0)
    and `default_unordered()` is (ROWS=0, UNBOUNDED_PRECEDING=0, 0,
    UNBOUNDED_FOLLOWING=4, 0) — between them, four of the five slots sit at the
    proto3 zero. A corpus built from either would let an encoder that never
    wrote `units`, `start_tag` or the two offsets emit byte-identical bytes to a
    correct one. That is the defaults hazard of the header's audit, and this
    is the corpus that does not reproduce it:

        units        RANGE (1)                  — not the ROWS (0) default
        start_tag    PRECEDING (1)              — not UNBOUNDED_PRECEDING (0)
        start_offset -5                         — not 0, and NEGATIVE, which is
                                                  the sign a uint32 would eat
        end_tag      FOLLOWING (3)              — not 0, and not CURRENT_ROW
        end_offset   7                          — not 0, and != start_offset,
                                                  so a codec that crossed the
                                                  two slots is a diff
    """
    return PartitionFrame(
        FRAME_UNITS_RANGE,
        FRAME_BOUND_PRECEDING, Int64(-5),
        FRAME_BOUND_FOLLOWING, Int64(7),
    )


def _second_frame() -> PartitionFrame:
    """★ THE CORPUS'S SECOND FRAME, AND WHY IT IS NOT `default_ordered()`.

    With only the two frames below, `WireFrame.units` and `WireFrame.start_tag`
    hold THE SAME BYTES at every frame instance the corpus builds, so a codec
    that wrote either into the other would be byte-identical and neither slot
    proven. The cause is that the vocabulary is PLUS-ONE on the wire and BOTH
    frames sit at the same index of their own enum:

        _deviating_frame()  (RANGE, PRECEDING)             = wire (2, 2)
        default_ordered()   (ROWS,  UNBOUNDED_PRECEDING)   = wire (1, 1)

    Neither is a default — the first was chosen adversarially and the second is
    what the engine builds — which is exactly why census and perturbation both
    pass on the pair. It takes a THIRD combination to separate them, and this
    is it: units ROWS (wire 1) against start_tag CURRENT_ROW (wire 3).

    ⚠ THE TWO OFFSETS STAY AT ZERO, deliberately. `_deviating_frame` carries -5
    and 7, so both offset slots are already two-valued through this pair, and
    moving them here would change which slots the CENSUS half reports for an
    unrelated reason."""
    return PartitionFrame(
        FRAME_UNITS_ROWS,
        FRAME_BOUND_CURRENT_ROW, Int64(0),
        FRAME_BOUND_UNBOUNDED_FOLLOWING, Int64(0),
    )


def _window_render_shows(e: Expr) raises -> Bool:
    """True when `Expr.write_to` prints this node's list CONTENTS, its
    `descending` and its frame -- all three carried at non-default values.

    ⚠ A render of two LENGTHS (`partition_by=#<len>, order_by=#<len>`) and
    never a name, never `descending`, never the frame would let two `.over()`
    queries in one EngineContext share a compiled plan, so the render prints
    every field, and this predicate pins that it keeps doing so."""
    var txt = String(e)
    ref w = e.window_fn_data_ref()
    var names = String("partition_by=[")
    for i in range(len(w.partition_by)):
        if i > 0:
            names += ", "
        names += w.partition_by[i]
    names += "]"
    return (
        len(w.partition_by) > 1
        and len(w.descending) > 0
        and names in txt
        and ("order_by=[" + w.order_by[0]) in txt
        and "descending=[T, F, T]" in txt
        and ("frame=" + String(w.frame)) in txt
    )


def test_a_window_fn_round_trips_with_every_render_invisible_part_deviating() raises:
    """★ EVERY CARRIED VALUE OF THIS ARM DEVIATES FROM ITS DEFAULT.

    `_infer_expr_field` has no EXPR_WINDOW_FN arm at all, so LEG 2 is blind to
    the whole node wherever it sits; LEG 1 sees what the render prints and
    LEG 3 sees the rest: every NAME in `partition_by` and `order_by`, the whole
    of `descending` (including its length), and all five frame bounds.

    Every one of them deviates here, and the deviation is ASSERTED rather than
    described, so the test cannot quietly become vacuous the way a
    default-valued `nulls_first` leg does:

      * `partition_by` = TWO entries in NON-SORTED order, so a
        codec that sorted or reordered them is a diff while `#2` is not.
      * `order_by`     = ONE entry, a DIFFERENT length from
        partition_by, so a codec that crossed the two slots is a diff.
      * `descending`   = [True, False, True] — THREE entries, matching NEITHER
        other list's length and starting at `True` (the non-default). Its
        length is what proves nothing derives it from `order_by`.
      * the frame — see `_deviating_frame`, all five slots off their defaults.
    """
    # ⚠ THE NAMES ARE REAL COLUMNS OF `_schema()`, AND THAT IS NOT COSMETIC:
    # `plan_wire_values.mojo` RESOLVES A WINDOW FUNCTION'S CARRIED NAMES, so a
    # name no schema here has would be refused. The slots this test is about
    # are three lists of three different lengths, in an order sorting would
    # disturb, plus the frame.
    # ⚠ `dec` / `dic` / `mp` / `js` AND NOT `a` / `b` / `s`, because
    # `_window_render_shows` asks whether a name is a SUBSTRING of the render
    # text — and the render contains `a` (in "partition"), `b` (in "by") and
    # `un` (in "func"). A one-letter column name makes such a predicate answer
    # for a reason that has nothing to do with the list contents.
    var pb: List[String] = [String("dec"), String("dic")]
    var ob: List[String] = [String("mp")]
    var desc: List[Bool] = [True, False, True]
    var w = Expr.window_fn(
        PF_LAG, String("js"), 3, _deviating_frame()
    ).with_window_spec(pb^, ob^, desc^)
    assert_true(
        _window_render_shows(w),
        "the WINDOW_FN render must print every list's CONTENTS, `descending`"
        + " and the frame -- it is the plan-compile cache key."
        + " Render text: " + String(w),
    )
    _assert_round_trips(
        String("filter(window_fn(lag) — three lists and a frame LEG 1 hides)"),
        LogicalPlan.filter(w^, _scan(String("t"), String("/x.orc"))),
    )


def test_a_window_fn_with_an_empty_order_by_and_a_nonempty_partition_round_trips() raises:
    """THE SHAPE `Expr.over(partition_by)` BUILDS, and the one that proves the
    three lists are not parallel.

    `over(pb)` pins `order_by` and `descending` EMPTY while `partition_by` is
    not — so a decoder that sized `descending` from `order_by`, or that
    reconstructed the node through `.over(...)` instead of `with_window_spec`,
    is right here and wrong on the test above. Both shapes have to survive for
    either to mean anything."""
    var pb: List[String] = [String("a")]  # a real column — see the note above
    _assert_round_trips(
        String("filter(window_fn(row_number).over(pb) — order_by empty)"),
        LogicalPlan.filter(
            Expr.window_fn(
                0, String(""), 0, PartitionFrame.default_unordered()
            ).over(pb^),
            _scan(String("t"), String("/x.orc")),
        ),
    )


def test_every_declared_window_fn_member_round_trips() raises:
    """ALL SIXTEEN, and the count is pinned against the DERIVED vocabulary.

    The space is the sparsest in the format after ExtractField: 0..5, 10..14,
    20..24, with 6..9 and 15..19 declared by nothing. A list written from the
    engine header and compared to `WINDOW_FN_WIRE_MEMBERS` is what keeps this
    from being true by construction — deriving both sides of the comparison
    would make the assertion say nothing.

    Every node carries a DIFFERENT `arg_offset` and a DIFFERENT `arg_col`, so a
    codec that wrote a constant into either slot, or that shifted the func by
    one, cannot be lucky on any of the sixteen."""
    assert_equal(
        WINDOW_FN_WIRE_MEMBERS, 16,
        "the derived WindowFn vocabulary no longer has sixteen members.",
    )
    var funcs: List[UInt8] = [
        UInt8(0), UInt8(1), UInt8(2), UInt8(3), UInt8(4), UInt8(5),
        UInt8(10), UInt8(11), UInt8(12), UInt8(13), UInt8(14),
        UInt8(20), UInt8(21), UInt8(22), UInt8(23), UInt8(24),
    ]
    assert_equal(
        len(funcs), WINDOW_FN_WIRE_MEMBERS,
        "the hand-written func list and the derived member count disagree.",
    )
    for i in range(len(funcs)):
        assert_true(
            window_fn_is_declared(funcs[i]),
            "the hand-written func list names " + String(Int(funcs[i]))
            + ", which the derived vocabulary does not declare.",
        )
        # ⚠ REAL COLUMNS OF `_schema()`, ROTATED BY `i` so consecutive funcs
        # still get DIFFERENT specs (which is what makes a codec that keyed the
        # spec off the func number go red). `_schema()` has ten columns and
        # there are sixteen funcs, so the rotation repeats — the funcs differ,
        # which is what this loop is about.
        var cols: List[String] = [
            String("a"), String("b"), String("s"), String("ts"), String("dec"),
            String("dic"), String("st"), String("un"), String("mp"),
            String("js"),
        ]
        var pb: List[String] = [cols[i % len(cols)]]
        var ob: List[String] = [cols[(i + 3) % len(cols)]]
        var desc: List[Bool] = [i % 2 == 0]
        _assert_round_trips(
            String("filter(window_fn(func=") + String(Int(funcs[i])) + "))",
            LogicalPlan.filter(
                Expr.window_fn(
                    funcs[i], cols[(i + 6) % len(cols)], i + 1,
                    _deviating_frame(),
                ).with_window_spec(pb^, ob^, desc^),
                _scan(String("t"), String("/x.orc")),
            ),
        )


def test_a_window_fn_in_the_sparse_hole_is_refused() raises:
    """A HOLE VALUE NARROWS INTO A `UInt8` LOSSLESSLY AND IS STILL NOT A WINDOW
    FUNCTION — the ExtractField lesson, on the sparser space.

    7 and 17 both sit in gaps the engine declares nothing in (6..9 and 15..19),
    and both are values `Expr.window_fn` accepts without complaint: `func` is a
    bare `UInt8` and no factory validates it. A codec that range-checked
    `0 <= func <= 24` would take both. `window_fn_to_wire` tests MEMBERSHIP, so
    it does not."""
    for hole in [UInt8(7), UInt8(17)]:
        assert_true(
            not window_fn_is_declared(hole),
            "engine tag " + String(Int(hole)) + " is now DECLARED. That is"
            + " good news and this test is the red that reports it — pick"
            + " another gap, or delete this test if the space has become"
            + " dense.",
        )
        var raised = False
        try:
            var b = plan_to_bytes(
                LogicalPlan.filter(
                    Expr.window_fn(
                        hole, String("v"), 1, PartitionFrame.default_ordered()
                    ),
                    _scan(String("t"), String("/x.orc")),
                )
            )
            _ = len(b)
        except e:
            raised = True
            assert_true(
                "WindowFn" in String(e),
                "the encoder refused window func " + String(Int(hole))
                + " but did not name the SPACE. got: " + String(e),
            )
        assert_true(
            raised,
            "the encoder ACCEPTED window func " + String(Int(hole))
            + ", which sits in a gap the engine declares nothing in. Encoding"
            + " it writes a wire number no reader can name.",
        )


# =============================================================================
# PLAN_PARTITION_BY / PLAN_PARTITION_TOPN — a render that prints a COUNT where
# the payload is
# =============================================================================


def _partition_by_render_shows(p: LogicalPlan) raises -> Bool:
    """True when the PartitionBy render prints each order key's direction and
    each partition expression's alias, offset, default and frame.

    ⚠ A render of `PartitionBy(partition=[…], order=[…], <n> funcs)` -- the
    key lists and a COUNT -- would let two windows differing only in
    direction or function share a compiled plan in one EngineContext. This
    pins the visibility."""
    var txt = String(p)
    ref d = p.partition_by_data_ref()
    if len(d.partition_exprs) == 0 or len(d.descending) == 0:
        return False
    if "DESC" not in txt:
        return False
    for i in range(len(d.partition_exprs)):
        ref x = d.partition_exprs[i]
        if (" AS " + x.alias_name) not in txt:
            return False
        if ("offset=" + String(x.offset)) not in txt:
            return False
        if ("frame=" + String(x.frame)) not in txt:
            return False
    return "default=" in txt


def test_a_partition_by_round_trips_with_every_expr_field_deviating() raises:
    """★ THE COUNT-SHAPED RENDER HOLE. `PartitionBy(partition=[…], order=[…],
    <n> funcs)` prints how MANY partition expressions the node holds and
    nothing about any one of them, so LEG 1 discriminates only the arity.

    LEG 2 is the strong leg on this arm, and unusually so — the node's output
    schema is the child's plus one column per expr, built by
    `partition_expr_output_field`, which reads `func`, `column`, `has_default`
    and `alias_name`. That is FOUR of the seven, and it is why the corpus
    below deviates so hard on the other three:

      * `offset`        — 4 on the LEAD (not the 1 every `lag`/`lead` factory
                          pins) and 7 on the NTILE. Reaches no leg but LEG 3.
      * `default_value` — a NON-NULL Int64 on the LEAD, with `has_default`
                          TRUE. This is the pair's third state, and it is the
                          one a codec that inferred the flag from the value
                          would still get right — so the FIRST expr carries a
                          default and the others do not, which is what makes
                          the flag itself a diff.
      * `frame`         — `_deviating_frame()`, all five slots off both engine
                          defaults, on every expr.

    Three exprs, three DIFFERENT funcs, and every one aliased — because an
    unaliased expr gets the derived name `_w<i>_<base>`, and a derived name is
    exactly the thing a decoder could reconstruct without reading the field.
    ★★ `descending` MATCHES `order_keys` IN LENGTH, AND THAT IS NOT A
    WEAKENING. A `descending` of length 1 against an `order_keys` of length 2
    would look like a good derivability argument ("so nothing may size one
    from the other") — but the engine's plan validator declares that exact
    state a VALIDATION FAILURE, and the partition-scan kernel reads
    `descending[i]` across the ORDER KEYS with nothing bounding it. Such a
    plan is unrunnable; it would round-trip only because a round trip never
    executes anything, and the door refuses it
    (`PLAN_WIRE_INCONSISTENT_COUNT`). A corpus held to the engine's own rule by
    a gate written for FOREIGN bytes is the argument for the door enforcing
    what the validator merely knows.

    THE DERIVABILITY PROPERTY IS KEPT, BY VALUES RATHER THAN BY LENGTH:
    `[True, False]` against `["a", "ts"]`. A decoder that sized `descending`
    from `order_keys` still cannot invent which of the two is which, and a
    decoder that dropped an element still lands on a different length."""
    var pk: List[String] = [String("b")]
    var ok: List[String] = [String("a"), String("ts")]
    var desc: List[Bool] = [True, False]
    var xs = List[PartitionExpr]()
    xs.append(
        PartitionExpr(
            PF_LEAD, String("a"), 4,
            ScalarValue.from_int64(Int64(-77)), True,
            _deviating_frame(), String("lead_with_a_default"),
        )
    )
    xs.append(
        PartitionExpr(
            PF_NTILE, String(""), 7,
            ScalarValue(), False,
            _deviating_frame(), String("ntile7"),
        )
    )
    xs.append(
        PartitionExpr(
            PF_SUM, String("a"), 0,
            ScalarValue(), False,
            _deviating_frame(), String("running_total"),
        )
    )
    var plan = LogicalPlan.partition_by(
        pk^, ok^, desc^, xs^, _scan(String("t"), String("/x.orc"))
    )
    assert_true(
        _partition_by_render_shows(plan),
        "the PartitionBy render must print each order key's direction and"
        + " every partition expression's fields -- it is the plan-compile cache"
        + " key. Render text: " + String(plan),
    )
    _assert_round_trips(
        String("partition_by(3 exprs, all seven fields deviating)"), plan^
    )


def test_a_partition_by_with_no_exprs_round_trips() raises:
    """THE ARITY THE RENDER *CAN* SEE, PINNED SO IT STAYS SEEN.

    `<n> funcs` is the one thing LEG 1 discriminates on this arm, and an empty
    expr list is the value at which an encoder that never wrote the repeated
    field and a correct one emit IDENTICAL bytes. Keeping it in the corpus
    asserts that it round-trips rather than merely that it is not refused."""
    var pk: List[String] = [String("a")]
    var ok: List[String] = [String("b")]
    var desc: List[Bool] = [False]
    _assert_round_trips(
        String("partition_by(no exprs — output schema == child schema)"),
        LogicalPlan.partition_by(
            pk^, ok^, desc^, List[PartitionExpr](),
            _scan(String("t"), String("/x.orc")),
        ),
    )


def test_a_partition_topn_round_trips_with_a_rank_over_fetch_and_a_rank_column() raises:
    """★ `over_fetch_k` IS A CONSTRUCTION-TIME SENTINEL, AND THAT IS THE TRAP.

    `LogicalPlan.partition_topn`'s default is `-1`, which
    `PartitionTopNData.__init__` resolves to `k`. The fuse-partition-topn
    optimizer passes `k + 16` explicitly for RANK, because RANK preserves ties
    at the K-th position and the kernel needs the buffer. So a decoder that
    re-passed the `-1` default instead of the stored value would build a plan
    that EXECUTES and silently drops tied rows — and `over_fetch_k` IS in the
    render, so that particular slip would be caught by LEG 1. What is not in
    the render is the difference between the sixteen funcs beyond 0 and 1:
    `plan_display` prints `FUNC_<n>` for all fourteen others.

    This node therefore carries `func=PF_RANK`, `k=5`, `over_fetch_k=21` (=
    k + 16, so DIFFERENT from k, which is the value the sentinel would produce)
    and a `output_rank_col_name` — the Some case, which appends an Int64
    column to the output schema and so is visible to LEG 2 as well."""
    var pk: List[String] = [String("b")]
    var sk: List[String] = [String("a")]
    var desc: List[Bool] = [True]
    var plan = LogicalPlan.partition_topn(
        pk^, sk^, desc^, 5, _scan(String("t"), String("/x.orc")),
        PF_RANK, 21, Optional(String("rk")),
    )
    ref d = plan.partition_topn_data_ref()
    assert_true(
        d.over_fetch_k != d.k,
        "the corpus node's over_fetch_k equals k, which is exactly what the"
        + " `-1` sentinel resolves to — a decoder that re-passed the sentinel"
        + " would be indistinguishable from a correct one on this plan.",
    )
    _assert_round_trips(
        String("partition_topn(rank, over_fetch_k=k+16, rank column)"), plan^
    )


def test_a_partition_topn_with_no_rank_column_round_trips() raises:
    """THE OTHER HALF OF THE `Optional[String]` — the None case.

    An absent string and an empty one are the same bytes on the wire, and here
    they are different OUTPUT SCHEMAS: `Some(name)` appends an Int64 column and
    `None` does not. The render omits the field entirely when None, so LEG 1
    cannot see a None that decoded as `Some("")` — LEG 2 can, which is why both
    halves are in the corpus.

    This one also uses the ROW_NUMBER func at its engine value 0, the offset-
    by-one case: `window_fn_to_wire` maps it to 1, and an encoder that wrote
    the engine value would write PF_WIRE_UNSPECIFIED."""
    var pk: List[String] = [String("b")]
    var sk: List[String] = [String("a")]
    var desc: List[Bool] = [False]
    _assert_round_trips(
        String("partition_topn(row_number, no rank column)"),
        LogicalPlan.partition_topn(
            pk^, sk^, desc^, 3, _scan(String("t"), String("/x.orc")),
            PF_ROW_NUMBER, 3, None,
        ),
    )


def test_a_partition_topn_func_the_render_cannot_name_round_trips() raises:
    """THE FOURTEEN FUNCS `plan_display` PRINTS AS `FUNC_<n>`.

    The render's map is two names wide — `ROW_NUMBER` for 0, `RANK` for 1 —
    and everything else falls to `FUNC_<n>`. `FUNC_<n>` does contain the
    number, so LEG 1 is not blind here; what it cannot do is object to a func
    the engine does not declare, because `plan_display` will happily print
    `FUNC_7`. The wire goes through `window_fn_to_wire`, which tests
    MEMBERSHIP, and the refusal below is the other half of that.

    PF_MIN (23) is chosen because it is in the third run of the sparse space,
    so a codec that clamped or ranged the func would land somewhere else."""
    var pk: List[String] = [String("b")]
    var sk: List[String] = [String("a")]
    var desc: List[Bool] = [True]
    var plan = LogicalPlan.partition_topn(
        pk^, sk^, desc^, 2, _scan(String("t"), String("/x.orc")),
        PF_MIN, 9, None,
    )
    assert_true(
        "FUNC_23" in String(plan),
        "the PartitionTopN render now names PF_MIN. That is good news and this"
        + " assertion is the red that reports it. Render text: " + String(plan),
    )
    _assert_round_trips(String("partition_topn(func=PF_MIN)"), plan^)


def test_a_partition_topn_func_in_the_sparse_hole_is_refused() raises:
    """`PartitionTopNData.func` IS A BARE `UInt8` AND NOTHING VALIDATES IT.

    The factory takes `func: UInt8 = 0` and the ctor stores it; the payload's
    own docstring says the ENGINE must raise on an unknown tag, and the render
    prints `FUNC_9` without complaint. So an undeclared func is a state the
    plan builder produces, and encoding it would write a wire number no reader
    can name."""
    var pk: List[String] = [String("b")]
    var sk: List[String] = [String("a")]
    var desc: List[Bool] = [True]
    var raised = False
    var text = String("")
    try:
        var b = plan_to_bytes(
            LogicalPlan.partition_topn(
                pk^, sk^, desc^, 2, _scan(String("t"), String("/x.orc")),
                UInt8(9), 2, None,
            )
        )
        _ = len(b)
    except e:
        raised = True
        text = String(e)
    assert_true(
        raised,
        "the encoder ACCEPTED PartitionTopN func 9, which sits in the gap"
        + " between the ranking run (0..5) and the offset run (10..14).",
    )
    assert_true(
        "WindowFn" in text,
        "the encoder refused func 9 but did not name the SPACE. got: " + text,
    )


# =============================================================================
# PLAN_ASOF_JOIN / PLAN_VIEW_REF / PLAN_CSE_REF / PLAN_CAST_TO_VARCHAR —
# the plan leftovers, and with them every MATERIALIZABLE plan tag
# =============================================================================


def _deviating_tolerance() -> AsofTolerance:
    """★ THE OFF-KIND SLOT IS POPULATED ON PURPOSE.

    `AsofTolerance` is `@fieldwise_init` and public, so this value —
    `kind=INT64` with a non-zero `float_val` — is one the plan builder can
    construct even though neither named factory produces it. A codec that
    re-derived the inactive slot from `kind` would silently rewrite it, and no
    other leg would ever say so: the render prints the kind and the SELECTED
    slot (`tolerance=INT64(5000)`), never the off-kind `float_val`.

    Both numbers are also far from proto3's zero, which is the other half of
    the point — an encoder that never wrote either field emits byte-identical
    bytes at (0, 0.0) and the decoder re-supplies the same zeros."""
    return AsofTolerance(ASOF_TOL_INT64, Int64(5000), Float64(2.5))


def _asof_render_hides_only_the_off_kind_slot(p: LogicalPlan) raises -> Bool:
    """True when the AsofJoin render prints both pre-sort hints and the
    SELECTED tolerance value, and NOT the off-kind tolerance slot, while the
    node carries all six at non-defaults.

    `plan_display` emits `AsofJoin(strategy=<NAME>, on=<l>=<r>, by=[<l>=<r>…]
    <, tolerance=<KIND>(<value>)><, left_sorted=[…]/[…]><, right_sorted=…>)`.
    The hints and the selected value are therefore LEG 1's to compare; the
    off-kind slot (`float_val` under kind INT64) is in no render and no output
    schema, so LEG 3 is the only comparison it has.

    ⚠ THE SORT-KEY NAMES ARE DELIBERATELY COLUMNS THE RENDER PRINTS ELSEWHERE,
    so this predicate cannot test for them by substring — `s` and `a` are in
    the `by=` and `on=` clauses. It tests for the FIELD LABELS instead."""
    var txt = String(p)
    ref d = p.asof_join_data_ref()
    return (
        len(d.left_sort_keys) > 0
        and len(d.right_sort_keys) > 0
        and len(d.left_sort_desc) > 0
        and len(d.right_sort_desc) > 0
        and not d.tolerance.is_none()
        and "left_sorted=" in txt
        and "right_sorted=" in txt
        and "5000" in txt
        and "2.5" not in txt
    )


def _asof(
    strategy: UInt8, tolerance: AsofTolerance, var right: LogicalPlan
) raises -> LogicalPlan:
    """★ EVERY PAIRED FIELD IS ASYMMETRIC ACROSS THE TWO SIDES.

    `left_keys`/`right_keys`, `left_asof`/`right_asof` and the two pre-sort
    hint pairs are four opportunities for a codec to cross the sides and emit a
    structurally valid message — the `MathFn2` operand trap, four times over.
    So no pair here holds equal values, and the two `*_sort_desc` lists have
    DIFFERENT LENGTHS (2 and 1), which makes a crossed pair a length diff and
    not merely a value diff.

    The equi-keys are `s`=`js` (both STRING in `_schema()`) and the ASOF
    columns are `a`=`b` (both INT64), so the pairs are type-plausible as well
    as name-distinct."""
    var lk: List[String] = [String("s")]
    var rk: List[String] = [String("js")]
    var lsk: List[String] = [String("s"), String("a")]
    var lsd: List[Bool] = [False, True]
    # ★ `ts`, NOT `js` AND NOT `b`. The docstring above claims "no pair here
    # holds equal values", and that covers more than the LEFT/RIGHT pairs:
    # `right_keys` and `right_sort_keys` are both on the RIGHT, and holding
    # `["js"]` in both would make those two slots byte-identical at every asof
    # instance the corpus builds. A codec that wrote the equi-key into the
    # pre-sort hint is exactly the "re-derived them from the equi-keys"
    # mistake the test below says produces WRONG ROWS, and it would be
    # invisible.
    #
    # ⚠ `b` WOULD BE WRONG TOO — it is `right_asof`, so it would move the
    # forgery one slot over (`right_asof` pointwise equal to
    # `right_sort_keys`). A repeated field of one element and a singular field
    # of the same string are the SAME BYTES. The value has to differ from every
    # other slot on this message.
    var rsk: List[String] = [String("ts")]
    var rsd: List[Bool] = [True]
    return LogicalPlan.asof_join(
        _scan(String("l"), String("/left.orc")),
        right^,
        lk^, rk^,
        String("a"), String("b"),
        strategy, tolerance,
        lsk^, lsd^, rsk^, rsd^,
    )


def test_an_asof_join_round_trips_with_every_render_invisible_part_deviating() raises:
    """★ THE PRE-SORT HINTS' FAILURE MODE IS ASYMMETRIC, AND THE TOLERANCE'S
    OFF-KIND SLOT REACHES NO LEG BUT LEG 3.

    A `*_sort_keys` hint asserts "this side is ALREADY sorted on these columns,
    skip the sort phase". Dropping one costs a sort. INVENTING one — which is
    what a decoder that let the factory's empty defaults stand does in reverse,
    and what a decoder that re-derived them from the equi-keys would do
    outright — skips a sort that was needed and produces WRONG ROWS. The render
    prints non-empty hints, so LEG 1 sees either mistake; the off-kind
    tolerance slot it does not print at all.

    `strategy` is NEAREST, not BACKWARD: BACKWARD is engine value 0 and hence
    proto3's absent-field value, so an encoder that never wrote the field would
    be byte-identical on the default. The tolerance is `_deviating_tolerance()`
    — non-NONE (the render suppresses the whole clause at NONE) with BOTH
    payload slots populated."""
    var plan = _asof(
        ASOF_NEAREST, _deviating_tolerance(),
        _scan(String("r"), String("/right.orc")),
    )
    assert_true(
        _asof_render_hides_only_the_off_kind_slot(plan),
        "the AsofJoin render dropped a pre-sort hint or the selected tolerance"
        + " value (both are plan identity), or now prints the off-kind slot."
        + " Render text: " + String(plan),
    )
    _assert_round_trips(
        String("asof_join(NEAREST, tol=INT64(5000)+2.5, four pre-sort hints)"),
        plan^,
    )


def test_every_declared_asof_strategy_round_trips() raises:
    """All three members of the `AsofDirection` space, one plan each.

    The render names all three (`BACKWARD` / `FORWARD` / `NEAREST`), so LEG 1
    does discriminate here — which is exactly why the test is cheap and worth
    having: it pins that the wire's +1 offset maps each engine value to its own
    number rather than shifting the run by one, and a shift by one is the
    failure this three-member space makes invisible to a single-value corpus.
    """
    var strategies: List[UInt8] = [ASOF_BACKWARD, ASOF_FORWARD, ASOF_NEAREST]
    for i in range(len(strategies)):
        var s = strategies[i]
        var plan = _asof(
            s, _deviating_tolerance(),
            _scan(String("r"), String("/right.orc")),
        )
        assert_true(
            "UNKNOWN" not in String(plan),
            "the AsofJoin render printed UNKNOWN for engine strategy "
            + String(Int(s)) + ", so `_asof_strategy_name` has fallen behind"
            + " the constants. Render text: " + String(plan),
        )
        _assert_round_trips(
            String("asof_join(strategy=") + String(Int(s)) + ")", plan^
        )


def test_every_asof_tolerance_kind_round_trips_with_both_slots_populated() raises:
    """★ ALL THREE KINDS, EACH CARRYING BOTH PAYLOAD SLOTS NON-ZERO.

    Including `ASOF_TOL_NONE` — which is the kind at which the render omits
    the clause ENTIRELY, so a NONE tolerance whose `int_val` is 42 renders
    exactly like one whose `int_val` is 0, and LEG 3 is the only thing that can
    tell them apart. A codec that normalized "NONE means no payload" would
    round-trip every plan any factory builds and lose this one.

    The three kinds are also the three consecutive engine values 0/1/2, so an
    off-by-one in the +1 wire mapping turns NONE into INT64 — an UNBOUNDED
    as-of match becoming a bounded one, or the reverse, which is a different
    answer rather than a different plan."""
    var kinds: List[UInt8] = [ASOF_TOL_NONE, ASOF_TOL_INT64, ASOF_TOL_FLOAT64]
    for i in range(len(kinds)):
        var k = kinds[i]
        _assert_round_trips(
            String("asof_join(tolerance kind=") + String(Int(k)) + ")",
            _asof(
                ASOF_FORWARD,
                AsofTolerance(k, Int64(42), Float64(0.75)),
                _scan(String("r"), String("/right.orc")),
            ),
        )


def test_an_asof_strategy_out_of_vocabulary_is_refused_by_name() raises:
    """`AsofJoinData.strategy` IS A BARE `UInt8` AND NOTHING VALIDATES IT.

    `LogicalPlan.asof_join` takes `strategy: UInt8` and stores it; the render
    prints `UNKNOWN` without complaint. So an undeclared strategy is a state
    the plan builder produces, and encoding it would write a wire number no
    reader can name."""
    var raised = False
    var text = String("")
    try:
        var b = plan_to_bytes(
            _asof(
                UInt8(9), _deviating_tolerance(),
                _scan(String("r"), String("/right.orc")),
            )
        )
        _ = len(b)
    except e:
        raised = True
        text = String(e)
    assert_true(
        raised,
        "the encoder ACCEPTED AsofJoin strategy 9. The space declares three"
        + " members (0..2) and the render prints UNKNOWN for the rest.",
    )
    assert_true(
        "AsofDirection" in text,
        "the encoder refused strategy 9 but did not name the SPACE. got: "
        + text,
    )


def test_an_asof_tolerance_kind_out_of_vocabulary_is_refused_by_name() raises:
    """Same shape one level down: `AsofTolerance.tag` is a bare `UInt8` on a
    `@fieldwise_init` struct, so a kind outside 0..2 is constructible and
    `_asof_tolerance_name` renders it as `UNKNOWN` rather than failing."""
    var raised = False
    var text = String("")
    try:
        var b = plan_to_bytes(
            _asof(
                ASOF_BACKWARD,
                AsofTolerance(UInt8(9), Int64(1), Float64(1.0)),
                _scan(String("r"), String("/right.orc")),
            )
        )
        _ = len(b)
    except e:
        raised = True
        text = String(e)
    assert_true(
        raised, "the encoder ACCEPTED AsofTolerance kind 9."
    )
    assert_true(
        "AsofToleranceKind" in text,
        "the encoder refused kind 9 but did not name the SPACE. got: " + text,
    )


def test_a_view_ref_round_trips_and_stays_unresolved() raises:
    """★ THE LEAF THAT NAMES SOMETHING OUTSIDE THE PLAN.

    A `PLAN_VIEW_REF` is `ctx.view(handle)`'s whole output: a name plus a
    SNAPSHOT of the view's schema. Decoding one must NOT resolve it — the
    registry that can resolve it belongs to whichever process runs
    `view_resolution_pass`, and a decoder that expanded the reference here
    would either fail on every cross-process plan or splice in a definition the
    writer never meant. So the assertion is that it comes back as a LEAF with
    the same name, which is what `_plan_ir`'s VIEWREF line says.

    ★ THE NODE HOLDS TWO SCHEMAS AND THE WIRE CARRIES ONE.
    `ViewRefData.output_schema` and `LogicalPlan.output_schema` are separate
    fields the factory fills from ONE argument, and nothing reassigns either
    afterwards — so no constructible plan can make them differ. Carrying both
    would let an encoder that wrote the NODE's schema where the payload's
    belonged leave this file GREEN, i.e. the second slot could not be made to
    fail at any value. It is derived at decode instead (sub-class (c) in the
    header).

    The render emits NEITHER schema — `ViewRef(name=…)` is all of it — so LEG 2
    (which reads only the node's) is the only leg with a real claim here, and
    `_check_output_schema` is a tautology on this arm the way it is on UNION."""
    var plan = LogicalPlan.view_ref(String("monthly_revenue"), _schema())
    assert_true(
        plan.tag == PLAN_VIEW_REF,
        "the fixture is not a view ref; this test would be asserting over the"
        + " wrong arm.",
    )
    assert_true(
        "monthly_revenue" in String(plan),
        "the ViewRef render stopped printing the view NAME, which is the only"
        + " field it ever printed. Render text: " + String(plan),
    )
    _assert_round_trips(String("view_ref(name, 10-column snapshot)"), plan^)


def test_a_cse_ref_round_trips_and_its_hash_is_the_canonical_hash() raises:
    """★ THE ONE NODE WHOSE `structural_hash` IS NOT FNV-1a OF ITS RENDER.

    `LogicalPlan.structural_hash` special-cases `PLAN_CSE_REF` and RETURNS
    `canonical_hash` — re-CSE idempotence: a CSE'd plan and a hand-written one
    that references the same canonical subtree must hash identically. So LEG
    1's hash assertion on a bare CSE-ref leaf is exactly the assertion that
    this UInt64 survived the wire, and the check below pins the special case
    itself so that a future change which deleted it would be reported here and
    not merely absorbed.

    The hash chosen is a full-width 64-bit value with bits set in the high
    word, because a codec that carried it through an Int32 or an Int64 slot
    would be right for every small value and wrong for this one."""
    var h = UInt64(0xC0FFEE1234567890)
    var plan = LogicalPlan.cse_ref(h, _schema())
    assert_equal(
        String(plan.structural_hash()), String(h),
        "a PLAN_CSE_REF's structural_hash is supposed to BE its"
        + " canonical_hash. If this is red the special case in"
        + " `LogicalPlan.structural_hash` is gone, and LEG 1's hash leg on this"
        + " arm has quietly become a hash of `CseRef(canonical_hash=…)` text.",
    )
    _assert_round_trips(String("cse_ref(high-word canonical hash)"), plan^)


def test_a_cast_to_varchar_round_trips_with_mixed_child_nullability() raises:
    """★ THE RENDER IS FIFTEEN CHARACTERS; THE MEANING IS IN THE SCHEMA.

    `CastToVarchar()` carries no field — the payload really is just the child —
    but the node's output schema is DERIVED: `LogicalPlan.cast_to_varchar`
    builds the per-column STRING mirror of the child's, keeping each column's
    NAME and NULLABILITY. So `_check_output_schema` is doing real work on this
    arm, and the corpus has to give it something to work with.

    `_schema()`'s column `a` is NON-nullable and the other nine are nullable,
    which is why this test uses that scan rather than a uniform one: a decoder
    that flattened nullability (or one whose child arrived subtly different, so
    that the re-derivation produced a different mirror) is a schema diff here
    and would be invisible over an all-nullable child.

    The assertions below pin the two halves of the derivation the round trip
    would otherwise take on faith — that every column became STRING, and that
    the non-nullable one stayed non-nullable."""
    var child = _scan(String("t"), String("/x.orc"))
    var child_cols = child.output_schema.num_columns()
    var plan = LogicalPlan.cast_to_varchar(child^)
    assert_equal(
        String(plan.output_schema.num_columns()), String(child_cols),
        "cast_to_varchar changed the column COUNT; the mirror is supposed to"
        + " be per-column.",
    )
    var all_string = True
    for i in range(plan.output_schema.num_columns()):
        if plan.output_schema.field_arrow_type(i).type_id != ArrowType.STRING.type_id:
            all_string = False
    assert_true(
        all_string,
        "cast_to_varchar left a column that is not STRING. The whole point of"
        + " the node is the per-column STRING mirror, and if the derivation"
        + " changed, `_check_output_schema` is checking a different claim.",
    )
    assert_true(
        not plan.output_schema.field_nullable(0),
        "column `a` is NON-nullable in `_schema()` and the mirror is supposed"
        + " to preserve nullability. If this is red the corpus has stopped"
        + " being adversarial on the one axis this arm's schema check reads.",
    )
    _assert_round_trips(
        String("cast_to_varchar(mixed-nullability 10-column child)"), plan^
    )


def test_the_four_leftover_arms_compose_round_trips() raises:
    """THE COMPOSITION. Each arm above is tested on a plan whose ROOT it is;
    this one puts all four in ONE tree, with two of them as CHILDREN of a third.

        CastToVarchar( AsofJoin( Scan, ViewRef ) )

    and a second tree with the CSE reference in the right slot. The point is
    the recursion edges: `WireAsofJoinNode.left` / `.right` are `List[WirePlan]`
    boxes (the generator's recursion-breaking shape) and `_one_child` is what
    refuses a box holding 0 or 2 rather than assuming it holds 1. A leaf arm
    that only ever appears at the root never exercises being decoded as
    somebody's child.

    ⚠ THE TWO SIDES ARE DIFFERENT PLAN KINDS ON PURPOSE. A codec that crossed
    `left` and `right` on this node would produce a tree whose two children
    have the same schema (both are `_schema()`-shaped) — so the OUTPUT schema
    of the join is unchanged by the swap and LEG 2 cannot see it. LEG 1 and
    LEG 3 can, because a `Scan` and a `ViewRef` do not render or walk alike.
    """
    _assert_round_trips(
        String("cast_to_varchar(asof_join(scan, view_ref))"),
        LogicalPlan.cast_to_varchar(
            _asof(
                ASOF_BACKWARD, _deviating_tolerance(),
                LogicalPlan.view_ref(String("dim_customer"), _schema()),
            )
        ),
    )
    _assert_round_trips(
        String("asof_join(scan, cse_ref) under a limit"),
        LogicalPlan.limit(
            3,
            _asof(
                ASOF_FORWARD,
                AsofTolerance(ASOF_TOL_FLOAT64, Int64(-9), Float64(0.125)),
                LogicalPlan.cse_ref(UInt64(0x0123456789ABCDEF), _schema()),
            ),
            1,
        ),
    )


# =============================================================================
# The refusals — the COVERAGE LEDGER, asserted rather than described
# =============================================================================


# =============================================================================
# ⛔ THERE IS NO PLAN-TAG TWIN OF THE TEST BELOW. Every `PLAN_*` id has a codec
# arm, so the armless plan-tag set is EMPTY, and a refusal test must be
# DELETED when its tag acquires an arm rather than pointed at something else.
#
# ⚠ `_plan_to_wire`'s `else` (`PLAN_WIRE_UNSUPPORTED_PLAN_TAG`) IS STILL LIVE
# and is still the right refusal for the next tag added without an arm. It is
# UNREACHABLE from any factory, and that is written down here rather than
# discovered. `test_an_unmodelled_expr_tag_is_refused_by_name` below covers the
# EXPR-side twin, which is a separate ladder.
# =============================================================================


def test_an_unmodelled_expr_tag_is_refused_by_name() raises:
    """BETWEEN and SORT_KEY have no message arm. Until someone writes one, a
    plan carrying either must not encode into a plan that has lost it.

    ⚠ THE POINT OF THIS TEST IS THAT IT GOES RED ON GOOD NEWS. When a named
    tag acquires an arm, the refusal it asserts stops happening — the signal
    the refusal tokens exist to produce. A ledger entry that could be deleted
    without anything going red is a ledger entry nothing is holding.

    ⚠ BOTH ARE TAGS NO FACTORY BUILDS A PAYLOAD FOR. `Expr` declares no
    `_between` and no `_sort_key` field, so there is nothing to carry and
    nothing to construct — the only way to make one is the bare `Expr(tag)`
    ctor, which is public and which the plan builder can therefore produce.
    That is a weak shape (the refusal is over a tag with nothing behind it
    rather than over a real payload), and it is the honest one: pretending
    otherwise would mean inventing a payload the engine does not have.

    ⚠ EVERY MEMBER OF THE ARMLESS SET IS ASSERTED, NOT ONLY THE ONE THE PROSE
    NAMES. "When BETWEEN lands, this moves to SORT_KEY" describes a HANDOFF,
    and a handoff is not a test: with only BETWEEN asserted, `_expr_to_wire`'s
    `else` could stop firing for SORT_KEY — or be replaced by a silent drop —
    and the entire round-trip suite would stay green.

    When these acquire ARMS this test must be DELETED rather than pointed at
    something else — at which point `_expr_to_wire`'s `else` branch becomes
    unreachable and should say so: with the armless set empty, any surviving
    assertion here is stale by construction."""
    _assert_refuses(
        String("EXPR_BETWEEN"),
        LogicalPlan.filter(
            Expr(EXPR_BETWEEN), _scan(String("t"), String("/x.orc")),
        ),
        String("PLAN_WIRE_UNSUPPORTED_EXPR_TAG"),
    )
    _assert_refuses(
        String("EXPR_SORT_KEY"),
        LogicalPlan.filter(
            Expr(EXPR_SORT_KEY), _scan(String("t"), String("/x.orc")),
        ),
        String("PLAN_WIRE_UNSUPPORTED_EXPR_TAG"),
    )
    # ⛔ `EXPR_UDF_CALL` IS NOT IN THE ARMLESS SET: `WireUdfCall` is a message
    # in `plan.proto` and the receiver re-mints the handle
    # (`UdfRegistry.resolve_unique_by_name`), so a refusal here would be false.
    #
    # ★ A REFUSAL AND AN ENCODING ARE NOT PINNED BY THE SAME SHAPE, so the UDF
    # arm has four tests of its own: `test_a_udf_call_round_trips`,
    # `test_a_udf_call_arrives_UNBOUND_however_it_was_encoded`,
    # `test_a_nested_udf_call_round_trips` and
    # `test_a_udf_call_whose_in_and_out_dtypes_DIFFER_round_trips`. The last is
    # the one nothing else can do: a type-preserving UDF hides a codec that
    # SWAPPED `in_arrow_type_id` and `out_arrow_type_id`.
    #
    # ⚠ ONE REFUSAL SURVIVES IN THIS AREA AND IT IS NOT HERE: an `EXPR_UDF_CALL`
    # with an EMPTY name (the live-closure case) is still refused at encode.
    # It is asserted in `test_a_nameless_udf_call_is_refused_at_encode` below,
    # with `_assert_refuses`, because it IS still a refusal.


def test_a_udf_call_round_trips() raises:
    """★ THE UDF-CALL ARM: a named UDF crosses the wire and is re-bound by the
    receiver.

    ⛔ IT IS BUILT WITH `handle=None`, AND THAT IS NOT A CONVENIENCE. LEG 1
    compares the plan's RENDER, and `Expr.write_to`'s UDF arm prints `h=7` for
    a bound node and `h=-` for an unbound one. The wire carries no handle by
    construction, so a node built with `handle=7` CANNOT round-trip its render
    — a corpus entry that expected it to would be a false test asserting the
    codec does something the design forbids. The strip is asserted POSITIVELY,
    on its own, in `test_a_udf_call_arrives_UNBOUND_however_it_was_encoded`;
    `_assert_round_trips` structurally cannot express it.

    ⚠ THE UDF SITS UNDER A `filter` on purpose: it is the same shape a codec
    without this arm would refuse, so the record shows exactly which shape is
    carried.
    """
    _assert_round_trips(
        String("filter(udf_call(affine, col(a)))"),
        LogicalPlan.filter(
            Expr.udf_call(
                String("affine"),
                Optional[Int](None),
                ArrowType.INT64,
                ArrowType.INT64,
                Expr.col_ref(String("a")),
            ),
            _scan(String("t"), String("/x.orc")),
        ),
    )
    # AND IN A PROJECTION, ALIASED — the shape every Python skin verb builds
    # (`df["y"] = affine(df["x"])` lowers to exactly this). It is a DIFFERENT
    # leg from the filter above rather than a second copy: a projection's
    # output schema is inferred through `_infer_expr_field` ->
    # `expr_walk.walk_expr_field`, whose UDF arm returns the node's `out_type`,
    # so LEG 2 reads a field the filter case does not have at all.
    var pe = ExprArray()
    pe.append(Expr.col_ref("a"))
    pe.append(
        Expr.alias(
            Expr.udf_call(
                String("affine"),
                Optional[Int](None),
                ArrowType.INT64,
                ArrowType.INT64,
                Expr.col_ref(String("a")),
            ),
            String("y"),
        )
    )
    _assert_round_trips(
        String("project(a, udf_call(affine, col(a)) AS y)"),
        LogicalPlan.project(pe^, _scan(String("t"), String("/x.orc"))),
    )


def test_a_udf_call_arrives_UNBOUND_however_it_was_encoded() raises:
    """★★ THE STRIP, ASSERTED POSITIVELY. This is the test `_assert_round_trips`
    cannot be.

    Every other corpus entry here asserts that what went in came back. This one
    asserts that ONE FIELD DID NOT — `UdfCallData.handle`, the process-local
    slot+generation the header of `plan.proto` says nothing in that file may
    be. A round-trip harness is structurally incapable of expressing "this
    field must be LOST": it compares before against after and a lost field is a
    diff.

    ⛔ AND WITHOUT THIS, CARRYING THE HANDLE WOULD BE INVISIBLE HERE. Nothing
    else in this file would notice — the round-trip entry above uses
    `handle=None` precisely so it CAN pass, so a codec that added a fifth wire
    field and faithfully round-tripped a handle would leave every other leg
    green. The failure that buys is the worst one this area has: a low slot at
    generation 0 exists in almost any registry, so a carried handle does not
    fail to resolve, it resolves PLAUSIBLY, to a different function.

    ⚠ IT READS THE RENDER, NOT THE IR, and both would work — `_expr_ir`'s UDF
    arm writes `handle=-` for exactly this reason. The render is used because
    it is what the L1/L2 plan CACHE KEYS ON (`structural_hash` is FNV-1a over
    it), so `h=-` in the render is the fact that actually protects a decoded
    plan from sharing a compiled plan with a locally-registered one.
    """
    var bound = LogicalPlan.filter(
        Expr.udf_call(
            String("affine"),
            Optional[Int](7),
            ArrowType.INT64,
            ArrowType.INT64,
            Expr.col_ref(String("a")),
        ),
        _scan(String("t"), String("/x.orc")),
    )
    # The premise: the node really was bound before it was encoded. Without
    # this the test would pass over a node that never had a handle, which is
    # the vacuity this file's other entries guard with a zero-bytes check.
    assert_true(
        "h=7" in String(bound),
        "the corpus built a UDF node with handle=7 and the render does not say"
        " so, so this test cannot observe the strip. got: " + String(bound),
    )
    var back = plan_from_bytes(plan_to_bytes(bound))
    assert_true(
        "h=-" in String(back),
        "a decoded EXPR_UDF_CALL is NOT unbound — the plan came back rendering"
        " a handle. `UdfCallData.handle` is a slot+generation into a"
        " UdfRegistry that exists in ONE process; a low slot at generation 0"
        " exists in almost any registry, so a carried handle resolves"
        " PLAUSIBLY to a DIFFERENT function rather than failing. got: "
        + String(back),
    )
    assert_true(
        "h=7" not in String(back),
        "the decoded plan still renders the ENCODER's handle. See above: this"
        " is the one field `plan.proto`'s header says the wire may never"
        " carry. got: " + String(back),
    )


def test_a_nested_udf_call_round_trips() raises:
    """`affine(affine(a))` — NESTING IS THE WHOLE REASON `EXPR_UDF_CALL` IS A
    TAG rather than a flag on a node.

    ⚠ `WireUdfCall.child` IS A RECURSION BOX (`List[WireExpr]`) because
    `WireExpr` can reach itself through it, so `_one_expr` is what refuses a
    box holding 0 or 2 instead of assuming 1. An arm only ever tested at the
    root never exercises being decoded as somebody's child, and this arm's
    child is another instance of itself.
    """
    _assert_round_trips(
        String("filter(udf_call(affine, udf_call(affine, col(a))))"),
        LogicalPlan.filter(
            Expr.udf_call(
                String("affine"),
                Optional[Int](None),
                ArrowType.INT64,
                ArrowType.INT64,
                Expr.udf_call(
                    String("affine"),
                    Optional[Int](None),
                    ArrowType.INT64,
                    ArrowType.INT64,
                    Expr.col_ref(String("a")),
                ),
            ),
            _scan(String("t"), String("/x.orc")),
        ),
    )


def test_a_udf_call_whose_in_and_out_dtypes_DIFFER_round_trips() raises:
    """⛔⛔ THE ONE ENTRY THAT CAN SEE A SWAPPED DTYPE PAIR.

    `WireUdfCall.in_arrow_type_id` and `.out_arrow_type_id` are adjacent
    `uint32`s. To protoc they are interchangeable: an encoder that wrote them
    the wrong way round produces a WELL-FORMED message that decodes without
    complaint. The only thing that distinguishes them is their VALUES — so
    over a TYPE-PRESERVING UDF, which is what most UDFs are (`accepts ==
    returns`; an `affine` int64 -> int64 map, say), a swap is BYTE-IDENTICAL
    and invisible to every leg of every test.

    ⇒ `in=INT64, out=FLOAT64`. LEG 3's `_expr_ir` keeps the two apart
    (`in=5,out=12`) rather than joining them, and LEG 2 sees the projection's
    output field come back FLOAT64, so a swap is caught twice and by two
    different mechanisms.

    ⚠ THE ENGINE REALLY SUPPORTS THIS SHAPE — it is what `SqlUdfEntry.out_type`
    exists for and `execute_udf_map_by_handle` has four arms over both
    positions independently. This is not a synthetic value the wire will never
    see; it is a capability a type-preserving corpus cannot reach.
    """
    var pe = ExprArray()
    pe.append(
        Expr.alias(
            Expr.udf_call(
                String("to_f64"),
                Optional[Int](None),
                ArrowType.INT64,
                ArrowType.FLOAT64,
                Expr.col_ref(String("a")),
            ),
            String("y"),
        )
    )
    _assert_round_trips(
        String("project(udf_call(to_f64, int64 -> float64) AS y)"),
        LogicalPlan.project(pe^, _scan(String("t"), String("/x.orc"))),
    )
    # ...AND THE OTHER WAY ROUND, which is NOT a duplicate. The observability
    # census demands TWO OR MORE DISTINCT VALUES per wire slot: with only the
    # entry above, every `WireUdfCall` in this whole corpus carries
    # `in_arrow_type_id = 5`, so the slot is a constant and a forgery into it
    # cannot be distinguished from the value it already held. FLOAT64 -> INT64
    # is what makes BOTH type-id slots two-valued, and it is the reversal of
    # the pair above rather than a third arbitrary shape so that a swap in the
    # encoder is caught by the two entries DISAGREEING with each other.
    var pe2 = ExprArray()
    pe2.append(
        Expr.alias(
            Expr.udf_call(
                String("to_i64"),
                Optional[Int](None),
                ArrowType.FLOAT64,
                ArrowType.INT64,
                # ⚠ `dec`, NOT a FLOAT64 COLUMN — `_schema()` has none, and the
                # ARGUMENT's dtype is not what this entry is about. A UDF
                # call's declared `in_type` is checked against the argument
                # column at EXECUTION (`_run_one_udf_call`'s plan-vs-data
                # check), never at plan-build or on the wire, so the corpus is
                # free to state the pair it needs the wire to carry.
                Expr.col_ref(String("dec")),
            ),
            String("z"),
        )
    )
    _assert_round_trips(
        String("project(udf_call(to_i64, float64 -> int64) AS z)"),
        LogicalPlan.project(pe2^, _scan(String("t"), String("/x.orc"))),
    )


def test_a_nameless_udf_call_is_refused_at_encode() raises:
    """★ THE ONE UDF REFUSAL THAT SURVIVES THE ARM, AND IT IS `WireUdf`'S RULE
    ONE ALTITUDE DOWN.

    A UDF minted from a live in-process closure has no resolvable name
    (`UdfDescriptor.is_describable()` is false exactly when the name is empty).
    The NAME is the only thing a peer can resolve against its own registry —
    the handle is process-local and is not carried — so a `WireUdfCall` with an
    empty name would cross losslessly and then refuse at the far end,
    arbitrarily far from the cause. `InMemorySource` is the same rule for live
    DATA inside the IR; this is live CODE. Both stay usable in-process and
    neither crosses.

    ⛔ AND IT IS REFUSED AT **ENCODE**, WHICH IS THE HALF THAT MATTERS. Refusing
    at decode would name the receiver's problem; refusing here names the
    producer's, which is the one that can be fixed.
    """
    _assert_refuses(
        String("EXPR_UDF_CALL_EMPTY_NAME"),
        LogicalPlan.filter(
            Expr.udf_call(
                String(""),
                Optional[Int](None),
                ArrowType.INT64,
                ArrowType.INT64,
                Expr.col_ref(String("a")),
            ),
            _scan(String("t"), String("/x.orc")),
        ),
        String("PLAN_WIRE_UDF_NOT_DESCRIBABLE"),
    )


def test_an_unknown_format_version_is_refused_not_best_effort() raises:
    """A decoder that cannot tell "written by an older build" from "corrupt"
    will eventually execute one as the other.

    Falsified by construction: the bytes are a VALID plan with ONE byte
    changed — the version — so a decoder that ignored the field would decode
    them successfully and this test would fail."""
    var good = plan_to_bytes(_scan(String("t"), String("/x.orc")))
    var tampered = good.copy()
    var patched = False
    # ⚠ THE VERSION BYTE IS DERIVED, NOT LITERAL. A literal goes stale on every
    # version bump (this loop then finds nothing and the test fails on its own
    # vacuity guard), and a literal that has to be edited on every bump is a
    # literal that will eventually be edited to whatever makes the test pass.
    var version_byte = UInt8(Int(PLAN_WIRE_FORMAT_VERSION))
    for i in range(len(tampered) - 1):
        if tampered[i] == UInt8(0x08) and tampered[i + 1] == version_byte:
            tampered[i + 1] = UInt8(99)
            patched = True
            break
    assert_true(
        patched,
        "could not find the format_version varint to tamper with — the"
        + " envelope's encoding changed and this test is no longer testing"
        + " what it says it is",
    )
    var raised = False
    var text = String("")
    try:
        var p = plan_from_bytes(tampered^)
        _ = p.structural_hash()
    except e:
        raised = True
        text = String(e)
    assert_true(raised, "an unknown format_version decoded without complaint")
    assert_true(
        String("PLAN_WIRE_VERSION_MISMATCH") in text,
        "the decoder raised, but not with PLAN_WIRE_VERSION_MISMATCH: " + text,
    )
    # THE CONTROL. Without it, a decoder that refused EVERYTHING would pass the
    # assertion above.
    var ok = plan_from_bytes(good^)
    _ = ok.structural_hash()


def test_truncated_bytes_do_not_decode_into_a_plan() raises:
    """Half a plan is not a plan. A decoder that returned a partial tree would
    hand the engine a plan the writer never wrote."""
    var good = plan_to_bytes(
        LogicalPlan.filter(
            Expr.binary(
                BIN_GT, Expr.col_ref("a"), Expr.literal(ScalarValue.from_int64(Int64(3)))
            ),
            _scan(String("t"), String("/x.orc")),
        )
    )
    assert_true(len(good) > 8, "the fixture plan encoded suspiciously small")
    var cut = List[UInt8]()
    for i in range(len(good) // 2):
        cut.append(good[i])
    var raised = False
    try:
        var p = plan_from_bytes(cut^)
        _ = p.structural_hash()
    except e:
        raised = True
    assert_true(
        raised,
        "truncated bytes decoded into a plan. Whatever came back is not the"
        + " plan that was written.",
    )


# =============================================================================
# THE HOSTILE ENCODER — every decode-side NARROWING, driven out of range
# =============================================================================
#
# ⚠ A DECODER IS THE ONE HALF OF A WIRE FORMAT THAT DOES NOT CHOOSE ITS INPUT.
# Everything above round-trips bytes THIS BUILD WROTE, so it can only ever
# exercise values this build's encoder can produce. A wire format's decoder
# faces a version-skewed peer, a different-language frontend, and a hostile
# one, and the format's own stated rule — nothing is silently dropped, every
# unsupported shape RAISES BY NAME — has to hold for all three.
#
# `WireField` carries THREE `ArrowType`s, and all three are UInt32 on the wire
# and UInt8 in the engine: `arrow_type_id`, `dict_index_type_id`, and each
# element of `child_type_ids`. Narrowed with a bare
# `ArrowType(UInt8(Int(w.arrow_type_id)))` and NO check, a wire value of 300
# becomes 44 (FIXED_SIZE_BINARY) — a decoded plan with a DIFFERENT SCHEMA, from
# bytes that raise nothing.
#
# ★ THE TARGET IS THE BINDING'S SCHEMA, DELIBERATELY. `WirePlan.output_schema`
# is cross-checked against the factory's derivation by `_check_output_schema`,
# so a corrupted type id THERE gets caught by accident, with the wrong token.
# `ScanBinding.schema` is compared against nothing — it is the site where the
# narrowing was, and is, genuinely silent.


def _tamper_binding_type_id(
    var bytes: List[UInt8], which: Int, value: UInt32
) raises -> List[UInt8]:
    """Rewrite ONE type id on the scan binding's schema, through the generated
    message types — i.e. exactly the bytes a hostile or version-skewed ENCODER
    would emit. `which`: 0 = arrow_type_id, 1 = dict_index_type_id, 2 = the
    first child_type_id.

    Every step RAISES rather than returning the input unchanged. A fixture that
    silently fails to mutate makes its test vacuously green, which is the whole
    failure class this file is about."""
    var env = decode_proto[WirePlanEnvelope](bytes^)
    if not env.plan:
        raise Error("fixture: the envelope carries no plan")
    var plan = env.plan.value().copy()
    if not plan.scan:
        raise Error("fixture: the plan root is not a SCAN")
    var scan = plan.scan[0].copy()
    if not scan.source:
        raise Error("fixture: the scan carries no source")
    var src = scan.source.value().copy()
    if not src.binding:
        raise Error("fixture: the source is not binding-backed")
    var b = src.binding.value().copy()
    if not b.schema:
        raise Error("fixture: the binding carries no schema")
    var sch = b.schema.value().copy()
    if len(sch.fields) == 0:
        raise Error("fixture: the binding schema declares no fields")
    var f = sch.fields[0].copy()
    if which == 0:
        f.arrow_type_id = value
    elif which == 1:
        f.dict_index_type_id = value
    else:
        var kid_types = List[UInt32]()
        kid_types.append(value)
        var kid_names = List[String]()
        kid_names.append(String("k"))
        var kid_nulls = List[Bool]()
        kid_nulls.append(True)
        f.child_type_ids = kid_types^
        f.child_names = kid_names^
        f.child_nullables = kid_nulls^
    var fields = List[WireField]()
    fields.append(f^)
    for i in range(1, len(sch.fields)):
        fields.append(sch.fields[i].copy())
    sch.fields = fields^
    b.schema = Optional(sch^)
    src.binding = Optional(b^)
    scan.source = Optional(src^)
    # RECURSION BOX (1.0.0): this is an INLINING edge on a cyclic
    # message, so the emitter boxes it as `List[T]` -- 1.0.0's
    # `Deinitable` is no longer co-inductive, so an `Optional[T]`
    # self-edge has no synthesizable destructor (see lower.rs).
    #
    # ⚠ REPLACE SLOT 0 -- NEVER `append`. Singular box; the encoder writes
    # slot 0 only, so an `append` leaves the tamper in `[1]` and off the wire.
    plan.scan[0] = scan^
    env.plan = Optional(plan^)
    return encode_proto[WirePlanEnvelope](env)


def _assert_hostile_type_id_refused(
    what: String, which: Int, value: UInt32
) raises:
    var good = plan_to_bytes(_scan(String("t"), String("/x.orc")))
    var bad = _tamper_binding_type_id(good.copy(), which, value)
    assert_true(
        bad != good,
        what + ": the tamper produced BYTE-IDENTICAL output. The message shape"
        + " moved and this test is no longer testing what it says it is.",
    )
    var raised = False
    var text = String("")
    try:
        var p = plan_from_bytes(bad^)
        _ = p.structural_hash()
    except e:
        raised = True
        text = String(e)
    assert_true(
        raised,
        what + ": the decoder ACCEPTED an out-of-vocabulary Arrow type id and"
        + " built a plan from it. A UInt32 narrowed into a UInt8 with no check"
        + " does not fail — it succeeds at describing a DIFFERENT schema, and"
        + " nothing downstream compares a binding's schema to anything.",
    )
    assert_true(
        String("PLAN_WIRE_UNSUPPORTED_ARROW_TYPE") in text,
        what + ": the decoder raised, but not with"
        + " PLAN_WIRE_UNSUPPORTED_ARROW_TYPE. A refusal a caller cannot name is"
        + " a refusal a test cannot pin. got: " + text,
    )
    # THE CONTROL, on every case. Without it a decoder that refused every input
    # would pass all four assertions above with full marks.
    var ok = plan_from_bytes(good^)
    _ = ok.structural_hash()


def _forge_slot_byte(
    bytes: List[UInt8], slot: String, value: UInt8, what: String
) raises -> List[UInt8]:
    """Patch the single-byte varint at slot `slot` to `value`, IN PLACE.

    Derived from the same `_walk` the observability probe uses, NEVER from a
    byte search: a raw scan for the value byte would also hit that byte inside
    a string payload, and a test that patched one of those would be measuring
    nothing while looking like it measured something.

    IN PLACE, so `value` must fit in one varint byte. A longer encoding would
    shift every later field and the decoder would be reading a DIFFERENT
    message rather than a forged one.
    """
    var reg = _SlotRegistry()
    var sites = _slot_sites(bytes, reg, slot)
    # ⚠ AT LEAST ONE, AND THE FORGE GOES TO THE FIRST. Requiring EXACTLY one
    # looked like the stronger vacuity guard and is the wrong one: `WireParam|2`
    # occurs FIVE times in a binding-backed scan, one per scan parameter, and a
    # guard that failed on that would be failing on the corpus being richer than
    # the author assumed. What has to be non-vacuous is that the slot is written
    # AT ALL — a zero here means the plan stopped carrying the field and every
    # assertion downstream is trivially true.
    assert_true(
        len(sites) >= 1,
        what + ": the corpus plan writes " + slot + " ZERO times, so this case"
        + " forges nothing and is vacuously green. Either the plan stopped"
        + " carrying the field or the slot moved.",
    )
    assert_true(
        Int(value) <= 127,
        what + ": the forge is IN PLACE, so the value must be a one-byte"
        + " varint.",
    )
    var out = bytes.copy()
    assert_true(
        out[sites[0]] != value,
        what + ": the forged value is what the encoder already wrote, so the"
        + " forge is a no-op and this case is vacuously green.",
    )
    out[sites[0]] = value
    return out^


def _assert_forged_slot_refused(
    var bad: List[UInt8], token: String, what: String, why: String
) raises:
    var raised = False
    var text = String("")
    try:
        var p = plan_from_bytes(bad^)
        _ = p.structural_hash()
    except e:
        raised = True
        text = String(e)
    assert_true(raised, what + ": " + why)
    assert_true(
        token in text,
        what + ": the decoder raised, but the message never named " + token
        + " — so the refusal did not come from the derived vocabulary, and the"
        + " space being registered is not actually load-bearing in the decode"
        + " path. got: " + text,
    )


def test_an_in_vocabulary_range_but_undeclared_scalar_kind_is_refused() raises:
    """★ A DISCRIMINATOR MUST NOT BE ASSIGNED WITHOUT A CHECK.

    `ScalarValue._kind` selects which of the struct's 17 payload fields is
    live. The naive decode is

        v._kind = UInt8(Int(w.kind))

    — no range check, no membership check, nothing: an unvalidated tag beside
    a flat payload, with no arm-presence check standing behind it. So
    `SCALAR_KIND_*` is a registered vocabulary space, with a proto enum and a
    test that walks it.

    ⚠ 11 IS THE INTERESTING VALUE, NOT 300. It is one past the highest declared
    member (`SCALAR_KIND_BINARY` = engine 9 = wire 10), so it fits in a UInt8,
    narrows LOSSLESSLY, and survives every range check a decoder might have. It
    is exactly what a peer built from a NEWER `scalar_value.mojo` sends — the
    version-skew case the format's fail-loud rule exists for. Separating a RANGE
    check from a MEMBERSHIP check is the entire point, and only an in-range
    value can do it.

    The bound is DERIVED: `scalar_kind_is_declared` comes out of the generated
    vocabulary's ScalarKind space, so once `comptime SCALAR_KIND_NEW: UInt8 = 10`
    is added to the engine and the vocabulary is regenerated from the engine's
    tag declarations, this value is legal with no edit here.
    """
    var lit = LogicalPlan.filter(
        Expr.binary(
            BIN_GT,
            Expr.col_ref("a"),
            Expr.literal(ScalarValue.date32(Int32(19000))),
        ),
        _scan(String("t"), String("/x.orc")),
    )
    var good = plan_to_bytes(lit)
    var what = String("scalar kind wire 11 (in range, not declared)")
    _assert_forged_slot_refused(
        _forge_slot_byte(good, String("WireScalar|6"), UInt8(11), what),
        String("ScalarKind"),
        what,
        "the decoder ACCEPTED an out-of-vocabulary ScalarKind and built a plan"
        + " from it. A discriminator narrowed into a UInt8 with no check does"
        + " not fail — it succeeds at describing a literal whose live arm does"
        + " not exist, and no round-trip leg compares a literal it cannot name.",
    )


def test_an_in_vocabulary_range_but_undeclared_param_tag_is_refused() raises:
    """★ THE NARROW-BEFORE-VALIDATE SITE, AND WHAT ITS FIX IS ACTUALLY WORTH.

    A decoder that computes `UInt8(Int(e.tag))` and compares the RESULT
    against the `PARAM_*` constants — the narrowing FIRST, the check on what
    came out — turns an untrusted `uint32` 256 into 0 and decodes it as
    `PARAM_STR`, 257 as `PARAM_I64`: every out-of-range value
    ALIASED onto a legal one instead of reaching the `else` that raises. Same
    class as an unchecked `arrow_type_id` narrowing (300 -> 44, silently
    renaming a column's type).

    ⚠ THIS TEST CANNOT WRITE 256 — the forge is in place and 256 is a two-byte
    varint, which would shift every later field and make the decoder read a
    different message. What it CAN do, and what settles the question this file
    can settle, is prove the codec CONSULTS THE VOCABULARY AT RUNTIME: wire 7 is
    one past `PARAM_BYTES` (engine 5 = wire 6), and the refusal must name the
    SPACE — i.e. come from `param_tag_from_wire` — rather than from a
    hand-rolled `else` raising PLAN_WIRE_UNSUPPORTED_PARAM_TAG, which would
    still pass a weaker assertion.

    The 256 case itself is closed two other ways, and neither of them is here:
      * BY TYPE. `WireParam.tag` is now a `ParamTag` proto enum, and the binary
        decoder's `read_enum` narrows the varint to Int32 before the codec ever
        sees it, so the uint32-to-UInt8 aliasing shape no longer exists.
      * BY THE VOCABULARY DRIVE. `test_plan_wire_vocabulary.mojo`'s
        `test_every_space_refuses_the_four_bad_wire_values` drives EVERY
        registered space with 0, -1, max+2 and 100000 — and because `ParamTag`
        is REGISTERED it covers it with NO EDIT to that file. That property
        is exactly why registering the space is the right guard, and why a
        hand-written check beside a ladder would not be.
    """
    var good = plan_to_bytes(_scan(String("t"), String("/x.orc")))
    var what = String("param tag wire 7 (in range, not declared)")
    _assert_forged_slot_refused(
        _forge_slot_byte(good, String("WireParam|2"), UInt8(7), what),
        String("ParamTag"),
        what,
        "the decoder ACCEPTED an out-of-vocabulary ParamTag and built a plan"
        + " from it.",
    )


def test_an_out_of_range_arrow_type_id_is_refused_by_name() raises:
    """300 does not fit in a UInt8. Unchecked, it becomes 44 —
    FIXED_SIZE_BINARY — and the decoded binding promises a column type its
    encoder never wrote."""
    _assert_hostile_type_id_refused(
        String("arrow_type_id=300"), 0, UInt32(300)
    )


def test_an_out_of_range_dict_index_type_id_is_refused_by_name() raises:
    """`Field._dict_index_type` is read by NEITHER leg — the plan render does
    not emit it and `_schema_text` does not either — so this narrowing is
    silent at every value, not merely at the corpus's."""
    _assert_hostile_type_id_refused(
        String("dict_index_type_id=300"), 1, UInt32(300)
    )


def test_an_out_of_range_child_type_id_is_refused_by_name() raises:
    """The three type ids are three separate narrowings and were three
    separate omissions; the child list is the one inside a loop."""
    _assert_hostile_type_id_refused(
        String("child_type_ids[0]=300"), 2, UInt32(300)
    )


def test_an_in_range_but_undeclared_arrow_type_id_is_refused_by_name() raises:
    """★ THE CASE THAT SEPARATES A RANGE CHECK FROM A MEMBERSHIP CHECK.

    50 fits in a UInt8 and narrows LOSSLESSLY, so a `w.arrow_type_id > 255`
    guard accepts it — and `ArrowType` declares 0..49, so there is no such
    type. It is exactly what a peer built from a NEWER `arrow_types.mojo`
    sends, which is the version-skew case the format's fail-loud rule exists
    for: a plan you cannot execute is not a plan you may partially execute.

    The bound is DERIVED, not written here: `arrow_type_is_declared` comes out
    of the generated vocabulary's ArrowType space, so once
    `comptime NEW_TYPE = ArrowType(50)` is added to the engine and the
    vocabulary is regenerated from the engine's tag declarations, this value is
    legal with no edit to the codec."""
    _assert_hostile_type_id_refused(
        String("arrow_type_id=50 (in range, not declared)"), 0, UInt32(50)
    )


def _assert_forged_is_refused(what: String, var bad: List[UInt8], token: String) raises:
    """Decode bytes no encoder here can produce, and demand a NAMED
    refusal. Same shape as `_assert_hostile_type_id_refused` above, generalised
    over the forgery: the decoder does not choose its input."""
    var raised = False
    var text = String("")
    try:
        var p = plan_from_bytes(bad^)
        _ = p.structural_hash()
    except e:
        raised = True
        text = String(e)
    assert_true(
        raised,
        what + ": the decoder ACCEPTED a shape the format cannot represent and"
        + " built a plan from it. Every unsupported shape RAISES BY NAME — a"
        + " decoder that quietly normalises one is a decoder that drops data.",
    )
    assert_true(
        token in text,
        what + ": the decoder raised, but not with " + token + ". A refusal a"
        + " caller cannot name is a refusal a test cannot pin. got: " + text,
    )


def test_a_schema_metadata_length_mismatch_is_refused_by_name() raises:
    """★ THE ELEVENTH FIELD'S OWN HOSTILE CASE.

    `WireSchema.metadata_keys` / `.metadata_values` are PARALLEL lists, and
    nothing in proto3 ties their lengths together. A decoder that zipped them
    to the shorter one would silently invent a schema whose metadata is a
    TRUNCATION of what the writer sent — the same class as dropping the pair
    outright.

    `_field_from_wire` carries this refusal for `Field`'s pair; the
    table-level pair gets the same refusal."""
    var good = plan_to_bytes(_scan(String("t"), String("/x.orc")))
    var env = decode_proto[WirePlanEnvelope](good^)
    if not env.plan:
        raise Error("fixture: the envelope carries no plan")
    var plan = env.plan.value().copy()
    if not plan.output_schema:
        raise Error("fixture: the plan root carries no output schema")
    var sch = plan.output_schema.value().copy()
    sch.metadata_keys = [String("k1"), String("k2")]
    sch.metadata_values = [String("v1")]
    plan.output_schema = Optional(sch^)
    env.plan = Optional(plan^)
    _assert_forged_is_refused(
        String("WireSchema metadata 2 keys / 1 value"),
        encode_proto[WirePlanEnvelope](env),
        String("PLAN_WIRE_MALFORMED"),
    )


def test_a_duplicate_schema_metadata_key_is_refused_by_name() raises:
    """★ THE SECOND HALF OF THE ELEVENTH FIELD'S DISCIPLINE — and the length
    check beside it cannot stand in for it.

    `_schema_from_wire` restores the table-level pair by RAW PARALLEL-LIST
    ASSIGNMENT onto the built `Schema`, because `SchemaBuilder` has no channel
    for it. That bypasses `Schema.set_metadata`, which is an UPSERT: it rewrites
    a key it already holds. So a duplicate key is a state NO ENGINE PATH CAN
    BUILD, and every reader — `get_metadata`, `has_metadata` — answers from the
    FIRST match, making the second pair unreachable while `metadata_count()`
    still counts it.

    Equal-length lists sail past the check this test sits next to, so the
    forgery below is well-formed by that rule and malformed by this one. A
    decoder that accepted it would hand back a schema the engine cannot
    construct; one that de-duplicated silently would truncate the writer's
    metadata, which is the exact failure the length check exists to prevent."""
    var good = plan_to_bytes(_scan(String("t"), String("/x.orc")))
    var env = decode_proto[WirePlanEnvelope](good^)
    if not env.plan:
        raise Error("fixture: the envelope carries no plan")
    var plan = env.plan.value().copy()
    if not plan.output_schema:
        raise Error("fixture: the plan root carries no output schema")
    var sch = plan.output_schema.value().copy()
    sch.metadata_keys = [String("owner"), String("owner")]
    sch.metadata_values = [String("first"), String("second")]
    plan.output_schema = Optional(sch^)
    env.plan = Optional(plan^)
    _assert_forged_is_refused(
        String("WireSchema metadata with the key 'owner' twice"),
        encode_proto[WirePlanEnvelope](env),
        String("PLAN_WIRE_MALFORMED"),
    )


def test_partition_values_with_no_partition_cols_are_refused_not_dropped() raises:
    """★ A SILENT DROP ON THE DECODE SIDE, IN A FORMAT WHOSE RULE IS FAIL-LOUD.

    `_parquet_from_wire`'s single-path fast path
    (`len(w.paths) == 1 and len(w.partition_cols) == 0`) hands the bytes to the
    single-path `ParquetSource` ctor, which has NO SLOT for `partition_values`
    — so a message carrying value rows with no columns had them DISCARDED with
    no diagnostic. `ParquetSource.partitioned` refuses exactly that shape by
    name ("partition_values must be empty when partition_cols is empty"), so
    the multi-path branch was already covered and this branch was the one place
    the engine's own invariant was not applied.

    ⚠ THE LEAF IS `_parquet_leaf_b()` DELIBERATELY — one path, no partition
    columns — because that is the ONLY leaf that reaches the fast path. Forging
    over `_parquet_leaf()` would exercise the branch that already refused."""
    var good = plan_to_bytes(_parquet_leaf_b())
    var env = decode_proto[WirePlanEnvelope](good^)
    if not env.plan:
        raise Error("fixture: the envelope carries no plan")
    var plan = env.plan.value().copy()
    if not plan.scan:
        raise Error("fixture: the plan root is not a SCAN")
    var scan = plan.scan[0].copy()
    if not scan.source:
        raise Error("fixture: the scan carries no source")
    var src = scan.source.value().copy()
    if not src.parquet:
        raise Error("fixture: the source is not a parquet leaf")
    var q = src.parquet.value().copy()
    if len(q.paths) != 1 or len(q.partition_cols) != 0:
        raise Error(
            "fixture: the leaf is not single-path/unpartitioned, so it does"
            " not reach the fast path this test is about"
        )
    q.partition_values = [WirePartitionValueRow([String("2024"), String("emea")])]
    src.parquet = Optional(q^)
    scan.source = Optional(src^)
    # RECURSION BOX (1.0.0): this is an INLINING edge on a cyclic
    # message, so the emitter boxes it as `List[T]` -- 1.0.0's
    # `Deinitable` is no longer co-inductive, so an `Optional[T]`
    # self-edge has no synthesizable destructor (see lower.rs).
    #
    # ⚠ REPLACE SLOT 0 -- NEVER `append`. Singular box; the encoder writes
    # slot 0 only, so an `append` leaves the tamper in `[1]` and off the wire.
    plan.scan[0] = scan^
    env.plan = Optional(plan^)
    _assert_forged_is_refused(
        String("WireParquetSource 1 value row / 0 partition cols"),
        encode_proto[WirePlanEnvelope](env),
        String("PLAN_WIRE_MALFORMED"),
    )
    # THE CONTROL. Without it a decoder that refused every parquet leaf would
    # pass both assertions above with full marks.
    var ok = plan_from_bytes(plan_to_bytes(_parquet_leaf_b()))
    _ = ok.structural_hash()


# =============================================================================
# FALSIFICATION RECORD — which leg catches which mutation
# =============================================================================
#
# Each line below is a mutation of the CODEC and the leg that turns it red.
# Which leg fires is a property of the RENDER (`Expr.write_to`,
# `plan_display`), not of the codec, and the only way to know is to drive it.
# Mutations that land on the SAME tests are driven one build at a time, so a
# red attributes to exactly one of them.
#
#   SCALAR AT ITS DEFAULT    `LimitData.offset` written as 0. LEG 1, and only
#                            because the corpus uses offset=2: over a
#                            default-offset corpus proto3 omits the field and
#                            the mutation is INVISIBLE.
#   LIST DROPPED             `JoinData.left_on`/`right_on` emptied. LEG 1.
#                            Dropping only ONE of the two is worse: the
#                            decoded plan cannot even be RENDERED (an index
#                            out of bounds aborts the process), so both are
#                            dropped to get an attributable assertion.
#   NESTED VARIANT           `AggExpr.child` dropped. Caught by the codec's OWN
#                            `_check_output_schema` (`SUM(<nothing>)`
#                            re-infers as NULL where the original was INT64),
#                            not by LEG 1 — the render emits the output column
#                            NAME, which survives.
#   RENDER-INVISIBLE FLAG    `CastData.try_cast` pinned False. LEG 3 ALONE: the
#                            render prints `Cast(<child>, <target>)`, and a
#                            FILTER predicate feeds no output schema.
#   INNER PLAN ONE LEVEL     a correlated subquery's inner FILTER dropped. LEG
#   SHALLOWER                3 ALONE — the render prints `inner_tag=<Int>` and
#                            does not recurse, which is why
#                            `_two_level_inner_plan` has TWO levels.
#   RIGHT COUNT, WRONG       `outer_refs` replaced by a same-length list. LEG 3
#   NAMES                    ALONE — the render prints `outer_refs=#<count>`.
#   LIST TAIL DROPPED        all but the first CASE branch. LEG 3 is the
#                            value-level check; `_infer_expr_field` types a
#                            CASE from its FIRST THEN clause, which the
#                            mutation preserves, so LEG 2 is blind by
#                            construction. A zero-case CASE is the control.
#   ENUM PINNED TO MEMBER 0  `AggFnData.op`, `MathFnData.op`,
#                            `ExtractData.unit`. LEG 1 (the op is rendered),
#                            but the sweep's FIRST iteration — the member that
#                            IS engine value 0 — is blind; the rest are not.
#                            Pinning the extract unit also turns the
#                            sparse-hole refusal test red, because the encoder
#                            no longer validates the caller's value.
#   OPERANDS CROSSED         `MathFn2Data.left`/`.right` swapped. LEG 1, and
#                            only because the corpus operands DIFFER: over
#                            `atan2(a, a)` the mutation is invisible to every
#                            leg.
#   DECODER RE-DERIVES       `Expr.substring(child, start)` at decode (the
#                            length parameter defaults to -1). LEG 1 on the
#                            three-argument form; the two-argument form is
#                            INDISTINGUISHABLE from a correct decoder, so the
#                            corpus carries both.
#   REFUSAL RE-ASSERTED      a refusal test left naming a tag that has just
#                            acquired an arm goes RED — the signal the refusal
#                            tokens exist to produce.
#
# ⚠ AND ONE THE TESTS CATCH WITHOUT A MUTATION: an arm ORDINAL is not a FIELD
# number. `when` is proto field 11 and ONEOF ARM 10 — protoc-gen-mojo's
# `_oneof0_case` counts arms from 1 in declaration order. Using the field number
# makes the encoder take the NEXT arm's branch and dereference its unset
# payload (`Optional.value() called on empty Optional`), killing the process.
# An off-by-one there is INVISIBLE while an arm is the last one declared — arm N
# and field N+1 coincide only until someone adds arm N+1.


# =============================================================================
# THE OBSERVABILITY PROBE — can a slot on the wire BE WRONG?
# =============================================================================
#
# ★ A CHECK THAT ASKS WHETHER A FIELD IS *MENTIONED* ASKS THE WRONG QUESTION.
#
# Whether a field is mentioned in the codec and mentioned in this file is a
# lexical property, and a mention-counting check can certify every carried
# field "compared" while fields exist that cannot be made to fail. A check that
# counts mentions cannot distinguish a carried field from a decorative one, and
# no sharper regex can, because the property is not lexical.
#
# The property is: FOR EACH SLOT THE CODEC WRITES, DOES MUTATING IT MAKE THIS
# SUITE RED? That is mutation testing, and it is answered by MEASUREMENT.
#
# HOW IT IS AFFORDABLE — AND WHY THAT DECIDED THE DESIGN
# ------------------------------------------------------
# The obvious form of mutation testing edits `plan_wire_codec.mojo`, rebuilds
# and re-runs — one compile of this target per wire slot, CPU HOURS per sweep,
# and a gate too expensive to run is a gate that gets turned off.
#
# So the mutation is applied to the BYTES instead of to the source. It is the
# same mutation: `plan_to_bytes` is the codec's whole output, and a codec that
# wrote a different value for one slot produces exactly the byte string this
# probe produces. Cost: ZERO extra compiles, and thousands of decode+observe
# cycles, which is milliseconds. It runs in every test run of this target.
#
# TWO ASSERTIONS PER SLOT, AND NEITHER SUBSUMES THE OTHER
# -------------------------------------------------------
#   CENSUS       every slot must be seen at TWO OR MORE DISTINCT VALUES across
#                the corpus. A single-valued slot survives an encoder that
#                HARDCODES it, and a slot no plan writes survives an encoder
#                that omits it. A `WireScalar.time_unit` that is MICRO in every
#                corpus scalar is this case. (A slot whose engine axis no
#                longer exists is removed from the format rather than given a
#                second value no plan could produce.)
#
#   PERTURBATION every occurrence of every slot, patched IN PLACE to a
#                different value of the SAME BYTE LENGTH, must either be
#                REFUSED by the decoder or change the round trip's observation.
#                It catches the shape where `_schema_to_wire` reads its `Field`
#                from an accessor that REBUILDS the `Field` and re-derives
#                `dtype` from `arrow_type` instead of returning the stored
#                entry — so no `WireField.dtype_code` on the wire could be made
#                to matter, at any value, in any corpus.
#
# The census passes a re-derived slot (its value varies with the column type,
# it is simply not READ back). The perturbation passes a single-valued slot
# (the perturbed value IS observed, it is merely never produced). Real defects
# fall on both sides, so a gate with either half alone would ship the other
# half's holes.
#
# THE UNIVERSE IS DERIVED, FROM `plan.proto`
# -------------------------------------------
# `_wire_slot_registry()` below is DERIVED from `komira_plan_proto`'s
# `plan.proto`, one row per declared field, and must be kept in step with it.
# A new wire field therefore cannot arrive outside this probe: it enters the
# registry, has no ledger row, and goes red.
#
# ⚠ AND THE PROBE REPORTS A SLOT IT SEES THAT THE REGISTRY DOES NOT DECLARE.
# The walk reads field numbers off the wire, so a message the codec writes that
# the proto does not describe is visible here and nowhere else.


# --- BEGIN WIRE-SLOT REGISTRY — DERIVED FROM plan.proto
# ⚠ Mechanically derived from `plan.proto`: one row per declared field, in
# declaration order. Edit it only together with `plan.proto`, and never by
# hand-picking rows.
#
# One row per WIRE SLOT: `Message|number|name|submessage-type|enum-type`.
# The submessage column is empty for every scalar, string, bytes and enum,
# and it is the ONLY thing that tells the walker where to recurse — a
# PACKED repeated scalar is length-delimited exactly like a submessage,
# so a walker that sniffed rather than read this would descend into
# `repeated int64` payloads and invent slots the format does not have.
#
# The enum column is the MUTATION OPERATOR's input, not the walker's. A
# one-bit flip on a vocabulary space allocated densely from 1 lands out
# of vocabulary at every value for some enum slots, so the decoder would
# refuse every perturbation and the gate would score them proven having
# tested only the RANGE CHECK. `_wire_enum_members` below lets
# `_census` mutate to another DECLARED member instead.
def _wire_slot_registry() -> List[String]:
    var r = List[String]()
    r.append(String("WireAggExpr|1|func||AggFn"))
    r.append(String("WireAggExpr|2|has_child0||"))
    r.append(String("WireAggExpr|3|child0|WireExpr|"))
    r.append(String("WireAggExpr|4|has_child1||"))
    r.append(String("WireAggExpr|5|child1|WireExpr|"))
    r.append(String("WireAggExpr|6|has_child2||"))
    r.append(String("WireAggExpr|7|child2|WireExpr|"))
    r.append(String("WireAggExpr|8|has_child3||"))
    r.append(String("WireAggExpr|9|child3|WireExpr|"))
    r.append(String("WireAggExpr|10|has_alias_name||"))
    r.append(String("WireAggExpr|11|alias_name||"))
    r.append(String("WireAggFn|1|op||AggFn"))
    r.append(String("WireAggFn|2|child|WireExpr|"))
    r.append(String("WireAggregateNode|1|group_by|WireExpr|"))
    r.append(String("WireAggregateNode|2|agg_exprs|WireAggExpr|"))
    r.append(String("WireAggregateNode|3|child|WirePlan|"))
    r.append(String("WireAggregateNode|4|has_estimated_groups||"))
    r.append(String("WireAggregateNode|5|estimated_groups||"))
    r.append(String("WireAggregateNode|6|has_udf||"))
    r.append(String("WireAggregateNode|7|udf|WireUdf|"))
    r.append(String("WireAlias|1|child|WireExpr|"))
    r.append(String("WireAlias|2|name||"))
    r.append(String("WireAsofJoinNode|1|left_keys||"))
    r.append(String("WireAsofJoinNode|2|right_keys||"))
    r.append(String("WireAsofJoinNode|3|left_asof||"))
    r.append(String("WireAsofJoinNode|4|right_asof||"))
    r.append(String("WireAsofJoinNode|5|strategy||AsofDirection"))
    r.append(String("WireAsofJoinNode|6|tolerance|WireAsofTolerance|"))
    r.append(String("WireAsofJoinNode|7|left_sort_keys||"))
    r.append(String("WireAsofJoinNode|8|left_sort_desc||"))
    r.append(String("WireAsofJoinNode|9|right_sort_keys||"))
    r.append(String("WireAsofJoinNode|10|right_sort_desc||"))
    r.append(String("WireAsofJoinNode|11|left|WirePlan|"))
    r.append(String("WireAsofJoinNode|12|right|WirePlan|"))
    r.append(String("WireAsofTolerance|1|kind||AsofToleranceKind"))
    r.append(String("WireAsofTolerance|2|int_val||"))
    r.append(String("WireAsofTolerance|3|float_val||"))
    r.append(String("WireBinaryOp|1|op||BinaryOp"))
    r.append(String("WireBinaryOp|2|left|WireExpr|"))
    r.append(String("WireBinaryOp|3|right|WireExpr|"))
    r.append(String("WireCast|1|child|WireExpr|"))
    r.append(String("WireCast|2|target_dtype_code||DTypeCode"))
    r.append(String("WireCast|3|target_arrow_type_id||"))
    r.append(String("WireCast|4|decimal_precision||"))
    r.append(String("WireCast|5|decimal_scale||"))
    r.append(String("WireCast|6|try_cast||"))
    r.append(String("WireCastToVarcharNode|1|child|WirePlan|"))
    r.append(String("WireColIdx|1|index||"))
    r.append(String("WireColRef|1|name||"))
    r.append(String("WireColRef|2|side||ColSide"))
    r.append(String("WireCorrelatedSubquery|1|inner_plan|WirePlan|"))
    r.append(String("WireCorrelatedSubquery|2|outer_refs||"))
    r.append(String("WireCorrelatedSubquery|3|kind||CorrelatedKind"))
    r.append(String("WireCorrelatedSubquery|4|in_lhs_col||"))
    r.append(String("WireCorrelatedSubquery|5|in_rhs_col||"))
    r.append(String("WireCseRefNode|1|canonical_hash||"))
    r.append(String("WireDistinctNode|1|has_columns||"))
    r.append(String("WireDistinctNode|2|columns||"))
    r.append(String("WireDistinctNode|3|child|WirePlan|"))
    r.append(String("WireDistinctNode|4|has_estimated_groups||"))
    r.append(String("WireDistinctNode|5|estimated_groups||"))
    r.append(String("WireExpr|2|col_ref|WireColRef|"))
    r.append(String("WireExpr|3|col_idx|WireColIdx|"))
    r.append(String("WireExpr|4|literal|WireScalar|"))
    r.append(String("WireExpr|5|binary_op|WireBinaryOp|"))
    r.append(String("WireExpr|6|unary_op|WireUnaryOp|"))
    r.append(String("WireExpr|7|alias|WireAlias|"))
    r.append(String("WireExpr|8|in_list|WireInList|"))
    r.append(String("WireExpr|9|cast|WireCast|"))
    r.append(String("WireExpr|10|correlated_subquery|WireCorrelatedSubquery|"))
    r.append(String("WireExpr|11|when|WireWhen|"))
    r.append(String("WireExpr|12|agg_fn|WireAggFn|"))
    r.append(String("WireExpr|13|extract|WireExtract|"))
    r.append(String("WireExpr|14|math_fn|WireMathFn|"))
    r.append(String("WireExpr|15|math_fn2|WireMathFn2|"))
    r.append(String("WireExpr|16|substring|WireSubstring|"))
    r.append(String("WireExpr|17|string_op|WireStringOp|"))
    r.append(String("WireExpr|18|regexp|WireRegexp|"))
    r.append(String("WireExpr|19|struct_field|WireStructField|"))
    r.append(String("WireExpr|20|struct_field_idx|WireStructFieldIdx|"))
    r.append(String("WireExpr|21|map_get|WireMapGet|"))
    r.append(String("WireExpr|22|json_extract|WireJsonExtract|"))
    r.append(String("WireExpr|23|window_fn|WireWindowFn|"))
    r.append(String("WireExpr|24|string_fn|WireStringFn|"))
    r.append(String("WireExpr|25|string_fn_n|WireStringFnN|"))
    r.append(String("WireExpr|26|udf_call|WireUdfCall|"))
    r.append(String("WireExtract|1|unit||ExtractField"))
    r.append(String("WireExtract|2|child|WireExpr|"))
    r.append(String("WireField|1|name||"))
    r.append(String("WireField|2|arrow_type_id||"))
    r.append(String("WireField|3|dtype_code||DTypeCode"))
    r.append(String("WireField|4|nullable||"))
    r.append(String("WireField|5|decimal_precision||"))
    r.append(String("WireField|6|decimal_scale||"))
    r.append(String("WireField|7|tz||"))
    r.append(String("WireField|8|dict_index_type_id||"))
    r.append(String("WireField|9|union_type_ids||"))
    r.append(String("WireField|10|flags||"))
    r.append(String("WireField|11|metadata_keys||"))
    r.append(String("WireField|12|metadata_values||"))
    r.append(String("WireField|13|child_names||"))
    r.append(String("WireField|14|child_type_ids||"))
    r.append(String("WireField|15|child_nullables||"))
    r.append(String("WireFilterNode|1|predicate|WireExpr|"))
    r.append(String("WireFilterNode|2|child|WirePlan|"))
    r.append(String("WireFilterNode|3|has_udf||"))
    r.append(String("WireFilterNode|4|udf|WireUdf|"))
    r.append(String("WireFrame|1|units||FrameUnits"))
    r.append(String("WireFrame|2|start_tag||FrameBound"))
    r.append(String("WireFrame|3|start_offset||"))
    r.append(String("WireFrame|4|end_tag||FrameBound"))
    r.append(String("WireFrame|5|end_offset||"))
    r.append(String("WireInList|1|child|WireExpr|"))
    r.append(String("WireInList|2|values|WireScalar|"))
    r.append(String("WireJoinNode|1|left|WirePlan|"))
    r.append(String("WireJoinNode|2|right|WirePlan|"))
    r.append(String("WireJoinNode|3|left_on||"))
    r.append(String("WireJoinNode|4|right_on||"))
    r.append(String("WireJoinNode|5|join_type||JoinType"))
    r.append(String("WireJoinNode|6|algo_hint||JoinAlgo"))
    r.append(String("WireJoinNode|7|has_residual||"))
    r.append(String("WireJoinNode|8|residual|WireExpr|"))
    r.append(String("WireJsonExtract|1|parent|WireExpr|"))
    r.append(String("WireJsonExtract|2|path_segments||"))
    r.append(String("WireJsonExtract|3|output_arrow_type_id||"))
    r.append(String("WireJsonExtract|4|preserve_extension_metadata||"))
    r.append(String("WireLimitNode|1|n||"))
    r.append(String("WireLimitNode|2|offset||"))
    r.append(String("WireLimitNode|3|child|WirePlan|"))
    r.append(String("WireMapGet|1|parent|WireExpr|"))
    r.append(String("WireMapGet|2|key|WireExpr|"))
    r.append(String("WireMathFn|1|op||MathFn1"))
    r.append(String("WireMathFn|2|child|WireExpr|"))
    r.append(String("WireMathFn2|1|op||MathFn2"))
    r.append(String("WireMathFn2|2|left|WireExpr|"))
    r.append(String("WireMathFn2|3|right|WireExpr|"))
    r.append(String("WireParam|1|key||"))
    r.append(String("WireParam|2|tag||ParamTag"))
    r.append(String("WireParam|3|s||"))
    r.append(String("WireParam|4|i||"))
    r.append(String("WireParam|5|f||"))
    r.append(String("WireParquetSource|1|paths||"))
    r.append(String("WireParquetSource|2|schema|WireSchema|"))
    r.append(String("WireParquetSource|3|has_name||"))
    r.append(String("WireParquetSource|4|name||"))
    r.append(String("WireParquetSource|5|mtime_ns||"))
    r.append(String("WireParquetSource|6|partition_cols|WireField|"))
    r.append(String("WireParquetSource|7|partition_values|WirePartitionValueRow|"))
    r.append(String("WireParquetSource|8|hive_dir_scan||"))
    r.append(String("WireParquetSource|9|has_hive_predicate||"))
    r.append(String("WireParquetSource|10|fs_is_local||"))
    r.append(String("WirePartitionByNode|1|partition_keys||"))
    r.append(String("WirePartitionByNode|2|order_keys||"))
    r.append(String("WirePartitionByNode|3|descending||"))
    r.append(String("WirePartitionByNode|4|partition_exprs|WirePartitionExpr|"))
    r.append(String("WirePartitionByNode|5|child|WirePlan|"))
    r.append(String("WirePartitionExpr|1|func||WindowFn"))
    r.append(String("WirePartitionExpr|2|column||"))
    r.append(String("WirePartitionExpr|3|offset||"))
    r.append(String("WirePartitionExpr|4|default_value|WireScalar|"))
    r.append(String("WirePartitionExpr|5|has_default||"))
    r.append(String("WirePartitionExpr|6|frame|WireFrame|"))
    r.append(String("WirePartitionExpr|7|alias_name||"))
    r.append(String("WirePartitionTopNNode|1|partition_keys||"))
    r.append(String("WirePartitionTopNNode|2|sort_keys||"))
    r.append(String("WirePartitionTopNNode|3|descending||"))
    r.append(String("WirePartitionTopNNode|4|k||"))
    r.append(String("WirePartitionTopNNode|5|func||WindowFn"))
    r.append(String("WirePartitionTopNNode|6|over_fetch_k||"))
    r.append(String("WirePartitionTopNNode|7|has_output_rank_col_name||"))
    r.append(String("WirePartitionTopNNode|8|output_rank_col_name||"))
    r.append(String("WirePartitionTopNNode|9|child|WirePlan|"))
    r.append(String("WirePartitionValueRow|1|values||"))
    r.append(String("WirePlan|2|output_schema|WireSchema|"))
    r.append(String("WirePlan|4|scan|WireScanNode|"))
    r.append(String("WirePlan|5|filter|WireFilterNode|"))
    r.append(String("WirePlan|6|project|WireProjectNode|"))
    r.append(String("WirePlan|7|aggregate|WireAggregateNode|"))
    r.append(String("WirePlan|8|join|WireJoinNode|"))
    r.append(String("WirePlan|9|sort|WireSortNode|"))
    r.append(String("WirePlan|10|limit|WireLimitNode|"))
    r.append(String("WirePlan|11|distinct|WireDistinctNode|"))
    r.append(String("WirePlan|12|topn|WireTopNNode|"))
    r.append(String("WirePlan|13|union_all|WireUnionNode|"))
    r.append(String("WirePlan|14|partition_by|WirePartitionByNode|"))
    r.append(String("WirePlan|15|partition_topn|WirePartitionTopNNode|"))
    r.append(String("WirePlan|16|asof_join|WireAsofJoinNode|"))
    r.append(String("WirePlan|17|view_ref|WireViewRefNode|"))
    r.append(String("WirePlan|18|cse_ref|WireCseRefNode|"))
    r.append(String("WirePlan|19|cast_to_varchar|WireCastToVarcharNode|"))
    r.append(String("WirePlanEnvelope|1|format_version||"))
    r.append(String("WirePlanEnvelope|2|plan|WirePlan|"))
    r.append(String("WirePlanEnvelope|3|write_target|WireWriteTarget|"))
    r.append(String("WireProjectNode|1|exprs|WireExpr|"))
    r.append(String("WireProjectNode|2|child|WirePlan|"))
    r.append(String("WireProjectNode|3|is_cse_introduced||"))
    r.append(String("WireProjectNode|4|has_udf||"))
    r.append(String("WireProjectNode|5|udf|WireUdf|"))
    r.append(String("WirePushdownGate|1|mode||PushdownGateMode"))
    r.append(String("WirePushdownGate|2|allowed_binary_ops||"))
    r.append(String("WirePushdownGate|3|allow_and_recurse||"))
    r.append(String("WirePushdownGate|4|allow_in_list||"))
    r.append(String("WirePushdownGate|5|require_stat_friendly_col||"))
    r.append(String("WireRegexp|1|op||RegexpOp"))
    r.append(String("WireRegexp|2|child|WireExpr|"))
    r.append(String("WireRegexp|3|pattern||"))
    r.append(String("WireRegexp|4|replacement||"))
    r.append(String("WireRegexp|5|flags||"))
    r.append(String("WireRegexp|6|group||"))
    r.append(String("WireRegexp|7|group_name||"))
    r.append(String("WireScalar|1|dtype_code||DTypeCode"))
    r.append(String("WireScalar|2|int_val||"))
    r.append(String("WireScalar|3|float_val||"))
    r.append(String("WireScalar|4|string_val||"))
    r.append(String("WireScalar|5|bool_val||"))
    r.append(String("WireScalar|6|kind||ScalarKind"))
    r.append(String("WireScalar|7|dec128_high||"))
    r.append(String("WireScalar|8|dec128_low||"))
    r.append(String("WireScalar|9|dec128_precision||"))
    r.append(String("WireScalar|10|dec128_scale||"))
    r.append(String("WireScalar|11|date32_val||"))
    r.append(String("WireScalar|12|ts_micros||"))
    r.append(String("WireScalar|13|null_dtype_code||DTypeCode"))
    r.append(String("WireScalar|14|iv_months||"))
    r.append(String("WireScalar|15|iv_days||"))
    r.append(String("WireScalar|16|iv_nanos||"))
    r.append(String("WireScalar|17|time_unit||ScalarTimeUnit"))
    r.append(String("WireScalar|18|dec256_high_lo||"))
    r.append(String("WireScalar|19|dec256_high_hi||"))
    r.append(String("WireScanBinding|1|kind_id||"))
    r.append(String("WireScanBinding|2|kind_name||"))
    r.append(String("WireScanBinding|3|name||"))
    r.append(String("WireScanBinding|4|params|WireParam|"))
    r.append(String("WireScanBinding|5|schema|WireSchema|"))
    r.append(String("WireScanBinding|6|fingerprint||"))
    r.append(String("WireScanBinding|7|structural_id||"))
    r.append(String("WireScanBinding|8|pushdown_gate|WirePushdownGate|"))
    r.append(String("WireScanBinding|9|pushdown_extra_cols||"))
    r.append(String("WireScanBinding|10|snapshot_policy||SnapshotPolicy"))
    r.append(String("WireScanBinding|11|snapshot_token||"))
    r.append(String("WireScanBinding|12|orientation||SourceOrientation"))
    r.append(String("WireScanBinding|13|legacy_source_type||SourceType"))
    r.append(String("WireScanBinding|14|variant_tag||SourceVariantTag"))
    r.append(String("WireScanBinding|15|has_stats||"))
    r.append(String("WireScanBinding|16|has_legacy_source_type||"))
    r.append(String("WireScanNode|1|source|WireScanSource|"))
    r.append(String("WireScanNode|2|has_schema||"))
    r.append(String("WireScanNode|3|schema|WireSchema|"))
    r.append(String("WireScanNode|4|has_projection||"))
    r.append(String("WireScanNode|5|projection||"))
    r.append(String("WireScanNode|6|has_filter||"))
    r.append(String("WireScanNode|7|filter|WireExpr|"))
    r.append(String("WireScanNode|8|has_row_count||"))
    r.append(String("WireScanNode|9|row_count||"))
    r.append(String("WireScanNode|10|source_kind||SourceOrientation"))
    r.append(String("WireScanNode|11|has_table_stats||"))
    r.append(String("WireScanSource|1|parquet|WireParquetSource|"))
    r.append(String("WireScanSource|2|binding|WireScanBinding|"))
    r.append(String("WireSchema|1|fields|WireField|"))
    r.append(String("WireSchema|2|metadata_keys||"))
    r.append(String("WireSchema|3|metadata_values||"))
    r.append(String("WireSortNode|1|keys||"))
    r.append(String("WireSortNode|2|descending||"))
    r.append(String("WireSortNode|3|nulls_first||"))
    r.append(String("WireSortNode|4|child|WirePlan|"))
    r.append(String("WireStringFn|1|op||StringFn"))
    r.append(String("WireStringFn|2|child|WireExpr|"))
    r.append(String("WireStringFnN|1|op||StringFnN"))
    r.append(String("WireStringFnN|2|args|WireExpr|"))
    r.append(String("WireStringOp|1|op||StringOp"))
    r.append(String("WireStringOp|2|child|WireExpr|"))
    r.append(String("WireStringOp|3|pattern||"))
    r.append(String("WireStructField|1|parent|WireExpr|"))
    r.append(String("WireStructField|2|field_name||"))
    r.append(String("WireStructFieldIdx|1|parent|WireExpr|"))
    r.append(String("WireStructFieldIdx|2|field_idx||"))
    r.append(String("WireSubstring|1|child|WireExpr|"))
    r.append(String("WireSubstring|2|start||"))
    r.append(String("WireSubstring|3|length||"))
    r.append(String("WireTopNNode|1|keys||"))
    r.append(String("WireTopNNode|2|descending||"))
    r.append(String("WireTopNNode|3|nulls_first||"))
    r.append(String("WireTopNNode|4|n||"))
    r.append(String("WireTopNNode|5|child|WirePlan|"))
    r.append(String("WireUdf|1|kind||"))
    r.append(String("WireUdf|2|name||"))
    r.append(String("WireUdf|3|input_columns|WireUdfColumn|"))
    r.append(String("WireUdf|4|output_columns|WireUdfColumn|"))
    r.append(String("WireUdf|5|null_mode||"))
    r.append(String("WireUdf|6|stability||"))
    r.append(String("WireUdf|7|parallelism_tag||"))
    r.append(String("WireUdf|8|partition_keys||"))
    r.append(String("WireUdf|9|order_keys||"))
    r.append(String("WireUdf|10|has_vector_path||"))
    r.append(String("WireUdf|11|operator_factory_id||"))
    r.append(String("WireUdf|12|call_site_salt||"))
    r.append(String("WireUdfCall|1|name||"))
    r.append(String("WireUdfCall|2|in_arrow_type_id||"))
    r.append(String("WireUdfCall|3|out_arrow_type_id||"))
    r.append(String("WireUdfCall|4|child|WireExpr|"))
    r.append(String("WireUdfColumn|1|name||"))
    r.append(String("WireUdfColumn|2|dtype_tag||"))
    r.append(String("WireUnaryOp|1|op||UnaryOp"))
    r.append(String("WireUnaryOp|2|child|WireExpr|"))
    r.append(String("WireUnionNode|1|children|WirePlan|"))
    r.append(String("WireViewRefNode|1|view_name||"))
    r.append(String("WireWhen|1|cases|WireWhenCase|"))
    r.append(String("WireWhen|2|default_expr|WireExpr|"))
    r.append(String("WireWhenCase|1|condition|WireExpr|"))
    r.append(String("WireWhenCase|2|result|WireExpr|"))
    r.append(String("WireWindowFn|1|func||WindowFn"))
    r.append(String("WireWindowFn|2|arg_col||"))
    r.append(String("WireWindowFn|3|arg_offset||"))
    r.append(String("WireWindowFn|4|frame|WireFrame|"))
    r.append(String("WireWindowFn|5|partition_by||"))
    r.append(String("WireWindowFn|6|order_by||"))
    r.append(String("WireWindowFn|7|descending||"))
    r.append(String("WireWriteTarget|1|path||"))
    r.append(String("WireWriteTarget|2|format||WriteFormat"))
    r.append(String("WireWriteTarget|3|codec||WriteCompression"))
    return r^


# One row per enum a `plan.proto` field names:
# `EnumName|n1,n2,...` — every number it declares, zero included.
def _wire_enum_members() -> List[String]:
    var r = List[String]()
    r.append(String("AggFn|0,1,2,3,4,5,6,7,8,9,10,11,12,13"))
    r.append(String("AsofDirection|0,1,2,3"))
    r.append(String("AsofToleranceKind|0,1,2,3"))
    r.append(String("BinaryOp|0,1,2,3,4,5,11,12,13,14,15,16,21,22"))
    r.append(String("ColSide|0,1,2,3"))
    r.append(String("CorrelatedKind|0,1,2,3,4"))
    r.append(String("DTypeCode|0,1,2,3,4,5,6,7,8,9,10,11,12"))
    r.append(String("ExtractField|0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,17,18,19,20,21,22,23,24,25,26"))
    r.append(String("FrameBound|0,1,2,3,4,5"))
    r.append(String("FrameUnits|0,1,2"))
    r.append(String("JoinAlgo|0,1,2,3"))
    r.append(String("JoinType|0,1,2,3,4,5,6,7"))
    r.append(String("MathFn1|0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24"))
    r.append(String("MathFn2|0,1,2"))
    r.append(String("ParamTag|0,1,2,3,4,5,6"))
    r.append(String("PushdownGateMode|0,1,2,3"))
    r.append(String("RegexpOp|0,1,2,3,4,5,6,7,8,9,10"))
    r.append(String("ScalarKind|0,1,2,3,4,5,6,7,8,9,10"))
    r.append(String("ScalarTimeUnit|0,1,2,3,4"))
    r.append(String("SnapshotPolicy|0,1,2,3"))
    r.append(String("SourceOrientation|0,1,2,256"))
    r.append(String("SourceType|0,1,2,3,4,5,6,7,8,9"))
    r.append(String("SourceVariantTag|0,3,4,5,6,7,8,9,10"))
    r.append(String("StringFn|0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16"))
    r.append(String("StringFnN|0,1,2,3,4,5,6,7,8,9,10"))
    r.append(String("StringOp|0,1,2,3,4"))
    r.append(String("UnaryOp|0,1,2,3,4,5,6,7,8"))
    r.append(String("WindowFn|0,1,2,3,4,5,6,11,12,13,14,15,21,22,23,24,25"))
    r.append(String("WriteCompression|0,1,2,3,4,5"))
    r.append(String("WriteFormat|0,1,2,3"))
    return r^
# --- END WIRE-SLOT REGISTRY


# (Message|number) -> why this slot is EXEMPT from one or both assertions, and
# from WHICH. The reason is the debt; the row disappears when the debt is paid.
# A row too short to be a reason is refused, and a row for a slot the
# proto no longer declares is refused, because a ledger cannot outlive what it
# excuses.
#
# The value is "<SCOPE>:<reason>", SCOPE in {CENSUS, PERTURB, BOTH}.
def _slot_exemptions() -> List[String]:
    var r = List[String]()
    r.append(
        String("WirePlanEnvelope|1|CENSUS:")
        + "`format_version` is a CONSTANT by construction — `plan_to_bytes`"
        + " writes PLAN_WIRE_FORMAT_VERSION and nothing else, and the whole"
        + " point of the field is that a reader can refuse a value it does not"
        + " speak. A second value in the corpus would mean this build encoding"
        + " a format it does not implement. The refusal itself IS asserted, by"
        + " token, in test_an_unknown_format_version_is_refused_not_best_effort,"
        + " which forges the bytes rather than asking the encoder for them."
    )
    return r^


struct _SlotLedger(Copyable, Movable):
    """What the corpus was measured to do to each wire slot.

    `vals[i]` is a US-separated multiset-as-set of value digests: a slot seen
    at two distinct values holds three separators. Linear scan over ~290 keys
    is fine — this runs once per corpus plan, not per row of data."""

    var keys: List[String]
    var vals: List[String]
    var observed: List[String]
    var occ_key: List[String]
    var occ_seen: List[Int]
    var occ_noticed: List[Int]
    var plans: Int
    var enum_mut: Int
    """How many PERTURBATION SITES took the in-vocabulary enum operator.

    ★ WITHOUT THIS THE FIX IS UNFALSIFIABLE. `_census` mutates an enum slot to
    another DECLARED member and falls back to `bytes[off] ^ 1` when there is
    none. A wiring break — an empty enum column, an `is_enum` that always says
    no, an `enum_alt` that always returns -1 — silently restores the OLD
    operator, and the old operator PASSES: it was scoring those slots proven by
    their range check, which is exactly the vacuity being removed. Silence is
    not success, so the fire count is measured and pinned."""
    var trace: List[String]
    """★ THE DERIVABILITY HALF. Indexed by REGISTRY INDEX, not by key:
    `trace[i]` is slot `i`'s value at EVERY instance of its message, in walk
    order, US-separated — `-` where the instance left the slot absent, which on
    the wire is a different byte sequence from a written zero and must
    therefore compare differently.

    This is the input to the FUNCTION SEARCH: for each slot, is its value at
    every instance predicted by some function of the OTHER content of the same
    message? See `_WIRE_SLOTS_DERIVABLE_PIN` for why that one question replaced
    four special cases."""

    var clean: List[String]
    """Corpus plans whose CLEAN round trip did not reproduce the observation.

    ★ NOT an `assert_equal` INSIDE `_census`, which would RAISE — so a corpus
    with one broken round trip would abort the walk and no single run could
    report both it and the derivability scan. A run has to be able to say
    everything it measured; a check that aborts the measurement hides every
    finding behind it. Recorded here, asserted with the rest."""

    def __init__(out self, reg: _SlotRegistry):
        self.keys = List[String]()
        self.vals = List[String]()
        self.observed = List[String]()
        self.occ_key = List[String]()
        self.occ_seen = List[Int]()
        self.occ_noticed = List[Int]()
        self.plans = 0
        self.enum_mut = 0
        self.trace = List[String]()
        self.clean = List[String]()
        for _ in range(len(reg.key)):
            self.trace.append(String(""))

    def index_of(self, key: String) -> Int:
        for i in range(len(self.keys)):
            if self.keys[i] == key:
                return i
        return -1

    def record(mut self, key: String, digest: String):
        var probe = String("\x1f") + digest + "\x1f"
        var i = self.index_of(key)
        if i < 0:
            self.keys.append(key)
            self.vals.append(probe)
            return
        if probe not in self.vals[i]:
            self.vals[i] += digest + String("\x1f")

    def distinct(self, key: String) -> Int:
        var i = self.index_of(key)
        if i < 0:
            return 0
        var n = 0
        for c in self.vals[i].as_bytes():
            if c == 0x1F:
                n += 1
        return n - 1

    def mark_observed(mut self, key: String):
        """⚠ ANY-OCCURRENCE. THE EVERY-OCCURRENCE READING IS A SECOND, NAMED
        CLAIM — see `record_occurrence` below — NOT A REDEFINITION OF THIS ONE.

        A slot can be written in a context where nothing reads it and in
        another where something does — `WireParam` carries all six typed slots
        and the decoder reads the ONE its `tag` selects, and `WirePlan.
        output_schema`'s `WireField`s are compared by `_check_output_schema`
        with name/type/nullability only while the same `WireField` inside
        `WireScanNode.schema` is restored in full. The question THIS half asks
        is "CAN this slot be wrong", so one place where it can is enough — and
        keeping it as its own number is what makes `_WIRE_SLOTS_UNPROVEN_PIN`
        comparable across commits."""
        for i in range(len(self.observed)):
            if self.observed[i] == key:
                return
        self.observed.append(key)

    def is_observed(self, key: String) -> Bool:
        for i in range(len(self.observed)):
            if self.observed[i] == key:
                return True
        return False

    def record_occurrence(mut self, key: String, noticed: Bool):
        """★ THE PER-SITE HALF.

        `key` is `Message|number@<path from the envelope>`, NOT the bare slot.

        "Some occurrence of this slot can be wrong" and "EVERY occurrence of it
        can be wrong" are different claims, and the gap between them is where a
        real defect can hide: deleting `f.dtype = self._dtypes[index]` from
        BOTH `Schema.field_at` and `field_at_unchecked` — the PERTURBATION
        exemplar in this file's header — leaves an any-occurrence gate GREEN,
        because `WireParquetSource.partition_cols` decodes its `WireField`s
        into bare `Field`s that never pass through a `Schema`, so the slot
        stays provable THERE while every schema-borne occurrence of it goes
        blind. Any-occurrence cannot see that; this can.

        It costs one decode plus three legs PER OCCURRENCE rather than per slot,
        and the cost is seconds, not hours."""
        var i = -1
        for j in range(len(self.occ_key)):
            if self.occ_key[j] == key:
                i = j
                break
        if i < 0:
            self.occ_key.append(key)
            self.occ_seen.append(1)
            self.occ_noticed.append(1 if noticed else 0)
            return
        self.occ_seen[i] += 1
        if noticed:
            self.occ_noticed[i] += 1


def _varint_len(v: Int) -> Int:
    """How many bytes `v` occupies as a base-128 varint. Used to keep an
    in-place mutation the SAME LENGTH as what it replaces — a longer one would
    shift every later field and the probe would be reading a different message
    rather than a mutated one."""
    var n = 1
    var x = v
    while x >= 128:
        x >>= 7
        n += 1
    return n


def _patch_varint(mut b: List[UInt8], off: Int, v: Int, n: Int):
    """Write `v` as an `n`-byte varint at `off`. The caller guarantees
    `_varint_len(v) == n` (see `_SlotRegistry.enum_alt`), so the continuation
    bits are set from `n` rather than from the value — a shorter value written
    into a longer slot must stay padded or the field's length changes."""
    var x = UInt64(v)
    for k in range(n):
        var byte = UInt8(x & 0x7F)
        x >>= 7
        b[off + k] = byte if k + 1 == n else (byte | 0x80)


struct _SlotRegistry(Copyable, Movable):
    """The generated rows, split once. `key[i]` is `Message|number`."""

    var key: List[String]
    var name: List[String]
    var sub: List[String]
    var enum_of: List[String]
    """WHICH ENUM DECLARES SLOT `i`'s VALUE SPACE, empty when it is not an enum.

    ★ THE MUTATION OPERATOR'S INPUT, and it exists because `mutated[off] ^ 1`
    IS VACUOUS ON A DENSELY-ALLOCATED ENUM. Every vocabulary space here is
    offset +1 from the engine tag so proto3's zero can mean "absent", so the
    live numbers run 1..N — and flipping bit 0 lands on `v-1` or `v+1`, which
    for some spaces is NEVER another declared member. Measured over
    plan.proto's 25 enum-typed slots, FOUR are in that state at every value they
    could ever hold: `WireScanNode.source_kind` and
    `WireScanBinding.orientation` (SourceOrientation, {1, 2, 256}),
    `WireFrame.units` (FrameUnits, {1, 2}) and `WireMathFn2.op` (MathFn2,
    {1, 2}). Their every perturbation was OUT OF VOCABULARY, the decoder
    refused it, "a refusal is an observation" scored the slot PROVEN — and what
    was proven is that the decoder RANGE-CHECKS the value, never that it READS
    it. `test_a_forged_source_kind_is_refused_by_name_not_silently_re_derived`
    documents the class one slot at a time, by hand; this makes it general."""

    var enum_name: List[String]
    var enum_members: List[List[Int]]
    var msg_names: List[String]
    var msg_of: List[Int]
    """`msg_of[i]` indexes `msg_names` — WHICH MESSAGE DECLARES SLOT `i`.

    The forgery half needs it, and needs it to be exactly this and not a name
    prefix match: two slots are candidates for mutual forgery only when they
    are declared on the SAME message, because that is the only scope in which
    an encoder writing one can NAME the other. `_walk` also uses it to resolve
    a message's slots once per instance rather than per field."""

    def __init__(out self) raises:
        self.key = List[String]()
        self.name = List[String]()
        self.sub = List[String]()
        self.enum_of = List[String]()
        self.enum_name = List[String]()
        self.enum_members = List[List[Int]]()
        self.msg_names = List[String]()
        self.msg_of = List[Int]()
        var erows = _wire_enum_members()
        if len(erows) == 0:
            raise Error(
                "OBSERVABILITY: the generated enum member table is EMPTY, and"
                + " plan.proto names 20 enums. With no member set every enum"
                + " slot falls back to the bit-0 flip, which on a space"
                + " allocated densely from 1 is a guaranteed vocabulary refusal"
                + " — the gate then cannot fail on those slots. Re-derive the"
                + " enum member table from plan.proto."
            )
        for i in range(len(erows)):
            var ep = erows[i].split(String("|"))
            if len(ep) != 2:
                raise Error(
                    "OBSERVABILITY: malformed enum row '" + erows[i] + "'"
                )
            var members = List[Int]()
            var nums = String(ep[1]).split(String(","))
            for j in range(len(nums)):
                # Inline rather than `_atoi`: every helper this file calls is
                # declared ABOVE its caller, and `_atoi` is not.
                var acc = 0
                for c in String(nums[j]).as_bytes():
                    acc = acc * 10 + Int(c) - 48
                members.append(acc)
            self.enum_name.append(String(ep[0]))
            self.enum_members.append(members^)
        var rows = _wire_slot_registry()
        if len(rows) == 0:
            raise Error(
                "OBSERVABILITY: the generated wire-slot registry is EMPTY. A"
                + " probe whose universe derives nothing is total over nothing,"
                + " which is the vacuity it exists to prevent. Re-derive the"
                + " registry from plan.proto."
            )
        for i in range(len(rows)):
            var parts = rows[i].split(String("|"))
            if len(parts) != 5:
                raise Error(
                    "OBSERVABILITY: malformed registry row '" + rows[i] + "'"
                )
            self.key.append(String(parts[0]) + String("|") + String(parts[1]))
            self.name.append(String(parts[0]) + String(".") + String(parts[2]))
            self.sub.append(String(parts[3]))
            self.enum_of.append(String(parts[4]))
            var m = String(parts[0])
            var k = -1
            for j in range(len(self.msg_names)):
                if self.msg_names[j] == m:
                    k = j
                    break
            if k < 0:
                self.msg_names.append(m)
                k = len(self.msg_names) - 1
            self.msg_of.append(k)

    def msg_index(self, msg: String) -> Int:
        for j in range(len(self.msg_names)):
            if self.msg_names[j] == msg:
                return j
        return -1

    def lookup_sub(self, msg: String, num: Int) -> String:
        var want = msg + String("|") + String(num)
        for i in range(len(self.key)):
            if self.key[i] == want:
                return self.sub[i]
        return String("")

    def field_name(self, msg: String, num: Int) -> String:
        """The FIELD name alone, for building a path. `WirePlan.scan` -> `scan`.
        Unknown numbers fall back to the number, so a path is always a name."""
        var want = msg + String("|") + String(num)
        for i in range(len(self.key)):
            if self.key[i] == want:
                var dot = self.name[i].find(String("."))
                if dot >= 0:
                    return String(self.name[i][byte=dot + 1:])
                return self.name[i]
        return String(num)

    def is_recursive(self, msg: String) -> Bool:
        """Is `msg` reachable from ITSELF through submessage edges?

        DERIVED from the registry, never listed: `WirePlan` reaches a `WirePlan`
        through `filter.child` / `join.left` / `union.children` / ..., and
        `WireExpr` through `binary.left` / `alias.child` / ... — and a message
        type added tomorrow that closes a new cycle is recognised with no edit
        here. `_walk` restarts the site path at each one, so a site is named by
        its position inside ONE node rather than by how deep the corpus happened
        to nest it."""
        var seen = List[String]()
        var stack = List[String]()
        for i in range(len(self.key)):
            if self.key[i].startswith(msg + String("|")) and self.sub[i].byte_length() > 0:
                stack.append(self.sub[i])
        while len(stack) > 0:
            var cur = stack.pop()
            if cur == msg:
                return True
            var known = False
            for i in range(len(seen)):
                if seen[i] == cur:
                    known = True
                    break
            if known:
                continue
            seen.append(cur)
            for i in range(len(self.key)):
                if (
                    self.key[i].startswith(cur + String("|"))
                    and self.sub[i].byte_length() > 0
                ):
                    stack.append(self.sub[i])
        return False

    def declares(self, key: String) -> Bool:
        for i in range(len(self.key)):
            if self.key[i] == key:
                return True
        return False

    def pretty(self, key: String) -> String:
        for i in range(len(self.key)):
            if self.key[i] == key:
                return self.name[i]
        return key

    def is_enum(self, key: String) -> Bool:
        """Does slot `key` carry a DECLARED enum? A `uint32` that happens to
        hold a vocabulary value (`WireField.arrow_type_id`) is
        deliberately NOT one: it is not declared as an enum, and inventing a
        member set for it would be the sniffing the derived registry exists to
        refuse."""
        for i in range(len(self.key)):
            if self.key[i] == key:
                return self.enum_of[i].byte_length() > 0
        return False

    def enum_members_of(self, key: String) -> List[Int]:
        """Every number slot `key`'s enum declares, zero included. Empty when
        the slot is not an enum."""
        var out = List[Int]()
        var e = String("")
        for i in range(len(self.key)):
            if self.key[i] == key:
                e = self.enum_of[i]
                break
        if e.byte_length() == 0:
            return out^
        for i in range(len(self.enum_name)):
            if self.enum_name[i] == e:
                for j in range(len(self.enum_members[i])):
                    out.append(self.enum_members[i][j])
                return out^
        return out^

    def enum_alt(self, key: String, cur: Int) -> Int:
        """A DIFFERENT DECLARED MEMBER of slot `key`'s enum, encodable in the
        SAME number of varint bytes as `cur`. `-1` when the slot is not an enum
        or its space offers no such member.

        ★ THIS IS WHAT LETS A PERTURBATION FAIL. See `enum_of`'s docstring for
        the slots a mutation whose every outcome is a vocabulary refusal would
        score PROVEN. An in-vocabulary
        LIE is the mutation that separates "the decoder validates this value"
        from "the decoder USES this value", and the second is the question.

        THREE CONSTRAINTS, EACH OF WHICH KILLS A DIFFERENT WRONG ANSWER:

          * SAME BYTE LENGTH. The patch is in place and `_walk` recorded the
            offset of the varint's FIRST byte; a longer encoding would shift
            every later field and the probe would be measuring a different
            message, not a mutated one.
          * NEVER ZERO. Proto3's zero is the `*_UNSPECIFIED` sentinel every
            `*_from_wire` refuses by construction, so mutating to it reproduces
            exactly the guaranteed-refusal vacuity this method exists to end.
          * SMALLEST QUALIFYING, deterministically — a run has to be
            reproducible, and a report has to name a value a reader can look up.
        """
        if not self.is_enum(key):
            return -1
        var e = String("")
        for i in range(len(self.key)):
            if self.key[i] == key:
                e = self.enum_of[i]
                break
        for i in range(len(self.enum_name)):
            if self.enum_name[i] != e:
                continue
            for j in range(len(self.enum_members[i])):
                var m = self.enum_members[i][j]
                if m != 0 and m != cur and _varint_len(m) == _varint_len(cur):
                    return m
            return -1
        return -1


def _digest(b: List[UInt8], start: Int, n: Int) -> String:
    """FNV-1a over a byte range, hex. Cheap, and only ever compared for
    EQUALITY — the census asks how many DISTINCT values a slot took, never
    what they were, so a collision costs a false "single-valued" report (a
    loud failure naming a real slot), never a silent pass."""
    var h: UInt64 = 0xCBF29CE484222325
    for i in range(start, start + n):
        h = (h ^ UInt64(Int(b[i]))) * 0x100000001B3
    return String(h)


def _read_varint(b: List[UInt8], mut off: Int) raises -> UInt64:
    var shift = 0
    var v: UInt64 = 0
    while True:
        if off >= len(b):
            raise Error("OBSERVABILITY: truncated varint at " + String(off))
        var c = b[off]
        off += 1
        v |= UInt64(Int(c & 0x7F)) << UInt64(shift)
        if (c & 0x80) == 0:
            break
        shift += 7
        if shift > 63:
            raise Error("OBSERVABILITY: varint longer than 10 bytes")
    return v


def _walk(
    b: List[UInt8],
    start: Int,
    stop: Int,
    msg: String,
    path: String,
    reg: _SlotRegistry,
    mut led: _SlotLedger,
    mut site_key: List[String],
    mut site_path: List[String],
    mut site_off: List[Int],
    depth: Int,
) raises:
    """Read one proto message, recording every slot it holds and one PATCH SITE
    per slot occurrence.

    ⚠ RECURSION IS DRIVEN BY THE REGISTRY, NEVER SNIFFED. A PACKED repeated
    scalar is length-delimited on the wire and byte-for-byte indistinguishable
    from a submessage, so a walker that guessed would descend into
    `repeated int64` payloads and invent slots the format does not have —
    inventing coverage is the same failure as missing it.

    `path` is the chain of FIELD NAMES down to this message —
    `.scan.schema.fields`. It is what separates "this slot can be wrong
    SOMEWHERE" from "this slot can be wrong HERE", and the two are genuinely
    different: `WireField.dtype_code` is restored in full under
    `WireScanNode.schema` and read for name/type/nullability only under
    `WirePlan.output_schema`. A count keyed on the slot alone cannot see one of
    those going blind while the other still works.

    ⚠ THE PATH IS RELATIVE TO THE NEAREST RECURSIVE ANCESTOR, and that is what
    keeps it a STRUCTURAL fact rather than a census of the corpus.
    `_SlotRegistry.is_recursive` DERIVES which message types contain themselves
    — `WirePlan` through `filter.child` / `join.left` / ..., `WireExpr` through
    `binary.left` / ... — and the path restarts at each one. Without that, an
    unread `output_schema` slot is a DIFFERENT site under
    `.plan.filter.child.` than under `.plan.project.child.` even though the
    codec reaches both by the SAME LINE, and the count becomes a function of
    how deep the corpus's plans happen to be. MEASURED, same corpus: 296 sites
    with the raw path, 74 with cycles collapsed but the root still special,
    and the derived form below."""
    if depth > 64:
        raise Error("OBSERVABILITY: message nesting deeper than 64")
    var off = start
    # ★ THE FORGERY HALF — ONE INSTANCE'S VALUES.
    # `loc_key` / `loc_val` accumulate what THIS message instance holds, and the
    # block after the loop turns that into one entry per DECLARED slot, absent
    # ones included. Per-instance is the granularity the question needs: "could
    # an encoder have written slot B's value into slot A" is only answerable
    # where both are in scope, which is one message at a time.
    var loc_key = List[String]()
    var loc_val = List[String]()
    var mi = reg.msg_index(msg)
    while off < stop:
        var tag = _read_varint(b, off)
        var num = Int(tag >> 3)
        var wt = Int(tag & 7)
        var key = msg + String("|") + String(num)
        var here = path + String(".") + reg.field_name(msg, num)
        var val = String("")
        if wt == 0:
            var at = off
            var v = _read_varint(b, off)
            led.record(key, String(v))
            val = String(v)
            # Patching bit 0 of a varint's FIRST byte never changes its length
            # (bit 7 is the continuation flag), so the message stays parseable
            # and only this slot's value moves.
            site_key.append(key)
            site_path.append(here)
            site_off.append(at)
        elif wt == 1:
            led.record(key, _digest(b, off, 8))
            val = _digest(b, off, 8)
            site_key.append(key)
            site_path.append(here)
            site_off.append(off)
            off += 8
        elif wt == 2:
            var n = Int(_read_varint(b, off))
            if off + n > stop:
                raise Error("OBSERVABILITY: length-delimited field overruns")
            led.record(key, _digest(b, off, n))
            # ⚠ `L<n>:` PREFIXED, because the digest alone is not the bytes. A
            # zero-length payload and an absent field are DIFFERENT byte
            # sequences (`<tag> 00` vs nothing at all), and forgery is a claim
            # about bytes — so the length has to be part of the value, and the
            # absent marker below has to be a string no present value produces.
            val = String("L") + String(n) + String(":") + _digest(b, off, n)
            var sub = reg.lookup_sub(msg, num)
            if sub.byte_length() > 0:
                # ⚠ THE PATH IS RELATIVE TO THE NEAREST RECURSIVE ANCESTOR.
                # `WirePlan` and `WireExpr` contain themselves, and that
                # recursion is the plan / expr TREE — noise for this question.
                # Restarting the path at each one names a site by its position
                # inside ONE node, so the root plan's `output_schema` and a
                # filter child's are the SAME site, which is what the codec
                # thinks too: one line reads both.
                _walk(
                    b, off, off + n, sub,
                    String("") if reg.is_recursive(sub) else here,
                    reg, led, site_key, site_path, site_off, depth + 1,
                )
            elif n > 0:
                # A string / bytes / packed-scalar payload: patch its LAST byte,
                # which for a packed varint run is the low bits of the final
                # element and for a string is the final character.
                site_key.append(key)
                site_path.append(here)
                site_off.append(off + n - 1)
            off += n
        elif wt == 5:
            led.record(key, _digest(b, off, 4))
            val = _digest(b, off, 4)
            site_key.append(key)
            site_path.append(here)
            site_off.append(off)
            off += 4
        else:
            raise Error(
                "OBSERVABILITY: wire type " + String(wt) + " in " + msg
                + " field " + String(num) + " — the codec wrote a wire type"
                + " proto3 does not define"
            )
        # A REPEATED field arrives as several occurrences of one number inside
        # one instance, so the instance's value for it is the whole run, joined.
        # An encoder forging a two-element list from a one-element one is not
        # byte-identical, and this is what keeps that visible.
        var seen_here = -1
        for j in range(len(loc_key)):
            if loc_key[j] == key:
                seen_here = j
                break
        if seen_here < 0:
            loc_key.append(key)
            loc_val.append(val)
        else:
            loc_val[seen_here] += String("\x1e") + val

    # ★ ONE TRACE ENTRY PER DECLARED SLOT, INCLUDING THE ABSENT ONES. The
    # absent marker is `-`, which no present value can produce (a varint
    # renders as digits, every length-delimited value starts `L`, every
    # fixed-width one is a digest). It has to be its own value rather than the
    # type's zero: proto3 omits a zero, so "absent" and "written zero" are
    # different bytes, and this half is a claim about bytes.
    if mi >= 0:
        for j in range(len(reg.key)):
            if reg.msg_of[j] != mi:
                continue
            var got = String("-")
            for k in range(len(loc_key)):
                if loc_key[k] == reg.key[j]:
                    got = loc_val[k]
                    break
            led.trace[j] += got + String("\x1f")


def _obs(p: LogicalPlan) raises -> String:
    """THE SUITE'S WHOLE OBSERVATION OF A PLAN, in one string.

    All three legs `_assert_round_trips` makes, concatenated: if these are
    equal for two plans, every assertion in this file is equal for them too.
    So "mutating this slot does not change `_obs`" IS "mutating this slot
    leaves the suite green"."""
    return (
        String(p) + String("\x01") + String(p.structural_hash())
        + String("\x01") + _schema_text(p.output_schema)
        + String("\x01") + _plan_ir(p)
    )


def _decode_obs(var bytes: List[UInt8]) raises -> String:
    """Decode WHATEVER SHAPE these bytes are, and render the whole observation.

    ⚠ `plan_envelope_from_bytes`, NOT `plan_from_bytes`, and the difference is
    not stylistic: `plan_from_bytes` REFUSES a write-carrying envelope by name,
    so using it here would make every mutation of a write envelope "a refusal,
    therefore an observation" — every `WireWriteTarget` slot scored PROVEN by a
    refusal that the CLEAN bytes also produce. A probe cannot measure a shape
    its decoder rejects."""
    var decoded = plan_envelope_from_bytes(bytes^)
    var target = Optional[WriteTarget](None)
    if decoded.write_target:
        target = Optional(decoded.write_target.value().copy())
    return _obs_env(decoded.take_plan(), target^)


def _obs_env(p: LogicalPlan, target: Optional[WriteTarget]) raises -> String:
    """`_obs` PLUS THE ENVELOPE'S DESTINATION.

    ★ WITHOUT THIS, EVERY `WireWriteTarget` SLOT IS UNOBSERVABLE BY
    CONSTRUCTION. `_obs` renders a `LogicalPlan`, and a destination is
    deliberately not part of one (see `WriteTarget`'s docstring — putting a
    filesystem path inside the value the plan-compile cache keys on is how two
    queries writing to two different files come to share a cache entry). So a
    probe that compared only `_obs` would mutate `path` on the wire, decode a
    different destination, see an identical plan, and score the slot PROVEN-
    UNOBSERVABLE — the exact vacuity this whole file exists to refuse, arriving
    through the comparison rather than through the corpus.

    ⚠ IT READS THE THREE FIELDS DIRECTLY AND MUST NOT DELEGATE TO
    `WriteTarget.describe()`. Delegating would be a real weakness rather than a
    style point: `describe()` is a DIAGNOSTIC renderer
    whose stated job is to read back as the COPY that produced it, so it is
    free to change for display reasons. The moment it suppresses a derived
    default — dropping `COMPRESSION` when it is `uncompressed`, precisely the
    "plan render suppresses a derived default" hazard of this file's header —
    every `WireWriteTarget.codec` mutation decodes to the same string and the
    slot scores PROVEN while being invisible. An observation is a contract; a
    human-facing description is not one. Naming `fmt` and `codec` here is also
    what lets a field-coverage check SEE them compared, which a call through a
    helper in another file structurally cannot."""
    if target:
        return (
            _obs(p)
            + String("\x01W\x01")
            + target.value().path
            + String("\x01")
            + String(Int(target.value().fmt))
            + String("\x01")
            + String(Int(target.value().codec))
        )
    return _obs(p) + String("\x01-")


def _census(q: String, plan: LogicalPlan, reg: _SlotRegistry, mut led: _SlotLedger) raises:
    """Round-trip one corpus plan, record what it wrote, then MUTATE EACH SLOT."""
    _census_env(q, plan, None, reg, led)


def _census_env(
    q: String,
    plan: LogicalPlan,
    var write_target: Optional[WriteTarget],
    reg: _SlotRegistry,
    mut led: _SlotLedger,
) raises:
    """`_census` over a whole ENVELOPE rather than a bare plan.

    ⚠ THE TWO ARE ONE FUNCTION AND MUST STAY SO. `WirePlanEnvelope` carries
    `write_target`, and a second probe over write envelopes would
    be a second answer to "is every slot observable" — with the envelope's own
    `format_version` slot measured by whichever of the two happened to run. It
    is measured HERE, over both shapes, which is why widening the accepted
    version set shows up as `format_version` becoming observable or not,
    rather than as nothing at all."""
    var has_write = Bool(write_target)
    var bytes = (
        plan_to_bytes_with_write_target(plan, write_target.value())
        if has_write
        else plan_to_bytes(plan)
    )
    var obs0 = _obs_env(plan, write_target)

    # ★ THE CLEAN ROUND TRIP. `_observability_corpus`'s docstring says every
    # plan here is "round-tripped by `_census` on the way in", and without
    # this decode it would not be: the other decodes below are of MUTATED
    # bytes and their three-leg comparison sets a BOOLEAN rather than
    # asserting anything. The plans here reach arms the per-arm corpus above
    # does not (row orientation, decimal256, a partitioned parquet leaf), so
    # one clean decode per plan is what makes the claim true.
    #
    # ⚠ RECORDED, NOT ASSERTED HERE. An `assert_equal` on this line would
    # raise — a corpus plan with a broken clean round trip would abort
    # `_census` on the FIRST plan, and the derivability / census /
    # perturbation counts would never be computed. The finding goes into the
    # ledger and every assertion is made once, at the end, over everything the
    # run measured.
    try:
        var clean = _decode_obs(bytes.copy())
        if clean != obs0:
            led.clean.append(
                q + ": the plan does not survive a CLEAN round trip. Every leg"
                + " this file has is concatenated into `_obs`, so the diff below"
                + " names the leg that lost something before any slot was"
                + " perturbed.\n    encoded: " + obs0 + "\n    decoded: " + clean
            )
    except e:
        led.clean.append(
            q + ": `plan_envelope_from_bytes` RAISED on the codec's OWN output"
            + " — the encoder wrote bytes its decoder refuses: " + String(e)
        )

    var site_key = List[String]()
    var site_path = List[String]()
    var site_off = List[Int]()
    _walk(
        bytes, 0, len(bytes), String("WirePlanEnvelope"), String(""), reg, led,
        site_key, site_path, site_off, 0,
    )
    led.plans += 1
    assert_true(
        len(site_key) > 0,
        q + ": the encoder produced bytes with NO readable slot. A census over"
        + " an empty walk certifies everything.",
    )
    for i in range(len(site_key)):
        # ★ EVERY OCCURRENCE, NOT ONE PER SLOT.
        #
        # An `if led.is_observed(...): continue` here would prove each slot
        # ONCE and skip the rest, and the time it saves is seconds (the test
        # runner's `Summary [ N ]` bracket is MILLISECONDS, not seconds). What
        # it costs: deleting `f.dtype = self._dtypes[index]` from BOTH
        # `Schema.field_at` and `field_at_unchecked` would leave the gate GREEN,
        # because the FIRST occurrence of `WireField.dtype_code` the walk
        # reaches lives under `WireParquetSource.partition_cols`, which decodes
        # into bare `Field`s that never pass through a `Schema` — so one
        # occurrence stays provable while every schema-borne one goes blind.
        # ★ AN IN-VOCABULARY LIE WHERE ONE EXISTS.
        #
        # An unconditional `mutated[off] ^ 1` CANNOT FAIL ON A
        # DENSELY-ALLOCATED ENUM. Every
        # vocabulary space is offset +1 from the engine tag (proto3's zero has
        # to mean "absent"), so live numbers run 1..N and flipping bit 0 lands
        # on `v-1` or `v+1`. For some enum-typed slots that is never another
        # declared member AT ANY VALUE — `WireScanNode.source_kind` and
        # `WireScanBinding.orientation` (SourceOrientation {1, 2, 256}),
        # `WireFrame.units` (FrameUnits {1, 2}) and `WireMathFn2.op` (MathFn2
        # {1, 2}) — so the decoder would refuse every perturbation, "a refusal
        # is an observation" would score the slot proven, and what was proven
        # would be the RANGE CHECK. A gate that cannot fail is not passing.
        #
        # `enum_alt` returns another DECLARED member of the same byte length,
        # so a refusal has to come from somewhere that consults the value
        # (`_require_orientation_agreement`, for one) and silence means the
        # reader genuinely ignores it. Everything that is not an enum keeps the
        # bit flip: for a free `int64` / `string` / packed run there is no
        # vocabulary to be inside of, so the flip is already an ordinary value.
        var mutated = bytes.copy()
        var alt = -1
        if reg.is_enum(site_key[i]):
            var read_off = site_off[i]
            var cur = Int(_read_varint(bytes, read_off))
            alt = reg.enum_alt(site_key[i], cur)
        if alt >= 0:
            _patch_varint(mutated, site_off[i], alt, _varint_len(alt))
            led.enum_mut += 1
        else:
            mutated[site_off[i]] = mutated[site_off[i]] ^ 1
        var noticed = False
        try:
            noticed = _decode_obs(mutated^) != obs0
        except e:
            # A REFUSAL IS AN OBSERVATION. A decoder that rejects the perturbed
            # value has demonstrably read the slot.
            noticed = True
        led.record_occurrence(
            site_key[i] + String("@") + site_path[i], noticed
        )
        if noticed:
            led.mark_observed(site_key[i])


# =============================================================================
# ★ THE GENERAL FORM. ONE PREDICATE, WHICH IS WHY IT REPLACED FOUR SPECIAL CASES.
# =============================================================================
#
#     A SLOT IS UNOBSERVABLE IFF ITS VALUE IS A FUNCTION OF OTHER BYTES ON THE
#     WIRE, OR OF NOTHING AT ALL.
#
# There are several ways for a carried slot to be unobservable, and a fix per
# way would be a new special case bolted beside the last. They are one
# property seen four times:
#
#   CENSUS        a function of NOTHING — a constant. An encoder that hardcodes
#                 it is byte-identical.
#   PERTURBATION  not a function of anything the READER consults, so patching it
#                 changes no observation.
#   FORGERY       the IDENTITY function of a sibling's value.
#   THE FOURTEENTH a NON-IDENTITY function of a sibling's PRESENCE or LENGTH —
#                 `has_projection` written as `len(projection) > 0`.
#
# ⚠ AND THE FOURTEENTH IS WHY THE SEARCH MUST CROSS WIRE TYPES. A forgery half
# that required `led.wt[j] == led.wt[i]` ("forgery is byte-identity: a varint
# slot cannot be written from a length-delimited one whatever their values")
# makes a claim about the sibling's VALUE, true of the IDENTITY function alone.
# Writing a bool from a sibling's PRESENCE or LENGTH is a different function of
# different bytes and can NEVER be the same wire type — so under that filter
# NO CORPUS COULD EVER MAKE THE GATE LOOK, and `has_projection =
# len(projection) > 0` would pass every other half.
#
# The census and perturbation halves stay separate. Census is the
# constant family and this scan deliberately excludes it (every family below
# requires the slot to have MOVED), so the two numbers stay disjoint and
# comparable rather than double-counting one defect under two names.
# Perturbation asks about the READER and no search over the writer's inputs can
# answer it. Together the three are total over the property above.


def _atoi(s: String) -> Int:
    """Non-negative decimal, or -1 on anything else.

    Local rather than the stdlib parse because the input is a trace THIS file
    built, and a raising parse would make every caller a raising expression for
    no benefit."""
    if s.byte_length() == 0:
        return -1
    var n = 0
    for c in s.as_bytes():
        var d = Int(c)
        if d < 48 or d > 57:
            return -1
        n = n * 10 + d - 48
    return n


def _v_elems(v: String) -> Int:
    """`len(x)` in ELEMENTS. A repeated field arrives as a RUN of occurrences
    inside one instance, RS-joined by `_walk`; absent is the empty list."""
    if v == String("-"):
        return 0
    var n = 1
    for c in v.as_bytes():
        if Int(c) == 0x1E:
            n += 1
    return n


def _v_bytelen(v: String) raises -> Int:
    """`len(x)` in BYTES, or -1 where the notion does not apply.

    Only a length-delimited value carries a length on the wire (`_walk` renders
    it `L<n>:<digest>`); a varint or a fixed-width slot does not, and pretending
    it does would invent a feature no encoder could read. Absent is 0 — an
    absent repeated field IS the empty list, and `len` of it being 0 is the
    whole point of the `len(x) > 0` family."""
    if v == String("-"):
        return 0
    var total = 0
    var parts = v.split(String("\x1e"))
    for i in range(len(parts)):
        var e = String(parts[i])
        if not e.startswith(String("L")):
            return -1
        var c = e.find(String(":"))
        if c < 2:
            return -1
        var n = _atoi(String(e[byte=1:c]))
        if n < 0:
            return -1
        total += n
    return total


struct _SlotFeatures(Copyable, Movable):
    """One slot's per-instance wire value, plus every FEATURE OF IT an encoder
    could compute at a sibling's write site.

    ★ PRECOMPUTED, ONCE PER SLOT. The scan is O(slots x siblings x families) and
    the corpus gives `WireField` nine hundred instances, so re-splitting a trace
    inside the inner loop is the difference between a second and a minute.
    Nothing here is a judgement about the slot: it is the same bytes, read five
    ways, and each way is something a writer can actually compute."""

    var inst: List[String]
    """The slot's value at each instance of its message, `-` where absent."""

    var nonconst: Bool
    """Did the slot MOVE across the corpus?

    ⚠ EVERY FAMILY REQUIRES THIS, and that is what keeps this number disjoint
    from the census one. A slot that did not move is a CONSTANT — `f()` of
    nothing — which is precisely what the census half reports. Counting it here
    too would make one defect move two numbers and neither would be
    attributable."""

    var pres: List[Bool]
    """PRESENT-OR-NOT. proto3 omits a default, so presence is a readable
    property of the BYTES rather than of the value — which is exactly why a
    presence bit is forgeable from its payload."""

    var blen: List[Int]
    var blen_ok: Bool
    var bgt0: List[Bool]
    var elems: List[Int]

    var shaped: Bool
    """Are the values what a BOOL looks like on the wire — `1` with false
    ABSENT (proto3 omits the zero), or an explicit `1`/`0`?

    ⚠ THIS IS THE MAIN GUARD AGAINST A COINCIDENCE, and the reason a function
    search is safe to run at all. Without it, ANY two-valued slot is a
    "function" of ANY two-valued feature via a lookup table no encoder could
    compute, and the scan would report the corpus's arithmetic rather than the
    format's redundancy."""

    var bvals: List[Bool]
    """The values read AS bools. Feeding this to `_explained_by_bool` is the
    "negation of a bool sibling" family — and its non-negated twin — because
    that predicate tests the map rather than the polarity."""

    def __init__(out self, trace: String) raises:
        self.inst = List[String]()
        # The trace is US-TERMINATED, so the final split part is the empty tail.
        var parts = trace.split(String("\x1f"))
        for i in range(len(parts) - 1):
            self.inst.append(String(parts[i]))
        self.pres = List[Bool]()
        self.blen = List[Int]()
        self.bgt0 = List[Bool]()
        self.elems = List[Int]()
        self.bvals = List[Bool]()
        self.blen_ok = True
        self.nonconst = False
        var zero = False
        var absent = False
        var other = False
        for k in range(len(self.inst)):
            var v = self.inst[k]
            if v != self.inst[0]:
                self.nonconst = True
            self.pres.append(v != String("-"))
            self.elems.append(_v_elems(v))
            self.bvals.append(v == String("1"))
            var n = _v_bytelen(v)
            if n < 0:
                self.blen_ok = False
                self.blen.append(0)
                self.bgt0.append(False)
            else:
                self.blen.append(n)
                self.bgt0.append(n > 0)
            if v == String("0"):
                zero = True
            elif v == String("-"):
                absent = True
            elif v != String("1"):
                other = True
        self.shaped = not other and not (zero and absent)


def _explained_by_bool(a: _SlotFeatures, feat: List[Bool]) -> Bool:
    """Is `a`'s value A BOOL WRITTEN FROM `feat`?

    Three conditions, and each kills a different coincidence:
      * `a` is BOOL-SHAPED on the wire (see `_SlotFeatures.shaped`);
      * `feat` takes BOTH values — a constant feature makes the function a
        constant, which is the CENSUS half's finding, not this one;
      * the map `feat -> value` is SINGLE-VALUED, which is the definition of "is
        a function of".

    ⚠ BOTH POLARITIES AND BOTH RENDERINGS FALL OUT OF THAT MAP rather than being
    enumerated: `f` and `not f` induce the same partition of the instances, and
    which of `1` / `0` / absent lands on which side is read off the data instead
    of being guessed. That is why "negation of a bool sibling" is not a separate
    branch here."""
    if not a.nonconst or not a.shaped:
        return False
    var t = String("")
    var f = String("")
    var have_t = False
    var have_f = False
    for k in range(len(a.inst)):
        if feat[k]:
            if not have_t:
                t = a.inst[k]
                have_t = True
            elif a.inst[k] != t:
                return False
        else:
            if not have_f:
                f = a.inst[k]
                have_f = True
            elif a.inst[k] != f:
                return False
    return have_t and have_f


def _explained_by_int(a: _SlotFeatures, feat: List[Int]) -> Bool:
    """Is `a`'s value the INTEGER `feat`, written as a varint?

    ⚠ ZERO IS ABSENT. proto3 omits a zero-valued scalar, so a computed
    `len(x) == 0` is written as nothing at all. Accepting only a literal `0`
    would miss exactly the `n = len(x)` encoder whose list is sometimes empty,
    which is the shape the fourteenth case was found in."""
    if not a.nonconst:
        return False
    var moved = False
    for k in range(len(a.inst)):
        if feat[k] != feat[0]:
            moved = True
        if feat[k] == 0:
            if a.inst[k] != String("-") and a.inst[k] != String("0"):
                return False
        elif a.inst[k] != String(feat[k]):
            return False
    return moved


def _derivability_scan(
    reg: _SlotRegistry, led: _SlotLedger, mut findings: String
) raises -> Int:
    """How many reached slots are a FUNCTION OF THE REST OF THEIR MESSAGE.

    Two passes, because the identity family is an EQUIVALENCE RELATION and the
    rest are directed:

      1. IDENTITY CLASSES. Slots of one message whose traces are equal are
         mutually forgeable, all of them, in every direction.

         ⚠ IT IS A CLASS, NOT AN EDGE. The scan this
         replaces `break`ed at the FIRST twin, so a mutually-forgeable trio
         rendered as three one-way edges each naming one partner and nothing in
         the report said they were one class — the reader had to reconstruct the
         partition from a chain. `WirePushdownGate`'s three booleans are the
         standing example.

         ⚠ AND THE SAME-WIRE-TYPE FILTER IS GONE. See the header above: it is
         true of identity alone, and it was what made the fourteenth case
         structurally invisible.

      2. THE FUNCTION SEARCH, over what identity did not explain. Per sibling,
         the first matching family is reported — one explanation per sibling
         keeps the message readable, and the COUNT is per slot either way.

    ⚠ SAME MESSAGE, DELIBERATELY, AND IT IS NOT THE WHOLE CLASS. An encoder can
    only compute from values it can NAME at the write site, and the message being
    built is the scope in which instances line up 1:1 by construction — so
    "at every instance" is a total claim rather than an alignment guess. Forgery
    from an ANCESTOR's field is real and strictly larger; a repeated ancestor
    edge gives no 1:1 alignment to make the claim total over, and
    `test_a_forged_source_kind_is_refused_by_name_not_silently_re_derived`
    covers the one known instance by hand."""
    var feat = List[_SlotFeatures]()
    for i in range(len(reg.key)):
        feat.append(_SlotFeatures(led.trace[i]))
    # ⚠ THE 1:1 ALIGNMENT IS THE WHOLE CLAIM, SO IT IS CHECKED RATHER THAN
    # ASSUMED. `_walk` writes one trace entry per DECLARED slot per instance, so
    # two slots of one message always carry the same number of entries — and if
    # that ever stops being true, comparing them pointwise compares different
    # instances and every finding below is meaningless. A silent index error
    # would be the fail-quiet shape this file exists against.
    for i in range(len(reg.key)):
        for j in range(len(reg.key)):
            if reg.msg_of[j] == reg.msg_of[i] and len(feat[j].inst) != len(feat[i].inst):
                raise Error(
                    "OBSERVABILITY: " + reg.name[i] + " has "
                    + String(len(feat[i].inst)) + " instance(s) and its sibling "
                    + reg.name[j] + " has " + String(len(feat[j].inst))
                    + ". Two slots of one message must line up 1:1 or the"
                    + " derivability scan compares different instances."
                )

    var seen = List[Bool]()
    var counted = List[Bool]()
    for _ in range(len(reg.key)):
        seen.append(False)
        counted.append(False)

    var n = 0
    for i in range(len(reg.key)):
        if seen[i] or not feat[i].nonconst:
            continue
        var members = String("")
        var group = List[Int]()
        for j in range(len(reg.key)):
            if (
                reg.msg_of[j] == reg.msg_of[i]
                and feat[j].nonconst
                and led.trace[j] == led.trace[i]
            ):
                seen[j] = True
                if len(group) > 0:
                    members += String(", ")
                members += reg.name[j]
                group.append(j)
        if len(group) < 2:
            continue
        for g in range(len(group)):
            counted[group[g]] = True
        n += len(group)
        findings += (
            "\n  DERIVABLE CLASS — " + String(len(group)) + " slots of "
            + reg.msg_names[reg.msg_of[i]] + " hold THE SAME BYTES at every one"
            + " of " + String(len(feat[i].inst)) + " instance(s): " + members
            + ".\n    Any one could have been written from any other with"
            + " identical output, so none of them is proven. The corpus needs a"
            + " plan in which they DIFFER."
        )

    for i in range(len(reg.key)):
        if counted[i] or not feat[i].nonconst:
            continue
        var why = String("")
        for j in range(len(reg.key)):
            if j == i or reg.msg_of[j] != reg.msg_of[i] or not feat[j].nonconst:
                continue
            var how = String("")
            if _explained_by_bool(feat[i], feat[j].pres):
                how = String("present(") + reg.name[j] + String(")")
            elif feat[j].blen_ok and _explained_by_bool(feat[i], feat[j].bgt0):
                how = String("len(") + reg.name[j] + String(") > 0")
            elif feat[j].shaped and _explained_by_bool(feat[i], feat[j].bvals):
                how = String("bool(") + reg.name[j] + String(")")
            elif feat[j].blen_ok and _explained_by_int(feat[i], feat[j].blen):
                how = String("len(") + reg.name[j] + String(") in bytes")
            elif _explained_by_int(feat[i], feat[j].elems):
                how = String("len(") + reg.name[j] + String(") in elements")
            if how.byte_length() == 0:
                continue
            if why.byte_length() > 0:
                why += String(", or ")
            why += how
        if why.byte_length() == 0:
            continue
        counted[i] = True
        n += 1
        findings += (
            "\n  DERIVABLE — " + reg.name[i] + " = " + why + ", at every one of "
            + String(len(feat[i].inst)) + " instance(s) of "
            + reg.msg_names[reg.msg_of[i]] + ". An encoder that COMPUTED this"
            + " slot instead of carrying it writes the same bytes, so no reader"
            + "\n    can tell the difference and no assertion in this suite can"
            + " go red. The corpus needs an instance where the function is"
            + " WRONG."
        )
    return n


def _assert_every_wire_slot_is_observable(reg: _SlotRegistry, led: _SlotLedger) raises:
    var ex = _slot_exemptions()
    var problems = String("")
    var partials = String("")
    var n = 0
    var partial = 0
    var reached = 0

    # A ledger cannot outlive what it excuses, and a status word is not a
    # reason — the same two rules the field-coverage and known-failing ledgers
    # carry.
    for i in range(len(ex)):
        var parts = ex[i].split(String("|"))
        if len(parts) < 3:
            problems += "\n  MALFORMED EXEMPTION: '" + ex[i] + "'"
            n += 1
            continue
        var key = String(parts[0]) + String("|") + String(parts[1])
        if not reg.declares(key):
            problems += (
                "\n  STALE EXEMPTION: " + key + " is excused but plan.proto no"
                + " longer declares it. Delete the row."
            )
            n += 1
        var reason = String(parts[2])
        var colon = reason.find(String(":"))
        if colon < 0 or reason.byte_length() - colon < 41:
            problems += (
                "\n  EXEMPTION WITH NO REASON: " + key + " — a scope word is"
                + " not a reason. Say why this slot cannot be made to fail."
            )
            n += 1

    for i in range(len(reg.key)):
        var key = reg.key[i]
        # ⚠ A SUBMESSAGE SLOT HAS NO PATCH SITE OF ITS OWN. The walk descends
        # into it rather than patching its length prefix, so its bytes ARE its
        # children's sites — asking whether `WireBinaryOp.left` survives a
        # perturbation is asking it of every field inside it, which the walk
        # already did. Only the CENSUS applies here: a submessage slot the
        # corpus writes at one value is still a subtree an encoder could pin.
        var is_msg = reg.sub[i].byte_length() > 0
        var scope = String("")
        for j in range(len(ex)):
            if ex[j].startswith(key + String("|")):
                scope = String(
                    ex[j].split(String("|"))[2].split(String(":"))[0]
                )
        var d = led.distinct(key)
        if d == 0:
            # NOT REACHED by the observability corpus at all. Held by the
            # ratchet below rather than by a per-slot row: an arm nothing
            # writes is a corpus gap, and 240 ledger rows would be a TODO list
            # wearing a gate's clothes.
            continue
        reached += 1
        if d < 2 and scope != "CENSUS" and scope != "BOTH":
            problems += (
                "\n  UNOBSERVABLE (CENSUS): " + reg.pretty(key) + " took "
                + String(d) + " distinct value(s) over " + String(led.plans)
                + " corpus plan(s). An encoder that HARDCODED it produces"
                + " byte-identical output and this suite stays green. Give the"
                + " corpus a plan whose value differs."
            )
            n += 1
        if (
            not is_msg
            and not led.is_observed(key)
            and scope != "PERTURB"
            and scope != "BOTH"
        ):
            problems += (
                "\n  UNOBSERVABLE (PERTURBATION): " + reg.pretty(key) + " was"
                + " patched to a different value on the wire — for an ENUM slot"
                + " to another DECLARED member, so the mutation is an"
                + " in-vocabulary LIE and not merely an out-of-range byte — in"
                + " every place the corpus writes it, and the decoded plan was"
                + " IDENTICAL under every leg. The decoder does not read this"
                + " slot; it re-derives or ignores it. No encoder mutation of"
                + " it can be caught, at any value."
            )
            n += 1
    # ★ THE PER-SITE HALF. Counted SEPARATELY
    # from `n` on purpose: it is a different question — not "can this slot be
    # wrong SOMEWHERE" but "is there a PLACE the codec writes it where nothing
    # reads it" — and folding it into `n` would make that pin incomparable
    # across commits. The key is the slot AND its path from the envelope, which
    # is the granularity the defect lives at: `WireField.dtype_code` is restored
    # in full under `WireScanNode.schema` and read for name/type/nullability
    # only under `WirePlan.output_schema`.
    #
    # ⚠ IT DOES NOT READ `_slot_exemptions`, DELIBERATELY. A `PERTURB`/`BOTH`
    # exemption says a slot cannot be made to fail ANYWHERE, which is a strictly
    # stronger claim than any this half makes — so if one is ever written, this
    # pin going up is the right outcome: it forces the author to say whether the
    # exemption is really total, at every site, rather than at the one they
    # checked. The register is CENSUS-only today, so no branch is being skipped.
    for i in range(len(led.occ_key)):
        var seen = led.occ_seen[i]
        var got = led.occ_noticed[i]
        if seen <= 0 or got >= seen:
            continue
        var at = led.occ_key[i].find(String("@"))
        var slot = String(led.occ_key[i][byte=0:at]) if at > 0 else led.occ_key[i]
        var where = String(led.occ_key[i][byte=at + 1:]) if at > 0 else String("?")
        partials += (
            "\n  BLIND SITE: " + reg.pretty(slot) + " at " + where
            + " — noticed at " + String(got) + " of " + String(seen)
            + " occurrence(s). The other " + String(seen - got) + " are bytes"
            + " the codec writes and the site reading them re-derives or"
            + " ignores."
        )
        partial += 1

    # ★ THE DERIVABILITY HALF — THE GENERAL FORM, replacing the same-wire-type
    # forgery scan rather than sitting beside it. Full rationale at the header
    # above `_atoi`; the short version is that census, perturbation, forgery and
    # the fourteenth case are one property, and only three of the four survive
    # as separate questions (census = the constant family, perturbation = the
    # READER's half, and this = every other function of the message's bytes).
    #
    # ⚠ REACHED SLOTS ONLY, and it is implied rather than filtered. A slot no
    # corpus plan writes has an all-absent trace, hence `nonconst == False`,
    # hence no family matches it — so the unmeasured set is reported by its own
    # ratchet (`_WIRE_SLOTS_REACHED_FLOOR`) and never a second time here in the
    # wrong units.
    var derivations = String("")
    var derivable = _derivability_scan(reg, led, derivations)

    for i in range(len(led.keys)):
        if not reg.declares(led.keys[i]):
            problems += (
                "\n  UNDECLARED SLOT: the codec wrote " + led.keys[i]
                + " and plan.proto does not declare it. The registry is"
                + " generated from the proto, so this is a field the format"
                + " does not describe."
            )
            n += 1

    # ★ THE RATCHET, IN BOTH DIRECTIONS, AND WHY IT IS A COUNT.
    #
    # This probe answers "does mutating this slot make the suite RED", and for
    # a large set of the slots the format declares the answer is NO. That is a
    # MEASUREMENT of the current corpus rather than a verdict on any change, so
    # it is held as a failing set that cannot be fixed in one pass: a number
    # that may only move in the good direction, and that goes RED WHEN IT
    # IMPROVES so the improvement has to be acknowledged.
    #
    # A per-slot exemption ledger is the alternative and is rejected: a long
    # list of rows of prose, each excusing a slot for the same reason (nothing
    # in the corpus deviates), is a TODO list wearing a gate's clothes — and
    # the one thing it would NOT do is make the next person's fix visible.
    #
    # ⚠ THE FULL LIST IS PRINTED ON EVERY FAILURE, so the ratchet never hides
    # WHICH slots are unproven — only the aggregate is pinned.
    #
    # ⚠ ONE ASSERTION AT THE END, NOT FIVE IN A ROW.
    # `assert_*` RAISES, so the FIRST check to fail is the only one a run can
    # report — and a clean-round-trip check inside `_census`, i.e. before the
    # walk had even finished, would make every other finding invisible behind
    # it. A gate whose findings mask each other costs a full test run per
    # finding. Each check below appends
    # its own fully-worded block to `report`, and the run says everything it
    # measured, once.
    var report = String("")

    if n != _WIRE_SLOTS_UNPROVEN_PIN:
        report += (
            String("\nthe plan wire format has ") + String(n) + " slot(s) that"
            + " CANNOT BE WRONG; the pin is " + String(_WIRE_SLOTS_UNPROVEN_PIN)
            + ".\n  A slot no mutation disturbs is bytes the format spends to"
            + " carry nothing, and it is indistinguishable from a\n  slot the"
            + " codec silently drops. If this number went DOWN, that is the good"
            + " news this\n  assertion exists to force you to record: set"
            + " _WIRE_SLOTS_UNPROVEN_PIN to " + String(n) + " and say which slot"
            + " you fixed.\n  If it went UP, a slot stopped being observable —"
            + " find it below.\n  Measured over " + String(led.plans)
            + " corpus plan(s), " + String(reached) + " reached of "
            + String(len(reg.key)) + " declared slot(s):" + problems + "\n"
        )

    # ★ THE RATCHET, AND WHY THE FLOOR IS A NUMBER RATHER THAN A LEDGER.
    #
    # A slot no corpus plan writes is not "observable" — it is UNMEASURED, and
    # the honest report is a count that may only go up. Writing one exemption
    # row per unreached slot would be a long TODO list that reads like a
    # decision; a floor that ratchets says the same thing in one number and makes
    # the only correct edit to it an INCREASE.
    #
    # ⚠ RAISING THIS IS NOT FREE, AND THAT IS THE POINT. A slot enters the
    # measured set only by being written, and the moment it is written every
    # assertion here applies to it in full — so a plan added to reach a new arm
    # must reach it at TWO distinct values, have the decoder read it back, AND
    # give it a value no function of its siblings predicts. Reaching an arm
    # decoratively makes this test RED, which is the opposite of what a coverage
    # counter does.
    if reached < _WIRE_SLOTS_REACHED_FLOOR:
        report += (
            String("\nthe observability corpus reached ") + String(reached)
            + " wire slot(s); the floor is " + String(_WIRE_SLOTS_REACHED_FLOOR)
            + ". Coverage went DOWN, which means a corpus plan stopped writing a"
            + " slot it wrote before. Restore it, or — if the format genuinely"
            + " lost the slot — lower the floor IN THE SAME CHANGE that removes"
            + " it, and say which slot.\n"
        )
    if reached > _WIRE_SLOTS_REACHED_FLOOR:
        report += (
            String("\nthe observability corpus now reaches ") + String(reached)
            + " wire slot(s), above the pinned floor of "
            + String(_WIRE_SLOTS_REACHED_FLOOR) + ". RED ON GOOD NEWS,"
            + " deliberately — the floor is what makes the unmeasured set"
            + " shrink, and a floor nobody raises stops being one. Set"
            + " _WIRE_SLOTS_REACHED_FLOOR to " + String(reached) + ".\n"
        )

    # ★ THE EVERY-OCCURRENCE RATCHET.
    #
    # Same shape as the pin above and a DIFFERENT QUESTION: not "can this slot
    # be wrong somewhere" but "is there a place the codec writes it where
    # nothing reads it". Both directions, for the same reason.
    #
    # ⚠ THIS IS THE HALF THAT CATCHES THE PERTURBATION EXEMPLAR.
    # Deleting `f.dtype = self._dtypes[index]` from BOTH `Schema.field_at` and
    # `field_at_unchecked` leaves the ANY-occurrence pin unchanged — the walk
    # reaches `WireField.dtype_code` first under
    # `WireParquetSource.partition_cols`, whose `WireField`s decode into bare
    # `Field`s that never pass through a `Schema`, so that one occurrence stays
    # provable while every schema-borne one goes blind. This number moves.
    if partial != _WIRE_SLOTS_PARTIAL_PIN:
        report += (
            String("\nthe plan wire format has ") + String(partial)
            + " SITE(s) where it writes a slot NOTHING READS; the pin is "
            + String(_WIRE_SLOTS_PARTIAL_PIN) + ".\n  A slot proved at ONE site"
            + " and blind at another is not a proved slot — it is a proved SITE,"
            + " and the\n  bytes at the others are spent to carry nothing. If"
            + " this went DOWN, record it: set _WIRE_SLOTS_PARTIAL_PIN\n  to "
            + String(partial) + " and say which site you fixed. If it went UP, a"
            + " site stopped being read — find it below."
            + partials + "\n"
        )

    # ★ THE OPERATOR HAS TO HAVE FIRED. A count, pinned in BOTH directions, for
    # the same reason its four neighbours are: a fix nothing measures is a fix
    # that can be silently undone. See `_SlotLedger.enum_mut`.
    if led.enum_mut != _ENUM_MUTATION_SITES_PIN:
        report += (
            String("\n`_census` applied the in-vocabulary enum mutation at ")
            + String(led.enum_mut) + " site(s); the pin is "
            + String(_ENUM_MUTATION_SITES_PIN) + ".\n  This number is how the"
            + " enum operator is falsifiable at all: every site it does NOT"
            + " reach fell back to the\n  bit-0 flip, which on a densely"
            + " allocated space is a guaranteed vocabulary refusal and scores"
            + " that\n  slot proven by its RANGE CHECK. If it went to ZERO the"
            + " generated enum table or `is_enum` is broken and the\n  gate"
            + " quietly fell back to the bit flip. If it merely"
            + " moved, the corpus changed how many\n  enum sites it writes — set"
            + " _ENUM_MUTATION_SITES_PIN to " + String(led.enum_mut)
            + " and say which plan did it.\n"
        )

    # ★ THE DERIVABILITY RATCHET — THE GENERAL FORM'S NUMBER. Both directions,
    # for the same reason as its siblings: an improvement nobody has to
    # acknowledge is an improvement nobody records.
    #
    # ⚠ THE FIX FOR A LINE HERE IS CORPUS DIVERSITY, NOT A CLEVERER ASSERTION —
    # except where the function IS the codec, in which case it is a codec fix.
    # These slots are compared, read back and perturbable. What is missing is an
    # instance in which the function that predicts them is WRONG, so the edit is
    # in `_observability_corpus`; an exemption row would be recording that the
    # corpus is too small rather than fixing it.
    if derivable != _WIRE_SLOTS_DERIVABLE_PIN:
        report += (
            String("\nthe plan wire format has ") + String(derivable)
            + " slot(s) whose value is A FUNCTION OF THE REST OF THEIR MESSAGE;"
            + " the pin is " + String(_WIRE_SLOTS_DERIVABLE_PIN) + ".\n  A slot"
            + " an encoder could COMPUTE from its siblings is a slot no reader"
            + " can attribute: writing the\n  function instead of the value"
            + " produces the same bytes. Census and perturbation both PASS on"
            + " such\n  a slot — census sees it move, perturbation sees it read"
            + " — which is why this is its own number.\n  If it went DOWN, set"
            + " _WIRE_SLOTS_DERIVABLE_PIN to " + String(derivable)
            + " and say which slot you separated.\n  If it went UP, a corpus"
            + " plan stopped deviating — find it below." + derivations + "\n"
        )

    # ★ THE CLEAN ROUND TRIP. Recorded during the
    # walk, asserted here, so it can never again hide the four counts above.
    if len(led.clean) > 0:
        report += (
            String("\n") + String(len(led.clean)) + " observability corpus"
            + " plan(s) do not survive a CLEAN round trip. Every leg this file"
            + " has is\n  concatenated into `_obs`, so a plan named here lost"
            + " something before ANY slot was perturbed, and every\n  count"
            + " above was measured against a codec that is already wrong:"
        )
        for i in range(len(led.clean)):
            report += String("\n  BROKEN ROUND TRIP: ") + led.clean[i]
        report += String("\n")

    assert_true(report.byte_length() == 0, report)


def _schema_b() raises -> Schema:
    """`_schema()` at a SECOND value of the TABLE-level metadata pair.

    ★ THE CENSUS NEEDS TWO VALUES. `_schema()` sets two table-metadata pairs, so
    an encoder that DROPPED them is caught by `_schema_ir` — but an encoder that
    HARDCODED them would be byte-identical everywhere, because every schema in
    this file's corpus is `_schema()`. This is the one occurrence that deviates,
    in both the key list and the value list and in their LENGTH, so a codec that
    wrote a constant pair is red.

    The FIELDS are `_schema()`'s, unchanged: every per-field assertion in this
    file is about those columns, and a second column set would be a second
    thing to keep in step for no gain."""
    var s = _schema()
    s._metadata_keys = [String("owner")]
    s._metadata_values = [String("binding-b")]
    return s^


def _binding_b() raises -> ScanBinding:
    """A SECOND binding whose every slot differs from `_binding`'s.

    ★ THE CENSUS NEEDS TWO VALUES, NOT ONE ADVERSARIAL ONE. `_binding` is
    already adversarial to the ctor defaults, and that is a different property:
    it kills an encoder that OMITS a slot. It does not kill an encoder that
    HARDCODES one, because with a single-binding corpus the hardcoded constant
    and the real value are the same bytes. Every scalar here therefore deviates
    from `_binding`'s, including the ones whose *default*-deviation `_binding`
    already carries."""
    var p = ScanParams()
    p.put_str(String("path"), String("/second.orc"))
    p.put_i64(String("stripe_count"), Int64(-3))
    p.put_bool(String("has_footer"), False)
    p.put_f64(String("selectivity"), Float64(0.75))
    p.put_u64(String("bytes"), UInt64(8192))
    return ScanBinding(
        kind_id=scan_kind_id(String("komira.orc")),
        kind_name=String("komira.orc"),
        name=String("second"),
        params=p^,
        schema=_schema_b(),
        fingerprint=UInt64(0x0BADC0DE),
        structural_id=UInt64(0x5EEDF00D),
        gate=PushdownGate.reject_all(),
        snapshot_policy=SNAPSHOT_LIVE,
        snapshot_token=UInt64(99),
        orientation=SCAN_ORIENTATION_COLUMNAR,
        legacy_source_type=SOURCE_PARQUET,
        # ★ TWO COLUMNS, NOT ONE (THE DERIVABILITY SCAN). With
        # `_binding`'s two and this one's one, `len(pushdown_extra_cols)` in
        # ELEMENTS was 2 then 1 — which is `orientation`'s wire value (ROW = 2,
        # COLUMNAR = 1) at those same instances, so a codec that wrote the list
        # length into the orientation slot was byte-identical across all 47
        # bindings the corpus builds. Equal lengths make the feature a CONSTANT,
        # and a constant predicts nothing; the NAMES still deviate from
        # `_binding`'s, so this slot's own census is untouched.
        pushdown_extra_cols=[String("un"), String("mp")],
    )


def _scan_b() raises -> LogicalPlan:
    return LogicalPlan.scan_from_source(
        SourceVariant(tag=SOURCE_VARIANT_ORC, binding=_binding_b()),
        _schema(),
    )


def _parquet_leaf() raises -> LogicalPlan:
    """★ THE PARQUET ARM'S FIVE SLOTS, NONE AT ITS DEFAULT.

    A corpus built with `read_parquet` leaves `_mtime_ns`, `has_name` +
    `name_text`, `partition_cols` and `partition_values` all at their defaults
    — no explicit name, mtime 0, no partitioning — so dropping them from
    `_parquet_to_wire` would leave such a corpus PASSING.

    So the leaf here is PARTITIONED, NAMED, and carries a non-zero mtime: the
    three slots are non-default, `partition_cols` holds two `WireField`s whose
    own slots differ from each other, and `partition_values` holds two rows
    that differ, so a codec that wrote row 0 twice goes red as well."""
    var pcols = List[Field]()
    pcols.append(Field("yr", ArrowType.INT32, False))
    var region = Field("region", ArrowType.STRING, True)
    region._metadata_keys = [String("src")]
    region._metadata_values = [String("hive")]
    pcols.append(region^)
    var pvals = List[List[String]]()
    pvals.append([String("2024"), String("emea")])
    pvals.append([String("2025"), String("apac")])
    var q = ParquetSource.partitioned(
        [String("/p/a.parquet"), String("/p/b.parquet")],
        _schema(),
        pcols^,
        pvals^,
        Optional(String("orders")),
        UInt64(1717171717000000007),
    )
    return LogicalPlan.scan_from_source(SourceVariant(q^), _schema())


def _parquet_leaf_b() raises -> LogicalPlan:
    """The parquet arm's SECOND value for every slot — a single-file, unnamed,
    zero-mtime leaf. Together with `_parquet_leaf` this is what makes
    `has_name`, `name`, `mtime_ns`, `partition_cols` and `partition_values`
    two-valued rather than merely non-default."""
    return LogicalPlan.scan_from_source(
        SourceVariant(ParquetSource(String("/p/solo.parquet"), _schema())),
        _schema(),
    )


comptime _WIRE_SLOTS_REACHED_FLOOR: Int = 288
# ⚠ `WireExpr.col_idx` AND `WireColIdx.index` ARE NOT REACHED, AND THE FORMAT
# DID NOT LOSE THEM — the encoder still writes both and `plan.proto` still
# declares them. A DECODED plan carrying one is refused by the value gate
# (`PLAN_WIRE_UNSUPPORTED_COL_IDX`: `col_idx: 1` against a correct three-column
# schema is a 257-byte SIGSEGV through the front door), and `_census` performs
# a CLEAN ROUND TRIP on every corpus plan — so the observation cannot be in
# this corpus without asserting that a plan the door refuses decodes. The
# refusal is asserted instead, by
# `test_a_positional_column_reference_is_refused_at_the_door`.
#
# ⚠ THIS IS THE ONE SHAPE OF "COVERAGE WENT DOWN" THAT IS NOT A REGRESSION, and
# it is worth naming because the ratchet cannot tell the two apart: a slot the
# format still writes but no DECODABLE plan may contain. If the engine ever
# executes ordinals, the observation comes back and so does the floor.
"""How many of `plan.proto`'s slots the corpus below actually writes.

Pinned in BOTH directions by `_assert_every_wire_slot_is_observable`: reaching
fewer means a corpus plan stopped writing a slot; reaching more is good news
this assertion refuses to let anyone bank silently. Besides the two above, it
does not reach `WireScanSource.in_memory` (the codec REFUSES that arm by name —
there is no plan that writes it) and `WireParam.bytes` (`ScanParams` has
`put_str` / `put_i64` / `put_u64` / `put_bool` / `put_f64` and NO
`put_bytes`, so the PARAM_BYTES tag is declared on both sides of the wire and
unreachable from the engine — a finding of this probe, not a property of the
corpus).

⚠ A FORMAT THAT SHRINKS LOWERS THIS FLOOR BY EXACTLY THE SLOTS IT LOST, and a
format that grows must add corpus plans that write the new slots in the SAME
change — a slot the corpus never writes is measured by nothing, and its absence
from this count is the only thing that would say so. The live figures are
printed by the assertion on every failure — `reached of len(reg.key)` — so
neither number should be quoted from a comment."""

comptime _WIRE_SLOTS_UNPROVEN_PIN: Int = 56
"""How many slot-assertions currently FAIL — the format's unobservable set.

A DEBT REGISTER AS A NUMBER, not a config knob. The only correct edit is
DOWNWARD, in the change that makes it true, and the assertion goes red when it
improves so the improvement is recorded rather than absorbed.

Most of the set is CENSUS (the corpus writes one value, so a hardcoding
encoder survives), retired by giving the corpus a second value. The
PERTURBATION members include `WireAggregateNode.estimated_groups` and
`WireDistinctNode.estimated_groups`, where the encoder writes the payload
beside a `has_` presence bit it wrote as FALSE — bytes on the wire that the
decoder is not allowed to read.

⚠ ANY-OCCURRENCE. `_WIRE_SLOTS_PARTIAL_PIN` below holds the stricter
every-occurrence reading as its OWN number, so that this one stays comparable
rather than being redefined under the same name.

★ A FORMAT CAN GROW AND THIS NUMBER STILL GO DOWN. `WireScanBinding.schema`
needs two distinct subtrees to be two-valued, which is why `_binding_b`
carries `_schema_b()` — the same columns at a second value of the TABLE-level
metadata pair. The two slots that pair adds (`WireSchema.metadata_keys` /
`.metadata_values`) enter the measured set PROVEN in both directions — census
from `_schema()` vs `_schema_b()`, perturbation from `_schema_ir`."""

comptime _WIRE_SLOTS_DERIVABLE_PIN: Int = 5
"""How many slots are A FUNCTION OF THE REST OF THEIR MESSAGE — the general form.

    CENSUS         a function of NOTHING — a constant.
    PERTURBATION   not a function of anything the READER consults.
    FORGERY        the IDENTITY function of a sibling's value.
    THE FOURTEENTH a non-identity function of a sibling's PRESENCE or LENGTH.

They are one property — A SLOT IS UNOBSERVABLE IFF ITS VALUE IS A FUNCTION OF
OTHER BYTES ON THE WIRE, OR OF NOTHING AT ALL — and this is the number for
"other bytes". Census keeps "nothing" (every family here requires the slot to
have MOVED, so the two sets are disjoint and neither pin absorbs the other's
defect) and perturbation keeps the READER's half, which no search over the
WRITER's inputs can answer.

★ CROSS-WIRE-TYPE IS THE POINT. A same-wire-type filter ("forgery is
byte-identity") is true OF THE IDENTITY FUNCTION only. Writing a bool from a
sibling's PRESENCE or LENGTH is a different function of different bytes and
can NEVER be the same wire type, so such a filter would not make the gate weak,
it would make it BLIND. All five slots pinned below are cross-wire-type.

THE TWO KINDS OF FINDING, which the report distinguishes and the reader must
not conflate:

  (a) A COINCIDENCE OF A TWO-VALUED CORPUS — retired by corpus diversity, never
      by an exemption row. Worked examples:
        * `WireJoinNode.join_type` = `len(right_on)` in BYTES when the keys are
          1 and 2 bytes and the kinds INNER = 1 and LEFT = 2.
        * `WireScanBinding.orientation` = `len(pushdown_extra_cols)` in
          ELEMENTS when the lists are two then one and ROW = 2, COLUMNAR = 1.
        * `WirePartitionTopNNode.descending` = `not has_output_rank_col_name`.
          A one-element repeated bool IS bool-shaped on the wire, so a NEGATION
          of a neighbour reproduces it.
        * `WireScanNode.has_projection` = `present(projection)` — retired by an
          empty-but-present projection, which is what a `COUNT(*)` pushdown is.

  (b) THE PRESENCE-BIT CLASS — the five below. A `has_X` bool beside an optional
      `X` restates what proto3 already encodes by omission.

⚠ A CORPUS FIX CAN RELOCATE A FINDING RATHER THAN REMOVE IT. Giving `right_on`
a THREE-byte key fixes `join_type` and MOVES the finding onto `algo_hint`,
whose wire values are (AUTO = 1, SORT_MERGE = 3) — the new lengths exactly.
Re-measure after every corpus change; do not reason about it.

THE RESIDUAL 5, PER ROW, AS THE PROBE REPORTS THEM (`_derivability_scan`
accumulates EVERY family that explains a slot and joins them with ", or "):

  1. WireAggExpr.has_child1  = present(child1)
  2. WireJoinNode.has_residual = present(residual)
  3. WireParquetSource.has_name = len(name) > 0,
       or present(partition_cols), or present(partition_values)
  4. WirePartitionTopNNode.has_output_rank_col_name
       = len(output_rank_col_name) > 0
  5. WireScanNode.has_filter = present(projection),
       or present(filter)

WHAT EACH ROW NEEDS. It is not uniform, which is the point:

  * ROWS 1 AND 2. The payload is a SUBMESSAGE, written exactly when it is set
    at any length including zero, so `present(X)` IS `has_X` for every plan the
    engine can build. NO CORPUS SEPARATES THEM. Retiring them is a FORMAT
    change — delete the bit: bytes restating what proto3 already encodes by
    omission.

  * ROW 5 — HALF OF IT IS SEPARABLE. `present(filter)` is the structural half
    and behaves like rows 1-2. `present(projection)` is a coincidence of the
    corpus, in which every scan carrying a filter also carries a projection and
    every scan carrying neither carries neither. A corpus CAN break that — a
    scan with a projection and no filter, or a filter and no projection — so
    this row is two findings, and deleting the bit from the format leaves the
    other one standing.

  * ROW 3 — ONE MORE PLAN IS NOT ENOUGH ON ITS OWN. `partition_cols` and
    `partition_values` are written exactly where `name` is non-empty, so a new
    plan has to break all three functions at once (an empty name WITH
    partitions, or a non-empty name WITHOUT them) or the row returns naming
    whichever function survived — the RELOCATION failure above.

  * ROW 4 — `len(X) > 0` is the whole finding. proto3 omits an EMPTY string,
    so `has_output_rank_col_name = true` beside `output_rank_col_name = ""`
    writes the bit and no payload and separates them — exactly how
    `has_projection` is retired. It needs a THIRD `:partition_topn` plan:
    turning one of the existing two into the empty-string case makes the bit
    CONSTANT, which does not fix it, it moves it into the census half's set.
    A new plan changes the occurrence ratios `_WIRE_SLOTS_PARTIAL_PIN` counts,
    so it belongs in its own change where that pin's movement is attributable.

★ HOW THE GATE FAILS, SHOWN ONCE. Replacing `_present_strs(d.projection)` in
`plan_wire_codec.mojo` by `len(d.projection.value()) > 0` — literally the
fourteenth case, an encoder writing a presence bit from its payload's
cardinality — makes ONE run report the derivability count, the
every-occurrence count AND a broken clean round trip together, and the CLASS
report names the two bits as one class (`has_projection`, `has_filter` holding
the same bytes at every instance) rather than as a one-way edge from whichever
the scan reached first. A gate whose first failure raised would report only
the round trip.

⚠ CONSTANTS ARE NOT COUNTED HERE. They are the CENSUS half's finding and are
counted there, inside `_WIRE_SLOTS_UNPROVEN_PIN`; counting them twice would
report one defect under two names. The 5 here are five defects nothing else in
this file can see."""

comptime _WIRE_SLOTS_PARTIAL_PIN: Int = 18
"""How many slots have an occurrence NOTHING READS — the every-occurrence half.

⚠ A DIFFERENT QUESTION FROM `_WIRE_SLOTS_UNPROVEN_PIN`, AND IT IS WHY THE TWO
ARE TWO NUMBERS. That one asks "can this slot be wrong ANYWHERE"; this asks "is
there a place the codec writes it where nothing reads it". A slot can pass the
first and fail this, and the gap is where a real defect hides.

★ `WirePlanEnvelope.format_version` IS ONE OF THEM, AND THAT IS THE HONEST
PRICE OF A VERSION SET. The reader tests SET MEMBERSHIP over `{4, 5}`, because a
write-carrying envelope declares 5 and a plan-only one declares 4 — so on the
plain envelopes the perturbation 4 -> 5 lands on a version the reader
LEGITIMATELY ACCEPTS, and the decode is identical. It is noticed only on the
write envelopes, where the perturbation runs 5 -> 4 and produces the
UNDERSTATED shape that `PLAN_WIRE_WRITE_TARGET_VERSION_UNDERSTATED` refuses.

⚠ THE OBVIOUS FIX IS WRONG. Refusing an OVERSTATED version (5 declared, no
write target) would restore every occurrence by making the version an exact
function of the content. It cannot be adopted, because the case the version
field exists for — an existing field CHANGING MEANING — is by definition not
derivable from content: a future version that re-meant `WirePlan.plan`
would be carried by a plain envelope, and an exact-against-derived check would
refuse it. So the rule is AT LEAST the required version, understating is
refused, overstating is accepted, and the blind occurrences are the honest
price of that. Do not "fix" this line by tightening the reader.

★ THE EXEMPLAR AN ANY-OCCURRENCE GATE CANNOT CATCH. Deleting
`f.dtype = self._dtypes[index]` from BOTH `Schema.field_at` and
`field_at_unchecked` leaves an any-occurrence gate GREEN: `_walk` reaches
`WireField.dtype_code` under `WireParquetSource.partition_cols`, whose
`WireField`s decode into bare `Field`s that NEVER PASS THROUGH A `Schema`, so
the slot stays provable there while every schema-borne occurrence goes blind.
This assertion names the blind sites:

      BLIND SITE: WireField.dtype_code at .schema.fields.dtype_code
      BLIND SITE: WireField.dtype_code at .source.binding.schema.fields.dtype_code
      BLIND SITE: WireField.dtype_code at .source.parquet.schema.fields.dtype_code

`partition_cols.dtype_code` is NOT among them — it is still fully observable,
which is exactly the masking an any-occurrence reading suffers.

★ THE SET FALLS INTO THREE CLASSES. The full list prints on every failure with
the exact `noticed of seen` ratio and the path, so the ratchet never hides
which:

  (1) THE PLAN'S `output_schema` IS A LOSSY CHANNEL — most of the set, every
      per-field `WireField` slot except `name` / `arrow_type_id` / `nullable`.
      `_check_output_schema` DECODES the carried schema, compares
      `_schema_text` — name, type, nullability — and then DISCARDS it: the
      decoded node's schema is the FACTORY'S derivation. So on every node the
      codec writes slots per column that nothing reads back. Not a data-loss
      bug (the two sides derive identically, which is what the cross-check
      asserts), but it IS bytes spent to carry nothing, and it is
      indistinguishable from a drop by every other assertion here.

  (2) A PAYLOAD BESIDE A FALSE PRESENCE BIT — `WireAggregateNode.
      estimated_groups` and `WireDistinctNode.estimated_groups` (both fail the
      ANY-occurrence pin too), plus `WireScanNode.row_count`.

  (3) THE UNION ARM, AND ONE OBSERVATION GAP — `WireParam.i` and `WireParam.f`.
      `WireParam` carries typed slots and the decoder reads the ONE its `tag`
      selects, which is the case the any-occurrence-only reading was written
      around. ⚠ `f`'s ratio is worse than the arm structure explains: patching
      the low bit of a `double` moves a value this file renders through
      `String(Float64)`, so a codec that corrupted a mantissa's low bits could
      be invisible for a reason that is about the OBSERVATION, not the codec."""


def _obs_scalars(v: Int) raises -> ExprArray:
    """Every ScalarValue arm, at a value that DIFFERS between v=0 and v=1.

    ★ `time_unit` is MICRO wherever `time_of_day`/`duration` default it, so an
    encoder that wrote the constant 2 would be byte-identical; the two variants
    here pass SECOND/NANO explicitly. `dec256_high_lo`/`dec256_high_hi` are
    reached only by a `decimal256`, so without one the whole 256-bit arm would
    be carried and untested.

    ⛔ TEN OF THESE FIFTEEN CANNOT BE BARE PROJECTION EXPRESSIONS — the same
    reason and the same spellings as `test_every_scalar_kind_round_trips`
    above; read its docstring. As bare projections, both `:project` plans would
    fail `_census`'s CLEAN ROUND TRIP because `plan_from_bytes` refuses the
    codec's own output — and the walk raises on the FIRST offender, so the
    message would name one defect where there are ten.

    ⚠ THE SLOTS ARE UNCHANGED, ONLY THE POSITIONS. Every kind is here at two
    deviating values; each sits under an `EXPR_BINARY_OP` whose other operand
    is a column of the literal's own comparison domain."""
    var d = Int64(v)
    var e = ExprArray()
    # ---- the kinds a bare projection slot CAN carry --------------------------
    e.append(Expr.alias(Expr.literal(ScalarValue.from_int64(Int64(-7) - d)), String("i")))
    e.append(Expr.alias(Expr.literal(ScalarValue.from_float(1.5 + Float64(v))), String("f")))
    e.append(Expr.alias(Expr.literal(ScalarValue.from_string(String("hi") + String(v))), String("s")))
    e.append(Expr.alias(Expr.literal(ScalarValue.null(DType.int32 if v == 0 else DType.float32)), String("n")))
    # ★ A BARE BOOL IS A KIND A PROJECTION SLOT CAN CARRY:
    # `compiler_helpers.broadcast_scalar` has a bool arm and
    # `plan_wire_values._literal_is_materializable` mirrors it. A corpus round
    # trip proves the BYTES survive, never that the plan is executable — that
    # is the engine's own test to make.
    #
    # ⚠ IN ADDITION TO, NOT INSTEAD OF, the predicate-operand spelling below: it is the
    # only reader in this corpus that carries a bool into
    # `compiler_eval_predicate`, a different reader with its own ladder, and
    # deleting it to "restore" this one would trade coverage for symmetry.
    # ⚠ SLOT-NEUTRAL BY CONSTRUCTION: `WireScalar.bool_val` is already reached
    # by that spelling, so `_WIRE_SLOTS_REACHED_FLOOR` does not move.
    e.append(Expr.alias(Expr.literal(ScalarValue.from_bool(v == 0)), String("bproj")))

    # ---- the bool AGAIN: a PREDICATE operand, a SECOND reader that carries it 
    e.append(
        Expr.alias(
            Expr.binary(
                BIN_AND,
                Expr.literal(ScalarValue.from_bool(v == 0)),
                Expr.binary(
                    BIN_GT if v == 0 else BIN_LT, Expr.col_ref("a"),
                    Expr.literal(ScalarValue.from_int64(Int64(1) + d)),
                ),
            ),
            String("b"),
        )
    )

    # ---- the decimals against the DECIMAL128 column --------------------------
    e.append(
        Expr.alias(
            Expr.binary(
                BIN_LT if v == 0 else BIN_GT, Expr.col_ref("dec"),
                Expr.literal(ScalarValue.decimal128(Int64(3) + d, Int64(9) + d, 18 - v, 4 + v)),
            ),
            String("d128"),
        )
    )
    # THE DECIMAL256 ARM — reached by nothing before this. All four limbs and
    # both scale slots differ between the variants, so a codec that wrote
    # `dec128_high` into `dec256_high_lo` is red rather than lucky.
    e.append(
        Expr.alias(
            Expr.binary(
                BIN_GT if v == 0 else BIN_LT, Expr.col_ref("dec"),
                Expr.literal(
                    ScalarValue.decimal256(
                        Int64(11) + d, Int64(22) + d, Int64(33) + d, Int64(44) + d,
                        38 - v, 6 + v,
                    )
                ),
            ),
            String("d256"),
        )
    )

    # ---- the temporal family against the TIMESTAMP column --------------------
    # One column serves all five: date32 / timestamp / time / duration /
    # interval share the "temporal" domain, which is the granularity this
    # engine's comparison dispatch has.
    e.append(
        Expr.alias(
            Expr.binary(
                BIN_LT if v == 0 else BIN_GT, Expr.col_ref("ts"),
                Expr.literal(ScalarValue.date32(Int32(19000) + Int32(v))),
            ),
            String("dt"),
        )
    )
    e.append(
        Expr.alias(
            Expr.binary(
                BIN_GT if v == 0 else BIN_LT, Expr.col_ref("ts"),
                Expr.literal(ScalarValue.timestamp_micros(Int64(1700000000000000) + d)),
            ),
            String("ts"),
        )
    )
    e.append(
        Expr.alias(
            Expr.binary(
                BIN_LT if v == 0 else BIN_GT, Expr.col_ref("ts"),
                Expr.literal(ScalarValue.interval_month_day_nano(Int32(3) + Int32(v), Int32(5) + Int32(v), Int64(7) + d)),
            ),
            String("iv"),
        )
    )
    # ⚠ THE UNIT IS PASSED, NEVER DEFAULTED. SECOND vs NANO is the difference
    # between a timestamp and one a billion times finer.
    var unit_a = SCALAR_TIME_UNIT_SECOND if v == 0 else SCALAR_TIME_UNIT_NANO
    var unit_b = SCALAR_TIME_UNIT_MILLI if v == 0 else SCALAR_TIME_UNIT_MICRO
    e.append(
        Expr.alias(
            Expr.binary(
                BIN_GT if v == 0 else BIN_LT, Expr.col_ref("ts"),
                Expr.literal(ScalarValue.time_of_day(Int64(123456) + d, unit_a)),
            ),
            String("tod"),
        )
    )
    e.append(
        Expr.alias(
            Expr.binary(
                BIN_LT if v == 0 else BIN_GT, Expr.col_ref("ts"),
                Expr.literal(ScalarValue.duration(Int64(999) + d, unit_b)),
            ),
            String("dur"),
        )
    )

    # ---- binary: NO column domain exists for it ------------------------------
    # ⚠ ADMITTED BY THE UNKNOWN-DOMAIN CARVE-OUT, NOT BY A MATCH. See the note
    # on the same entry in `test_every_scalar_kind_round_trips`.
    e.append(
        Expr.alias(
            Expr.binary(
                BIN_LT if v == 0 else BIN_GT, Expr.col_ref("s"),
                Expr.literal(ScalarValue.from_binary(String("\x01\x02") + String(v))),
            ),
            String("bin"),
        )
    )
    return e^


def _obs_exprs(v: Int) raises -> ExprArray:
    """One node of every modelled Expr arm, every scalar deviating on v."""
    var d = Int64(v)
    var e = _obs_scalars(v)
    e.append(Expr.alias(Expr.col_ref("a"), String("cr") + String(v)))
    # ⚠ NO `Expr.col_idx` HERE. It is still ENCODED (`WireExpr.col_idx` keeps
    # its arm and its field number), but a decoded plan carrying one is refused
    # by the value gate — `col_idx: 1` against a correct three-column schema is
    # a 257-byte SIGSEGV through the front door. `_census` performs a CLEAN
    # ROUND TRIP on every corpus plan, so
    # leaving it here would make this corpus assert that a plan the door refuses
    # decodes. The refusal is asserted instead, by
    # `test_a_positional_column_reference_is_refused_at_the_door` below, and the
    # two `WireColIdx` slots outside the reached set are accounted for in
    # `_WIRE_SLOTS_REACHED_FLOOR`.
    e.append(Expr.alias(Expr.unary(UN_NOT if v == 0 else UN_NOT, Expr.binary(BIN_LT if v == 0 else BIN_GT, Expr.col_ref("a"), Expr.literal(ScalarValue.from_int64(Int64(2) + d)))), String("un")))
    var vals: List[ScalarValue] = [
        ScalarValue.from_int64(Int64(1) + d), ScalarValue.from_int64(Int64(2) + d),
    ]
    e.append(Expr.alias(Expr.in_list_node(Expr.col_ref("a"), vals^), String("inl")))
    e.append(Expr.alias(Expr.cast(Expr.col_ref("b"), DType.float64 if v == 0 else DType.int32), String("cst")))
    e.append(Expr.alias(Expr.cast_to_decimal(Expr.col_ref("dec"), 18 - v, 4 + v), String("cdec")))
    e.append(Expr.alias(_case_expr() if v == 0 else Expr.when(List[WhenCaseData](), Expr.literal(ScalarValue.from_int64(Int64(77)))), String("cse")))
    e.append(Expr.alias(Expr.agg_fn(AGG_SUM if v == 0 else AGG_MIN, Expr.col_ref("b")), String("agf")))
    e.append(Expr.alias(Expr.extract(EXTRACT_YEAR if v == 0 else EXTRACT_TRUNC_MONTH, Expr.col_ref("ts")), String("ext")))
    e.append(Expr.alias(Expr.math_fn(MATH_SIN if v == 0 else MATH_SQRT, Expr.col_ref("a")), String("m1")))
    e.append(Expr.alias(Expr.math_fn2(MATH2_ATAN2 if v == 0 else MATH2_POW, Expr.col_ref("a"), Expr.col_ref("b")), String("m2")))
    e.append(Expr.alias(Expr.substring(Expr.col_ref("s"), 3 + v, 4 + v) if v == 0 else Expr.substring(Expr.col_ref("s"), 2), String("sub")))
    e.append(Expr.alias(Expr.string_op(STR_CONTAINS if v == 0 else STR_LIKE, Expr.col_ref("s"), String("p") + String(v)), String("sop")))
    e.append(
        Expr.alias(
            Expr.regexp(
                REGEXP_LIKE if v == 0 else REGEXP_REPLACE,
                Expr.col_ref("s"),
                String("^a") + String(v) + String("(?P<g>b+)$"),
                String("R") + String(v),
                String("i") if v == 0 else String("m"),
                v + 3,
                String("g") + String(v),
            ),
            String("rx"),
        )
    )
    e.append(Expr.alias(Expr.struct_field(Expr.col_ref("st"), String("k") if v == 0 else String("v")), String("sf")))
    e.append(Expr.alias(Expr.struct_field_idx(Expr.col_ref("st"), v), String("sfi")))
    e.append(Expr.alias(Expr.map_get(Expr.col_ref("mp"), Expr.col_ref("s") if v == 0 else Expr.literal(ScalarValue.from_string(String("k")))), String("mg")))
    e.append(Expr.alias(Expr.json_extract_string(Expr.col_ref("js"), String("$.a") + String(v)) if v == 0 else Expr.json_extract_json(Expr.col_ref("js"), String("$.b")), String("jx")))
    return e^


def _obs_window(v: Int) raises -> Expr:
    var pb: List[String] = [String("a")] if v == 0 else [String("b"), String("a")]
    var ob: List[String] = [String("b")] if v == 0 else [String("s")]
    var de: List[Bool] = [True] if v == 0 else [False]
    return Expr.window_fn(
        PF_LAG if v == 0 else PF_NTILE,
        String("b") if v == 0 else String("a"),
        2 + v,
        _deviating_frame() if v == 0 else _second_frame(),
    ).with_window_spec(pb^, ob^, de^)


def _obs_partition_expr(v: Int) raises -> PartitionExpr:
    return PartitionExpr(
        PF_SUM if v == 0 else PF_MIN,
        String("b") if v == 0 else String("a"),
        3 + v,
        ScalarValue.from_int64(Int64(9) + Int64(v)),
        v == 0,
        _deviating_frame() if v == 0 else _second_frame(),
        String("w") + String(v),
    )


def _observability_corpus(reg: _SlotRegistry, mut led: _SlotLedger) raises:
    """The plans the probe measures. Its job is TWO DISTINCT VALUES PER SLOT,
    which is a different job from the per-arm corpus above (does each arm
    survive) — so every builder here is parameterised on a variant index and
    called TWICE, and nothing in it is at a default that the other variant also
    holds.

    Every plan is round-tripped CLEANLY by `_census` on the way in — encode,
    decode, `assert_equal` on all three legs concatenated — so a plan added
    here to widen the census is also a plan the suite asserts.

    ⚠ THE CLEAN DECODE IS WHAT MAKES THAT SENTENCE TRUE. The probe's other
    decodes are of MUTATED bytes and their comparison sets a BOOLEAN rather
    than asserting, so without the clean round trip the corpus would be
    measured, never asserted."""
    for v in range(2):
        var tag = String("obs[") + String(v) + String("]")
        var leaf = _scan(String("t"), String("/x.orc")) if v == 0 else _scan_b()

        _census(tag + ":scan", leaf.copy(), reg, led)
        _census(
            tag + ":parquet",
            _parquet_leaf() if v == 0 else _parquet_leaf_b(),
            reg, led,
        )

        # ⚠ THERE IS NO ROW-ORIENTED CASE: a plan carries no orientation, and
        # `WirePlan` field 3 is `reserved`. A slot whose engine axis is gone
        # would take one value over the whole corpus (CENSUS) and change
        # nothing the reader consults (PERTURBATION), and booking it under
        # `_WIRE_SLOTS_UNPROVEN_PIN` would be the one move that DEBT REGISTER
        # exists to refuse. So the slot leaves the measured universe instead.
        #
        # ⚠ THE GENERAL RULE: WHEN AN ENGINE AXIS IS DELETED, THE WIRE SLOT
        # MIRRORING IT IS PART OF THE DELETION. Leaving it behind does not
        # preserve compatibility — old bytes decode either way, because proto3
        # skips a reserved field — it just converts a live field into bytes
        # nothing can get wrong, which this probe cannot distinguish from a
        # field the codec silently drops.

        # ★★ THE WRITE ENVELOPE. Same plan SHAPE as `:scan`, for the reason
        # `:scan(gate)` gives one block down: a new shape moves
        # `_WIRE_SLOTS_PARTIAL_PIN` together with the slot counts and then
        # neither number is attributable. What differs is the ENVELOPE.
        #
        # ⚠ ALL THREE FIELDS DIFFER BETWEEN v=0 AND v=1, and that is what the
        # CENSUS half needs — a slot that takes ONE value over the whole corpus
        # is one an encoder could HARDCODE, producing byte-identical output with
        # this suite green. The pairs are (parquet, snappy) and (csv, gzip):
        # both are in `write_target_supported`'s 13, they share NO member, and
        # the format/codec cross is what makes the pair-check reachable.
        #
        # ⚠ AND THIS IS WHAT KEEPS `WirePlanEnvelope.format_version`
        # OBSERVABLE. On a plain envelope (version 4) the perturbation 4 -> 5
        # lands on a version the reader ACCEPTS (over-declaring a reader floor
        # is legal — see `PLAN_WIRE_WRITE_TARGET_VERSION_UNDERSTATED`) and the
        # decode is identical. Here the perturbation runs the other way: 5 -> 4 on a
        # write-carrying envelope is the UNDERSTATED shape, which is refused by
        # name. The refusal is the observation.
        _census_env(
            tag + ":write",
            leaf.copy(),
            Optional(
                WriteTarget(String("/w/out.parquet"), WFMT_PARQUET, WCOMP_SNAPPY)
                if v == 0
                else WriteTarget(String("/w2/out.csv.gz"), WFMT_CSV, WCOMP_GZIP)
            ),
            reg, led,
        )

        # ★ THE THIRD AND FOURTH `PushdownGate` VALUES. Same plan SHAPE as `:scan` on purpose — a new shape would
        # add occurrence paths and move `_WIRE_SLOTS_PARTIAL_PIN` together with
        # the forgery pin, and then neither number would be attributable. The
        # only thing that differs is the gate.
        _census(
            tag + ":scan(gate)",
            LogicalPlan.scan_from_source(
                SourceVariant(
                    tag=SOURCE_VARIANT_ORC,
                    binding=_binding_gated(
                        String("g"), String("/g.orc"),
                        _gate_c() if v == 0 else _gate_d(),
                    ),
                ),
                _schema(),
            ),
            reg, led,
        )

        var proj: List[String] = (
            [String("a"), String("b"), String("s")] if v == 0 else [String("b")]
        )
        _census(
            tag + ":scan(optionals)",
            LogicalPlan.scan_from_source(
                SourceVariant(
                    tag=SOURCE_VARIANT_ORC,
                    binding=_binding(String("t"), String("/x.orc"))
                    if v == 0 else _binding_b(),
                ),
                _schema(),
                Optional(proj^),
                Optional(
                    Expr.binary(
                        BIN_GT if v == 0 else BIN_LT,
                        Expr.col_ref("a"),
                        Expr.literal(ScalarValue.from_int64(Int64(11) + Int64(v))),
                    )
                ),
                Optional(4242 + v),
            ),
            reg, led,
        )

        # ★ ONE OPTIONAL AT A TIME. Every scan the
        # corpus held either set ALL THREE of `projection` / `filter` /
        # `row_count` (`:scan(optionals)`) or NONE of them, so their three
        # presence bits were the same bit at every `WireScanNode` instance and a
        # decoder that read the wrong one was invisible. This plan sets exactly
        # ONE, and a DIFFERENT one per variant, which separates all three at
        # once: `has_projection` is the only bit set at v=0 and `has_row_count`
        # the only one at v=1.
        # ★ AN EMPTY-BUT-PRESENT PROJECTION (THE DERIVABILITY SCAN). Without
        # it `WireScanNode.has_projection` is exactly
        # `present(WireScanNode.projection)` at every scan instance, so the
        # bit carries nothing proto3 is not already saying and an encoder that
        # computed it would be byte-identical. The one state that separates them is a
        # projection that is SET AND EMPTY: the bit is written, the repeated
        # field is not. It is also the state a `COUNT(*)` pushdown produces —
        # a scan that needs no columns — so this is the format's real shape and
        # not a contrivance.
        var solo_proj = List[String]()
        _census(
            tag + ":scan(one optional)",
            LogicalPlan.scan_from_source(
                SourceVariant(
                    tag=SOURCE_VARIANT_ORC,
                    binding=_binding(String("o"), String("/o.orc")),
                ),
                _schema(),
                Optional(solo_proj^) if v == 0 else None,
                None,
                None if v == 0 else Optional(11 + v),
            ),
            reg, led,
        )

        _census(
            tag + ":filter",
            LogicalPlan.filter(
                Expr.binary(
                    BIN_AND,
                    Expr.binary(BIN_GT, Expr.col_ref("a"), Expr.literal(ScalarValue.from_int64(Int64(3) + Int64(v)))),
                    _obs_window(v),
                ),
                leaf.copy(),
            ),
            reg, led,
        )
        _census(
            tag + ":project",
            LogicalPlan.project(_obs_exprs(v), leaf.copy(), v == 0),
            reg, led,
        )

        var gb = ExprArray()
        gb.append(Expr.col_ref("a") if v == 0 else Expr.col_ref("b"))
        var ax = AggExprArray()
        ax.append(
            AggExpr(
                AGG_CORR if v == 0 else AGG_SUM,
                Optional(Expr.col_ref("b")),
                Optional(Expr.col_ref("a")) if v == 0 else None,
                Optional(String("total") + String(v)),
            )
        )
        _census(
            tag + ":aggregate",
            LogicalPlan.aggregate(gb^, ax^, leaf.copy()),
            reg, led,
        )

        var keys: List[String] = (
            [String("a"), String("b")] if v == 0 else [String("s")]
        )
        var desc: List[Bool] = [True, False] if v == 0 else [False]
        # ★ NOT `[True, False]`. That is `desc`
        # ITSELF, at every sort instance in the corpus, so `WireSortNode.
        # nulls_first` and `.descending` were byte-identical lists everywhere
        # and a codec that wrote one into the other was invisible — which for
        # THESE two fields reverses the null placement of every sorted result.
        # `_assert_nulls_first_deviates` could not see it: it asks whether
        # `nulls_first` differs from the DERIVED default `not descending`, and
        # `[True, False]` does. Deviating from `not desc` and from `desc` are
        # two different requirements; this value meets both.
        var nf: List[Bool] = [True, True] if v == 0 else [False]
        _assert_nulls_first_deviates(tag + ":sort", desc, nf)
        _census(
            tag + ":sort",
            LogicalPlan.sort(keys^, desc^, leaf.copy(), Optional(nf^)),
            reg, led,
        )

        # ★ THE v=1 TOPN CARRIES TWO KEYS, and the
        # SECOND key is what makes the fix possible at all. With single-element
        # lists `nulls_first` is FORCED to equal `descending`: the only value
        # that deviates from the derived `not descending` IS `descending`, so
        # one element can never separate the two slots — they would be
        # byte-identical at both variants. Two elements can.
        var tkeys: List[String] = (
            [String("b")] if v == 0 else [String("a"), String("s")]
        )
        var tdesc: List[Bool] = [True] if v == 0 else [False, True]
        # ⚠ `[False, False]`, NOT `[True, True]`. Both separate the two slots,
        # and only this one keeps the CENSUS half green: a repeated bool is
        # written UNPACKED, so the census sees the ELEMENTS, and with `[True]`
        # at v=0 an all-True v=1 leaves `nulls_first` single-valued corpus-wide
        # — an encoder that hardcoded `true` would be byte-identical, and the
        # unproven pin would rise by one while the forgery was being fixed,
        # which is the shape of trade this file exists to refuse.
        # `[False, False]` deviates from the derived `[True, False]` at index 0.
        var tnf: List[Bool] = [True] if v == 0 else [False, False]
        _assert_nulls_first_deviates(tag + ":topn", tdesc, tnf)
        _census(
            tag + ":topn",
            LogicalPlan.topn(tkeys^, tdesc^, 3 + v, leaf.copy(), Optional(tnf^)),
            reg, led,
        )

        _census(tag + ":limit", LogicalPlan.limit(5 + v, leaf.copy(), 2 + v), reg, led)
        var dcols: List[String] = [String("a")] if v == 0 else [String("s"), String("b")]
        _census(
            tag + ":distinct",
            LogicalPlan.distinct(Optional(dcols^), leaf.copy()), reg, led,
        )

        var lo: List[String] = [String("a")] if v == 0 else [String("s")]
        # ★ `s`, NOT `js` (THE DERIVABILITY SCAN) — AND THE FIRST
        # TRY WAS WRONG IN THE WAY THIS FILE KEEPS BEING WRONG. With a one-byte
        # right key at v=0 and a two-byte one at v=1, `len(right_on)` in BYTES
        # was 1 then 2, which is exactly `join_type`'s wire value (INNER = 1,
        # LEFT = 2) at those same instances — a codec that wrote the key length
        # into the join kind was byte-identical.
        #
        # ⚠ `dec` (3 bytes) FIXED `join_type` AND MOVED THE FINDING ONTO
        # `algo_hint`, whose wire values are (AUTO = 1, SORT_MERGE = 3) — the
        # new lengths, exactly. The probe reported it on the next run. A
        # one-byte key at BOTH variants makes the byte length a CONSTANT, and a
        # constant predicts nothing at all rather than predicting something
        # else; `s` also keeps the right key type-compatible with the left one
        # (`lo` is `s` at v=1), which `dec` did not.
        var ro: List[String] = [String("b")] if v == 0 else [String("s")]
        _census(
            tag + ":join",
            LogicalPlan.join(
                leaf.copy(), _scan(String("r"), String("/r.orc")),
                lo^, ro^,
                JOIN_INNER if v == 0 else JOIN_LEFT,
                JOIN_ALGO_AUTO if v == 0 else JOIN_ALGO_SORT_MERGE,
                Optional(
                    OwnedPointer(
                        Expr.binary(
                            BIN_GT, Expr.col_ref("a"),
                            Expr.literal(
                                ScalarValue.from_int64(Int64(1) + Int64(v))
                            ),
                        )
                    )
                ) if v == 0 else None,
            ),
            reg, led,
        )

        var kids = List[OwnedPointer[LogicalPlan]]()
        kids.append(OwnedPointer(leaf.copy()))
        kids.append(OwnedPointer(_scan(String("m"), String("/m.orc"))))
        if v == 1:
            kids.append(OwnedPointer(_scan(String("n"), String("/n.orc"))))
        _census(tag + ":union", LogicalPlan.union(kids^, _schema()), reg, led)

        var pkeys: List[String] = [String("a")] if v == 0 else [String("b")]
        var okeys: List[String] = [String("b")] if v == 0 else [String("s")]
        var odesc: List[Bool] = [True] if v == 0 else [False]
        var pxs = List[PartitionExpr]()
        pxs.append(_obs_partition_expr(v))
        pxs.append(_obs_partition_expr(1 - v))
        _census(
            tag + ":partition_by",
            LogicalPlan.partition_by(
                pkeys^, okeys^, odesc^, pxs^, leaf.copy()
            ),
            reg, led,
        )

        var qkeys: List[String] = [String("a")] if v == 0 else [String("s")]
        # ★ TWO ORDER KEYS AT v=1 (THE DERIVABILITY SCAN). With a
        # single-element list at both variants `descending` is BOOL-SHAPED on
        # the wire — `0` then `1` — and the corpus sets the rank column name at
        # v=0 only, so `descending` was exactly `not has_output_rank_col_name`
        # and a codec that wrote one into the other was byte-identical. A
        # two-element run is not a bool at any instance, so no boolean function
        # of any sibling can produce it.
        var qokeys: List[String] = (
            [String("b")] if v == 0 else [String("a"), String("b")]
        )
        var qodesc: List[Bool] = [False] if v == 0 else [True, False]
        _census(
            tag + ":partition_topn",
            LogicalPlan.partition_topn(
                qkeys^, qokeys^, qodesc^,
                2 + v,
                leaf.copy(),
                PF_RANK if v == 0 else PF_ROW_NUMBER,
                5 + v if v == 0 else -1,
                Optional(String("rk") + String(v)) if v == 0 else None,
            ),
            reg, led,
        )

        _census(
            tag + ":asof",
            _asof(
                ASOF_BACKWARD if v == 0 else ASOF_NEAREST,
                _deviating_tolerance() if v == 0 else AsofTolerance.none(),
                _scan(String("r"), String("/r.orc")),
            ),
            reg, led,
        )

        _census(
            tag + ":view_ref",
            LogicalPlan.view_ref(String("v") + String(v), _schema()), reg, led,
        )
        _census(
            tag + ":cse_ref",
            LogicalPlan.cse_ref(UInt64(0xABCDEF) + UInt64(v), _schema()),
            reg, led,
        )
        _census(
            tag + ":cast_to_varchar",
            LogicalPlan.cast_to_varchar(
                leaf.copy() if v == 0
                else LogicalPlan.limit(9, leaf.copy(), 1)
            ),
            reg, led,
        )

        var corr_refs: List[String] = (
            [String("a"), String("b")] if v == 0 else [String("s")]
        )
        _census(
            tag + ":correlated",
            LogicalPlan.filter(
                Expr.in_correlated_subquery(
                    _two_level_inner_plan(), corr_refs^,
                    String("a"), String("b"),
                ) if v == 0
                else Expr.correlated_subquery(
                    _two_level_inner_plan(), corr_refs^, CORR_KIND_SCALAR
                ),
                leaf.copy(),
            ),
            reg, led,
        )
        _ = leaf^


def test_every_wire_slot_can_be_wrong() raises:
    """★ THE GATE THAT ANSWERS THE QUESTION THE OTHER GATES ASKED LEXICALLY.

    Every slot `plan.proto` declares that the corpus below WRITES is (a)
    written at two or more distinct values, so an encoder that hardcoded it
    goes red, and (b) read back by the decoder in a way this suite can see, so
    an encoder that got it wrong goes red. A slot failing (a) survives a
    hardcoding encoder; a slot failing (b) survives ANY encoder. Both are bytes
    the format spends to carry nothing.

    The slots the corpus does NOT write are UNMEASURED, not blessed, and the
    ratchet at the end of `_assert_every_wire_slot_is_observable` is what makes
    that set shrink."""
    var reg = _SlotRegistry()
    var led = _SlotLedger(reg)
    _observability_corpus(reg, led)
    _assert_every_wire_slot_is_observable(reg, led)


def _slot_sites(
    bytes: List[UInt8], reg: _SlotRegistry, want: String
) raises -> List[Int]:
    """Every byte offset at which the walk found slot `want` (`Message|number`).

    DERIVED FROM THE SAME WALK THE PROBE USES, never from a byte search. A raw
    scan for the tag byte would also hit that byte inside a string payload, and
    a test that patched one of those would be measuring nothing while looking
    like it measured something."""
    var led = _SlotLedger(reg)
    var sk = List[String]()
    var sp = List[String]()
    var so = List[Int]()
    _walk(
        bytes, 0, len(bytes), String("WirePlanEnvelope"), String(""), reg, led,
        sk, sp, so, 0,
    )
    var out = List[Int]()
    for i in range(len(sk)):
        if sk[i] == want:
            out.append(so[i])
    return out^


def _put_varint(mut out: List[UInt8], v: Int):
    """Append `v` as a base-128 varint — the writer's half of `_read_varint`."""
    var x = UInt64(v)
    while True:
        var b = UInt8(x & 0x7F)
        x >>= 7
        if x != 0:
            out.append(b | 0x80)
        else:
            out.append(b)
            break


def _append_varint_field_to_the_envelopes_plan(
    b: List[UInt8], field_no: Int, value: Int
) raises -> List[UInt8]:
    """Append one VARINT field to the `WirePlan` inside a `WirePlanEnvelope`,
    rewriting the length prefix. Bytes NO ENCODER HERE PRODUCES, which
    is the only way to ask what a non-Mojo frontend's mistake does here.

    ⚠ APPENDED, NEVER PREPENDED, AND THAT IS LOAD-BEARING. proto3 resolves two
    occurrences of one scalar number by LAST-ONE-WINS, so a forged field placed
    BEFORE a real one of the same number is the one that LOSES — the forge would
    decode identically to the honest bytes and the test would pass while
    measuring nothing. Appending makes the forge the winner."""
    var out = List[UInt8]()
    var off = 0
    var done = False
    while off < len(b):
        var tag_at = off
        var tag = _read_varint(b, off)
        var tag_end = off
        var num = Int(tag >> 3)
        var wt = Int(tag & 7)
        if wt == 0:
            _ = _read_varint(b, off)
            for i in range(tag_at, off):
                out.append(b[i])
        elif wt == 2:
            var n = Int(_read_varint(b, off))
            for i in range(tag_at, tag_end):
                out.append(b[i])
            var ins = List[UInt8]()
            if num == 2 and not done:
                done = True
                _put_varint(ins, field_no * 8)  # field number, wire type 0
                _put_varint(ins, value)
            _put_varint(out, n + len(ins))
            for i in range(off, off + n):
                out.append(b[i])
            for i in range(len(ins)):
                out.append(ins[i])
            off += n
        else:
            raise Error(
                "the envelope holds wire type " + String(wt) + ", which this"
                + " forge does not model"
            )
    if not done:
        raise Error("the envelope carries no `plan` submessage to forge into")
    return out^


comptime _ENUM_SLOTS_PIN: Int = 38
"""How many wire slots carry a DECLARED enum.

The number is a property of the FORMAT, so it moves only when the format does.
A vocabulary field that crosses as a bare `uint32` is validated by nothing, so
every vocabulary-valued slot is a declared enum: `WireScalar.kind` /
`.time_unit`, `WireParam.tag`, `WirePushdownGate.mode`,
`WireScanBinding.snapshot_policy`, the four `DTypeCode` slots
(`WireField.dtype_code`, `WireScalar.dtype_code` / `.null_dtype_code`,
`WireCast.target_dtype_code`), `WireWriteTarget.format` / `.codec`,
`WireStringFn.op` and `WireStringFnN.op`, among others.

★ A DTYPE CODE IS AN ENUM SO A READER CAN NAME IT. A Python or TypeScript reader
that decodes `dtype_code: 5` has nowhere to look up what 5 IS, in a format whose
whole purpose is that several languages share one plan. The perturbation reach
below comes free with it, and it is large.

⚠ THE BYTES DO NOT MOVE when a `uint32` becomes an enum: proto3 encodes an enum
as a varint exactly as it encodes a `uint32`, and `test_plan_wire_golden_bytes`
stays green over frozen fixtures across such an edit. A slot's ENUM-NESS is a
schema fact, not a wire fact.

★ SOME OPS DECIDE MORE THAN A FUNCTION. `WireMathFn.op` decides WHICH libm
function runs — every member returns FLOAT64 — whereas `WireStringFn.op`
decides the OUTPUT TYPE (`expr.string_fn_returns_int`), and `WireStringFnN.op`
also decides the LEGAL ARITY (`expr.string_fn_n_arity`) over a `repeated` field
with no length prefix. A bare `uint32` there would be a slot that can name a
column type, or an arity, that nobody wrote.
"""

comptime _FLIP_VACUOUS_ENUM_SLOTS_PIN: Int = 4
"""How many of them a plain `bytes[off] ^ 1` mutation could not lie to.

A space whose live wire numbers are such that flipping bit 0 never lands on
another declared member (wire 0 is `*_WIRE_UNSPECIFIED`, which this probe
excludes because a decoder is REQUIRED to refuse it) is flip-vacuous. A
one-member space is always flip-vacuous, and leaves this set the moment a
second member is declared, since wire 1 and wire 2 then differ in bit 0 and
the flip becomes a legal lie.

⚠ THE NUMBER IS NOT DOWNWARD-ONLY. It is downward only for a FIXED set of
slots; a new slot whose vocabulary is too SMALL to be lied to adds one, and will
keep doing so for as long as one-member spaces are born. It is a property of how
the vocabulary allocates its members, not of the corpus. A pin that comes back
down with no stated cause reads as a weakened operator — so say which, when it
moves."""

comptime _ENUM_MUTATION_SITES_PIN: Int = 2794
"""How many perturbation sites `_census` mutated with the ENUM operator.

The reach is per-column, not per-node: `WireField.dtype_code` IS ON EVERY
COLUMN OF EVERY SCHEMA — every plan node carries an `output_schema`, and
`ScanData.schema`, `ScanBinding.schema` and `ParquetSource.schema_cached` each
carry another — and `WireScalar.kind` occurs once per LITERAL. Every such site
gets an IN-VOCABULARY LIE the decoder must refuse (`_dtype_from_wire` is what
refuses it for the DType code) instead of an implausible byte mutation.

⚠ IT MOVES WITH THE CORPUS AS WELL AS THE FORMAT. A plan added to the corpus
adds its enum sites (an `alias(literal(...))` adds its `WireExpr` tags plus the
literal's two enum-valued scalar fields — `WireScalar.kind` and
`.time_unit`); a plan removed removes them. When it moves, attribute the
movement per plan in the change that moves it; the operator's own count is the
authority for the total.

⚠ AND IT MOVES INDEPENDENTLY OF `_WIRE_SLOTS_REACHED_FLOOR`. A plan can add
MUTATION SITES without adding REACHED SLOTS (a second bool literal reaches
`WireScalar.bool_val`, already reached). The two counters measure different
things, and a change that moved both by the same amount would be the
suspicious one.

Pinned in both directions by `_assert_every_wire_slot_is_observable`. See
`_SlotLedger.enum_mut` for why a fire count is what makes the operator
falsifiable: a wiring break restores the bit flip, and the bit flip PASSES."""

comptime _UNMUTATABLE_ENUM_MEMBERS_PIN: Int = 2
"""(slot, member) pairs with NO in-vocabulary mutation of the same byte length.

`SourceOrientation` declares {0, 1, 2, 256}; 256 is a two-byte varint and the
space has no second one, so at that member neither operator can produce a legal
lie. Two slots carry the enum, hence two pairs. The corpus writes 1 and 2, so
this is a hole in the OPERATOR's reach, not in the corpus — recorded rather
than hidden, because that is the difference between a known gap and an
unknown one.

A ONE-MEMBER SPACE is the other way to enter this set: with only wire 1
declared (wire 0 is `*_WIRE_UNSPECIFIED`, which a decoder is required to
refuse) there is no other declared member to lie WITH at any byte length.

⚠ SO A DECREASE HERE IS NOT AUTOMATICALLY GOOD NEWS. It is good news when the
cause is a vocabulary GROWING past a one-member space, and it is bad news if a
slot merely stopped being reached. Say which whenever the number moves."""


def test_the_enum_perturbation_is_an_in_vocabulary_lie_not_a_range_error() raises:
    """★ A MUTATION THAT CANNOT FAIL, AND THE PROOF THAT THIS ONE CAN.

    Perturbing every slot with `mutated[off] ^ 1` is not neutral on an enum.
    Every vocabulary space here is offset +1 from the engine tag — the
    plan-wire vocabulary generator does that so proto3's zero can mean "the
    field was absent" — so live numbers run 1..N
    and flipping bit 0 lands on `v-1` or `v+1`. For some spaces that is NEVER
    another declared member, so the decoder refused EVERY perturbation, "a
    refusal is an observation" scored the slot PROVEN, and what was proven was
    the RANGE CHECK. A gate that cannot fail is not a gate that passed.

    ⚠ ONE SLOT OF THE CLASS IS ALSO FORGED BY HAND.
    `test_a_forged_source_kind_is_refused_by_name_not_silently_re_derived`
    says it in prose about `WireScanNode.source_kind` and forges that one lie
    manually; this test generalises it to every member of the class. A defect
    known at one site and unaddressed at the others is a recurring shape.

    THREE ASSERTIONS, AND THE THIRD IS THE ONE THAT MAKES THE OPERATOR
    NON-VACUOUS.

      (1) THE CLASS, TOTAL OVER THE FORMAT. Derived from the registry,
          so it is a claim about every enum slot plan.proto declares and not
          about the four this docstring happens to name.

      (2) THE OPERATOR OFFERS A LEGAL ALTERNATIVE where the flip does not.

      (3) THE ALTERNATIVE IS CAUGHT BY OBSERVATION, NOT BY REFUSAL — measured on
          real bytes, with the old operator run beside it as the control. If
          `enum_alt` ever silently returned -1 everywhere, `_census` would fall
          back to the flip, every enum slot would go back to being proven by its
          range check, and NOTHING ELSE IN THIS FILE WOULD NOTICE."""
    var reg = _SlotRegistry()

    # ---- (1) THE CLASS.
    var enum_slots = 0
    var flip_vacuous = 0
    var stuck = 0
    var named = String("")
    for i in range(len(reg.key)):
        if not reg.is_enum(reg.key[i]):
            continue
        enum_slots += 1
        var members = reg.enum_members_of(reg.key[i])
        var any_flip_legal = False
        for j in range(len(members)):
            var v = members[j]
            if v == 0:
                continue
            var flip_legal = False
            for k in range(len(members)):
                if members[k] == (v ^ 1) and members[k] != 0:
                    flip_legal = True
            if flip_legal:
                any_flip_legal = True
            elif reg.enum_alt(reg.key[i], v) < 0:
                stuck += 1
        if not any_flip_legal:
            flip_vacuous += 1
            named += String("\n    ") + reg.pretty(reg.key[i])
    assert_equal(
        enum_slots, _ENUM_SLOTS_PIN,
        "plan.proto's enum-typed slot count moved. That is fine — say so here"
        + " — but the two pins below are counts OVER this set and a silent"
        + " change to the denominator makes them incomparable.",
    )
    assert_equal(
        flip_vacuous, _FLIP_VACUOUS_ENUM_SLOTS_PIN,
        "the number of enum slots a bit-0 flip cannot tell an in-vocabulary lie"
        + " to is now " + String(flip_vacuous) + "; the pin is "
        + String(_FLIP_VACUOUS_ENUM_SLOTS_PIN) + ". Every one of these was"
        + " scored PROVEN by a perturbation whose only possible outcome was a"
        + " vocabulary refusal. If this went DOWN a vocabulary space grew a"
        + " member — record it. If it went UP, a new space is allocated so"
        + " densely that the old operator is blind to it. The set:" + named,
    )
    assert_equal(
        stuck, _UNMUTATABLE_ENUM_MEMBERS_PIN,
        "the number of (slot, member) pairs with NO legal same-length mutation"
        + " is now " + String(stuck) + "; the pin is "
        + String(_UNMUTATABLE_ENUM_MEMBERS_PIN) + ". These are values the probe"
        + " cannot lie about at all — a hole in the operator's reach, and it has"
        + " to be a number rather than a silence.",
    )

    # ---- (2) + (3) ON REAL BYTES. `WireFrame.units` is FrameUnits {0, 1, 2}:
    # the corpus writes RANGE (1), the flip gives 0 (UNSPECIFIED, refused) and
    # the only legal alternative is ROWS (2).
    # Real columns of `_schema()` — see the note on
    # `test_a_window_fn_round_trips_with_every_render_invisible_part_deviating`.
    # This plan is ENCODED and then byte-perturbed, so its names only have to be
    # resolvable; nothing here reads them.
    var pb: List[String] = [String("dec"), String("dic")]
    var ob: List[String] = [String("ts")]
    var desc: List[Bool] = [True, False, True]
    var w = Expr.window_fn(
        PF_LAG, String("js"), 3, _deviating_frame()
    ).with_window_spec(pb^, ob^, desc^)
    var p = LogicalPlan.filter(w^, _scan(String("t"), String("/x.orc")))
    var b = plan_to_bytes(p)
    var sites = _slot_sites(b, reg, String("WireFrame|1"))
    assert_true(
        len(sites) > 0,
        "the window-fn plan wrote no WireFrame.units site, so the two halves"
        + " below are measuring nothing. `_deviating_frame` sets units=RANGE"
        + " precisely so proto3 does not omit it.",
    )
    var off = sites[0]
    var cur = Int(b[off])
    var alt = reg.enum_alt(String("WireFrame|1"), cur)
    assert_true(
        alt > 0 and alt != cur,
        "`enum_alt` offered no legal alternative for WireFrame.units at wire"
        + " value " + String(cur) + ". `_census` then falls back to the bit-0"
        + " flip, which for this space is a guaranteed refusal — the exact"
        + " vacuity this whole mechanism exists to end, restored silently.",
    )
    var lied = b.copy()
    _patch_varint(lied, off, alt, _varint_len(alt))
    assert_true(
        _obs(plan_from_bytes(lied^)) != _obs(p),
        "forging WireFrame.units from " + String(cur) + " to the OTHER DECLARED"
        + " member (" + String(alt) + ") changed nothing observable. Then the"
        + " slot's bytes are spent on nothing and the round trip cannot see it —"
        + " which is a real finding, not a test bug: report it as such.",
    )

    # ---- THE CONTROL, and it is what makes the half above mean anything: the
    # OLD operator on the SAME byte is refused, so on this slot it could only
    # ever have measured the range check.
    var flipped = b.copy()
    flipped[off] = flipped[off] ^ 1
    var raised = False
    try:
        var back = plan_from_bytes(flipped^)
        _ = back.structural_hash()
    except e:
        raised = True
    assert_true(
        raised,
        "CONTROL FAILED: flipping bit 0 of WireFrame.units produced a value the"
        + " decoder ACCEPTED, so FrameUnits has grown a member and this slot is"
        + " no longer in the flip-vacuous class. Good news — move"
        + " _FLIP_VACUOUS_ENUM_SLOTS_PIN and pick a slot that still is.",
    )


def test_the_node_kind_has_exactly_one_discriminator_on_the_wire() raises:
    """★ A REDUNDANCY THE OBSERVABILITY GATE CANNOT SEE, REMOVED FROM THE
    FORMAT RATHER THAN CHECKED IN THE DECODER.

    THE PROPERTY. An explicit node-kind tag beside the `node` oneof is a TOTAL
    FUNCTION of which sibling submessage is present: an encoder that computed
    the tag PURELY from the oneof arm ordinal and DISCARDED the carried
    `p.tag` would produce byte-identical output (the compiler itself calls the
    carried value dead: `assignment to 'wtag' was never used`). It is a second
    discriminator for a fact proto3's `oneof` already carries, so `WirePlan`
    and `WireExpr` field 1 are reserved.

    ⚠ WHY NO HALF OF THE OBSERVABILITY GATE COULD REPORT IT, AND WHY LOOSENING
    THAT GATE WOULD BE THE WRONG FIX. The derivability scan's families all
    require the slot to be BOOL-SHAPED on the wire (`_SlotFeatures.shaped`), so
    a 16-valued discriminator is excluded a priori, and there is no "which of N
    siblings is present" family at all. The bool-shape guard is what stops any
    two-valued slot from being "explained" by a lookup table no encoder could
    compute; widening it into a table search produces noise, not truth. THE
    FILTER THAT STOPS THE NOISE ALSO STOPS THE FINDING — so the fix is to the
    FORMAT.

    ⚠ AND THE PERTURBATION HALF WOULD SCORE SUCH A SLOT *PROVEN*, VACUOUSLY.
    Flipping bit 0 of a node-kind tag moves it to a DIFFERENT tag, whose arm is
    then absent, so the decoder raises — every time, at every value. The
    refusal comes from the arm-presence check and never from anything reading
    the tag. Same class as `WireScanNode.source_kind` one test below.

    WHAT THIS ASSERTS, IN TWO HALVES.

      (1) THE SHAPE. The encoder writes no `WirePlan|1` and no `WireExpr|1`
          slot: the node kind is stated ONCE.

      (2) THE BEHAVIOUR, WHICH IS THE LANGUAGE-AGNOSTIC CLAIM. A frontend that
          is not Mojo writes these bytes, and anything the format lets it get
          wrong it will get wrong. So: forge `tag = PLAN_SCAN` (wire 1) onto a
          plan whose arm is `filter`. With a tag field, that byte sequence
          would steer the decoder into the scan branch and raise `PLAN_SCAN
          with no scan payload` — a refusal that misnames the fault, since a
          filter payload is right there. With the number RESERVED, proto3
          skips an unknown field, and the disagreement is UNREPRESENTABLE: the
          plan decodes as what its arm says it is.

    THE ALTERNATIVE, AND WHY IT IS WORSE. Keeping `tag` and having the decoder
    REFUSE BY NAME on disagreement also removes the silent case — but it keeps a
    field whose ONLY purpose is to be checked against another field, obliges
    every non-Mojo frontend to compute a value it cannot get right and cannot
    benefit from, and leaves the format's correctness resting on a runtime check
    rather than on what is expressible. Deleting the slot makes the wrong state
    unrepresentable, which is strictly stronger than making it refused."""
    var reg = _SlotRegistry()
    var p = LogicalPlan.filter(
        Expr.binary(
            BIN_GT,
            Expr.col_ref("a"),
            Expr.literal(ScalarValue.from_int64(Int64(3))),
        ),
        _scan(String("t"), String("/x.orc")),
    )
    var bytes = plan_to_bytes(p)

    # ---- (1) THE SHAPE. Field 1 of both messages is retired and reserved.
    assert_equal(
        len(_slot_sites(bytes, reg, String("WirePlan|1"))), 0,
        "WirePlan field 1 is RESERVED — the plan's node kind is carried by the"
        + " `node` oneof and by nothing else. A second discriminator is a"
        + " second thing a non-Mojo writer can get wrong, and it carries no"
        + " information the arm does not.",
    )
    assert_equal(
        len(_slot_sites(bytes, reg, String("WireExpr|1"))), 0,
        "WireExpr field 1 is RESERVED, for the same reason as WirePlan's: one"
        + " tag per arm, a bijection an encoder would compute and a decoder"
        + " re-derive.",
    )

    # ---- (2) THE BEHAVIOUR. The classic disagreement, forged by hand.
    var forged = _append_varint_field_to_the_envelopes_plan(bytes, 1, 1)
    assert_true(
        len(forged) > len(bytes),
        "the forge did not add the bytes it claims to add; every assertion"
        + " below it would then be about the honest encoding",
    )
    assert_equal(
        _obs(plan_from_bytes(forged^)), _obs(p),
        "a `tag = PLAN_SCAN` forged beside a `filter` arm CHANGED THE DECODE."
        + " That is the exact disagreement removing the field exists to make"
        + " unrepresentable: field 1 is reserved, so proto3's skip-and-keep rule"
        + " must swallow it and the arm must remain the only discriminator. If"
        + " this went red, either field 1 was re-allocated or the decoder grew a"
        + " second source of truth for the node kind.",
    )


def test_a_forged_source_kind_is_refused_by_name_not_silently_re_derived() raises:
    """★ THE ONE FORGE THE PERTURBATION HALF STRUCTURALLY CANNOT TRY — AND THE
    ANSWER IS NOT THE OBVIOUS ONE.

    THE HYPOTHESIS, WHICH THIS TEST FALSIFIES. `WireScanNode.source_kind` looks
    like `WireField.dtype_code` one struct over: `ScanData.__init__` opens with

        if self.source.is_binding_backed():
            self.source_kind = self.source.binding_ref().orientation

    — a deriving accessor that DISCARDS whatever the wire carried, which would
    make the slot bytes spent on nothing. It is not: decoding does not
    go through that ctor unchallenged. `_scan_from_wire` calls
    `LogicalPlan.scan_from_source`, whose `_require_orientation_agreement`
    REFUSES a `source_kind` that disagrees with the kind's declaration before
    the ctor ever runs. The slot is REDUNDANT — its only decodable value is the
    binding's own orientation — and it is fully READ. Those are different
    things, and only a forge to a VALID member can tell them apart.

    ⚠ WHY THE PROBE'S PERTURBATION CANNOT REACH THIS. `source_orientation_to_wire`
    is `engine_tag + 1` over a TWO-member space, so the only live wire values are
    1 (COLUMNAR) and 2 (ROW). `_walk` perturbs by flipping bit 0, which sends
    2 -> 3 (undeclared) and 1 -> 0 (UNSPECIFIED), and
    `source_orientation_from_wire` raises on both. Every perturbation this slot
    can receive is a VOCABULARY refusal, so the gate scores it proven without
    ever testing whether the value is USED. A one-bit mutation operator over a
    dense two-member enum cannot produce an in-vocabulary lie; this test does it
    by hand.

    THE CONTROL IS THE FIRST HALF, and it is what makes the second mean
    anything: on a PARQUET leaf — not binding-backed, so `scan_from_source` has
    no declaration to check against and the ctor's `else` keeps the caller's
    value — the same one-byte forge is accepted and CHANGES the decoded plan. So
    the two arms differ in kind, not in whether anyone is looking.
    """
    var reg = _SlotRegistry()

    # ---- THE CONTROL: a non-binding-backed leaf. The forge is ACCEPTED, and
    # it lands in the decoded plan — which is how we know `_obs` can see this
    # field at all (`_plan_ir` prints `source_kind=`).
    var pq = _parquet_leaf()
    var pq_bytes = plan_to_bytes(pq)
    var pq_sites = _slot_sites(pq_bytes, reg, String("WireScanNode|10"))
    assert_equal(
        len(pq_sites), 1,
        "the parquet leaf should write WireScanNode.source_kind exactly once;"
        + " the walk found " + String(len(pq_sites)) + " site(s)",
    )
    assert_equal(
        Int(pq_bytes[pq_sites[0]]), 1,
        "the parquet leaf's source_kind should be COLUMNAR, which is engine tag"
        + " 0 and therefore wire value 1",
    )
    var pq_forged = pq_bytes.copy()
    pq_forged[pq_sites[0]] = UInt8(2)  # ROW — the OTHER DECLARED member
    assert_true(
        _obs(plan_from_bytes(pq_forged^)) != _obs(pq),
        "CONTROL FAILED: forging source_kind COLUMNAR -> ROW on a"
        + " NON-binding-backed leaf changed nothing observable. Either the"
        + " parquet arm has become binding-backed — in which case this control"
        + " needs a new non-binding source — or `_plan_ir` stopped printing"
        + " source_kind and the second half below is now vacuous.",
    )

    # ---- THE BINDING ARM: the same forge is REFUSED, and refused BY NAME.
    var sc = _scan(String("t"), String("/x.orc"))
    var sc_bytes = plan_to_bytes(sc)
    var sc_sites = _slot_sites(sc_bytes, reg, String("WireScanNode|10"))
    assert_equal(
        len(sc_sites), 1,
        "the binding-backed leaf should write WireScanNode.source_kind exactly"
        + " once; the walk found " + String(len(sc_sites)) + " site(s)",
    )
    assert_equal(
        Int(sc_bytes[sc_sites[0]]), 2,
        "`_binding` declares SCAN_ORIENTATION_ROW, which is engine tag 1 and"
        + " therefore wire value 2",
    )
    var sc_forged = sc_bytes.copy()
    sc_forged[sc_sites[0]] = UInt8(1)  # COLUMNAR — in vocabulary, and a LIE
    var raised = False
    var text = String("")
    try:
        var back = plan_from_bytes(sc_forged^)
        text = _obs(back)
    except e:
        raised = True
        text = String(e)
    assert_true(
        raised,
        "a binding-backed scan whose wire source_kind CONTRADICTS its own"
        + " binding's declared orientation decoded without complaint. Then the"
        + " slot really is write-only on this arm and the format is spending"
        + " bytes on it for nothing — which is the hypothesis this test was"
        + " written to check. got: " + text,
    )
    assert_true(
        "orientation" in text,
        "the decoder refused a contradictory source_kind but did not NAME the"
        + " disagreement. A caller holding bytes it cannot decode needs to know"
        + " WHICH field disagrees with WHICH declaration. got: " + text,
    )


def main() raises:
    var suite = TestSuite()
    suite.test[test_scan_leaf_round_trips]()
    suite.test[test_filter_round_trips]()
    suite.test[test_a_nested_expression_tree_round_trips]()
    suite.test[test_project_round_trips]()
    suite.test[test_aggregate_round_trips]()
    suite.test[test_sort_round_trips]()
    suite.test[test_limit_with_a_nonzero_offset_round_trips]()
    suite.test[test_distinct_round_trips]()
    suite.test[test_topn_round_trips]()
    suite.test[test_join_round_trips]()
    suite.test[test_left_join_round_trips_as_left]()
    suite.test[test_a_deep_composition_round_trips]()
    suite.test[test_union_round_trips]()
    suite.test[test_a_scan_with_every_optional_populated_round_trips]()
    suite.test[test_a_cse_introduced_project_round_trips]()
    suite.test[test_every_scalar_kind_round_trips]()
    suite.test[test_an_in_list_and_a_unary_round_trip]()
    suite.test[test_a_positional_column_reference_is_refused_at_the_door]()
    suite.test[test_an_out_of_range_ordinal_keeps_its_own_token]()
    suite.test[test_a_cast_round_trips]()
    suite.test[test_every_render_invisible_cast_part_deviates_and_round_trips]()
    suite.test[test_a_case_expression_round_trips]()
    suite.test[test_a_nested_case_expression_round_trips]()
    suite.test[test_a_case_with_no_when_branches_round_trips]()
    suite.test[test_every_agg_fn_member_round_trips]()
    suite.test[test_an_agg_fn_over_a_case_round_trips]()
    suite.test[test_every_math_fn1_member_round_trips]()
    suite.test[
        test_every_math_fn2_member_round_trips_with_asymmetric_operands
    ]()
    suite.test[test_every_declared_extract_unit_round_trips]()
    suite.test[test_an_extract_unit_in_the_sparse_hole_is_refused]()
    suite.test[test_a_substring_round_trips_with_both_length_forms]()
    suite.test[test_the_four_scalar_arms_compose_round_trips]()
    suite.test[test_every_string_op_member_round_trips]()
    suite.test[test_every_unary_op_member_round_trips]()
    suite.test[test_every_string_fn_member_round_trips]()
    suite.test[test_every_string_fn_n_member_round_trips]()
    suite.test[test_every_regexp_op_member_round_trips]()
    suite.test[
        test_the_regexp_fields_the_render_hides_deviate_and_round_trip
    ]()
    suite.test[test_the_regexp_fields_the_render_shows_are_the_control]()
    suite.test[
        test_the_struct_field_twins_round_trip_as_two_different_nodes
    ]()
    suite.test[test_a_map_get_round_trips_with_asymmetric_children]()
    suite.test[
        test_the_json_extract_field_no_render_reads_deviates_and_round_trips
    ]()
    suite.test[test_the_six_string_and_struct_arms_compose_round_trips]()
    suite.test[
        test_a_window_fn_round_trips_with_every_render_invisible_part_deviating
    ]()
    suite.test[
        test_a_window_fn_with_an_empty_order_by_and_a_nonempty_partition_round_trips
    ]()
    suite.test[test_every_declared_window_fn_member_round_trips]()
    suite.test[test_a_window_fn_in_the_sparse_hole_is_refused]()
    suite.test[
        test_a_partition_by_round_trips_with_every_expr_field_deviating
    ]()
    suite.test[test_a_partition_by_with_no_exprs_round_trips]()
    suite.test[
        test_a_partition_topn_round_trips_with_a_rank_over_fetch_and_a_rank_column
    ]()
    suite.test[test_a_partition_topn_with_no_rank_column_round_trips]()
    suite.test[test_a_partition_topn_func_the_render_cannot_name_round_trips]()
    suite.test[test_a_partition_topn_func_in_the_sparse_hole_is_refused]()
    suite.test[
        test_an_asof_join_round_trips_with_every_render_invisible_part_deviating
    ]()
    suite.test[test_every_declared_asof_strategy_round_trips]()
    suite.test[
        test_every_asof_tolerance_kind_round_trips_with_both_slots_populated
    ]()
    suite.test[test_an_asof_strategy_out_of_vocabulary_is_refused_by_name]()
    suite.test[
        test_an_asof_tolerance_kind_out_of_vocabulary_is_refused_by_name
    ]()
    suite.test[test_a_view_ref_round_trips_and_stays_unresolved]()
    suite.test[
        test_a_cse_ref_round_trips_and_its_hash_is_the_canonical_hash
    ]()
    suite.test[
        test_a_cast_to_varchar_round_trips_with_mixed_child_nullability
    ]()
    suite.test[test_the_four_leftover_arms_compose_round_trips]()
    suite.test[test_an_in_correlated_subquery_round_trips]()
    suite.test[test_a_scalar_correlated_subquery_round_trips]()
    suite.test[
        test_a_non_in_kind_carrying_in_columns_is_refused_by_name
    ]()
    suite.test[test_a_four_slot_agg_expr_round_trips]()
    suite.test[test_the_two_unread_agg_slots_are_carried_and_refused]()
    suite.test[test_a_join_with_a_residual_and_an_algo_hint_round_trips]()
    suite.test[test_a_bigger_plan_encodes_to_more_bytes]()
    suite.test[test_an_out_of_range_arrow_type_id_is_refused_by_name]()
    suite.test[test_an_out_of_range_dict_index_type_id_is_refused_by_name]()
    suite.test[test_an_out_of_range_child_type_id_is_refused_by_name]()
    suite.test[
        test_an_in_range_but_undeclared_arrow_type_id_is_refused_by_name
    ]()
    suite.test[
        test_an_in_vocabulary_range_but_undeclared_scalar_kind_is_refused
    ]()
    suite.test[
        test_an_in_vocabulary_range_but_undeclared_param_tag_is_refused
    ]()
    suite.test[test_a_schema_metadata_length_mismatch_is_refused_by_name]()
    suite.test[test_a_duplicate_schema_metadata_key_is_refused_by_name]()
    suite.test[
        test_partition_values_with_no_partition_cols_are_refused_not_dropped
    ]()
    # ⚠ There is no plan-tag twin of the next test: every `PLAN_*` id has an
    # arm (see the note above `test_an_unmodelled_expr_tag_is_refused_by_name`).
    suite.test[test_an_unmodelled_expr_tag_is_refused_by_name]()
    suite.test[test_a_udf_call_round_trips]()
    suite.test[test_a_udf_call_arrives_UNBOUND_however_it_was_encoded]()
    suite.test[test_a_nested_udf_call_round_trips]()
    suite.test[
        test_a_udf_call_whose_in_and_out_dtypes_DIFFER_round_trips
    ]()
    suite.test[test_a_nameless_udf_call_is_refused_at_encode]()
    suite.test[test_an_unknown_format_version_is_refused_not_best_effort]()
    suite.test[test_truncated_bytes_do_not_decode_into_a_plan]()
    suite.test[test_every_wire_slot_can_be_wrong]()
    suite.test[
        test_the_enum_perturbation_is_an_in_vocabulary_lie_not_a_range_error
    ]()
    suite.test[test_the_node_kind_has_exactly_one_discriminator_on_the_wire]()
    suite.test[
        test_a_forged_source_kind_is_refused_by_name_not_silently_re_derived
    ]()
    suite^.run()
