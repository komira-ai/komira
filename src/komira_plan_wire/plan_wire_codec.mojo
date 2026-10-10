# =============================================================================
# plan_wire_codec.mojo — a `LogicalPlan` to BYTES and back.
# =============================================================================
#
# THE ASSERTION THIS EXISTS TO MAKE TRUE:
#
#     plan -> bytes -> plan'   with   structural_hash(plan) == structural_hash(plan')
#
# `structural_hash` is FNV-1a over the plan's TEXT RENDER and is what
# `EngineContext`'s plan-compile cache keys on (`factory_hash`). If it
# survives, the decoded plan IS the same plan to the engine. The round-trip
# tests assert it, plus the legs the hash cannot see (the output SCHEMA, which
# the render does not emit, and IR equality field by field).
#
# WHERE THIS LIVES, AND WHY NOT IN CORE
# -------------------------------------
# the core packages' deps stay minimal and that is load-bearing — almost every
# package depends on it, so anything added to its deps goes upstream of nearly
# everything. The codec needs `komira_proto_codec` and the generated `komira_plan_proto`
# messages, so it lives in its own package ABOVE core: the package whose job
# is to close over a lower layer's types sits on top of it, never inside it.
#
# ============================ THE COVERAGE LEDGER ============================
#
# ⚠ EVERY UNSUPPORTED SHAPE RAISES BY NAME. NOTHING IS SILENTLY DROPPED.
#
# This is the single most important property of the file, and it is what makes
# the coverage list below TRUE rather than aspirational: a plan shape that is
# not modelled cannot round-trip QUIETLY into a smaller plan. Every refusal
# carries a `PLAN_WIRE_*` token naming the field or tag, so a caller learns
# WHICH shape it hit, and a test can assert the refusal by name.
#
# The precedent this follows is the epoch gate two doors down
# (`scan_binding_gate`), whose whole lesson was that a walk which enumerates
# what it knows and RAISES on what it does not is the only kind that cannot
# quietly no-op. The failure mode it was built against — a check that returned
# clean because it never looked — is exactly what a "best effort" codec is.
#
# ⚠ AND EVERY REFUSAL IN THIS LEDGER IS DOWNSTREAM OF A SUCCESSFUL PARSE.
# That is worth stating here rather than only in the file that handles it,
# because THIS ledger is what an engineer reads to decide the refusal
# discipline is complete. It is complete about SHAPES THE FORMAT CANNOT CARRY
# and silent about BYTES THE READER CANNOT SURVIVE — unbounded, 901 bytes of
# nesting SIGSEGV the process from inside `decode_proto`, before any token
# below can be reached. A `raises` function that dies on the way in has no
# refusal discipline at all, however good its ledger is.
#
# The structural half lives in `plan_wire_admit.mojo` and runs BEFORE
# `decode_proto` — size, format version, nesting depth, node count, each
# refusing by name in the same style. The two halves are not interchangeable
# and neither subsumes the other.
#
# ⚠ AND THE STRUCTURAL HALF IS NOT WHERE THE STACK GUARANTEE LIVES. A prescan
# that declines to descend where the decoder descends is beaten by ONE APPENDED
# BYTE: a trailing `0x07` can hide a 320-record nest behind an apparent depth
# of 1 and admit 902 bytes that then SIGSEGV `decode_proto` anyway (see
# `plan_wire_admit.mojo`'s header).
#
# What bounds the stack is `komira_proto_codec`'s `PbDecoder` COUNTING ITS OWN
# RECURSION (`PB_MAX_DECODE_DEPTH`). The prescan still runs, still refuses
# earlier and by a better name, and still owns the NODE budget — which is a
# statement about what a plan is and which no depth bound anywhere can see. But
# an engineer reading this ledger to decide the discipline is complete should
# know that the part of it protecting the process is one layer down, on the
# recursion itself, where nothing has to agree with it.
#
# --- PLAN TAGS: 16 of 18 modelled --------------------------------------------
#   MODELLED   SCAN, FILTER, PROJECT, AGGREGATE, JOIN, SORT, LIMIT, DISTINCT,
#              TOPN, UNION, PARTITION_BY, PARTITION_TOPN, ASOF_JOIN, VIEW_REF,
#              CSE_REF, CAST_TO_VARCHAR
#
#   ★ EVERY MATERIALIZABLE PLAN TAG NOW HAS AN ARM. The two that do not —
#   CONVERT_COLUMN_TO_ROW and CONVERT_ROW_TO_COLUMN — are the two no producer
#   emits (see the REFUSED line below), so `_plan_to_wire`'s `else` is now
#   reachable only through the bare `LogicalPlan(tag, schema)` ctor. It is kept,
#   and asserted by token, for exactly that reason: the ctor is public, so the
#   state is constructible, and a codec that silently encoded around it would
#   write a plan the writer never wrote.
#
#   ⚠ ASOF_JOIN'S TOLERANCE OFF-KIND SLOT REACHES NO RENDER.
#   `plan_display` prints `AsofJoin(strategy=…, on=<l>=<r>, by=[…])`, then
#   `tolerance=INT64(<int_val>)` or `tolerance=FLOAT64(<float_val>)` (nothing
#   at kind NONE), then each NON-EMPTY pre-sort hint as
#   `left_sorted=[quoted keys]/[dirs]` / `right_sorted=…`. So LEG 1 sees the hints and
#   the selected tolerance value, but never the slot `kind` does not select,
#   and at kind NONE it sees no tolerance at all. All THREE slots are carried
#   verbatim, including the one `kind` does not select: `AsofTolerance` is
#   `@fieldwise_init` and public, so an off-kind payload is constructible and
#   re-deriving it would silently rewrite the struct. The hint lists are
#   carried verbatim too: a non-empty hint ASSERTS "this side is already
#   sorted, skip the sort phase", so dropping one costs time while inventing
#   one produces wrong rows.
#
#   ★ VIEW_REF AND CSE_REF EACH HOLD TWO SCHEMAS AND THE WIRE CARRIES ONE.
#   Both payloads declare an `output_schema` BESIDE the node's, and both
#   factories fill the two from ONE argument — so they are equal in every
#   constructible state (a plan node's schema is assigned only inside its
#   `__init__`; nothing reassigns it after construction). A second `WireSchema`
#   would therefore be a FORGEABLE DUPLICATE, the `ScanData.source_path`
#   situation.
#
#   With the slot present, an encoder that wrote `p.output_schema` where the
#   payload's belonged — a codec that simply ASSUMED the two were aliases —
#   would leave every round-trip test GREEN. A field
#   no mutation can disturb is a field that tests nothing (the same class as an
#   uncarried `nulls_first`). So the payload copies are DERIVED at decode.
#
#   The consequence, stated so nobody reads these arms as checked: both are
#   `output_schema`-RESTORED, so `_check_output_schema` is a TAUTOLOGY on them,
#   exactly as it is on PLAN_UNION.
#
#   ⚠ CSE_REF IS THE ONE NODE WHOSE `structural_hash` IS NOT ITS RENDER.
#   `LogicalPlan.structural_hash` special-cases it to RETURN `canonical_hash`
#   (re-CSE idempotence), so on a bare CSE-ref leaf LEG 1's hash assertion is
#   an assertion that this one UInt64 survived, and nothing else.
#
#   A DECODED VIEW REFERENCE IS UNRESOLVED, AND THAT IS THE POINT. It names a
#   definition outside the plan; decoding it does not consult a registry,
#   because the registry that matters is the DECODING process's.
#   `view_resolution_pass` is what expands it, there. Carrying the reference
#   rather than a snapshot of someone else's registry is what makes the plan
#   language-agnostic rather than process-agnostic-in-name-only.
#
#   ⚠ PARTITION_BY'S RENDER PRINTS A COUNT WHERE ITS PAYLOAD IS.
#   `PartitionBy(partition=[…], order=[…], <n> funcs)` — so LEG 1 covers the
#   two key lists and knows only HOW MANY `PartitionExpr`s the node holds,
#   never anything about one, and `descending` is absent from the render at
#   every value. LEG 2 is unusually strong here instead: the output schema is
#   the child's plus one column per expr via `partition_expr_output_field`,
#   which reads `func`, `column`, `has_default` and `alias_name` — so four of
#   the seven are held by the schema and `offset`, `default_value` and the
#   five frame bounds by the IR leg alone.
#
#   ⚠ PARTITION_TOPN'S RENDER NAMES TWO FUNCS OUT OF SIXTEEN. `plan_display`
#   prints `func=ROW_NUMBER` for 0, `func=RANK` for 1 and `func=FUNC_<n>` for
#   everything else, so LEG 1 cannot tell PF_SUM from PF_MIN. `over_fetch_k`
#   IS rendered, and is the field with the worst failure mode of the plan arms:
#   its `-1` is a CONSTRUCTION-TIME sentinel that `PartitionTopNData.__init__`
#   resolves to `k`, so a decoder that re-passed the sentinel instead of the
#   stored value would collapse every fused RANK node's tie buffer and produce
#   a plan that executes and silently drops tied rows.
#   REFUSED    CONVERT_COLUMN_TO_ROW, CONVERT_ROW_TO_COLUMN — declared by the
#              engine and never materialized (`insert_orientation_conversions`
#              RAISES a deferral), so no plan carries them. Already
#              EXEMPT in `plan_vocabulary.proto` for the same reason.
#
# --- EXPR TAGS: 25 of 27 modelled --------------------------------------------
#   MODELLED   COL_REF, COL_IDX, LITERAL, BINARY_OP, UNARY_OP, ALIAS, IN_LIST,
#              CAST, CORRELATED_SUBQUERY, WHEN, AGG_FN, EXTRACT, MATH_FN,
#              MATH_FN2, SUBSTRING, STRING_OP, STRING_FN, STRING_FN_N, REGEXP,
#              STRUCT_FIELD, STRUCT_FIELD_IDX, MAP_GET, JSON_EXTRACT,
#              WINDOW_FN, UDF_CALL
#   REFUSED    the other 2 — BETWEEN and SORT_KEY. They are tags NO factory
#              builds a payload for: `Expr` declares no `_between` /
#              `_sort_key` field, so the only way to construct one is the bare
#              `Expr(tag)` ctor, and there is nothing behind the tag to carry.
#
#   ★ UDF_CALL IS MODELLED BECAUSE OF THE RE-MINT, NOT THE MESSAGE. What makes
#   a UDF call carriable is the decode-time RE-MINT that resolves `name`
#   against the executing process's own registry
#   (`UdfRegistry.resolve_unique_by_name`, called when the UDF call executes).
#   Without that re-mint, a name on the wire would resolve to nothing.
#
#   ⛔ WHAT IS NOT CARRIED IS `UdfCallData.handle`, AND IT IS
#   UNSPELLABLE RATHER THAN OMITTED — `WireUdfCall` has four fields and none of
#   them is a handle. A decoded UDF call is UNBOUND; see the decode arm.
#
#   ★ `Expr.write_to` PRINTS EVERY WINDOW_FN FIELD — the two name lists,
#   `descending`, the frame — and every WHEN case plus its ELSE, because the
#   render IS the plan-compile cache key: a render that printed a stub would
#   let two different queries share one compiled plan. `_infer_expr_field` has
#   no WINDOW_FN arm, so LEG 2 is blind to the entire node; the IR-equality leg
#   reads every field anyway.
#
#   ⚠ THE THREE LISTS ARE NOT PARALLEL AND MUST NOT BE SIZED FROM EACH OTHER.
#   `descending` is per-ORDER-key; `partition_by` is unrelated to both.
#   `Expr.over(partition_by)` builds a non-empty `partition_by` with `order_by`
#   AND `descending` both empty, so a decoder that sized `descending` from
#   `order_by` would be right on the fluent surface and wrong on the wire.
#
#   ⚠ THE FOUR SCALAR ARMS ARE THE ONES LEG 1 *DOES* COVER, AND THAT IS A FACT
#   ABOUT `Expr.write_to`, NOT ABOUT THIS FILE. `Extract(unit=<n>, <child>)`,
#   `MathFn(op=<n>, <child>)`, `MathFn2(op=<n>, <l>, <r>)` and
#   `Substring(<child>, start=<n>, length=<n>)` each print every scalar they
#   carry, so a dropped field is red in the plan TEXT — the opposite of WHEN,
#   whose render is seven characters. The IR-equality leg reads them anyway.
#   Which leg fires is a property of the render, and the only way to know which
#   is to drive it; see the falsification record in the round-trip test.
#
#   ⚠ EXTRACT'S UNIT SPACE IS THE SPARSEST IN THE FORMAT: two disjoint runs,
#   0..6 (fields) and 16..25 (truncations), with 7..15 DECLARED BY NOTHING. So
#   both directions go through `extract_field_{to,from}_wire`, which test
#   MEMBERSHIP rather than a bound — exactly the distinction the ArrowType
#   narrowing turns on. A hole value narrows into a `UInt8` losslessly and is
#   still not a unit.
#
#   ⚠ MATH_FN2 CARRIES TWO CHILDREN OF THE SAME TYPE IN A NON-COMMUTATIVE
#   POSITION. `atan2(y, x)` and `pow(base, exponent)` change VALUE when their
#   operands swap, and the output type is FLOAT64 either way, so a codec that
#   crossed the two slots produces a well-typed plan that computes a different
#   number. Nothing but an operand-asymmetric corpus can see it.
#
#   ⚠ SUBSTRING'S `length` DEFAULTS TO -1, NOT 0 — the only scalar among the
#   four scalar arms whose ENGINE default is not the PROTO3 default. `Expr.substring(s,
#   start)` means "to end of string" and spells it as a negative length, so an
#   encoder that dropped the field would convert every open-ended substring
#   into a zero-length one: a plan that quietly returns empty strings rather
#   than one that fails.
#
#   ⚠ WHEN RENDERS AS `When(WHEN c THEN r, ..., ELSE d)` (see above), but
#   `_infer_expr_field` types a CASE from its FIRST THEN clause, so cases 1..n
#   reach no output schema. Everything in `WhenData` is carried explicitly and
#   compared by the round trip's IR-equality leg as well as by the render.
#
#   ⚠ AGG_FN REUSES THE `AggFn` VOCABULARY, WHICH HAS THIRTEEN MEMBERS AND NO
#   COUNT CONSTANT IN THE ENGINE. `agg_expr.mojo` declares AGG_SUM..AGG_VAR_SAMP
#   as thirteen free `comptime`s with nothing asserting how many there are —
#   a drift hazard, so the derived vocabulary's
#   `AGG_FN_WIRE_MEMBERS` is pinned against a HARDCODED 13 in the round-trip
#   test for exactly that reason: deriving both sides of that comparison would
#   make it true by construction.
#
#   ★ CORRELATED_SUBQUERY IS WHAT MAKES THIS CODEC MUTUALLY RECURSIVE.
#   `CorrelatedSubqueryData.inner_plan` is the ONLY cross-edge from the
#   expression tree back into the plan tree — the only `LogicalPlan`-typed
#   field anywhere outside a plan node's own child slot — so `_expr_to_wire`
#   calling `_plan_to_wire` happens on exactly one arm and nowhere else.
#   Declaring it in `plan.proto` closes the cycle in the MESSAGE graph too, so
#   protoc-gen-mojo's recursion-breaking pass decides which edges are
#   `List[T]` boxes: `WireScanNode.filter`, `WireFilterNode.predicate`,
#   `WireFilterNode.child` and `WireJoinNode.residual` are boxes and
#   `WirePlan.filter` is not. Those shapes are READ OFF the generated
#   `plan.mojo`; `_one_expr` / `_one_child` are where a box that holds 0 or 2
#   is refused rather than assumed away.
#
#   ⚠ THE RENDER STOPS AT THE INNER PLAN'S TAG. `Expr.write_to` prints
#   `inner_tag=<Int>` and does NOT recurse, and prints `outer_refs=#<count>`
#   rather than the names — so LEG 1 cannot tell two different inner plans of
#   the same root tag apart, nor two different ref-name lists of equal length.
#   The IR-equality leg is the only thing that compares either.
#
#   ⚠ CAST CARRIES SIX PARTS AND THE RENDER EMITS THE OTHER FOUR ONLY WHEN THEY
#   DEVIATE. `Expr.write_to` prints `Cast(<child>, <target>` then
#   `, arrow=<type>` when `target_arrow` is not `ArrowType.from_dtype(target)`,
#   `, p=<p>, s=<s>` when either is non-zero, and `, try` for TRY_CAST. So
#   LEG 1 sees a dropped part only when its value deviates; at the default it
#   prints nothing, and the IR-equality leg is the only thing that compares
#   it. Each part therefore gets its own wire slot — re-deriving
#   `target_arrow` from `target` at decode would be exactly the bug
#   `Expr.cast_preserving_arrow` exists to fix, re-committed one layer down.
#
#   ⚠ REGEXP RENDERS FOUR OF ITS SEVEN FIELDS *CONDITIONALLY*, WHICH IS A THIRD
#   KIND OF RENDER HOLE — not "always printed" (the four scalar arms) and not
#   "never printed" (CAST, WHEN), but PRINTED ON SOME OPS AND NOT OTHERS.
#   `Expr.write_to` gates `replacement` on `op == REGEXP_REPLACE`, `group` on
#   EXTRACT / EXTRACT_ALL, and `flags` / `group_name` on being non-empty. So
#   the SAME field is covered by LEG 1 on one node and invisible on the node
#   beside it, and `Expr.regexp(...)` — the total factory the decoder must use,
#   because the ten `regexp_*` factories each pin some subset — will build
#   exactly the invisible combinations. LEG 2 is worse: `_infer_expr_field`
#   reads only `op`, so the other six are invisible to it on ALL ten ops. The
#   corpus therefore carries a REGEXP_COUNT node with a non-zero `group` and a
#   non-empty `replacement`, which LEG 1 prints NEITHER of.
#
#   ★ JSON_EXTRACT'S `output_type` IS READ BY NO OTHER LEG AT ANY VALUE ON ANY
#   OP. The render prints parent, path and `mode=->`/`mode=->>` and stops, and
#   `_infer_expr_field` has NO EXPR_JSON_EXTRACT ARM AT ALL — the tag falls
#   through to the `else`, so the node types as `ArrowType.NULL` and LEG 2 sees
#   the same thing whatever the field says. Both convenience factories DERIVE it
#   (`ArrowType.STRING`, always), so a decoder calling one of them would agree
#   with a correct one on every plan that exists today. That is why decode goes
#   through `Expr.json_extract_from_parts` and not through `json_extract_json` /
#   `json_extract_string`: same reason, same shape, as `cast_from_parts`.
#
#   ⚠ JSON_EXTRACT'S PATH IS CARRIED AS SEGMENTS, NOT AS A JOINED STRING. A
#   path joined on `.` is AMBIGUOUS where the list is not — `["a.b"]` and
#   `["a", "b"]` both join to `$.a.b`. (The render escapes a `.` inside a
#   segment, `$.a\.b`, so it tells them apart; that is the render's escape,
#   not `parse_json_path`'s syntax, so it is still not a form to decode from.)
#   Re-parsing at decode would also be a re-derivation, and it would silently
#   split a segment in two. Carrying segments is what keeps a dot-bearing key
#   intact across the wire.
#
#   ⚠ MAP_GET IS THE `MathFn2` OPERAND TRAP IN A NEW PLACE. `parent` and `key`
#   are both `WireExpr` recursion boxes and the pair is not interchangeable, so
#   a codec that crossed them emits a structurally valid message. The corpus
#   never gives this arm two equal children.
#
#   ⚠ STRUCT_FIELD AND STRUCT_FIELD_IDX ARE TWO TAGS, NOT ONE TAG WITH A UNION.
#   They are the `EXPR_COL_REF` / `EXPR_COL_IDX` bound-twin shape: by-name
#   linear-scans `_field_names` at eval time and by-idx indexes `_children`
#   directly. Folding one into the other at decode would change how the plan
#   EXECUTES, not merely how it prints.
#
# --- SOURCE ARMS: parquet + every binding-backed kind ------------------------
#   MODELLED   PARQUET (single- or multi-path, no Hive partitioning, local fs)
#   MODELLED   every BINDING-backed arm — JSON, CSV, ARROW ×3, ORC, AVRO and
#              any kind an upper package declares. A binding is PURE DATA by
#              construction, which is the entire point of `ScanBinding`, so
#              these need no per-kind code here and a NEW kind costs this file
#              ZERO lines. That is the property `ScanBinding` exists to
#              produce.
#   REFUSED    IN_MEMORY — `InMemorySource` holds
#              `ArcPointer[Slab[RecordBatch]]`, LIVE HEAP DATA INSIDE THE IR.
#              This is THE fact that makes a plan unserializable, and it is
#              not a gap in this file: there is nothing to encode. It
#              disappears once in-memory scans become binding-backed, at which
#              point they are covered by the arm above with no edit here.
#   REFUSED    a Hive-partitioned parquet scan (`hive_dir_scan`,
#              `hive_predicate`) and a non-local `fs_descriptor`. Both are
#              carried as presence bits so the refusal is precise.
#
# --- FIELDS REFUSED RATHER THAN DROPPED --------------------------------------
#   `FilterData.udf` / `ProjectData.udf` / `AggregateData.udf`
#       A `UdfData` holds a Mojo FUNCTION POINTER. It is not data and cannot
#       be bytes in any format. This is a permanent boundary, not a TODO — a
#       serializable plan that calls back into one process's code is not
#       serializable. The eventual answer is a NAMED udf resolved through a
#       registry at decode, which is the ScanBinding handle pattern again.
#   `ScanData.schema` when it is None
#       Both facades build scans through `LogicalPlan.scan_from_source`, whose
#       schema argument is non-optional, so `None` is only reachable through
#       the legacy `LogicalPlan.scan` factory. Decoding one would materialize
#       a schema from the source and turn `None` into `Some` — an IR change no
#       leg of the round-trip test can see.
#   `CorrelatedSubqueryData` with a NON-IN kind and a non-empty `in_lhs_col`
#       or `in_rhs_col`
#       DECODE-SIDE ONLY. The engine has no factory for that state — those two
#       columns are populated only for CORR_KIND_IN_CORRELATED — so accepting
#       it would mean silently dropping the columns or silently changing the
#       kind. Refused, by `PLAN_WIRE_MALFORMED`.
#   `ScanData.table_stats` / `ScanBinding.stats`
#       `TableStats` is pure data and CAN be encoded; it simply is not yet.
#       Refused rather than dropped because stats steer join-order and a
#       silently statless decoded plan is a silent plan change.
#
# --- THE DECODE SIDE, WHICH DOES NOT CHOOSE ITS INPUT ------------------------
#   Every narrowing from a wire type to an engine type is CHECKED and RAISES BY
#   NAME. There are three, all on `WireField` and all `uint32` -> `UInt8`:
#   `arrow_type_id`, `dict_index_type_id`, `child_type_ids[]`. See
#   `_arrow_type_from_wire` — the check is MEMBERSHIP in the derived ArrowType
#   vocabulary, not a range test, because 50 narrows losslessly and is still
#   not a type. A narrowing that does not raise does not fail; it succeeds at
#   naming a DIFFERENT type, and a decoded plan with a different schema is a
#   silently wrong plan that LEG 2 would compare happily.
#
# ⚠ THE THREE LISTS ABOVE ARE PROSE AND PROSE ROTS. What keeps them honest is
# that each entry corresponds to a `raise` with a distinct token, and the
# round-trip tests assert the refusals BY TOKEN — so deleting a refusal
# without adding its encoding turns a test red.
# =============================================================================

from std.memory import OwnedPointer

from komira_proto_codec import encode_proto, decode_proto

from komira_plan_proto.plan import (
    WireField,
    WireSchema,
    WireScalar,
    WireParam,
    WirePushdownGate,
    WireScanBinding,
    WireUdfColumn,
    WireUdf,
    WireParquetSource,
    WirePartitionValueRow,
    WireScanSource,
    WireColRef,
    WireColIdx,
    WireBinaryOp,
    WireUnaryOp,
    WireAlias,
    WireInList,
    WireCast,
    WireCorrelatedSubquery,
    WireWhenCase,
    WireWhen,
    WireAggFn,
    WireExtract,
    WireMathFn,
    WireMathFn2,
    WireSubstring,
    WireStringOp,
    WireStringFn,
    WireStringFnN,
    WireUdfCall,
    WireRegexp,
    WireStructField,
    WireStructFieldIdx,
    WireMapGet,
    WireJsonExtract,
    WireFrame,
    WireWindowFn,
    WireExpr,
    WireAggExpr,
    WireScanNode,
    WireFilterNode,
    WireProjectNode,
    WireAggregateNode,
    WireJoinNode,
    WireSortNode,
    WireLimitNode,
    WireDistinctNode,
    WireTopNNode,
    WireUnionNode,
    WirePartitionExpr,
    WirePartitionByNode,
    WirePartitionTopNNode,
    WireAsofTolerance,
    WireAsofJoinNode,
    WireViewRefNode,
    WireCseRefNode,
    WireCastToVarcharNode,
    WirePlan,
    WirePlanEnvelope,
    WireWriteTarget,
)
from komira_plan_proto.plan_vocabulary import (
    AggFn,
    AsofDirection,
    AsofToleranceKind,
    BinaryOp,
    ColSide,
    CorrelatedKind,
    DTypeCode,
    ExtractField,
    FrameBound,
    FrameUnits,
    JoinAlgo,
    JoinType,
    MathFn1,
    MathFn2,
    ParamTag,
    PushdownGateMode,
    RegexpOp,
    ScalarKind,
    ScalarTimeUnit,
    SnapshotPolicy,
    StringOp,
    StringFn,
    StringFnN,
    SourceOrientation,
    SourceType,
    SourceVariantTag,
    UnaryOp,
    WindowFn,
    WriteCompression,
    WriteFormat,
)

from komira_arrow.arrow_types import ArrowType
from komira_arrow.schema import Field, Schema, SchemaBuilder
from komira_collections.slab import Slab
from komira_arrow.dtype_sentinel import DTYPE_NONE
from komira_plan_expr.agg_expr import AggExpr
from komira_plan_expr.expr import Expr, WhenCaseData
from komira_plan_expr.partition_pred_pod import PartitionPredicatePod
from komira_plan_expr.expr import (
    COL_SIDE_NONE,
    COL_SIDE_LEFT,
    COL_SIDE_RIGHT,
    EXPR_COL_REF,
    EXPR_COL_IDX,
    EXPR_LITERAL,
    EXPR_BINARY_OP,
    EXPR_UNARY_OP,
    EXPR_ALIAS,
    EXPR_IN_LIST,
    EXPR_CAST,
    EXPR_CORRELATED_SUBQUERY,
    EXPR_WHEN,
    EXPR_AGG_FN,
    EXPR_EXTRACT,
    EXPR_MATH_FN,
    EXPR_MATH_FN2,
    EXPR_SUBSTRING,
    EXPR_STRING_OP,
    EXPR_STRING_FN,
    EXPR_STRING_FN_N,
    # The UDF-call arm: encoded by NAME, never by handle, and re-bound by the
    # receiver — see the EXPR_UDF_CALL arms of `_expr_to_wire` /
    # `_expr_from_wire`.
    EXPR_UDF_CALL,
    string_fn_n_arity,
    string_fn_n_arity_ok,
    string_fn_n_name,
    EXPR_REGEXP,
    EXPR_STRUCT_FIELD,
    EXPR_STRUCT_FIELD_IDX,
    EXPR_MAP_GET,
    EXPR_JSON_EXTRACT,
    EXPR_WINDOW_FN,
)
from komira_plan_expr.partition_expr import PartitionExpr, PartitionFrame
from komira_plan_ir.logical_plan import (
    LogicalPlan,
    ExprArray,
    AggExprArray,
    PLAN_SCAN,
    PLAN_FILTER,
    PLAN_PROJECT,
    PLAN_AGGREGATE,
    PLAN_JOIN,
    PLAN_SORT,
    PLAN_LIMIT,
    PLAN_DISTINCT,
    PLAN_TOPN,
    PLAN_UNION,
    PLAN_PARTITION_BY,
    PLAN_PARTITION_TOPN,
    PLAN_ASOF_JOIN,
    PLAN_VIEW_REF,
    PLAN_CSE_REF,
    PLAN_CAST_TO_VARCHAR,
    AsofTolerance,
    CORR_KIND_IN_CORRELATED,
)
from komira_plan_ir.corr_subquery import corr_subq_inner_plan_ref
from komira_plan_ir.logical_plan_variants import UnionData
from komira_plan_expr.udf_data import UdfData
from komira_plan_wire.plan_wire_vocabulary import (
    agg_fn_to_wire,
    agg_fn_from_wire,
    arrow_type_is_declared,
    binary_op_to_wire,
    binary_op_from_wire,
    col_side_to_wire,
    col_side_from_wire,
    correlated_kind_to_wire,
    correlated_kind_from_wire,
    extract_field_to_wire,
    extract_field_from_wire,
    join_algo_to_wire,
    join_algo_from_wire,
    join_type_to_wire,
    join_type_from_wire,
    math_fn1_to_wire,
    math_fn1_from_wire,
    math_fn2_to_wire,
    math_fn2_from_wire,
    plan_tag_to_wire,
    plan_tag_wire_name,
    expr_tag_wire_name,
    regexp_op_to_wire,
    regexp_op_from_wire,
    string_op_to_wire,
    string_op_from_wire,
    string_fn_to_wire,
    string_fn_from_wire,
    string_fn_n_to_wire,
    string_fn_n_from_wire,
    source_orientation_to_wire,
    source_orientation_from_wire,
    source_type_to_wire,
    source_type_from_wire,
    source_variant_tag_to_wire,
    source_variant_tag_from_wire,
    asof_direction_to_wire,
    asof_direction_from_wire,
    asof_tolerance_kind_to_wire,
    asof_tolerance_kind_from_wire,
    unary_op_to_wire,
    unary_op_from_wire,
    window_fn_to_wire,
    window_fn_from_wire,
    frame_units_to_wire,
    frame_units_from_wire,
    frame_bound_to_wire,
    frame_bound_from_wire,
    # SIX MORE NARROWED SPACES. Each crosses the wire as a `uint32` the decoder
    # narrows to UInt8, so each goes through a checked `*_from_wire` rather
    # than a bare narrowing.
    scalar_kind_to_wire,
    scalar_kind_from_wire,
    scalar_time_unit_to_wire,
    scalar_time_unit_from_wire,
    param_tag_to_wire,
    param_tag_from_wire,
    pushdown_gate_mode_to_wire,
    pushdown_gate_mode_from_wire,
    snapshot_policy_to_wire,
    snapshot_policy_from_wire,
    # THE WRITE ENVELOPE. Declared in `komira_arrow/write_target.mojo` —
    # DOWN in core rather than in the SQL frontend, because a wire vocabulary
    # outside this codec's the core packages import closure is one a vocabulary
    # completeness check over core structurally cannot see.
    write_format_to_wire,
    write_format_from_wire,
    write_compression_to_wire,
    write_compression_from_wire,
)
from komira_arrow.write_target import WriteTarget, write_target_supported

# ★ THE STRUCTURAL REFUSALS. Everything below in this file is a PER-FIELD
# refusal on a value a successful parse produced; `plan_wire_admit` is the
# refusal that runs BEFORE the parse, on the bytes themselves. Measured without
# it, 901 bytes of nesting kill the process before any per-field refusal runs —
# see that file's header for the table.
from .plan_wire_admit import (
    plan_wire_admit,
    plan_wire_apparent_depth,
    PlanWireVersionSet,
    PLAN_WIRE_MAX_DEPTH,
    PLAN_WIRE_MAX_NODES,
    PLAN_WIRE_MAX_BYTES,
    PLAN_WIRE_TOO_DEEP,
    PLAN_WIRE_TOO_MANY_NODES,
    PLAN_WIRE_TOO_LARGE,
    PLAN_WIRE_VERSION_MISMATCH,
    PLAN_WIRE_WRITE_TARGET_MIN_VERSION,
    PLAN_WIRE_WRITE_TARGET_VERSION_UNDERSTATED,
)

# THE THIRD PASS. `plan_wire_admit` bounds FRAMING before the parse; the ledger
# in this file refuses SHAPES the format cannot carry; this one refuses VALUES
# the plan's own schema contradicts. All three are needed and none subsumes
# another — an out-of-range `col_idx` is inside every budget, is a shape the
# format carries perfectly, and unchecked is a SIGSEGV at 261 bytes.
from .plan_wire_values import (
    plan_wire_check_values,
    PLAN_WIRE_COLUMN_INDEX_OUT_OF_RANGE,
    PLAN_WIRE_UNRESOLVED_COLUMN,
    PLAN_WIRE_INCONSISTENT_COUNT,
    PLAN_WIRE_NEGATIVE_COUNT,
    PLAN_WIRE_UNCHECKED_VALUE_SITE,
)
from komira_plan_expr.scalar_value import ScalarValue
from komira_scan_source.pushdown_gate import PushdownGate
from komira_scan_source.scan_binding import (
    ScanBinding,
    SCAN_LEGACY_SOURCE_TYPE_NONE,
)
from komira_scan_source.scan_params import ParamValue, ScanParams, PARAM_STR, PARAM_I64, PARAM_U64, PARAM_F64, PARAM_BOOL, PARAM_BYTES
from komira_scan_source.parquet_source import ParquetSource
from komira_scan_source.source_variant import (
    SourceVariant,
    SOURCE_VARIANT_PARQUET,
    SOURCE_VARIANT_IN_MEMORY,
)


# =============================================================================
# Format version + the refusal tokens
# =============================================================================

comptime PLAN_WIRE_FORMAT_VERSION: UInt32 = 4
"""THE VERSION A PLAIN (non-write) ENVELOPE DECLARES.

⚠ THIS IS NO LONGER "THE" VERSION — it is the FLOOR, and reading it as the only
one is now a bug. A write-carrying envelope declares
`PLAN_WIRE_WRITE_TARGET_MIN_VERSION` (5) instead; see
`plan_wire_supported_versions()` for what this build READS, and
`_envelope_version_for` for what it WRITES.

THE RULE, IN THREE CASES.

`plan_from_bytes` refuses on SET MEMBERSHIP, never on `<`. So
this is a CAPABILITY TOKEN, not an ordering, and the only question a bump
answers is: CAN A READER THAT DID NOT BUMP MIS-READ THESE BYTES?

  ADD a field       NO BUMP. proto3 preserve-and-ignore: an older reader skips
                    what it does not know, and every field this format has
                    added is additive by construction — the decode path RAISES
                    rather than defaulting on anything it needs.
  CHANGE a meaning  BUMP. The bytes keep their shape and say something else,
                    which is exactly the case an unversioned reader cannot
                    detect for itself.
  DELETE a field    BUMP, UNCONDITIONALLY. Retiring `WirePlan.tag` /
                    `WireExpr.tag` and reserving their numbers looks safe
                    without a bump, because an old reader meets an absent tag,
                    calls `plan_tag_from_wire(0)` and RAISES — loud, not
                    silent. But that reasoning is
                    PER-FIELD and PER-READER, and old readers are precisely the
                    population you cannot audit. Delete a `bool` instead and the
                    old reader gets `False` and decodes a different plan in
                    silence; `WireScanBinding.has_stats` would do it today. A
                    rule that needs an audit before you can apply it is a rule
                    that gets applied wrong, so deletion bumps unconditionally.
                    It also costs nothing: set membership already makes the
                    deletion breaking, and the bump converts a confusing refusal
                    that names a TAG into `PLAN_WIRE_VERSION_MISMATCH`, which
                    names the actual problem.

VERSION 2 carries two changes:
  * the `WirePlan.tag` / `WireExpr.tag` retirement; and
  * six vocabulary fields moving from ENGINE-VERBATIM `uint32` to the derived
    +1-offset enums — `WireScalar.kind` / `.time_unit` / `.error_code` (the
    last deleted in version 4),
    `WireParam.tag`, `WirePushdownGate.mode`, `WireScanBinding.snapshot_policy`.
    Same bytes, every value shifted by one, which is the meaning change this
    rule's first line has always been about.

VERSION 3 IS THE FIRST BUMP FOR AN *ADDED* FIELD, AND IT BREAKS
THE FIRST RULE ABOVE ON PURPOSE. `WirePlanEnvelope.write_target` is a field
whose OMISSION IS THE FAILURE: "ADD a field -> NO BUMP" is sound exactly when
proto3's skip-what-you-do-not-know loses nothing the caller needed, and here it
loses the entire point of the message — the reader runs the query, returns rows,
writes no file, and raises nothing. So the write version (3 then, 5 now) is
declared ONLY by envelopes that carry field 3, which makes it a MINIMUM READER
CAPABILITY rather than a format generation: a version-2 reader refuses a write
envelope by name instead of executing half of it.

VERSIONS 4 AND 5 DELETE `WireScalar.error_code` (field 20; its number and name
are reserved). Both envelope shapes carry scalars, so both move: a plain
envelope declares 4 and a write-carrying one declares 5, and this build reads
only `{4, 5}`. A reader of `{2, 3}` refuses either by
`PLAN_WIRE_VERSION_MISMATCH`, and this build refuses 2 and 3 the same way.
5 is still a minimum reader capability over 4: a write target under 4 is
refused as understated.
"""


def plan_wire_supported_versions() raises -> PlanWireVersionSet:
    """THE VERSIONS THIS BUILD READS. `{4, 5}`.

    ⚠ A FUNCTION AND NOT A `comptime`, because `PlanWireVersionSet` construction
    is `raises` (it refuses a version >= 32 rather than shifting past the end of
    the mask). The cost is a couple of shifts on a path that already walks every
    byte of the message.

    ⚠ AND IT IS A SET, WHICH IS THE WHOLE POINT. `>=` would claim that any
    reader speaking a lower version can read a higher one, which is precisely
    false for the CHANGE-A-MEANING case this format's version field exists for.
    A DELETE-a-field bump needs the same: this build reads `{4, 5}` and
    refuses 2 and 3, which an ordering could not express.
    """
    return PlanWireVersionSet.only(PLAN_WIRE_FORMAT_VERSION).plus(
        PLAN_WIRE_WRITE_TARGET_MIN_VERSION
    )


def _envelope_version_for(has_write_target: Bool) -> UInt32:
    """The version an envelope of this SHAPE must declare.

    ★ DERIVED FROM THE CONTENT, NEVER PASSED IN. The writer cannot choose a
    version, so the writer cannot get it wrong — and the reader's
    `PLAN_WIRE_WRITE_TARGET_VERSION_UNDERSTATED` check is this same function
    read in the other direction. Two independent statements of one rule is how
    the rule rots; one function used by both sides is how it does not."""
    if has_write_target:
        return PLAN_WIRE_WRITE_TARGET_MIN_VERSION
    return PLAN_WIRE_FORMAT_VERSION

# Every token below is asserted BY NAME in the round-trip test. A refusal
# whose token nothing checks is a refusal that can be deleted by accident.
comptime PLAN_WIRE_UNSUPPORTED_PLAN_TAG: String = "PLAN_WIRE_UNSUPPORTED_PLAN_TAG"
comptime PLAN_WIRE_UNSUPPORTED_EXPR_TAG: String = "PLAN_WIRE_UNSUPPORTED_EXPR_TAG"
comptime PLAN_WIRE_UNSUPPORTED_SOURCE_IN_MEMORY: String = "PLAN_WIRE_UNSUPPORTED_SOURCE_IN_MEMORY"
comptime PLAN_WIRE_UNSUPPORTED_HIVE_PARQUET: String = "PLAN_WIRE_UNSUPPORTED_HIVE_PARQUET"
comptime PLAN_WIRE_UNSUPPORTED_REMOTE_FS: String = "PLAN_WIRE_UNSUPPORTED_REMOTE_FS"
comptime PLAN_WIRE_UNSUPPORTED_UDF: String = "PLAN_WIRE_UNSUPPORTED_UDF"
# ⚠ NOT NAMED `PLAN_WIRE_UNSUPPORTED_UDF_*`, DELIBERATELY. The door classifies
# by `msg.startswith(token)`, so a token that EXTENDS another is a prefix pair,
# and a prefix pair mapped in the wrong order silently answers with the shorter
# token's code. Choosing a non-extending name means the invariant never has to
# be defended by arm ORDER.
comptime PLAN_WIRE_UDF_NOT_DESCRIBABLE: String = "PLAN_WIRE_UDF_NOT_DESCRIBABLE"
comptime PLAN_WIRE_UNSUPPORTED_TABLE_STATS: String = "PLAN_WIRE_UNSUPPORTED_TABLE_STATS"
comptime PLAN_WIRE_UNSUPPORTED_SCHEMALESS_SCAN: String = "PLAN_WIRE_UNSUPPORTED_SCHEMALESS_SCAN"
comptime PLAN_WIRE_UNSUPPORTED_ESTIMATED_GROUPS: String = "PLAN_WIRE_UNSUPPORTED_ESTIMATED_GROUPS"
comptime PLAN_WIRE_UNSUPPORTED_DTYPE: String = "PLAN_WIRE_UNSUPPORTED_DTYPE"
comptime PLAN_WIRE_UNSUPPORTED_ARROW_TYPE: String = "PLAN_WIRE_UNSUPPORTED_ARROW_TYPE"
comptime PLAN_WIRE_UNSUPPORTED_PARAM_TAG: String = "PLAN_WIRE_UNSUPPORTED_PARAM_TAG"
comptime PLAN_WIRE_MALFORMED: String = "PLAN_WIRE_MALFORMED"
# `PLAN_WIRE_VERSION_MISMATCH` is declared in `plan_wire_admit.mojo` and
# imported above — it is raised by the pass that runs BEFORE the parse, which is
# the only place a version gate is worth anything. Same for the three
# structural budgets. See that file for why.
comptime PLAN_WIRE_OUTPUT_SCHEMA_DIVERGED: String = "PLAN_WIRE_OUTPUT_SCHEMA_DIVERGED"

comptime PLAN_WIRE_WRITE_TARGET_DROPPED: String = "PLAN_WIRE_WRITE_TARGET_DROPPED"
"""★ `plan_from_bytes` RETURNS A `LogicalPlan`, AND A `LogicalPlan` CANNOT
EXPRESS A DESTINATION. So when the envelope carries one, this entry point
REFUSES rather than returning the plan without it.

⚠ THAT IS NOT DEFENSIVENESS, IT IS THE SAME REFUSAL AS CODE 36 ONE LAYER DOWN.
A caller that receives the plan and not the destination executes the query and
returns rows — correct rows, at a correct schema, with the user's file never
written and nothing raised anywhere. The return type is what loses the
information, so the return type is where the refusal belongs.

`plan_envelope_from_bytes` is the entry point that CAN carry it, and every
caller that might meet a write envelope must use it."""

comptime PLAN_WIRE_UNSUPPORTED_WRITE_TARGET: String = (
    "PLAN_WIRE_UNSUPPORTED_WRITE_TARGET"
)
"""A `(format, compression)` pair with no file sink, or an empty destination.

⚠ THE PER-SPACE `*_from_wire` CHECKS CANNOT CATCH THIS, and that is why the
token exists. `WriteFormat` and `WriteCompression` are INDEPENDENT enums on the
wire: 3 x 5 = 15 encodable combinations against the 13 `SinkVariant` file arms.
A frontend in any language can author `(WFMT_CSV, WCOMP_SNAPPY)` from the
published vocabulary alone and both members validate — snappy is a Parquet PAGE
codec, not a whole-file wrapper, so the pair is what is invalid and neither
member is. `write_target_supported` is the one table that decides it, shared
with the SQL parser and with `plan_write._sink_tag_for`'s arm lookup.

The empty-path arm is here for a proto3 reason rather than a sink one: a
zero-length `string` is indistinguishable from an absent field, so `path: ""`
is the one value that is certainly not a destination and must not reach a
`sink_variant_for_tag` that would happily open it."""

# NO PLAN ORIENTATION. Every plan is columnar, so the format carries no
# orientation: `WirePlan` field 3 (`orientation_plus_one`) and its name are
# `reserved` in plan.proto, and its two wire values may never be reused.
#
# ⛔ KEEPING THE SLOT AND HARDCODING ITS VALUE IS NOT AN ALTERNATIVE.
# `test_every_wire_slot_can_be_wrong` would see it as an unobservable slot: an
# encoder that hardcodes a slot is byte-identical to one that carries it
# (CENSUS), and a slot no reader consults cannot be perturbed into a wrong
# answer (PERTURBATION). A dead slot on the wire is not free -- it is bytes
# spent to carry nothing, indistinguishable from a slot the codec drops.
#
# ⚠ OLDER BYTES STILL DECODE. proto3 skips an unknown field, so an envelope
# that carries field 3 lands as the same plan; that is why the number may
# never be reissued.


def _malformed(var what: String) -> Error:
    return Error(String(PLAN_WIRE_MALFORMED) + String(": ") + what^)


# `Optional[T]` presence as a plain Bool, one helper per T. Mojo has no
# generic-over-any-T `Optional` helper here that keeps the origin clean, and
# spelling `if o:` inline at each site would put a branch in the middle of a
# generated-struct constructor argument list.
def _present_str(o: Optional[String]) -> Bool:
    if o:
        return True
    return False


def _present_strs(o: Optional[List[String]]) -> Bool:
    if o:
        return True
    return False


def _present_int(o: Optional[Int]) -> Bool:
    if o:
        return True
    return False


def _present_schema(o: Optional[Schema]) -> Bool:
    if o:
        return True
    return False


def _present_expr(o: Optional[Expr]) -> Bool:
    if o:
        return True
    return False


def _present_expr_box(o: Optional[OwnedPointer[Expr]]) -> Bool:
    if o:
        return True
    return False


def _present_hive(o: Optional[PartitionPredicatePod]) -> Bool:
    if o:
        return True
    return False


def _col_ref_of_side(var name: String, side: UInt8) raises -> Expr:
    """`Expr` has THREE public col-ref factories, one per side, and no
    side-parameterised one. Branching here keeps the codec off `_col_ref`."""
    if side == COL_SIDE_NONE:
        return Expr.col_ref(name^)
    if side == COL_SIDE_LEFT:
        return Expr.left(name^)
    if side == COL_SIDE_RIGHT:
        return Expr.right(name^)
    raise _malformed("EXPR_COL_REF with COL_SIDE " + String(Int(side)))  # cov: unreachable the vocabulary's from_wire already refused an undeclared value


# =============================================================================
# DType — the one space with no numeric identity in the Mojo stdlib
# =============================================================================
#
# `DType` is an opaque MLIR-backed type; it has no stable integer. Deriving
# `Field.dtype` from `Field.arrow_type` at decode is NOT equivalent —
# `ArrowType.from_dtype(DType.index)` folds onto INT64, so the round trip
# would silently retype an index column. An explicit table that RAISES on an
# unmapped DType is the only total answer.
#
# ★ THESE NUMBERS ARE PUBLISHED, AND THEY ARE NAMED.
# The generated plan vocabulary DERIVES the `DTypeCode` proto enum from
# these very `comptime` lines, so `plan_vocabulary.proto` carries
# `_DT_INT64 = 5` and a Python or TypeScript reader decodes `dtype_code: _DT_INT64`
# instead of a bare `5` it has nowhere to look up. Adding a constant here adds
# a member there; MOVING or reusing one is never allowed, because a published
# number is part of the format.
#
# ⚠ THE MOJO SIDE IS STILL HAND-WRITTEN BELOW, DELIBERATELY. The generated
# `*_from_wire` shape RAISES on wire 0, and `_DT_INVALID` IS wire 0 — a legal,
# reachable code (`cast_to_decimal` produces `DType.invalid`). So the space is
# `emit_proto=True, emit_mojo=False`: the enum is for the four languages that
# bind to the schema; the refusal stays here, where 0 is accepted and
# everything unknown raises PLAN_WIRE_UNSUPPORTED_DTYPE.

comptime _DT_INVALID: UInt32 = 0
comptime _DT_BOOL: UInt32 = 1
comptime _DT_INT8: UInt32 = 2
comptime _DT_INT16: UInt32 = 3
comptime _DT_INT32: UInt32 = 4
comptime _DT_INT64: UInt32 = 5
comptime _DT_UINT8: UInt32 = 6
comptime _DT_UINT16: UInt32 = 7
comptime _DT_UINT32: UInt32 = 8
comptime _DT_UINT64: UInt32 = 9
comptime _DT_FLOAT16: UInt32 = 10
comptime _DT_FLOAT32: UInt32 = 11
comptime _DT_FLOAT64: UInt32 = 12
# 13 is RESERVED for DType.index. `DType` as of Mojo 1.0.0b2 had no `index`
# member (an observation about that toolchain version), so there is
# nothing to map — but the code is burned so a future stdlib that adds it
# cannot silently take a number already in use.


def _dtype_to_wire(d: DType) raises -> DTypeCode:
    """The codec's DType code, as the `DTypeCode` proto enum.

    ⚠ RETURNS THE NEWTYPE, NOT `UInt32`, SO THE WRAP LIVES IN ONE PLACE.
    The four wire fields that carry a DType code (`WireField.dtype_code`,
    `WireScalar.dtype_code` / `null_dtype_code`, `WireCast.target_dtype_code`)
    are `DTypeCode` in `plan.proto`. Wrapping at each of the
    eight call sites instead would put the transport type in eight places and
    let one of them drift to a bare integer without anything noticing.
    """
    if d == DTYPE_NONE:
        return DTypeCode(Int(_DT_INVALID))
    if d == DType.bool:
        return DTypeCode(Int(_DT_BOOL))
    if d == DType.int8:
        return DTypeCode(Int(_DT_INT8))
    if d == DType.int16:
        return DTypeCode(Int(_DT_INT16))
    if d == DType.int32:
        return DTypeCode(Int(_DT_INT32))
    if d == DType.int64:
        return DTypeCode(Int(_DT_INT64))
    if d == DType.uint8:
        return DTypeCode(Int(_DT_UINT8))
    if d == DType.uint16:
        return DTypeCode(Int(_DT_UINT16))
    if d == DType.uint32:
        return DTypeCode(Int(_DT_UINT32))
    if d == DType.uint64:
        return DTypeCode(Int(_DT_UINT64))
    if d == DType.float16:
        return DTypeCode(Int(_DT_FLOAT16))
    if d == DType.float32:
        return DTypeCode(Int(_DT_FLOAT32))
    if d == DType.float64:
        return DTypeCode(Int(_DT_FLOAT64))
    raise Error(
        PLAN_WIRE_UNSUPPORTED_DTYPE + ": the codec has no wire code for DType '"
        + String(d) + "'. Add one beside the others; do NOT derive it from"
        + " arrow_type — deriving it is lossy for any DType whose"
        + " ArrowType.from_dtype folds onto another."
    )


def _dtype_from_wire(c: DTypeCode) raises -> DType:
    """The inverse, taking the `DTypeCode` proto enum.

    ⚠ ACCEPTS WIRE 0. `_DT_INVALID` is a REACHABLE code — `cast_to_decimal`
    sets `DType.invalid` — which is exactly why `DTypeCode` emits no generated
    Mojo: the generated `*_from_wire` shape raises on wire 0 unconditionally.
    Everything this table has no DType for still raises, by name.

    ⚠ AND THE ENUM BEING OPEN IS WHY THAT REFUSAL STILL MATTERS. proto3
    PRESERVES an unrecognised enum value in the field rather than discarding
    it, so a future producer's `_DT_INDEX = 13` arrives here intact and is
    REFUSED rather than silently read as something else.
    """
    var w = UInt32(c.number())
    if w == _DT_INVALID:
        return DTYPE_NONE
    if w == _DT_BOOL:
        return DType.bool
    if w == _DT_INT8:
        return DType.int8
    if w == _DT_INT16:
        return DType.int16
    if w == _DT_INT32:
        return DType.int32
    if w == _DT_INT64:
        return DType.int64
    if w == _DT_UINT8:
        return DType.uint8
    if w == _DT_UINT16:
        return DType.uint16
    if w == _DT_UINT32:
        return DType.uint32
    if w == _DT_UINT64:
        return DType.uint64
    if w == _DT_FLOAT16:
        return DType.float16
    if w == _DT_FLOAT32:
        return DType.float32
    if w == _DT_FLOAT64:
        return DType.float64
    raise Error(
        PLAN_WIRE_UNSUPPORTED_DTYPE + ": unknown DType wire code "
        + String(Int(w))
    )


# =============================================================================
# ArrowType — the ONE narrowing on the decode side, checked in one place
# =============================================================================
#
# ⚠ A DECODER DOES NOT CHOOSE ITS INPUT. `WireField` carries three `ArrowType`s
# and every one of them is a `uint32` on the wire and a `UInt8` in the engine:
# `arrow_type_id`, `dict_index_type_id`, and each element of `child_type_ids`.
# A bare `ArrowType(UInt8(Int(w.arrow_type_id)))` does not FAIL on 300 — it
# SUCCEEDS, at 44, and hands back a `Field` whose type its encoder never wrote.
# Nothing downstream can catch that: a binding's schema is compared to nothing,
# and `_dict_index_type` / `_child_types` are emitted by neither the plan
# render nor `_schema_text`, so LEG 1 and LEG 2 are both blind to them.
#
# ★ THE BOUND IS DERIVED, NOT WRITTEN HERE. `arrow_type_is_declared` comes out
# of the generated plan vocabulary's ArrowType space, whose members are generated
# from `arrow_types.mojo` itself. So this is a MEMBERSHIP check, not a range
# check — 50 fits in a UInt8 and narrows losslessly, and is still not a type —
# and once `comptime NEW_TYPE = ArrowType(50)` is added to the engine and the
# vocabulary is regenerated from the engine's tag declarations, it is admitted
# here with no edit to the codec.
#
# Fail-loud is the format's stated rule:
# A PLAN YOU CANNOT EXECUTE IS NOT A PLAN YOU MAY PARTIALLY EXECUTE.


def _arrow_type_from_wire(w: UInt32, where: String) raises -> ArrowType:
    """Narrow a wire `uint32` type id to an `ArrowType`, or RAISE by name.

    Args:
        w: The wire value, UNTRUSTED and full UInt32 range.
        where: The field being decoded, named in the error.

    Returns:
        The `ArrowType` the wire named.
    """
    if w > UInt32(255) or not arrow_type_is_declared(UInt8(Int(w))):
        raise Error(
            PLAN_WIRE_UNSUPPORTED_ARROW_TYPE + ": " + where + " carries Arrow"
            + " type id " + String(Int(w)) + ", which `arrow_types.mojo` does"
            + " not declare. Narrowing it into a UInt8 would not fail — it"
            + " would succeed at naming a DIFFERENT type, and a decoded plan"
            + " with a different schema is a silently wrong plan. If this is a"
            + " real new type, declare it in the engine and regenerate the"
            + " generated plan vocabulary from the engine's tag declarations."
        )
    return ArrowType(UInt8(Int(w)))


# =============================================================================
# Field / Schema
# =============================================================================


def _field_to_wire(f: Field) raises -> WireField:
    """TOTAL: every `var` on `Field` has a slot. A codec that can only express
    the states its public constructors can build is how a field gets silently
    dropped, and `Field` carries six such states."""
    var union_ids = List[Int64]()
    for i in range(len(f._union_type_ids)):
        union_ids.append(Int64(f._union_type_ids[i]))
    var child_types = List[UInt32]()
    for i in range(len(f._child_types)):
        child_types.append(UInt32(f._child_types[i]))
    return WireField(
        String(f.name),
        UInt32(f.arrow_type.type_id),
        _dtype_to_wire(f.dtype),
        f.nullable,
        Int64(f.decimal_precision),
        Int64(f.decimal_scale),
        String(f._tz),
        UInt32(f._dict_index_type.type_id),
        union_ids^,
        f._flags,
        f._metadata_keys.copy(),
        f._metadata_values.copy(),
        f._child_names.copy(),
        child_types^,
        f._child_nullables.copy(),
    )


def _field_from_wire(w: WireField) raises -> Field:
    var f = Field(
        String(w.name),
        _arrow_type_from_wire(
            w.arrow_type_id,
            "WireField '" + String(w.name) + "'.arrow_type_id",
        ),
        w.nullable,
    )
    # `Field`'s arrow ctor DERIVES `dtype`; the wire value is authoritative.
    f.dtype = _dtype_from_wire(w.dtype_code)
    f.decimal_precision = Int(w.decimal_precision)
    f.decimal_scale = Int(w.decimal_scale)
    f._tz = String(w.tz)
    f._dict_index_type = _arrow_type_from_wire(
        w.dict_index_type_id,
        "WireField '" + String(w.name) + "'.dict_index_type_id",
    )
    var union_ids = List[Int]()
    for i in range(len(w.union_type_ids)):
        union_ids.append(Int(w.union_type_ids[i]))
    f._union_type_ids = union_ids^
    f._flags = w.flags
    if len(w.metadata_keys) != len(w.metadata_values):
        raise _malformed(
            "WireField '" + String(w.name) + "': metadata keys/values differ in"
            + " length (" + String(len(w.metadata_keys)) + " vs "
            + String(len(w.metadata_values)) + ")"
        )
    f._metadata_keys = w.metadata_keys.copy()
    f._metadata_values = w.metadata_values.copy()
    if len(w.child_names) != len(w.child_type_ids) or len(
        w.child_names
    ) != len(w.child_nullables):
        raise _malformed(
            "WireField '" + String(w.name) + "': the three child lists differ"
            + " in length"
        )
    var child_types = List[UInt8]()
    for i in range(len(w.child_type_ids)):
        child_types.append(
            _arrow_type_from_wire(
                w.child_type_ids[i],
                "WireField '" + String(w.name) + "'.child_type_ids["
                + String(i) + "]",
            ).type_id
        )
    f._child_names = w.child_names.copy()
    f._child_types = child_types^
    f._child_nullables = w.child_nullables.copy()
    return f^


def _schema_to_wire(s: Schema) raises -> WireSchema:
    """TOTAL: the field list AND the TABLE-level kv metadata.

    ⚠ `Schema._metadata_keys` / `_metadata_values` are NOT `Field`'s pair of the
    same name. `Field`'s describes one column and rides on `WireField`; these
    describe THE TABLE. `SchemaBuilder` has no table-metadata channel, so a
    decoder that rebuilt through it alone would drop them on EVERY round trip,
    and the shared name is what would hide that: a coverage check that credits
    a field it finds by name in this file would see `_field_to_wire` name
    `f._metadata_keys` and call the table's pair carried."""
    var fields = List[WireField]()
    for i in range(s.num_columns()):
        fields.append(_field_to_wire(s.field_at(i)))
    return WireSchema(
        fields^, s._metadata_keys.copy(), s._metadata_values.copy()
    )


def _schema_from_wire(w: WireSchema) raises -> Schema:
    var b = SchemaBuilder()
    for i in range(len(w.fields)):
        b.add_field(_field_from_wire(w.fields[i]))
    var s = b.build()
    # `SchemaBuilder` carries the PER-FIELD metadata and has no channel for the
    # table's own, so the pair is restored onto the built Schema directly —
    # the same shape `_field_from_wire` uses for `Field`'s pair.
    if len(w.metadata_keys) != len(w.metadata_values):
        raise _malformed(
            "WireSchema: table-level metadata keys/values differ in length ("
            + String(len(w.metadata_keys)) + " vs "
            + String(len(w.metadata_values)) + ")"
        )
    # ⚠ AND THE KEYS MUST BE UNIQUE. The length check above is not the only
    # discipline `Schema` has: `set_metadata` is an
    # UPSERT — it rewrites a key it already holds — so NO engine path can build
    # a schema whose key list repeats, and `get_metadata` / `has_metadata`
    # answer from the FIRST match. Assigning the lists directly bypassed that,
    # so a message carrying one key twice decoded into a `Schema` the engine
    # cannot construct and whose second value is unreachable by every accessor.
    # Refused by name for the same reason the length mismatch is: accepting it
    # invents a schema, and silently dropping the duplicate truncates the
    # writer's metadata — the failure the length check exists to prevent.
    for i in range(len(w.metadata_keys)):
        for j in range(i + 1, len(w.metadata_keys)):
            if w.metadata_keys[i] == w.metadata_keys[j]:
                raise _malformed(
                    "WireSchema: table-level metadata key '"
                    + w.metadata_keys[i] + "' appears twice, at positions "
                    + String(i) + " and " + String(j)
                    + ". Schema.set_metadata is an upsert, so this schema has"
                    + " no constructor, and get_metadata would answer from the"
                    + " first pair only."
                )
    s._metadata_keys = w.metadata_keys.copy()
    s._metadata_values = w.metadata_values.copy()
    return s^


def _opt_schema_from_wire(
    w: Optional[WireSchema], what: String
) raises -> Schema:
    if not w:
        raise _malformed(what + ": the schema message is absent")
    return _schema_from_wire(w.value())


# =============================================================================
# ScalarValue
# =============================================================================


def _scalar_to_wire(v: ScalarValue) raises -> WireScalar:
    """TOTAL: 19 `var`s, 19 slots. The struct is a flat union whose live arm is
    (`_kind`, `dtype`); every other slot is zero, and proto3 omits zeros, so
    totality is free on the wire.

    THE ENUM SLOTS GO THROUGH THE DERIVED VOCABULARY, so encoding a kind or
    unit the engine does not declare RAISES here rather than writing bytes no
    reader can name."""
    return WireScalar(
        _dtype_to_wire(v.dtype),
        v.int_val,
        v.float_val,
        String(v.string_val),
        v.bool_val,
        ScalarKind(Int(scalar_kind_to_wire(v._kind))),
        v.dec128_high,
        v.dec128_low,
        Int64(v.dec128_precision),
        Int64(v.dec128_scale),
        v.date32_val,
        v.ts_micros,
        _dtype_to_wire(v.null_dtype),
        v.iv_months,
        v.iv_days,
        v.iv_nanos,
        ScalarTimeUnit(Int(scalar_time_unit_to_wire(v.time_unit))),
        v.dec256_high_lo,
        v.dec256_high_hi,
    )


def _scalar_from_wire(w: WireScalar) raises -> ScalarValue:
    """⚠ `kind` IS A DISCRIMINATOR, SO IT IS NEVER ASSIGNED UNCHECKED
    (`v._kind = UInt8(Int(w.kind))` would be the bug).

    `_kind` selects which of the struct's 17 payload fields is live, so an
    out-of-vocabulary kind would produce a ScalarValue that reads a field
    nothing wrote, with no arm-presence check to turn a perturbation into a
    refusal. Both enum slots go through the derived vocabulary, which
    validates the RANGE BEFORE the narrowing rather than after it."""
    var v = ScalarValue()
    v.dtype = _dtype_from_wire(w.dtype_code)
    v.int_val = w.int_val
    v.float_val = w.float_val
    v.string_val = String(w.string_val)
    v.bool_val = w.bool_val
    v._kind = scalar_kind_from_wire(Int32(w.kind.number()))
    v.dec128_high = w.dec128_high
    v.dec128_low = w.dec128_low
    v.dec128_precision = Int(w.dec128_precision)
    v.dec128_scale = Int(w.dec128_scale)
    v.date32_val = w.date32_val
    v.ts_micros = w.ts_micros
    v.null_dtype = _dtype_from_wire(w.null_dtype_code)
    v.iv_months = w.iv_months
    v.iv_days = w.iv_days
    v.iv_nanos = w.iv_nanos
    v.time_unit = scalar_time_unit_from_wire(Int32(w.time_unit.number()))
    v.dec256_high_lo = w.dec256_high_lo
    v.dec256_high_hi = w.dec256_high_hi
    return v^


# =============================================================================
# PartitionFrame — the payload SHARED by WindowFnData and PartitionExpr
# =============================================================================
#
# ⚠ NO RENDER READS ANY OF THE FIVE, ON ANY ARM, AT ANY VALUE. `Expr.write_to`'s
# WINDOW_FN arm prints func / col / offset and the two list LENGTHS;
# `plan_display`'s PartitionBy arm prints the key names and a `<n> funcs` COUNT
# and never descends into a `PartitionExpr` at all. `_infer_expr_field` has no
# WINDOW_FN arm, and `partition_expr_output_field` reads func / column /
# has_default / alias_name. So LEG 1 and LEG 2 are blind to the frame
# everywhere, and the IR-equality leg is the only thing that can see one go.
#
# ⚠ AND IT LOOKS DERIVABLE, WHICH IS THE HAZARD. Every `ColExpr` window factory
# passes `PartitionFrame.default_ordered()` or `_rolling_frame(n)`, so a
# decoder that re-derived the frame from `func` and `arg_offset` would be
# indistinguishable from a correct one over everything the fluent surface
# builds — and would silently rewrite every frame built through the public
# `PartitionExpr.agg_with_frame` / `.with_frame(...)`. Carried, never derived.


def _frame_to_wire(f: PartitionFrame) raises -> WireFrame:
    """TOTAL: five `var`s, five slots. Both tag spaces go through the derived
    vocabulary, so an undeclared bound RAISES rather than writing bytes no
    reader can name."""
    return WireFrame(
        FrameUnits(Int(frame_units_to_wire(f.units))),
        FrameBound(Int(frame_bound_to_wire(f.start_tag))),
        Int64(f.start_offset),
        FrameBound(Int(frame_bound_to_wire(f.end_tag))),
        Int64(f.end_offset),
    )


def _frame_from_wire(o: Optional[WireFrame], where: String) raises -> PartitionFrame:
    """An ABSENT frame is REFUSED, not defaulted.

    `PartitionFrame` is a required part of both payloads that hold one, and
    proto3 cannot distinguish "absent" from "all zeros" for a message field
    except by presence — which is exactly why presence is read here. Defaulting
    to `default_ordered()` would turn a truncated message into a plan whose
    running aggregate silently became a full-partition one."""
    if not o:
        raise _malformed(where + " is absent; a window frame is not optional")
    ref w = o.value()
    return PartitionFrame(
        frame_units_from_wire(Int32(w.units.number())),
        frame_bound_from_wire(Int32(w.start_tag.number())),
        w.start_offset,
        frame_bound_from_wire(Int32(w.end_tag.number())),
        w.end_offset,
    )


def _tolerance_to_wire(t: AsofTolerance) raises -> WireAsofTolerance:
    """ALL THREE SLOTS, INCLUDING THE ONE `tag` DOES NOT SELECT.

    `AsofTolerance` is `@fieldwise_init` and public, so
    `AsofTolerance(tag=ASOF_TOL_INT64, int_val=5, float_val=2.5)` is a value
    the plan builder can construct — the two named factories (`int64`,
    `float64`) zero the other slot, and nothing enforces that they are the only
    producers. Carrying only the selected slot would make this codec a
    NORMALIZER, quietly rewriting a struct on its way through, and the render
    prints neither number so no other leg would ever say so."""
    return WireAsofTolerance(
        AsofToleranceKind(Int(asof_tolerance_kind_to_wire(t.tag))),
        t.int_val,
        t.float_val,
    )


def _tolerance_from_wire(
    o: Optional[WireAsofTolerance], where: String
) raises -> AsofTolerance:
    """An ABSENT tolerance is REFUSED, not defaulted to `none()`.

    Same argument as `_frame_from_wire`: `AsofJoinData.tolerance` is a
    NON-optional field, proto3 cannot tell an absent message from an all-zero
    one except by presence, and the two mean opposite things here. Defaulting
    would turn a truncated message into an UNBOUNDED as-of match — a join that
    executes and pairs rows arbitrarily far apart in time."""
    if not o:
        raise _malformed(
            where + " is absent; AsofJoinData.tolerance is not optional and an"
            + " absent one would decode as the unbounded match"
        )
    ref w = o.value()
    return AsofTolerance(
        asof_tolerance_kind_from_wire(Int32(w.kind.number())),
        w.int_val,
        w.float_val,
    )


# =============================================================================
# Expr
# =============================================================================


def _expr_to_wire(e: Expr) raises -> WireExpr:
    # ⚠ THE ENGINE TAG PICKS THE ARM AND IS NOT ITSELF WRITTEN. `WireExpr.tag`
    # was a second copy of "which arm is set" and is retired (see the block
    # above `message WireExpr` in plan.proto). `arm` below IS the discriminator.
    var tag = e.tag

    var col_ref: Optional[WireColRef] = None
    var col_idx: Optional[WireColIdx] = None
    var literal: Optional[WireScalar] = None
    var binary_op = List[WireBinaryOp]()
    var unary_op = List[WireUnaryOp]()
    var alias_ = List[WireAlias]()
    var in_list = List[WireInList]()
    var cast = List[WireCast]()
    var corr_subq = List[WireCorrelatedSubquery]()
    var when_ = List[WireWhen]()
    var agg_fn = List[WireAggFn]()
    var extract = List[WireExtract]()
    var math_fn = List[WireMathFn]()
    var math_fn2 = List[WireMathFn2]()
    var substring = List[WireSubstring]()
    var string_op = List[WireStringOp]()
    var string_fn = List[WireStringFn]()
    var string_fn_n = List[WireStringFnN]()
    var udf_call = List[WireUdfCall]()
    var regexp = List[WireRegexp]()
    var struct_field = List[WireStructField]()
    var struct_field_idx = List[WireStructFieldIdx]()
    var map_get = List[WireMapGet]()
    var json_extract = List[WireJsonExtract]()
    var window_fn: Optional[WireWindowFn] = None
    # Declared, not initialised: every branch below either assigns `arm` or
    # RAISES, so an initial value would be dead — which is exactly what the
    # compiler said ("assignment to 'arm' was never used").
    var arm: Int

    if tag == EXPR_COL_REF:
        arm = 1
        col_ref = Optional(
            WireColRef(
                e.col_ref_name(),
                ColSide(Int(col_side_to_wire(e.col_ref_side()))),
            )
        )
    elif tag == EXPR_COL_IDX:
        arm = 2
        col_idx = Optional(WireColIdx(Int64(e.col_idx_index())))
    elif tag == EXPR_LITERAL:
        arm = 3
        literal = Optional(_scalar_to_wire(e.literal_value()))
    elif tag == EXPR_BINARY_OP:
        arm = 4
        var bl = List[WireExpr]()
        bl.append(_expr_to_wire(e.binary_left()))
        var br = List[WireExpr]()
        br.append(_expr_to_wire(e.binary_right()))
        binary_op.append(
            WireBinaryOp(
                BinaryOp(Int(binary_op_to_wire(e.binary_op()))), bl^, br^
            )
        )
    elif tag == EXPR_UNARY_OP:
        arm = 5
        var uk = List[WireExpr]()
        uk.append(_expr_to_wire(e.unary_child()))
        unary_op.append(
            WireUnaryOp(UnaryOp(Int(unary_op_to_wire(e.unary_op()))), uk^)
        )
    elif tag == EXPR_ALIAS:
        arm = 6
        var ak = List[WireExpr]()
        ak.append(_expr_to_wire(e.alias_child()))
        alias_.append(WireAlias(ak^, e.alias_name()))
    elif tag == EXPR_IN_LIST:
        arm = 7
        var lk = List[WireExpr]()
        lk.append(_expr_to_wire(e.in_list_child()))
        var vals = List[WireScalar]()
        for i in range(e.in_list_len()):
            vals.append(_scalar_to_wire(e.in_list_values_ref()[i]))
        in_list.append(WireInList(lk^, vals^))
    elif tag == EXPR_CAST:
        arm = 8
        # ⚠ ALL SIX PARTS, AND FOUR OF THEM REACH NO RENDER. `write_to` emits
        # `Cast(<child>, <target>)`; `target_arrow`, the decimal pair and
        # `try_cast` are invisible to LEG 1 at EVERY value, so the IR-equality
        # leg is the only thing that can see one go missing. Deriving
        # `target_arrow` from `target` here instead of carrying it is the
        # `cast_preserving_arrow` bug, re-committed on the wire.
        var ck = List[WireExpr]()
        ck.append(_expr_to_wire(e.cast_child()))
        cast.append(
            WireCast(
                ck^,
                _dtype_to_wire(e.cast_target()),
                UInt32(Int(e.cast_target_arrow().type_id)),
                Int64(e.cast_decimal_precision()),
                Int64(e.cast_decimal_scale()),
                e.cast_is_try(),
            )
        )
    elif tag == EXPR_CORRELATED_SUBQUERY:
        arm = 9
        # ★ THE CROSS-EDGE. This is the ONE call that makes `_expr_to_wire` and
        # `_plan_to_wire` MUTUALLY RECURSIVE — every other expr arm recurses
        # only into exprs. It goes through `corr_subq_inner_plan_ref(e)` and not
        # through `_corr_subq` by hand precisely so that
        # `git grep corr_subq_inner_plan_ref` enumerates this codec among the
        # walks that cross it; the walk that did NOT appear in that grep
        # (`scan_binding_gate`) silently skipped every plan hanging off one.
        #
        # ⚠ THE RENDER STOPS AT THE INNER PLAN'S TAG. `Expr.write_to` prints
        # `inner_tag=<Int>` and does not recurse, so LEG 1 cannot tell two
        # different inner plans of the same root tag apart — and it prints
        # `outer_refs=#<count>`, not the names. The IR-equality leg is what
        # compares either.
        var cs_inner = List[WirePlan]()
        cs_inner.append(_plan_to_wire(corr_subq_inner_plan_ref(e)))
        corr_subq.append(
            WireCorrelatedSubquery(
                cs_inner^,
                e.corr_subq_outer_refs(),
                CorrelatedKind(
                    Int(correlated_kind_to_wire(e.corr_subq_kind()))
                ),
                e.corr_subq_in_lhs_col(),
                e.corr_subq_in_rhs_col(),
            )
        )
    elif tag == EXPR_WHEN:
        # ⚠ `arm` IS THE ONEOF'S ARM ORDINAL, NOT THE PROTO FIELD NUMBER. The
        # generated `_oneof0_case` counts arms from 1 in declaration order, so
        # `when` is field 11 and arm 10. Getting this wrong does not fail to
        # encode — it encodes the NEXT arm's `Optional`, which is empty, and
        # aborts the process inside the generated `encode` with
        # `Optional.value() called on empty Optional`).
        arm = 10
        # Every part of a CASE is carried explicitly, and none is re-derived.
        # LEG 2 is nearly blind to them — `_infer_expr_field` types a CASE as
        # the type of its FIRST THEN clause, so cases 1..n feed no output
        # schema — and the IR-equality leg is what holds the rest.
        #
        # ORDER IS SEMANTIC: a CASE returns the FIRST matching branch, so the
        # case list is a sequence, not a set.
        var cases = List[WireWhenCase]()
        for i in range(e.when_num_cases()):
            var cc = List[WireExpr]()
            cc.append(_expr_to_wire(e.when_case_condition_ref(i)))
            var cr = List[WireExpr]()
            cr.append(_expr_to_wire(e.when_case_result_ref(i)))
            cases.append(WireWhenCase(cc^, cr^))
        var dk = List[WireExpr]()
        dk.append(_expr_to_wire(e.when_default_ref()))
        when_.append(WireWhen(cases^, dk^))
    elif tag == EXPR_AGG_FN:
        # Arm ordinal, not field number — `agg_fn` is field 12 and arm 11.
        arm = 11
        # An aggregate used AS AN EXPRESSION — a different node from the
        # `AggExpr` an AGGREGATE plan node carries, and it appears where no
        # aggregate node exists (a predicate over a filter-of-aggregate, which
        # `optimizer_scalar_broadcast` rewrites). `op` goes through the SAME
        # `AggFn` vocabulary as `WireAggExpr.func`, deliberately: two encodings
        # of one engine space is the two-sources-of-truth problem one level
        # down, and AGG_SUM is engine value 0, which is exactly the value the
        # +1 wire offset exists to keep distinguishable from "absent".
        var gk = List[WireExpr]()
        gk.append(_expr_to_wire(e.agg_fn_child_ref()))
        agg_fn.append(
            WireAggFn(
                AggFn(Int(agg_fn_to_wire(e.agg_fn_op()))), gk^
            )
        )
    elif tag == EXPR_EXTRACT:
        # Arm ordinal, not field number — `extract` is field 13 and arm 12.
        arm = 12
        # ⚠ THE UNIT GOES THROUGH `extract_field_to_wire`, WHICH IS A
        # MEMBERSHIP TEST OVER TWO DISJOINT RUNS (0..6 and 16..25), not a
        # bound. An `ExtractData` built with unit 12 — reachable, because
        # `Expr.extract(unit, child)` and `Expr.date_trunc(unit, child)` both
        # take a raw `UInt8` — is REFUSED at encode rather than written as a
        # number the reader would have to invent a meaning for.
        var ek = List[WireExpr]()
        ek.append(_expr_to_wire(e.extract_child_ref()))
        extract.append(
            WireExtract(
                ExtractField(Int(extract_field_to_wire(e.extract_unit()))),
                ek^,
            )
        )
    elif tag == EXPR_MATH_FN:
        # Arm ordinal, not field number — `math_fn` is field 14 and arm 13.
        arm = 13
        var mk = List[WireExpr]()
        mk.append(_expr_to_wire(e.math_fn_child_ref()))
        math_fn.append(
            WireMathFn(MathFn1(Int(math_fn1_to_wire(e.math_fn_op()))), mk^)
        )
    elif tag == EXPR_MATH_FN2:
        # Arm ordinal, not field number — `math_fn2` is field 15 and arm 14.
        arm = 14
        # ⚠ TWO CHILDREN OF THE SAME TYPE IN A NON-COMMUTATIVE POSITION.
        # `atan2(y, x)` and `pow(base, exponent)` both change VALUE when their
        # operands swap, and neither the type system nor the output schema
        # (always FLOAT64) can tell. Writing `left` into the `right` slot is
        # therefore a silent wrong-answer bug, which is why the corpus never
        # gives this arm two equal operands.
        var lk = List[WireExpr]()
        lk.append(_expr_to_wire(e.math_fn2_left_ref()))
        var rk = List[WireExpr]()
        rk.append(_expr_to_wire(e.math_fn2_right_ref()))
        math_fn2.append(
            WireMathFn2(
                MathFn2(Int(math_fn2_to_wire(e.math_fn2_op()))), lk^, rk^
            )
        )
    elif tag == EXPR_SUBSTRING:
        # Arm ordinal, not field number — `substring` is field 16 and arm 15.
        arm = 15
        # ⚠ `length` DEFAULTS TO -1, NOT 0. `Expr.substring(child, start)` is
        # the two-argument SQL form and the engine spells "to end of string" as
        # a NEGATIVE length, so this is the one scalar arm whose
        # engine default is not the proto3 default. An encoder that dropped it
        # would turn every open-ended substring into a zero-length one — a plan
        # that quietly returns empty strings, not one that fails.
        var sk = List[WireExpr]()
        sk.append(_expr_to_wire(e.substring_child_ref()))
        substring.append(
            WireSubstring(
                sk^, Int64(e.substring_start()), Int64(e.substring_length())
            )
        )
    elif tag == EXPR_STRING_OP:
        # Arm ordinal, not field number — `string_op` is field 17 and arm 16.
        arm = 16
        # STR_CONTAINS is engine value 0, which is why `op` goes through the
        # offset-by-one vocabulary and not through a raw cast: a `contains`
        # written at wire 0 would be indistinguishable from a field nobody
        # wrote.
        var pk = List[WireExpr]()
        pk.append(_expr_to_wire(e.string_op_child_ref()))
        string_op.append(
            WireStringOp(
                StringOp(Int(string_op_to_wire(e.string_op_type()))),
                pk^,
                e.string_op_pattern(),
            )
        )
    elif tag == EXPR_REGEXP:
        # Arm ordinal, not field number — `regexp` is field 18 and arm 17.
        arm = 17
        # ⚠ ALL SEVEN PARTS, AND FOUR OF THEM ARE RENDERED *CONDITIONALLY* —
        # the third kind of render hole this file has met. `Expr.write_to`
        # prints `replacement` only when `op == REGEXP_REPLACE`, `group` only
        # for EXTRACT / EXTRACT_ALL, and `flags` / `group_name` only when
        # non-empty. So each of the four is covered by LEG 1 on SOME ops and
        # invisible on the rest, and `Expr.regexp(...)` — the total factory —
        # builds the invisible combinations happily. `_infer_expr_field` reads
        # only `op`, so LEG 2 is blind to all six others on every op. Nothing
        # here may be derived from anything else: `group_name` in particular is
        # resolved to an index only at EXECUTION time, by
        # `RegexProgram.group_index_for_name`, because the pattern is not
        # compiled until then.
        var rk = List[WireExpr]()
        rk.append(_expr_to_wire(e.regexp_child_ref()))
        regexp.append(
            WireRegexp(
                RegexpOp(Int(regexp_op_to_wire(e.regexp_op()))),
                rk^,
                e.regexp_pattern(),
                e.regexp_replacement(),
                e.regexp_flags(),
                Int64(e.regexp_group()),
                e.regexp_group_name(),
            )
        )
    elif tag == EXPR_STRUCT_FIELD:
        # Arm ordinal, not field number — `struct_field` is field 19, arm 18.
        arm = 18
        # THE BY-NAME HALF OF A BOUND TWIN, and it stays the by-name half. The
        # engine resolves this one by linear-scanning `_field_names` at eval
        # time; `EXPR_STRUCT_FIELD_IDX` below indexes `_children` directly. A
        # codec that "helpfully" resolved the name to an index at encode would
        # produce a plan that EXECUTES differently, and one that pinned a plan
        # to a schema it has not seen.
        var fk = List[WireExpr]()
        fk.append(_expr_to_wire(e.struct_field_parent_ref()))
        struct_field.append(
            WireStructField(fk^, e.struct_field_name())
        )
    elif tag == EXPR_STRUCT_FIELD_IDX:
        # Arm ordinal, not field number — field 20, arm 19.
        arm = 19
        # ⚠ THE INDEX IS SIGNED ON THE ENGINE (`StructFieldIdxData.field_idx`
        # is an `Int`) and is carried signed. It is NOT range-checked here:
        # `_infer_expr_field` has an explicit out-of-range arm that yields a
        # NULL placeholder and the eval arm raises with the parent's field
        # list, so an out-of-range index is a state the engine BUILDS and
        # diagnoses. Refusing it here would be this codec inventing a rule the
        # engine does not have — the same call the empty-CASE arm makes.
        var ik = List[WireExpr]()
        ik.append(_expr_to_wire(e.struct_field_idx_parent_ref()))
        struct_field_idx.append(
            WireStructFieldIdx(ik^, Int64(e.struct_field_index()))
        )
    elif tag == EXPR_MAP_GET:
        # Arm ordinal, not field number — field 21, arm 20.
        arm = 20
        # ⚠ TWO RECURSION BOXES OF THE SAME TYPE IN A NON-INTERCHANGEABLE
        # ORDER — the `MathFn2` trap in a new place. `map[key]` and `key[map]`
        # are both structurally valid messages, and the key may itself be a
        # whole expression (a literal for a constant key, a col_ref for a
        # per-row one), so nothing about the shape distinguishes them. The
        # corpus never gives this arm two equal children.
        var mpk = List[WireExpr]()
        mpk.append(_expr_to_wire(e.map_get_parent_ref()))
        var mkk = List[WireExpr]()
        mkk.append(_expr_to_wire(e.map_get_key_ref()))
        map_get.append(WireMapGet(mpk^, mkk^))
    elif tag == EXPR_JSON_EXTRACT:
        # Arm ordinal, not field number — field 22, arm 21.
        arm = 21
        # ★ `output_type` REACHES NO OTHER LEG AT ANY VALUE. The render prints
        # the parent, the path and the `->` / `->>` mode and stops, and
        # `_infer_expr_field` has NO EXPR_JSON_EXTRACT arm at all — the tag
        # falls through to the `else` and types as `ArrowType.NULL` — so LEG 2
        # sees the same thing whatever this field says. Both convenience
        # factories pin it to STRING, which is exactly what makes carrying it
        # necessary rather than redundant: a decoder that re-derived would be
        # indistinguishable on those factories' plans and would silently
        # truncate a typed `json_extract[Int64]`.
        #
        # ⚠ THE PATH IS CARRIED AS SEGMENTS. A path joined on `.` cannot
        # represent `["a.b"]` distinctly from `["a", "b"]`.
        var jk = List[WireExpr]()
        jk.append(_expr_to_wire(e.json_extract_parent_ref()))
        json_extract.append(
            WireJsonExtract(
                jk^,
                e.json_extract_path_segments(),
                UInt32(Int(e.json_extract_output_type().type_id)),
                e.json_extract_preserve_extension_metadata(),
            )
        )
    elif tag == EXPR_WINDOW_FN:
        # Arm ordinal, not field number — `window_fn` is field 23 and arm 22.
        arm = 22
        # ★ SEVEN PARTS, every one carried explicitly. `_infer_expr_field` has
        # no WINDOW_FN arm at all, so LEG 2 is blind to the whole node; the
        # IR-equality leg is what holds every value.
        #
        # ⚠ THE THREE LISTS ARE NOT PARALLEL. `descending` is per-ORDER-key and
        # `partition_by` is unrelated to both, so `len(descending)` may differ
        # from `len(order_by)` — `Expr.over(partition_by)` builds exactly that,
        # with order_by and descending both empty while partition_by is not.
        # Nothing here may be sized from anything else.
        ref wf = e.window_fn_data_ref()
        window_fn = Optional(
            WireWindowFn(
                WindowFn(Int(window_fn_to_wire(wf.func))),
                wf.arg_col.copy(),
                Int64(wf.arg_offset),
                Optional(_frame_to_wire(wf.frame)),
                wf.partition_by.copy(),
                wf.order_by.copy(),
                wf.descending.copy(),
            )
        )
    elif tag == EXPR_STRING_FN:
        # Arm ordinal, not field number — `string_fn` is field 24 and arm 23.
        arm = 23
        # STRFN_UPPER is engine value 0, which is why `op` goes through the
        # offset-by-one vocabulary and not through a raw cast — the same reason
        # as `string_op` two arms up. ⚠ AND HERE THE OP IS LOAD-BEARING FOR THE
        # OUTPUT TYPE, not just the value: dropping it renders a `length` as an
        # `upper`, which is an INT64 column decoded as a Utf8 one.
        var fk = List[WireExpr]()
        fk.append(_expr_to_wire(e.string_fn_child_ref()))
        string_fn.append(
            WireStringFn(
                StringFn(Int(string_fn_to_wire(e.string_fn_op()))), fk^
            )
        )
    elif tag == EXPR_STRING_FN_N:
        # Arm ordinal, not field number — `string_fn_n` is field 25, arm 24.
        arm = 24
        # ⚠ EVERY ARGUMENT IS WRITTEN, IN ORDER, AND THE COUNT IS NOT WRITTEN
        # ANYWHERE ELSE. `repeated` carries the count implicitly, by
        # occurrence — so there is no length field for a decoder to
        # cross-check against, and the only defence against a lost argument is
        # that `Expr.write_to` renders `n=` (see plan.proto's note on this
        # message). Loop over `string_fn_n_num_args()`, never over a
        # fixed-arity constant: this family's whole point is that its arity is
        # per-op and, for `concat`, unbounded.
        var sfnn_args = List[WireExpr]()
        for i in range(e.string_fn_n_num_args()):
            sfnn_args.append(_expr_to_wire(e.string_fn_n_arg_ref(i)))
        string_fn_n.append(
            WireStringFnN(
                StringFnN(Int(string_fn_n_to_wire(e.string_fn_n_op()))),
                sfnn_args^,
            )
        )
    elif tag == EXPR_UDF_CALL:
        # Arm ordinal, not field number — `udf_call` is field 26, arm 25.
        arm = 25
        # ⛔⛔ THE HANDLE IS NOT WRITTEN, AND THERE IS NOWHERE TO WRITE IT.
        # `UdfCallData.handle` is a slot+generation into a `UdfRegistry` that
        # exists in ONE process. This is not a field we choose to drop: the
        # message has four fields and none of them is a handle, so "forgot to
        # strip it" is UNSPELLABLE rather than merely wrong. A decoded node is
        # UNBOUND; the receiver re-mints by resolving `name` against its own
        # registry (`UdfRegistry.resolve_unique_by_name`).
        #
        # ⛔ AND A UDF WITH NO RESOLVABLE NAME IS REFUSED, NOT ENCODED. An
        # empty `name` is exactly what makes a UDF non-describable
        # (`UdfDescriptor.is_describable`), and a description no peer can
        # resolve is not a description. Same rule as `WireUdf`'s live-closure
        # refusal, one altitude down — and it is checked HERE rather than at
        # decode because refusing at ENCODE names the cause.
        if e.udf_call_name().byte_length() == 0:
            # ⚠ `PLAN_WIRE_UDF_NOT_DESCRIBABLE`, **NOT**
            # `PLAN_WIRE_UNSUPPORTED_EXPR_TAG`. The tag IS supported now — it
            # has an arm four lines up — so classifying this as an unsupported
            # tag would tell a frontend author to wait for a feature that
            # shipped. It is the identical condition `_udf_to_wire` refuses one
            # altitude up (`UdfData.is_describable()`, which is DERIVED from
            # the name), so it gets the identical token and the door maps it to
            # the identical code.
            raise Error(
                _udf_not_describable_message(
                    String("EXPR_UDF_CALL (`WireUdfCall`)")
                )
            )
        # ⚠ BOTH DTYPES RIDE — `UdfCallData.in_type` and `UdfCallData.out_type`,
        # each as a verbatim `ArrowType.type_id` — AND NEITHER IS DERIVED HERE.
        # `_run_one_udf_call`
        # compares both against the fingerprints the REGISTERED INSTANCE was
        # bound with; a decoder that re-derived them from the registry would
        # make that check compare a value to itself. Verbatim `type_id`, NOT
        # offset — the same convention as `WireCast.target_arrow_type_id`, and
        # `_arrow_type_from_wire` is the same membership check on the way back.
        var uck = List[WireExpr]()
        uck.append(_expr_to_wire(e.udf_call_child_ref()))
        udf_call.append(
            WireUdfCall(
                e.udf_call_name(),
                UInt32(Int(e.udf_call_in_type().type_id)),
                UInt32(Int(e.udf_call_out_type().type_id)),
                uck^,
            )
        )
    else:
        raise Error(
            PLAN_WIRE_UNSUPPORTED_EXPR_TAG + ": '"
            + _expr_tag_name(tag)
            + "' (engine tag " + String(Int(tag)) + ") has no message arm in"
            + " plan.proto. See the COVERAGE LEDGER at the top of"
            + " plan_wire_codec.mojo." + _missing_wire_artefact_hint(tag)
        )

    return WireExpr(
        arm, col_ref^, col_idx^, literal^, binary_op^, unary_op^,
        alias_^, in_list^, cast^, corr_subq^, when_^, agg_fn^, extract^,
        math_fn^, math_fn2^, substring^, string_op^, regexp^, struct_field^,
        struct_field_idx^, map_get^, json_extract^, window_fn^,
        string_fn^, string_fn_n^, udf_call^,
    )


def _expr_tag_name(tag: UInt8) -> String:
    """The wire name of an engine ExprTag, for a refusal message.

    Total, unlike `expr_tag_to_wire`: the tags these refusals are about
    include EXPR_BETWEEN and EXPR_SORT_KEY, whose wire numbers
    plan_vocabulary.proto reserves, and `expr_tag_to_wire` raises on them.
    Raising here would replace the PLAN_WIRE_UNSUPPORTED_EXPR_TAG refusal
    with the vocabulary's untokened one."""
    return expr_tag_wire_name(Int32(Int(tag)) + 1)


def _missing_wire_artefact_hint(tag: UInt8) -> String:
    """★ NAME THE MISSING ARTEFACT, NOT THE CONCEPT.

    The generic refusal above says a tag "has no message arm in plan.proto",
    which is true of every armless tag and actionable for none of them: it
    names the CONCEPT that is missing. A reader then has to work out what would
    have to exist for it to encode.

    ⛔ AND A REFUSAL THAT NAMES A CONCEPT CAN GO STALE WHILE STILL PASSING.
    A refusal that names the TAG becomes false the moment the tag exists but
    still cannot be encoded — the refusal still fires and nothing goes red,
    because "the tag does not exist" and "the tag cannot be encoded" are two
    facts and only one of them changed. A concept arrives in halves. An
    ARTEFACT does not: a message such as `WireUdfCall` either is in
    `plan.proto` or it is not.

    ⛔ The function is KEPT even while it holds no row: the next armless tag
    with a written-down blocker needs exactly this seam. A row must be deleted
    the moment its artefact exists, because a hint naming a missing artefact
    that is no longer missing is a lie.

    ⚠ TOTAL AND NON-RAISING. It runs INSIDE an error path; a hint that raised
    would replace the refusal it is decorating with its own.

    Returns "" for a tag with no recorded blocker — an empty hint is correct
    for "armless and nobody has written down why", and inventing an artefact
    name for one would be worse than saying nothing. Today EVERY armless tag is
    in that state: `EXPR_BETWEEN` and `EXPR_SORT_KEY` have no payload on `Expr`
    at all, so there is no artefact for either to be waiting on.
    """
    return String("")


def _expr_tag_of_arm(arm: Int) raises -> UInt8:
    """WHICH ENGINE TAG A SET `node` ARM MEANS — the whole discriminator.

    ⚠ THIS IS THE INVERSE OF `_expr_to_wire`'s LADDER, AND A DISAGREEMENT
    BETWEEN THEM IS A REFUSAL, NEVER A WRONG PLAN. Each decode branch guards its
    OWN arm (`if not w.cast: raise _malformed(...)`), so if this table ever said
    arm 8 meant EXPR_SUBSTRING while the encoder wrote arm 8 for EXPR_CAST, the
    substring branch would find no substring payload and raise by name. The
    round trip is what pins the pair positively: every one of the arms has a
    named round-trip test in `tests/test_plan_wire_round_trip_ir.mojo`, and
    a mismatched arm decodes into a different node kind, which the IR leg sees.

    `arm == 0` is "no arm set". Under the OLD format that state was reachable
    with a tag beside it and the tag decided; now it is a message that does not
    say what it is, and it is refused."""
    if arm == 1:
        return EXPR_COL_REF
    if arm == 2:
        return EXPR_COL_IDX
    if arm == 3:
        return EXPR_LITERAL
    if arm == 4:
        return EXPR_BINARY_OP
    if arm == 5:
        return EXPR_UNARY_OP
    if arm == 6:
        return EXPR_ALIAS
    if arm == 7:
        return EXPR_IN_LIST
    if arm == 8:
        return EXPR_CAST
    if arm == 9:
        return EXPR_CORRELATED_SUBQUERY
    if arm == 10:
        return EXPR_WHEN
    if arm == 11:
        return EXPR_AGG_FN
    if arm == 12:
        return EXPR_EXTRACT
    if arm == 13:
        return EXPR_MATH_FN
    if arm == 14:
        return EXPR_MATH_FN2
    if arm == 15:
        return EXPR_SUBSTRING
    if arm == 16:
        return EXPR_STRING_OP
    if arm == 17:
        return EXPR_REGEXP
    if arm == 18:
        return EXPR_STRUCT_FIELD
    if arm == 19:
        return EXPR_STRUCT_FIELD_IDX
    if arm == 20:
        return EXPR_MAP_GET
    if arm == 21:
        return EXPR_JSON_EXTRACT
    if arm == 22:
        return EXPR_WINDOW_FN
    if arm == 23:
        return EXPR_STRING_FN
    if arm == 24:
        return EXPR_STRING_FN_N
    if arm == 25:
        return EXPR_UDF_CALL
    if arm == 0:
        raise _malformed(
            "a WireExpr with NO `node` arm set. The arm IS the node kind — the"
            + " retired `tag` field used to let a message name a kind it did"
            + " not carry, and this is that state, refused."
        )
    raise _malformed(  # cov: unreachable the generated decoder only assigns declared cases
        "a WireExpr whose `node` oneof case is " + String(arm) + ", which"  # cov: unreachable see the line above
        + " plan.proto does not declare. A decoder that guessed an arm here"  # cov: unreachable see the line above
        + " would build an expression nobody wrote."  # cov: unreachable see the line above
    )


def _expr_from_wire(w: WireExpr) raises -> Expr:
    # ⚠ THE ARM IS THE DISCRIMINATOR, AND THE ONLY ONE. `WireExpr.tag` is
    # retired: it was a total function of this same case ordinal, so a frontend
    # could state the kind twice and disagree with itself. See plan.proto.
    var tag = _expr_tag_of_arm(w._oneof0_case)
    if tag == EXPR_COL_REF:
        if not w.col_ref:
            raise _malformed("EXPR_COL_REF with no col_ref payload")  # cov: unreachable the generated decoder sets the oneof case with its payload
        var side = col_side_from_wire(Int32(w.col_ref.value().side.number()))
        return _col_ref_of_side(String(w.col_ref.value().name), side)
    if tag == EXPR_COL_IDX:
        if not w.col_idx:
            raise _malformed("EXPR_COL_IDX with no col_idx payload")  # cov: unreachable the generated decoder sets the oneof case with its payload
        return Expr.col_idx(Int(w.col_idx.value().index))
    if tag == EXPR_LITERAL:
        if not w.literal:
            raise _malformed("EXPR_LITERAL with no literal payload")  # cov: unreachable the generated decoder sets the oneof case with its payload
        return Expr.literal(_scalar_from_wire(w.literal.value()))
    if tag == EXPR_BINARY_OP:
        if len(w.binary_op) != 1:
            raise _malformed(  # cov: unreachable the generated decoder sets the oneof case with its payload
                "EXPR_BINARY_OP carries " + String(len(w.binary_op))  # cov: unreachable see the line above
                + " payloads; exactly 1 is legal"  # cov: unreachable see the line above
            )
        var b = w.binary_op[0].copy()
        if len(b.left) == 0 or len(b.right) == 0:
            raise _malformed("EXPR_BINARY_OP missing an operand")
        return Expr.binary(
            binary_op_from_wire(Int32(b.op.number())),
            _expr_from_wire(b.left[0]),
            _expr_from_wire(b.right[0]),
        )
    if tag == EXPR_UNARY_OP:
        if not w.unary_op:
            raise _malformed("EXPR_UNARY_OP with no unary_op payload")  # cov: unreachable the generated decoder sets the oneof case with its payload
        var u = w.unary_op[0].copy()
        if len(u.child) != 1:
            raise _malformed(
                "EXPR_UNARY_OP carries " + String(len(u.child))
                + " children; exactly 1 is legal"
            )
        return Expr.unary(
            unary_op_from_wire(Int32(u.op.number())),
            _expr_from_wire(u.child[0]),
        )
    if tag == EXPR_ALIAS:
        if not w.alias_:
            raise _malformed("EXPR_ALIAS with no alias payload")  # cov: unreachable the generated decoder sets the oneof case with its payload
        var a = w.alias_[0].copy()
        if len(a.child) != 1:
            raise _malformed(
                "EXPR_ALIAS carries " + String(len(a.child))
                + " children; exactly 1 is legal"
            )
        return Expr.alias(_expr_from_wire(a.child[0]), String(a.name))
    if tag == EXPR_IN_LIST:
        if not w.in_list:
            raise _malformed("EXPR_IN_LIST with no in_list payload")  # cov: unreachable the generated decoder sets the oneof case with its payload
        var l = w.in_list[0].copy()
        if len(l.child) != 1:
            raise _malformed(
                "EXPR_IN_LIST carries " + String(len(l.child))
                + " children; exactly 1 is legal"
            )
        var vals = List[ScalarValue]()
        for i in range(len(l.values)):
            vals.append(_scalar_from_wire(l.values[i]))
        return Expr.in_list_node(_expr_from_wire(l.child[0]), vals^)
    if tag == EXPR_CAST:
        if not w.cast:
            raise _malformed("EXPR_CAST with no cast payload")  # cov: unreachable the generated decoder sets the oneof case with its payload
        var c = w.cast[0].copy()
        if len(c.child) != 1:
            raise _malformed(
                "EXPR_CAST carries " + String(len(c.child))
                + " children; exactly 1 is legal"
            )
        # `cast_from_parts` and not one of the five query-facing factories:
        # every one of those DERIVES some of the six parts from the others, and
        # a decoder handed six values must produce the node they name. A
        # case-analysis over partial factories is not total — it fails on the
        # first combination none of them expresses (a TRY_CAST to DECIMAL, for
        # one).
        return Expr.cast_from_parts(
            _expr_from_wire(c.child[0]),
            _dtype_from_wire(c.target_dtype_code),
            _arrow_type_from_wire(
                c.target_arrow_type_id, String("WireCast.target_arrow_type_id")
            ),
            Int(c.decimal_precision),
            Int(c.decimal_scale),
            c.try_cast,
        )
    if tag == EXPR_CORRELATED_SUBQUERY:
        if not w.correlated_subquery:
            raise _malformed(  # cov: unreachable the generated decoder sets the oneof case with its payload
                "EXPR_CORRELATED_SUBQUERY with no correlated_subquery payload"  # cov: unreachable see the line above
            )
        var cs = w.correlated_subquery[0].copy()
        if not cs.inner_plan:
            raise _malformed(
                "EXPR_CORRELATED_SUBQUERY carries no inner_plan. A correlated"
                + " subquery whose inner plan is absent is not a smaller"
                + " subquery; it is not a subquery."
            )
        var kind = correlated_kind_from_wire(Int32(cs.kind.number()))
        # ⚠ THE ENGINE HAS NO FACTORY FOR (non-IN kind, non-empty IN columns),
        # so a decoder that accepted those bytes would have to silently drop
        # the columns or silently change the kind. Both are the fail-quiet
        # shape this format is built against, so it REFUSES instead. The
        # invariant is `CorrelatedSubqueryData`'s own: `in_lhs_col` /
        # `in_rhs_col` are populated ONLY for CORR_KIND_IN_CORRELATED.
        if kind == CORR_KIND_IN_CORRELATED:
            return Expr.in_correlated_subquery(
                _plan_from_wire(cs.inner_plan[0]),
                cs.outer_refs.copy(),
                String(cs.in_lhs_col),
                String(cs.in_rhs_col),
            )
        if cs.in_lhs_col.byte_length() > 0 or cs.in_rhs_col.byte_length() > 0:
            raise _malformed(
                "EXPR_CORRELATED_SUBQUERY of kind " + String(Int(kind))
                + " carries in_lhs_col='" + String(cs.in_lhs_col)
                + "' / in_rhs_col='" + String(cs.in_rhs_col) + "'. Those two"
                + " are populated ONLY for CORR_KIND_IN_CORRELATED, and no"
                + " engine factory can build the state these bytes describe."
            )
        return Expr.correlated_subquery(
            _plan_from_wire(cs.inner_plan[0]),
            cs.outer_refs.copy(),
            kind,
        )
    if tag == EXPR_WHEN:
        if not w.when:
            raise _malformed("EXPR_WHEN with no when payload")  # cov: unreachable the generated decoder sets the oneof case with its payload
        var wh = w.when[0].copy()
        var cases = List[WhenCaseData]()
        for i in range(len(wh.cases)):
            var c = wh.cases[i].copy()
            # ⚠ BOTH HALVES OR NEITHER. `WhenCaseData` has no state for "a
            # condition with no result" — its ctor takes two `Expr`s — so a
            # decoder handed a half-case can only invent one or drop the pair.
            # Both are the fail-quiet shape; it refuses instead.
            if len(c.condition) == 0 or len(c.result) == 0:
                raise _malformed(
                    "WireWhen.cases[" + String(i) + "] carries condition="
                    + String(len(c.condition) != 0) + " result="
                    + String(len(c.result) != 0) + ". A WHEN/THEN pair"
                    + " with one half missing is not a smaller CASE; there is"
                    + " no engine state for it."
                )
            cases.append(
                WhenCaseData(
                    _expr_from_wire(c.condition[0]),
                    _expr_from_wire(c.result[0]),
                )
            )
        # ⚠ ZERO CASES IS LEGAL AND IS NOT REFUSED. `WhenData.cases` is a plain
        # `List` and `_infer_expr_field` has an explicit no-cases branch that
        # types the node from `default`, so an empty CASE is a state the engine
        # can build — refusing it would be this codec inventing a rule the
        # engine does not have. An absent `default_expr` IS refused, by
        # `_one_expr`: `WhenData.default` is a non-Optional OwnedPointer.
        return Expr.when(
            cases^, _one_expr(wh.default_expr, "WireWhen.default_expr")
        )
    if tag == EXPR_AGG_FN:
        if not w.agg_fn:
            raise _malformed("EXPR_AGG_FN with no agg_fn payload")  # cov: unreachable the generated decoder sets the oneof case with its payload
        var af = w.agg_fn[0].copy()
        return Expr.agg_fn(
            agg_fn_from_wire(Int32(af.op.number())),
            _one_expr(af.child, "WireAggFn.child"),
        )
    if tag == EXPR_EXTRACT:
        if not w.extract:
            raise _malformed("EXPR_EXTRACT with no extract payload")  # cov: unreachable the generated decoder sets the oneof case with its payload
        var ex = w.extract[0].copy()
        # ⚠ MEMBERSHIP, NOT RANGE — THE SAME DISTINCTION THE ARROW-TYPE
        # NARROWING TURNS ON. `extract_field_from_wire` RAISES on wire 0 (an
        # absent proto3 enum) AND on any wire number whose engine value falls
        # in the 7..15 HOLE between the field run and the truncation run. Those
        # values narrow into a `UInt8` perfectly well; they are simply not
        # units, and a decoder that accepted one would build a `date_trunc` to
        # a period the engine has no arm for.
        return Expr.extract(
            extract_field_from_wire(Int32(ex.unit.number())),
            _one_expr(ex.child, "WireExtract.child"),
        )
    if tag == EXPR_MATH_FN:
        if not w.math_fn:
            raise _malformed("EXPR_MATH_FN with no math_fn payload")  # cov: unreachable the generated decoder sets the oneof case with its payload
        var mf = w.math_fn[0].copy()
        return Expr.math_fn(
            math_fn1_from_wire(Int32(mf.op.number())),
            _one_expr(mf.child, "WireMathFn.child"),
        )
    if tag == EXPR_MATH_FN2:
        if not w.math_fn2:
            raise _malformed("EXPR_MATH_FN2 with no math_fn2 payload")  # cov: unreachable the generated decoder sets the oneof case with its payload
        var m2 = w.math_fn2[0].copy()
        # BOTH BOXES, IN ORDER. `_one_expr` on each rather than one call over a
        # concatenation: the two slots are separate recursion boxes and a
        # message that filled one and left the other empty must be refused, not
        # silently re-associated into a unary node.
        return Expr.math_fn2(
            math_fn2_from_wire(Int32(m2.op.number())),
            _one_expr(m2.left, "WireMathFn2.left"),
            _one_expr(m2.right, "WireMathFn2.right"),
        )
    if tag == EXPR_SUBSTRING:
        if not w.substring:
            raise _malformed("EXPR_SUBSTRING with no substring payload")  # cov: unreachable the generated decoder sets the oneof case with its payload
        var sb = w.substring[0].copy()
        # ⚠ `Expr.substring`'s `length` PARAMETER HAS A DEFAULT OF -1 AND IT IS
        # PASSED EXPLICITLY HERE. Relying on the default would make the decoder
        # re-derive a value the wire carries — the `cast_preserving_arrow`
        # shape one arm over — and it would be invisible over any corpus whose
        # substrings happen to be open-ended.
        return Expr.substring(
            _one_expr(sb.child, "WireSubstring.child"),
            Int(sb.start),
            Int(sb.length),
        )
    if tag == EXPR_STRING_FN:
        if not w.string_fn:
            raise _malformed("EXPR_STRING_FN with no string_fn payload")  # cov: unreachable the generated decoder sets the oneof case with its payload
        var sf = w.string_fn[0].copy()
        return Expr.string_fn(
            string_fn_from_wire(Int32(sf.op.number())),
            _one_expr(sf.child, "WireStringFn.child"),
        )
    if tag == EXPR_STRING_FN_N:
        if not w.string_fn_n:
            raise _malformed("EXPR_STRING_FN_N with no string_fn_n payload")  # cov: unreachable the generated decoder sets the oneof case with its payload
        var sfn = w.string_fn_n[0].copy()
        # ⛔ THE ARITY IS CHECKED HERE, AGAINST `string_fn_n_arity`, BEFORE THE
        # NODE IS BUILT. `repeated` carries no length prefix, so a truncated
        # or over-long `args` decodes cleanly into a well-formed message that
        # is a MALFORMED EXPRESSION — `lpad` with two arguments, `replace`
        # with four. Refusing at the door names the wire as the culprit;
        # letting it through surfaces as a `PipelineCompiler:` error at
        # execution, pointing at the executor.
        var sfnn_op = string_fn_n_from_wire(Int32(sfn.op.number()))
        if not string_fn_n_arity_ok(sfnn_op, len(sfn.args)):
            raise _malformed(
                "EXPR_STRING_FN_N `" + string_fn_n_name(sfnn_op) + "` arrived"
                + " with " + String(len(sfn.args)) + " argument(s);"
                + " string_fn_n_arity says " + String(string_fn_n_arity(sfnn_op))
                + " (negative = variadic floor)"
            )
        var sfnn_args = List[Expr]()
        for i in range(len(sfn.args)):
            sfnn_args.append(_expr_from_wire(sfn.args[i]))
        return Expr.string_fn_n(sfnn_op, sfnn_args^)
    if tag == EXPR_UDF_CALL:
        # ★ THE DECODED NODE IS **UNBOUND**, AND
        # THAT IS THE CONTRACT RATHER THAN A LIMITATION.
        #
        # `Optional[Int](None)` is passed for the handle explicitly, and it is
        # the only value this decoder can pass: the wire carries no handle and
        # `WireUdfCall` has no field for one. `Expr.write_to` renders `h=-` for
        # it, which is what the round-trip corpus's `test_a_udf_call_arrives_
        # UNBOUND_however_it_was_encoded` asserts POSITIVELY — the strip is a
        # fact a test can see, not merely the absence of one.
        #
        # Re-minting is the RECEIVER's job and happens at ONE altitude, when
        # the UDF call executes, through `UdfRegistry.resolve_unique_by_name`.
        # That resolver REFUSES on an ambiguous name instead of picking.
        #
        # ⚠ THERE IS NO EARLIER CHECKPOINT. `komira_plan_endpoint` runs SIZE /
        # ADMIT / DECODE / EXECUTE and consults no registry, so the resolution
        # happens per BATCH during execution and an unresolvable name comes
        # back as PLAN_ENDPOINT_EXECUTION_FAILED(20), not as an early named
        # refusal. This decoder's whole argument for leaving a node UNBOUND is
        # that somebody downstream binds it, and that execution-time resolution
        # is the one cover — the thing an edit must not remove.
        #
        # ⛔ THIS DECODER DOES NOT AND MAY NOT TOUCH A REGISTRY. The codec is a
        # pure structural decode — protoc can serve as an independent oracle
        # for it — and a registry lookup in here would make the same bytes
        # decode differently in two processes.
        if not w.udf_call:
            raise _malformed("EXPR_UDF_CALL with no udf_call payload")  # cov: unreachable the generated decoder sets the oneof case with its payload
        var uc = w.udf_call[0].copy()
        # ⚠ THE EMPTY NAME IS REFUSED ON THE WAY IN TOO, NOT ONLY ON THE WAY
        # OUT. proto3 omits an empty string, so "never wrote the field" and
        # "wrote the empty string" are the same bytes — a hostile or truncated
        # message reaches here with `name == ""`, and a nameless UDF call is
        # one nothing can ever resolve. The encoder's refusal names the cause
        # for OUR producers; this one covers everybody else's.
        if uc.name.byte_length() == 0:
            raise _malformed(
                "EXPR_UDF_CALL carries an EMPTY name. The name is the ONLY"
                " thing a receiver can resolve against its own UdfRegistry —"
                " the handle is process-local and is not on the wire — so this"
                " node could never be bound to any function"
            )
        return Expr.udf_call(
            String(uc.name),
            Optional[Int](None),
            _arrow_type_from_wire(
                uc.in_arrow_type_id, String("WireUdfCall.in_arrow_type_id")
            ),
            _arrow_type_from_wire(
                uc.out_arrow_type_id, String("WireUdfCall.out_arrow_type_id")
            ),
            _one_expr(uc.child, "WireUdfCall.child"),
        )
    if tag == EXPR_STRING_OP:
        if not w.string_op:
            raise _malformed("EXPR_STRING_OP with no string_op payload")  # cov: unreachable the generated decoder sets the oneof case with its payload
        var so = w.string_op[0].copy()
        return Expr.string_op(
            string_op_from_wire(Int32(so.op.number())),
            _one_expr(so.child, "WireStringOp.child"),
            String(so.pattern),
        )
    if tag == EXPR_REGEXP:
        if not w.regexp:
            raise _malformed("EXPR_REGEXP with no regexp payload")  # cov: unreachable the generated decoder sets the oneof case with its payload
        var rx = w.regexp[0].copy()
        # `Expr.regexp` — the TOTAL factory — and not one of the ten
        # `regexp_*` ones. Every one of those PINS some subset of the seven
        # (`regexp_like` pins replacement="" and group=0; `regexp_replace`
        # pins group=0; `regexp_extract_named` pins group from the name), so a
        # case-analysis over them is not total: it fails on the first
        # combination none of them expresses, and `Expr.regexp` is public, so
        # those combinations are states the engine builds. Same call as
        # `cast_from_parts`.
        return Expr.regexp(
            regexp_op_from_wire(Int32(rx.op.number())),
            _one_expr(rx.child, "WireRegexp.child"),
            String(rx.pattern),
            String(rx.replacement),
            String(rx.flags),
            Int(rx.group),
            String(rx.group_name),
        )
    if tag == EXPR_STRUCT_FIELD:
        if not w.struct_field:
            raise _malformed("EXPR_STRUCT_FIELD with no struct_field payload")  # cov: unreachable the generated decoder sets the oneof case with its payload
        var sf = w.struct_field[0].copy()
        return Expr.struct_field(
            _one_expr(sf.parent, "WireStructField.parent"),
            String(sf.field_name),
        )
    if tag == EXPR_STRUCT_FIELD_IDX:
        if not w.struct_field_idx:
            raise _malformed(  # cov: unreachable the generated decoder sets the oneof case with its payload
                "EXPR_STRUCT_FIELD_IDX with no struct_field_idx payload"  # cov: unreachable see the line above
            )
        var sfi = w.struct_field_idx[0].copy()
        return Expr.struct_field_idx(
            _one_expr(sfi.parent, "WireStructFieldIdx.parent"),
            Int(sfi.field_idx),
        )
    if tag == EXPR_MAP_GET:
        if not w.map_get:
            raise _malformed("EXPR_MAP_GET with no map_get payload")  # cov: unreachable the generated decoder sets the oneof case with its payload
        var mg = w.map_get[0].copy()
        # BOTH BOXES, IN ORDER, `_one_expr` on each — the `MathFn2` discipline.
        # A message that filled `parent` and left `key` empty must be refused,
        # not silently re-read as a struct projection.
        return Expr.map_get(
            _one_expr(mg.parent, "WireMapGet.parent"),
            _one_expr(mg.key, "WireMapGet.key"),
        )
    if tag == EXPR_JSON_EXTRACT:
        if not w.json_extract:
            raise _malformed("EXPR_JSON_EXTRACT with no json_extract payload")  # cov: unreachable the generated decoder sets the oneof case with its payload
        var je = w.json_extract[0].copy()
        # ★ `json_extract_from_parts`, NOT `json_extract_json` /
        # `json_extract_string`. Both of those DERIVE `output_type` (pinned to
        # STRING) and RE-PARSE the path out of a joined string, and both
        # derivations are exactly the fail-quiet shape: no other leg reads
        # `output_type` at any value, and re-parsing the JOINED string would
        # silently split a dot-bearing segment in two. ⚠ `parse_json_path`
        # CAN produce such a segment (`$."a.b"`), and that does NOT rescue a
        # joined form — joined on `.`, `["a.b"]` and `["a","b"]` are the same
        # string. The narrowing on the
        # type id is CHECKED by membership, the same way
        # `WireCast.target_arrow_type_id` is.
        var segs = List[String]()
        for i in range(len(je.path_segments)):
            segs.append(String(je.path_segments[i]))
        return Expr.json_extract_from_parts(
            _one_expr(je.parent, "WireJsonExtract.parent"),
            segs^,
            _arrow_type_from_wire(
                je.output_arrow_type_id,
                String("WireJsonExtract.output_arrow_type_id"),
            ),
            je.preserve_extension_metadata,
        )
    if tag == EXPR_WINDOW_FN:
        if not w.window_fn:
            raise _malformed("EXPR_WINDOW_FN with no window_fn payload")  # cov: unreachable the generated decoder sets the oneof case with its payload
        var wf = w.window_fn.value().copy()
        # `Expr.window_fn(...)` then `with_window_spec(...)` — the two-step is
        # the ONLY total path. The factory takes func / arg_col / arg_offset /
        # frame and pins the three lists EMPTY, and `.over(...)` is a family of
        # overloads each of which DERIVES the two it is not given
        # (`.over(partition_by)` pins order_by and descending to empty;
        # `.over("g")` pins all three from one string). `with_window_spec` is
        # the one that sets all three from what the wire says, so a message
        # whose `descending` is longer than its `order_by` — a state the public
        # surface builds and no leg but the IR one can see — survives.
        return Expr.window_fn(
            window_fn_from_wire(Int32(wf.func.number())),
            String(wf.arg_col),
            Int(wf.arg_offset),
            _frame_from_wire(wf.frame, String("WireWindowFn.frame")),
        ).with_window_spec(
            wf.partition_by.copy(), wf.order_by.copy(), wf.descending.copy()
        )
    # UNREACHABLE BY CONSTRUCTION and kept anyway: `_expr_tag_of_arm` returns
    # only the 22 tags the ladder above handles and raises on everything else,
    # so this line fires only if the two fall out of step — which is exactly
    # when a reader must hear about it rather than fall through.
    raise Error(  # cov: unreachable the if-chain above handles every tag its arm map returns
        PLAN_WIRE_UNSUPPORTED_EXPR_TAG + ": '"  # cov: unreachable see the line above
        + _expr_tag_name(tag)  # cov: unreachable see the line above
        + "' has no decode arm"  # cov: unreachable see the line above
    )


# =============================================================================
# AggExpr — FOUR SPARSE SLOTS, carried as four, not as a list
# =============================================================================
#
# `AggExpr.num_children()` stops at the FIRST empty slot, so a payload holding
# (child, None, child2, None) cannot be enumerated by walking. A `repeated`
# field would densify it and lose the arity. A validator that reads only
# slot 0 is the easy mistake this shape invites.


def _agg_expr_to_wire(a: AggExpr) raises -> WireAggExpr:
    var c0 = List[WireExpr]()
    var c1 = List[WireExpr]()
    var c2 = List[WireExpr]()
    var c3 = List[WireExpr]()
    if a.child:
        c0.append(_expr_to_wire(a.child.value()))
    if a.child1:
        c1.append(_expr_to_wire(a.child1.value()))
    if a.child2:
        c2.append(_expr_to_wire(a.child2.value()))
    if a.child3:
        c3.append(_expr_to_wire(a.child3.value()))
    var has_alias = _present_str(a.alias_name)
    var alias_text = String("")
    if has_alias:
        alias_text = String(a.alias_name.value())
    return WireAggExpr(
        AggFn(Int(agg_fn_to_wire(a.func))),
        _present_expr(a.child), c0^,
        _present_expr(a.child1), c1^,
        _present_expr(a.child2), c2^,
        _present_expr(a.child3), c3^,
        has_alias, alias_text^,
    )


def _agg_expr_from_wire(w: WireAggExpr) raises -> AggExpr:
    var c0: Optional[Expr] = None
    var c1: Optional[Expr] = None
    var c2: Optional[Expr] = None
    var c3: Optional[Expr] = None
    if w.has_child0:
        if len(w.child0) == 0:
            raise _malformed("WireAggExpr.has_child0 set with no child0")
        c0 = Optional(_expr_from_wire(w.child0[0]))
    if w.has_child1:
        if len(w.child1) == 0:
            raise _malformed("WireAggExpr.has_child1 set with no child1")
        c1 = Optional(_expr_from_wire(w.child1[0]))
    if w.has_child2:
        if len(w.child2) == 0:
            raise _malformed("WireAggExpr.has_child2 set with no child2")
        c2 = Optional(_expr_from_wire(w.child2[0]))
    if w.has_child3:
        if len(w.child3) == 0:
            raise _malformed("WireAggExpr.has_child3 set with no child3")
        c3 = Optional(_expr_from_wire(w.child3[0]))
    var alias_name: Optional[String] = None
    if w.has_alias_name:
        alias_name = Optional(String(w.alias_name))
    # `AggExpr` publishes a 1-slot and a 2-slot ctor and no 4-slot one. Slots
    # 2 and 3 are public `var`s, so the two remaining slots are assigned after
    # construction rather than reached through a private field.
    var a = AggExpr(
        agg_fn_from_wire(Int32(w.func.number())), c0^, c1^, alias_name^
    )
    a.child2 = c2^
    a.child3 = c3^
    return a^


# =============================================================================
# The scan leaf
# =============================================================================


def _params_to_wire(p: ScanParams) raises -> List[WireParam]:
    var out = List[WireParam]()
    for i in range(p.num_params()):
        var key = p.key_at(i)
        var v = p.value_at(i)
        var s = String("")
        var iv = Int64(0)
        var fv = Float64(0)
        if v.tag == PARAM_STR or v.tag == PARAM_BYTES:
            s = String(v.s)
        elif v.tag == PARAM_I64 or v.tag == PARAM_U64 or v.tag == PARAM_BOOL:
            iv = v.i
        elif v.tag == PARAM_F64:
            fv = v.f
        else:
            raise Error(
                PLAN_WIRE_UNSUPPORTED_PARAM_TAG + ": ScanParams key '" + key
                + "' carries tag " + String(Int(v.tag))
            )
        out.append(
            WireParam(key^, ParamTag(Int(param_tag_to_wire(v.tag))), s^, iv, fv)
        )
    return out^


def _params_from_wire(w: List[WireParam]) raises -> ScanParams:
    """⚠ VALIDATE BEFORE NARROWING, OR EVERY MULTIPLE OF 256 IS EXPLOITABLE.

    The naive shape is `var tag = UInt8(Int(e.tag))` followed by comparisons
    against the `PARAM_*` constants — the narrowing FIRST, the check on the
    RESULT. `e.tag` is an untrusted `uint32`, so 256 would become 0 and decode
    as `PARAM_STR`, 257 would become `PARAM_I64`, and so on: every out-of-range
    value aliases onto a legal one instead of reaching the `else` that raises.
    It is the same class as an unchecked `arrow_type_id` narrowing (300 -> 44,
    silently renaming a column's type).

    `param_tag_from_wire` checks the RANGE and the MEMBERSHIP before it
    narrows, so the refusal happens on the value that was actually written."""
    var p = ScanParams()
    for i in range(len(w)):
        var e = w[i].copy()
        var tag = param_tag_from_wire(Int32(e.tag.number()))
        var v: ParamValue
        if tag == PARAM_STR:
            v = ParamValue.of_str(String(e.s))
        elif tag == PARAM_BYTES:
            v = ParamValue.of_bytes(String(e.s))
        elif tag == PARAM_I64:
            v = ParamValue.of_i64(e.i)
        elif tag == PARAM_U64:
            v = ParamValue.of_u64(UInt64(e.i))
        elif tag == PARAM_BOOL:
            v = ParamValue.of_bool(e.i != Int64(0))
        elif tag == PARAM_F64:
            v = ParamValue.of_f64(e.f)
        else:
            raise Error(  # cov: unreachable the vocabulary's from_wire already refused an undeclared value
                PLAN_WIRE_UNSUPPORTED_PARAM_TAG + ": unknown param tag "  # cov: unreachable see the line above
                + String(Int(tag))  # cov: unreachable see the line above
            )
        p.put(String(e.key), v^)
    return p^


def _gate_to_wire(g: PushdownGate) raises -> WirePushdownGate:
    """⚠ `mode` GOES THROUGH THE VOCABULARY; `allowed_binary_ops` DOES NOT, AND
    MUST NOT. The first is an enumeration (REJECT_ALL / ACCEPT_ALL / SHAPED);
    the second is a BITMASK over the `GATE_OP_*` bit positions, where every
    32-bit value is meaningful. Offsetting a mask by one would make every
    stored gate mean something else — which is why the generator EXCLUDES
    `GATE_OP*` from the `PushdownGateMode` space rather than absorbing it."""
    return WirePushdownGate(
        PushdownGateMode(Int(pushdown_gate_mode_to_wire(g.mode))),
        g.allowed_binary_ops,
        g.allow_and_recurse,
        g.allow_in_list,
        g.require_stat_friendly_col,
    )


def _gate_from_wire(w: Optional[WirePushdownGate]) raises -> PushdownGate:
    if not w:
        raise _malformed("WireScanBinding: the pushdown_gate message is absent")
    var g = w.value().copy()
    return PushdownGate(
        pushdown_gate_mode_from_wire(Int32(g.mode.number())),
        g.allowed_binary_ops,
        g.allow_and_recurse,
        g.allow_in_list,
        g.require_stat_friendly_col,
    )


def _binding_to_wire(b: ScanBinding, variant_tag: UInt8) raises -> WireScanBinding:
    if b.stats:
        raise Error(
            PLAN_WIRE_UNSUPPORTED_TABLE_STATS + ": ScanBinding '" + b.name
            + "' carries TableStats. It is pure data and CAN be encoded; it"
            + " simply is not yet. Refused rather than dropped because stats"
            + " steer join order."
        )
    # THE SENTINEL IS A REAL, REACHABLE VALUE AND IS NOT IN THE VOCABULARY.
    # `legacy_source_type` defaults to `SCAN_LEGACY_SOURCE_TYPE_NONE = 255`,
    # which no `SOURCE_*` constant names, so `source_type_to_wire(255)` RAISES.
    # Carried as presence + value rather than mapped onto a SOURCE_* member,
    # which would silently retype every kind that declares none.
    var has_legacy = b.legacy_source_type != SCAN_LEGACY_SOURCE_TYPE_NONE
    var legacy_wire = Int32(0)
    if has_legacy:
        legacy_wire = source_type_to_wire(b.legacy_source_type)
    return WireScanBinding(
        b.kind_id,
        String(b.kind_name),
        String(b.name),
        _params_to_wire(b.params),
        Optional(_schema_to_wire(b.schema)),
        b.fingerprint,
        b.structural_id,
        Optional(_gate_to_wire(b.pushdown_gate)),
        b.pushdown_extra_cols.copy(),
        SnapshotPolicy(Int(snapshot_policy_to_wire(b.snapshot_policy))),
        b.snapshot_token,
        SourceOrientation(Int(source_orientation_to_wire(b.orientation))),
        has_legacy,
        SourceType(Int(legacy_wire)),
        SourceVariantTag(Int(source_variant_tag_to_wire(variant_tag))),
        False,
    )


def _binding_from_wire(w: WireScanBinding) raises -> ScanBinding:
    """⚠ THE DECODED BINDING IS UNBOUND, ALWAYS.

    `handle` and `registry_epoch` are NOT on the wire — a handle is an index
    into a registry that exists in ONE process, and carrying it would let a
    decoded plan name a slot in a registry that never existed. `SCAN_HANDLE_
    UNBOUND` / `SCAN_EPOCH_NONE` are the ctor defaults and are exactly what
    `scan_binding_gate.check_plan_scan_bindings` treats as the safe case
    (an UNBOUND binding passes)."""
    if w.has_stats:
        raise Error(
            PLAN_WIRE_UNSUPPORTED_TABLE_STATS + ": decoded ScanBinding '"
            + String(w.name) + "' claims stats the wire cannot carry"
        )
    return ScanBinding(
        kind_id=w.kind_id,
        kind_name=String(w.kind_name),
        name=String(w.name),
        params=_params_from_wire(w.params),
        schema=_opt_schema_from_wire(
            w.schema, "WireScanBinding '" + String(w.name) + "'"
        ),
        fingerprint=w.fingerprint,
        structural_id=w.structural_id,
        gate=_gate_from_wire(w.pushdown_gate),
        snapshot_policy=snapshot_policy_from_wire(
            Int32(w.snapshot_policy.number())
        ),
        snapshot_token=w.snapshot_token,
        orientation=source_orientation_from_wire(
            Int32(w.orientation.number())
        ),
        legacy_source_type=_legacy_source_type_from_wire(w),
        pushdown_extra_cols=w.pushdown_extra_cols.copy(),
    )


def _legacy_source_type_from_wire(w: WireScanBinding) raises -> UInt8:
    if not w.has_legacy_source_type:
        return SCAN_LEGACY_SOURCE_TYPE_NONE
    return source_type_from_wire(Int32(w.legacy_source_type.number()))


def _write_cloud_scheme_of[W: Writer](mut writer: W, path: String):
    """WRITE what `_cloud_scheme_of` returns. ⚠ THIS WRITES; IT DOES NOT RETURN.

    The arms live here so no string constant is ever SELECTED and
    returned. A literal-returning ladder lowers to two parallel
    (pointer, length) constant arrays whose two call-site references
    an `--emit shared-lib` link binds INDEPENDENTLY; a shared library
    that binds such a pair CROSSED reads the wrong bytes and can crash
    the host process that loaded it."""
    if path.startswith("s3://"):
        writer.write(String("s3"))
        return
    if path.startswith("gs://"):
        writer.write(String("gs"))
        return
    if path.startswith("gcs://"):
        writer.write(String("gcs"))
        return
    if path.startswith("az://"):
        writer.write(String("az"))
        return
    if path.startswith("abfs://"):
        writer.write(String("abfs"))
        return
    if path.startswith("abfss://"):
        writer.write(String("abfss"))
        return
    writer.write(String(""))
    return


def _cloud_scheme_of(path: String) -> String:
    """The object-store URI scheme `path` names, or `""` for a local path.

    ⚠ ONLY the four schemes `FsDescriptorPod` can describe
    (`FS_SCHEME_{S3,GCS,AZURE}` + their spellings). A conservative list rather
    than "anything containing `://`", because a local path is allowed to
    contain odd characters and a false positive here REFUSES a plan that
    encodes correctly today.
    """
    var out = String()
    _write_cloud_scheme_of(out, path)
    return out^


def _parquet_to_wire(p: ParquetSource) raises -> WireParquetSource:
    if p.hive_dir_scan or p.hive_predicate:
        raise Error(
            PLAN_WIRE_UNSUPPORTED_HIVE_PARQUET + ": '" + p.path + "' is a"
            + " Hive-partitioned scan (hive_dir_scan="
            + String(p.hive_dir_scan) + ", hive_predicate="
            + String(_present_hive(p.hive_predicate)) + "). The partition"
            + " PREDICATE is a PartitionPredicatePod with no message arm yet."
        )
    if not p.fs_descriptor.is_local():
        raise Error(
            PLAN_WIRE_UNSUPPORTED_REMOTE_FS + ": '" + p.path + "' names a"
            + " non-local filesystem. FsDescriptorPod has no message arm yet."
        )
    # ⚠ THE DESCRIPTOR IS NOT THE ONLY WITNESS, AND ON ITS OWN IT IS NOT
    # SUFFICIENT.
    #
    # `ParquetSource.__init__` stamps `fs_descriptor = FsDescriptorPod.local()`
    # UNCONDITIONALLY, and only the `PlanCarrier` cloud seams ever call
    # `with_fs_descriptor(...cloud...)`. Every OTHER producer of a scan node
    # (for example `read_parquet(paths)`, or a caller that builds
    # `ParquetSource(path, schema)` directly) leaves the descriptor saying
    # LOCAL no matter what the path says.
    #
    # So without a second witness `read_parquet(["s3://bucket/x.parquet"])`
    # would encode with `fs_is_local = True`, and the receiver would decode a plan that is
    # structurally perfect and opens `s3://bucket/x.parquet` AS A LOCAL FILE —
    # which would not be a decode error, not the REMOTE_FS refusal the format
    # promises, and on a receiver whose local tree happens to hold that literal
    # name is WRONG ROWS rather than a failure.
    #
    # The PATH is the second witness and it is the one the producer cannot
    # forget to set. Both are checked; the descriptor arm stays first so a
    # correctly-descriptored cloud source still reports through it.
    for i in range(len(p.paths)):
        var scheme = _cloud_scheme_of(p.paths[i])
        if scheme != "":
            raise Error(
                PLAN_WIRE_UNSUPPORTED_REMOTE_FS + ": '" + p.paths[i] + "'"
                + " names the '" + scheme + "' object store, but the source's"
                + " FsDescriptorPod claims LOCAL. FsDescriptorPod has no"
                + " message arm yet, so encoding would emit fs_is_local=True"
                + " for a path the receiver cannot open locally — and would"
                + " read a LOCAL FILE OF THAT NAME if one exists. The scan"
                + " path is checked independently of the descriptor because"
                + " ParquetSource stamps the descriptor LOCAL by default and"
                + " only the two PlanCarrier cloud seams ever override it."
            )
    var pcols = List[WireField]()
    for i in range(len(p.partition_cols)):
        pcols.append(_field_to_wire(p.partition_cols[i]))
    var pvals = List[WirePartitionValueRow]()
    for i in range(len(p.partition_values)):
        pvals.append(WirePartitionValueRow(p.partition_values[i].copy()))
    var has_name = _present_str(p.name)
    var name_text = String("")
    if has_name:
        name_text = String(p.name.value())
    return WireParquetSource(
        p.paths.copy(),
        Optional(_schema_to_wire(p.schema_cached)),
        has_name,
        name_text^,
        p._mtime_ns,
        pcols^,
        pvals^,
        False,
        False,
        True,
    )


def _parquet_from_wire(w: WireParquetSource) raises -> ParquetSource:
    if w.hive_dir_scan or w.has_hive_predicate:
        raise Error(
            PLAN_WIRE_UNSUPPORTED_HIVE_PARQUET
            + ": decoded WireParquetSource claims Hive state the wire cannot"
            + " carry"
        )
    if not w.fs_is_local:
        raise Error(
            PLAN_WIRE_UNSUPPORTED_REMOTE_FS
            + ": decoded WireParquetSource claims a non-local filesystem"
        )
    if len(w.paths) == 0:
        raise _malformed("WireParquetSource with an empty path list")
    # ⚠ AND THE SAME SECOND WITNESS ON THE WAY IN — THIS ARM IS NOT SYMMETRY
    # FOR ITS OWN SAKE, IT COVERS A PRODUCER THIS FILE DOES NOT CONTROL.
    #
    # A producer in another language writes the protobuf directly and never
    # enters `_parquet_to_wire`, so the encoder-side check above cannot see
    # its bytes. One that sets `fs_is_local = True` from the path alone, with
    # no scheme check, emits a well-formed envelope whose scan path is
    # `s3://bucket/key` and whose `fs_is_local` says local.
    #
    # A decoder that trusted `fs_is_local` alone would hand the engine a LOCAL
    # scan of an object-store URI — not a decode error, and on a receiver that
    # happens to hold a local file of that literal name, WRONG ROWS. The
    # format's stated rule is that nothing is silently dropped; a scheme the
    # envelope cannot describe is exactly that.
    for i in range(len(w.paths)):
        var scheme = _cloud_scheme_of(w.paths[i])
        if scheme != "":
            raise Error(
                PLAN_WIRE_UNSUPPORTED_REMOTE_FS
                + ": decoded WireParquetSource says fs_is_local=true and its"
                + " path '" + w.paths[i] + "' names the '" + scheme + "'"
                + " object store. FsDescriptorPod has no message arm yet, so"
                + " there is no honest decoding of this pair — accepting it"
                + " would execute a LOCAL scan of an object-store URI."
            )
    # ⚠ THE SINGLE-PATH FAST PATH BELOW HAS NO SLOT FOR `partition_values`, SO
    # THE SHAPE THAT WOULD REACH IT WITH ONE IS REFUSED HERE RATHER THAN
    # DROPPED. `ParquetSource.partitioned` already refuses "values with no
    # columns" by name, so the multi-path branch was covered; the single-path
    # ctor is the ONE decode path where that engine invariant is not applied,
    # and it would DISCARD the rows with no diagnostic — a silent drop in a
    # format whose stated rule is that nothing is silently dropped. A row of
    # partition values with no partition columns to name them describes
    # nothing, and no encoder in this package produces it: it is exactly the version-skewed or
    # hostile input a decoder does not get to choose.
    if len(w.partition_cols) == 0 and len(w.partition_values) > 0:
        raise _malformed(
            "WireParquetSource carries " + String(len(w.partition_values))
            + " partition value row(s) and ZERO partition columns"
        )
    var schema = _opt_schema_from_wire(w.schema, "WireParquetSource")
    var name: Optional[String] = None
    if w.has_name:
        name = Optional(String(w.name))
    if len(w.paths) == 1 and len(w.partition_cols) == 0:
        return ParquetSource(
            String(w.paths[0]), schema^, name^, w.mtime_ns
        )
    var pcols = List[Field]()
    for i in range(len(w.partition_cols)):
        pcols.append(_field_from_wire(w.partition_cols[i]))
    var pvals = List[List[String]]()
    for i in range(len(w.partition_values)):
        pvals.append(w.partition_values[i].values.copy())
    return ParquetSource.partitioned(
        w.paths.copy(), schema^, pcols^, pvals^, name^, w.mtime_ns
    )


def _source_to_wire(s: SourceVariant) raises -> WireScanSource:
    if s.tag == SOURCE_VARIANT_IN_MEMORY:
        raise Error(
            PLAN_WIRE_UNSUPPORTED_SOURCE_IN_MEMORY + ": the scan leaf holds an"
            + " InMemorySource, i.e. ArcPointer[Slab[RecordBatch]] — LIVE HEAP"
            + " DATA INSIDE THE IR. There is nothing to encode: a plan"
            + " carrying this arm is a container OF the data, not a"
            + " description of work. It becomes encodable only once in-memory"
            + " scans are binding-backed."
        )
    if s.tag == SOURCE_VARIANT_PARQUET:
        # `SourceVariant` publishes `binding_ref()` for the open arm but has
        # NO accessor for the two concrete ones; `_parquet.value()` is the
        # established read (the core packages' own logical-plan derivation ladder
        # does exactly this). It disappears with the arm.
        return WireScanSource(
            1, Optional(_parquet_to_wire(s._parquet.value())), None
        )
    if s.is_binding_backed():
        return WireScanSource(
            2, None, Optional(_binding_to_wire(s.binding_ref(), s.tag))
        )
    raise Error(
        PLAN_WIRE_UNSUPPORTED_SOURCE_IN_MEMORY + ": SourceVariant tag "
        + String(Int(s.tag)) + " is neither parquet nor binding-backed"
    )


def _source_from_wire(w: Optional[WireScanSource]) raises -> SourceVariant:
    if not w:
        raise _malformed("WireScanNode: the source message is absent")
    var s = w.value().copy()
    if s._oneof0_case == 1:
        if not s.parquet:
            raise _malformed("WireScanSource case=parquet with no payload")  # cov: unreachable the generated decoder sets the oneof case with its payload
        return SourceVariant(_parquet_from_wire(s.parquet.value()))
    if s._oneof0_case == 2:
        if not s.binding:
            raise _malformed("WireScanSource case=binding with no payload")  # cov: unreachable the generated decoder sets the oneof case with its payload
        var tag = source_variant_tag_from_wire(
            Int32(s.binding.value().variant_tag.number())
        )
        return SourceVariant(
            tag=tag, binding=_binding_from_wire(s.binding.value())
        )
    raise _malformed(
        "WireScanSource with no oneof arm set (case="
        + String(s._oneof0_case) + ")"
    )


# =============================================================================
# LogicalPlan
# =============================================================================


def _partition_expr_to_wire(x: PartitionExpr) raises -> WirePartitionExpr:
    """TOTAL: seven `var`s, seven slots.

    ⚠ NO RENDER DESCENDS INTO ONE OF THESE. `plan_display`'s PartitionBy arm
    prints `<n> funcs` — a COUNT — so LEG 1 knows how many partition
    expressions a node has and nothing about any of them. LEG 2 sees four of
    the seven, lossily: `partition_expr_output_field` derives the output
    Field's name from `alias_name` (or from `func` and the expr index), its
    type from `func` and `column`, and its nullability from `func`, `column`
    and `has_default`. `offset`, `default_value` and the whole `frame` reach
    NEITHER leg at ANY value."""
    return WirePartitionExpr(
        WindowFn(Int(window_fn_to_wire(x.func))),
        x.column.copy(),
        Int64(x.offset),
        Optional(_scalar_to_wire(x.default_value)),
        x.has_default,
        Optional(_frame_to_wire(x.frame)),
        x.alias_name.copy(),
    )


def _partition_expr_from_wire(w: WirePartitionExpr) raises -> PartitionExpr:
    """The SEVEN-ARGUMENT ctor, not one of the eighteen factories.

    Every factory PINS some subset — `row_number()` pins column="" offset=0
    has_default=False frame=default_ordered() alias_name=""; `lag(col, n)` pins
    the last three; `agg_with_frame` pins offset and the default pair — so a
    case analysis over them is not total. It fails on the first combination
    none of them expresses, and `PartitionExpr(...)` plus `.with_alias(...)` /
    `.with_frame(...)` are public, so those combinations are states the engine
    builds. Same call as `cast_from_parts` and `Expr.regexp`.

    ★ `has_default` IS READ FROM THE WIRE, NEVER INFERRED FROM THE VALUE. The
    pair has three states, not two: absent (flag false, value the null
    `ScalarValue()`), present-and-null, and present-and-set. A codec that set
    the flag from "the value is non-null" would collapse the middle one — and
    `has_default` is the one field of the seven that reaches the output schema,
    because `partition_expr_output_field` makes LAG/LEAD non-nullable exactly
    when it is true. The collapse would therefore be a NULLABILITY flip on a
    NULL default, which LEG 2 would catch only for those two funcs."""
    if not w.default_value:
        raise _malformed(
            "WirePartitionExpr.default_value is absent; `PartitionExpr"
            ".default_value` is a non-optional ScalarValue and `has_default`"
            " is the separate presence flag"
        )
    return PartitionExpr(
        window_fn_from_wire(Int32(w.func.number())),
        String(w.column),
        Int(w.offset),
        _scalar_from_wire(w.default_value.value()),
        w.has_default,
        _frame_from_wire(w.frame, String("WirePartitionExpr.frame")),
        String(w.alias_name),
    )


def _plan_to_wire(p: LogicalPlan) raises -> WirePlan:
    # ⚠ Same as `_expr_to_wire`: the engine tag picks the ARM, and the arm is
    # the only thing written. `WirePlan.tag` is retired — see plan.proto.
    var tag = p.tag
    var out_schema = Optional(_schema_to_wire(p.output_schema))

    var scan = List[WireScanNode]()
    var filter = List[WireFilterNode]()
    var project = List[WireProjectNode]()
    var aggregate = List[WireAggregateNode]()
    var join = List[WireJoinNode]()
    var sort = List[WireSortNode]()
    var limit = List[WireLimitNode]()
    var distinct = List[WireDistinctNode]()
    var topn = List[WireTopNNode]()
    var union_all = List[WireUnionNode]()
    var partition_by = List[WirePartitionByNode]()
    var partition_topn = List[WirePartitionTopNNode]()
    var asof_join = List[WireAsofJoinNode]()
    var view_ref: Optional[WireViewRefNode] = None
    var cse_ref: Optional[WireCseRefNode] = None
    var cast_to_varchar = List[WireCastToVarcharNode]()
    # Same as `_expr_to_wire`: every branch assigns or raises.
    var arm: Int

    if tag == PLAN_SCAN:
        arm = 1
        ref d = p.scan_data_ref()
        if d.table_stats:
            raise Error(
                PLAN_WIRE_UNSUPPORTED_TABLE_STATS + ": ScanData for '"
                + d.source_path + "' carries TableStats"
            )
        var sch_present = _present_schema(d.schema)
        var sch: Optional[WireSchema] = None
        if sch_present:
            sch = Optional(_schema_to_wire(d.schema.value()))
        var proj_present = _present_strs(d.projection)
        var proj = List[String]()
        if proj_present:
            proj = d.projection.value().copy()
        var filt_present = _present_expr(d.filter)
        var filt = List[WireExpr]()
        if filt_present:
            filt.append(_expr_to_wire(d.filter.value()))
        var rc_present = _present_int(d.row_count)
        var rc = Int64(0)
        if rc_present:
            rc = Int64(d.row_count.value())
        scan.append(
            WireScanNode(
                Optional(_source_to_wire(d.source)),
                sch_present, sch^,
                proj_present, proj^,
                filt_present, filt^,
                rc_present, rc,
                SourceOrientation(
                    Int(source_orientation_to_wire(d.source_kind))
                ),
                False,
            )
        )
    elif tag == PLAN_FILTER:
        arm = 2
        ref d = p.filter_data_ref()
        var f_udf: Optional[WireUdf] = None
        if d.udf:
            f_udf = Optional(_udf_to_wire(d.udf.value()[], "FilterData"))
        var pred = List[WireExpr]()
        pred.append(_expr_to_wire(d.predicate))
        var kid = List[WirePlan]()
        kid.append(_plan_to_wire(d.child[]))
        filter.append(WireFilterNode(pred^, kid^, Bool(d.udf), f_udf^))
    elif tag == PLAN_PROJECT:
        arm = 3
        ref d = p.project_data_ref()
        var pj_udf: Optional[WireUdf] = None
        if d.udf:
            pj_udf = Optional(_udf_to_wire(d.udf.value()[], "ProjectData"))
        var exprs = List[WireExpr]()
        for i in range(len(d.exprs)):
            exprs.append(_expr_to_wire(d.exprs[i]))
        var kid = List[WirePlan]()
        kid.append(_plan_to_wire(d.child[]))
        project.append(
            WireProjectNode(
                exprs^, kid^, d.is_cse_introduced, Bool(d.udf), pj_udf^
            )
        )
    elif tag == PLAN_AGGREGATE:
        arm = 4
        ref d = p.aggregate_data_ref()
        var ag_udf: Optional[WireUdf] = None
        if d.udf:
            ag_udf = Optional(_udf_to_wire(d.udf.value()[], "AggregateData"))
        var gb = List[WireExpr]()
        for i in range(len(d.group_by)):
            gb.append(_expr_to_wire(d.group_by[i]))
        var ax = List[WireAggExpr]()
        for i in range(len(d.agg_exprs)):
            ax.append(_agg_expr_to_wire(d.agg_exprs[i]))
        var kid = List[WirePlan]()
        kid.append(_plan_to_wire(d.child[]))
        var eg_present = Bool(d.estimated_groups.__bool__())
        var eg = Int64(0)
        if eg_present:
            eg = Int64(d.estimated_groups.value())
        aggregate.append(
            WireAggregateNode(
                gb^, ax^, kid^, eg_present, eg, Bool(d.udf), ag_udf^
            )
        )
    elif tag == PLAN_JOIN:
        arm = 5
        ref d = p.join_data_ref()
        var lk = List[WirePlan]()
        lk.append(_plan_to_wire(d.left[]))
        var rk = List[WirePlan]()
        rk.append(_plan_to_wire(d.right[]))
        var res_present = _present_expr_box(d.residual)
        var res = List[WireExpr]()
        if res_present:
            res.append(_expr_to_wire(d.residual.value()[]))
        join.append(
            WireJoinNode(
                lk^, rk^, d.left_on.copy(), d.right_on.copy(),
                JoinType(Int(join_type_to_wire(d.join_type))),
                JoinAlgo(Int(join_algo_to_wire(d.algo_hint))),
                res_present, res^,
            )
        )
    elif tag == PLAN_SORT:
        arm = 6
        ref d = p.sort_data_ref()
        var kid = List[WirePlan]()
        kid.append(_plan_to_wire(d.child[]))
        sort.append(
            WireSortNode(
                d.keys.copy(), d.descending.copy(), d.nulls_first.copy(), kid^
            )
        )
    elif tag == PLAN_LIMIT:
        arm = 7
        ref d = p.limit_data_ref()
        var kid = List[WirePlan]()
        kid.append(_plan_to_wire(d.child[]))
        limit.append(WireLimitNode(Int64(d.n), Int64(d.offset), kid^))
    elif tag == PLAN_DISTINCT:
        arm = 8
        ref d = p.distinct_data_ref()
        var cols_present = _present_strs(d.columns)
        var cols = List[String]()
        if cols_present:
            cols = d.columns.value().copy()
        var kid = List[WirePlan]()
        kid.append(_plan_to_wire(d.child[]))
        var eg_present = Bool(d.estimated_groups.__bool__())
        var eg = Int64(0)
        if eg_present:
            eg = Int64(d.estimated_groups.value())
        distinct.append(
            WireDistinctNode(cols_present, cols^, kid^, eg_present, eg)
        )
    elif tag == PLAN_TOPN:
        arm = 9
        ref d = p.topn_data_ref()
        var kid = List[WirePlan]()
        kid.append(_plan_to_wire(d.child[]))
        topn.append(
            WireTopNNode(
                d.keys.copy(), d.descending.copy(), d.nulls_first.copy(),
                Int64(d.n), kid^,
            )
        )
    elif tag == PLAN_UNION:
        arm = 10
        ref d = p.union_data_ref()
        var kids = List[WirePlan]()
        for i in range(len(d.children)):
            kids.append(_plan_to_wire(d.children[i][]))
        union_all.append(WireUnionNode(kids^))
    elif tag == PLAN_PARTITION_BY:
        # Arm ordinal, not field number — `partition_by` is field 14, arm 11.
        arm = 11
        # ⚠ THE RENDER PRINTS A COUNT WHERE THE PAYLOAD IS. `plan_display`
        # emits `PartitionBy(partition=[…], order=[…], <n> funcs)` — so LEG 1
        # covers the two key lists and knows only HOW MANY partition
        # expressions there are, never anything about one. `descending` is not
        # in the render at any value either. LEG 2 is the strongest leg on this
        # arm for once: the node's output schema is the child's plus one column
        # per expr, derived by `partition_expr_output_field`, so a dropped
        # `alias_name` or a shifted `func` is a schema diff.
        ref d = p.partition_by_data_ref()
        var pxs = List[WirePartitionExpr]()
        for i in range(len(d.partition_exprs)):
            pxs.append(_partition_expr_to_wire(d.partition_exprs[i]))
        var kid = List[WirePlan]()
        kid.append(_plan_to_wire(d.child[]))
        partition_by.append(
            WirePartitionByNode(
                d.partition_keys.copy(), d.order_keys.copy(),
                d.descending.copy(), pxs^, kid^,
            )
        )
    elif tag == PLAN_PARTITION_TOPN:
        # Arm ordinal, not field number — `partition_topn` is field 15, arm 12.
        arm = 12
        # ⚠ `over_fetch_k` IS THE STORED VALUE, NEVER THE `-1` SENTINEL.
        # `PartitionTopNData.__init__` resolves `over_fetch_k < 0` to `k` at
        # construction and the fuse-partition-topn pass passes `k + 16`
        # explicitly for RANK, so what is on the struct is the heap capacity
        # the engine will use. Re-passing the sentinel at decode would collapse
        # every fused RANK node's tie buffer back to `k` — a plan that executes
        # and drops tied rows, which is the worst kind.
        #
        # ⚠ THE RENDER NAMES ONLY TWO OF THE SIXTEEN FUNCS (`ROW_NUMBER` for 0,
        # `RANK` for 1, `FUNC_<n>` for the rest), so LEG 1 cannot tell PF_SUM
        # from PF_MIN here. The wire goes through the derived vocabulary, which
        # tests membership.
        ref d = p.partition_topn_data_ref()
        var kid = List[WirePlan]()
        kid.append(_plan_to_wire(d.child[]))
        var rc_present = _present_str(d.output_rank_col_name)
        var rc_name = String("")
        if rc_present:
            rc_name = d.output_rank_col_name.value().copy()
        partition_topn.append(
            WirePartitionTopNNode(
                d.partition_keys.copy(), d.sort_keys.copy(),
                d.descending.copy(), Int64(d.k),
                WindowFn(Int(window_fn_to_wire(d.func))),
                Int64(d.over_fetch_k),
                rc_present, rc_name^, kid^,
            )
        )
    elif tag == PLAN_ASOF_JOIN:
        # Arm ordinal, not field number — `asof_join` is field 16, arm 13.
        arm = 13
        # The `*_sort_keys` / `*_sort_desc` pairs are PRE-SORT HINTS ("this
        # side is already sorted on these; skip the sort phase"); `plan_display`
        # emits them when non-empty. They are carried verbatim: dropping a hint
        # costs a sort, and inventing one on a side that is not sorted produces
        # wrong rows.
        #
        # ⚠ THE TOLERANCE RENDERS ITS KIND AND THE SELECTED SLOT ONLY, AND
        # NOTHING AT `NONE`. The off-kind slot is in the text at no value, so
        # LEG 3 is the only comparison it has.
        ref d = p.asof_join_data_ref()
        var lk = List[WirePlan]()
        lk.append(_plan_to_wire(d.left[]))
        var rk = List[WirePlan]()
        rk.append(_plan_to_wire(d.right[]))
        asof_join.append(
            WireAsofJoinNode(
                d.left_keys.copy(), d.right_keys.copy(),
                d.left_asof.copy(), d.right_asof.copy(),
                AsofDirection(Int(asof_direction_to_wire(d.strategy))),
                Optional(_tolerance_to_wire(d.tolerance)),
                d.left_sort_keys.copy(), d.left_sort_desc.copy(),
                d.right_sort_keys.copy(), d.right_sort_desc.copy(),
                lk^, rk^,
            )
        )
    elif tag == PLAN_VIEW_REF:
        # Arm ordinal, not field number — `view_ref` is field 17, arm 14.
        arm = 14
        # ★ ONE FIELD, NOT TWO. `ViewRefData` declares `view_name` AND
        # `output_schema`, and only the name is here: `view_ref` copies its one
        # schema argument into both the payload and the node, nothing reassigns
        # either afterwards, so a duplicate on the wire would be
        # unobservable — see the decode arm.
        ref d = p.view_ref_data_ref()
        view_ref = Optional(
            WireViewRefNode(d.view_name.copy())
        )
    elif tag == PLAN_CSE_REF:
        # Arm ordinal, not field number — `cse_ref` is field 18, arm 15.
        arm = 15
        # ⚠ `canonical_hash` IS THIS NODE'S `structural_hash`. The plan-level
        # hash special-cases PLAN_CSE_REF to return it verbatim rather than
        # hashing the render, so on a bare CSE-ref leaf LEG 1's hash assertion
        # IS the assertion that this UInt64 survived. `output_schema` is
        # absent for the same reason as VIEW_REF's.
        ref d = p.cse_ref_data_ref()
        cse_ref = Optional(
            WireCseRefNode(d.canonical_hash)
        )
    elif tag == PLAN_CAST_TO_VARCHAR:
        # Arm ordinal, not field number — `cast_to_varchar` is field 19, arm 16.
        arm = 16
        # The whole payload is the child; the node's meaning is in its DERIVED
        # output schema (the per-column STRING mirror of the child's, keeping
        # each column's name and nullability), which `_check_output_schema`
        # genuinely checks on this arm.
        ref d = p.cast_to_varchar_data_ref()
        var kid = List[WirePlan]()
        kid.append(_plan_to_wire(d.child[]))
        cast_to_varchar.append(WireCastToVarcharNode(kid^))
    else:
        # ⚠ REACHABLE ONLY THROUGH THE BARE `LogicalPlan(tag, schema)` CTOR.
        # Every materializable tag now has an arm; the two that do not —
        # CONVERT_COLUMN_TO_ROW / CONVERT_ROW_TO_COLUMN — have no producer,
        # because `insert_orientation_conversions` raises a deferral instead of
        # emitting one. The ctor is public, so the state is still constructible,
        # and that is the whole reason this branch stays: a plan the engine
        # cannot execute must not become bytes that decode into a plan it can.
        raise Error(
            PLAN_WIRE_UNSUPPORTED_PLAN_TAG + ": '"
            + plan_tag_wire_name(plan_tag_to_wire(tag))
            + "' (engine tag " + String(Int(tag)) + ") has no message arm in"
            + " plan.proto. See the COVERAGE LEDGER at the top of"
            + " plan_wire_codec.mojo."
        )

    return WirePlan(
        out_schema^, arm, scan^, filter^, project^, aggregate^,
        join^, sort^, limit^, distinct^, topn^, union_all^, partition_by^,
        partition_topn^, asof_join^, view_ref^, cse_ref^, cast_to_varchar^,
    )


def _estimated_groups_message(where: String) -> String:
    """`estimated_groups` is an OPTIMIZER-populated cardinality hint. It is
    plain data and the `.proto` has slots for it — but there is no public
    mutable path to it after construction (`aggregate_data_ref` borrows
    `self` immutably), and restoring it through the private `_aggregate` field
    would make the codec depend on the node's internal layout. Refused rather
    than dropped: silently losing a cardinality hint changes which side of a
    join builds, which is a plan change that no leg of the round-trip test
    would see."""
    return (
        PLAN_WIRE_UNSUPPORTED_ESTIMATED_GROUPS + ": " + where + " carries an"
        + " estimated_groups hint. Plans taken BEFORE `optimize()` do not have"
        + " one; this fires on a post-optimizer plan."
    )


def _udf_not_describable_message(where: String) -> String:
    return (
        PLAN_WIRE_UDF_NOT_DESCRIBABLE + ": " + where + " carries a UdfData with"
        + " an EMPTY name, i.e. a UDF minted from a live in-process closure."
        + " What crosses the wire is a DESCRIPTION, and the peer re-mints its"
        + " own handle by resolving that description against ITS OWN registry"
        + " — so a UDF with no resolvable name has nothing for the peer to"
        + " resolve. Encoding it would produce a plan that decodes cleanly and"
        + " then cannot run, which is strictly worse than this refusal."
        + " REMEDY: register the UDF under a stable name both processes know."
        + " (This is the `InMemorySource` rule applied to live CODE: refused at"
        + " the wire, fully usable in-process.)"
    )


def _udf_tag_message(where: String, field: String, value: UInt32) -> String:
    return (
        PLAN_WIRE_MALFORMED + ": " + where + "." + field + " = " + String(value)
        + " is outside the declared range. The UDF tag spaces are dense and"
        + " engine-owned; a value outside them would construct a UdfData whose"
        + " null / stability / parallelism semantics no arm implements."
    )


def _udf_to_wire(u: UdfData, where: String) raises -> WireUdf:
    """`UdfData` -> `WireUdf`: the DESCRIPTION, never the handle.

    ⛔ REFUSES a non-describable UDF BEFORE encoding anything. The check is
    `UdfData.is_describable()`, which is DERIVED from the name — a producer
    cannot flag its own closure as describable.

    ⛔ `registered_handle_id` IS NOT WRITTEN, and there is no field to write it
    to. It is a slot+generation into a registry that exists in ONE process, and
    a low slot at generation 0 exists in almost any registry — so a carried
    handle would not merely be stale, it would PLAUSIBLY resolve, to a
    different function. Same rule, same reason, as `ScanBinding.handle`.

    `is_restartable` is not written either: `UdfData.__init__` DERIVES it from
    `parallelism_tag` "so the two can never disagree", and carrying a derived
    fact lets a hostile message assert it."""
    if not u.is_describable():
        raise Error(_udf_not_describable_message(where))
    var ins = List[WireUdfColumn]()
    for i in range(len(u.input_columns)):
        ins.append(
            WireUdfColumn(
                String(u.input_columns[i][0]), UInt32(u.input_columns[i][1])
            )
        )
    var outs = List[WireUdfColumn]()
    for i in range(len(u.output_columns)):
        outs.append(
            WireUdfColumn(
                String(u.output_columns[i][0]), UInt32(u.output_columns[i][1])
            )
        )
    return WireUdf(
        UInt32(u.kind),
        String(u.name),
        ins^,
        outs^,
        UInt32(u.null_mode),
        UInt32(u.stability),
        UInt32(u.parallelism_tag),
        u.partition_keys.copy(),
        u.order_keys.copy(),
        u.has_vector_path,
        u.operator_factory_id,
        u.call_site_salt,
    )


def _udf_from_wire(w: WireUdf, where: String) raises -> UdfData:
    """`WireUdf` -> `UdfData`. ⚠ THE DECODED UDF IS UNBOUND, ALWAYS.

    `registered_handle_id` comes back `None`, exactly as a decoded
    `ScanBinding` comes back with `SCAN_HANDLE_UNBOUND`. The peer resolves
    `name` against its OWN registry and mints its OWN handle; nothing here may
    invent one.

    ⚠ AND THE NAME IS RE-CHECKED ON THE WAY IN. The encoder refuses an empty
    name, but the decoder does not get to assume the encoder was ours — a
    language-agnostic format is BY DEFINITION parsed from bytes some other
    program produced. An empty name here would decode to a UDF nothing can
    resolve and everything downstream would treat as a live closure."""
    if w.name.byte_length() == 0:
        raise Error(_udf_not_describable_message(where))
    if UInt32(w.kind) > UInt32(2):
        raise Error(_udf_tag_message(where, "kind", w.kind))
    if UInt32(w.null_mode) > UInt32(2):
        raise Error(_udf_tag_message(where, "null_mode", w.null_mode))
    if UInt32(w.stability) > UInt32(2):
        raise Error(_udf_tag_message(where, "stability", w.stability))
    if UInt32(w.parallelism_tag) > UInt32(3):
        raise Error(
            _udf_tag_message(where, "parallelism_tag", w.parallelism_tag)
        )
    var ins = List[Tuple[String, UInt8]]()
    for i in range(len(w.input_columns)):
        ins.append((String(w.input_columns[i].name), UInt8(w.input_columns[i].dtype_tag)))
    var outs = List[Tuple[String, UInt8]]()
    for i in range(len(w.output_columns)):
        outs.append((String(w.output_columns[i].name), UInt8(w.output_columns[i].dtype_tag)))
    return UdfData(
        kind=UInt8(w.kind),
        name=String(w.name),
        input_columns=ins^,
        output_columns=outs^,
        operator_factory_id=w.operator_factory_id,
        call_site_salt=w.call_site_salt,
        null_mode=UInt8(w.null_mode),
        stability=UInt8(w.stability),
        parallelism_tag=UInt8(w.parallelism_tag),
        partition_keys=w.partition_keys.copy(),
        order_keys=w.order_keys.copy(),
        has_vector_path=w.has_vector_path,
        registered_handle_id=None,
    )


def _one_udf(box: Optional[WireUdf], where: String) raises -> WireUdf:
    """A `has_udf` bit with no payload is MALFORMED, not "no UDF". The two
    fields are one fact and a message that splits them is not one we wrote."""
    if not box:
        raise _malformed(where + ".has_udf is set but .udf is absent")
    return box.value().copy()


def _udf_message(where: String) -> String:
    return (
        PLAN_WIRE_UNSUPPORTED_UDF + ": " + where + " carries a UdfData. A UDF"
        + " is a Mojo FUNCTION POINTER — not data, and not encodable in any"
        + " format. This is a permanent boundary, not a TODO: a plan that"
        + " calls back into one process's code is not a serializable plan."
        + " The eventual answer is a NAMED udf resolved through a registry at"
        + " decode, i.e. the ScanBinding handle pattern again."
    )


def _one_expr(box: List[WireExpr], where: String) raises -> Expr:
    """The expr twin of `_one_child`.

    ⚠ WHICH EDGES ARE `List[T]` RECURSION BOXES IS NOT A CHOICE THIS FILE
    MAKES. `recursion_breaking_edges` in protoc-gen-mojo decides it, and a
    `List[T]` here means "the emitter broke a cycle at this edge". 0-or-many is
    what a box can physically hold, so exactly-1 is CHECKED rather than assumed.

    The rule: a singular message field is a `List[T]` box exactly when its
    target can get back to the message that declares it, by ANY chain of
    fields — `repeated` hops included. That is a property of the `.proto`, not
    of a traversal, so adding a message does not re-cut existing edges (a
    DFS back-edge cut would depend on message DECLARATION ORDER, and closing
    one new cycle could flip unrelated fields into or out of boxes). The
    reasoning is in the proto code generator's `recursion_breaking_edges`.

    The shapes below are still read off the generated `plan.mojo`, never
    guessed."""
    if len(box) != 1:
        raise _malformed(
            where + " carries " + String(len(box))
            + " exprs in its recursion box; exactly 1 is legal"
        )
    return _expr_from_wire(box[0])


def _one_child(kids: List[WirePlan], where: String) raises -> LogicalPlan:
    if len(kids) != 1:
        raise _malformed(
            where + " carries " + String(len(kids))
            + " children in its recursion box; exactly 1 is legal"
        )
    return _plan_from_wire(kids[0])


def _check_output_schema(
    p: LogicalPlan, w: Optional[WireSchema], where: String
) raises:
    """⚠ THE FACTORIES RE-DERIVE `output_schema`; THE WIRE CARRIES IT. THIS IS
    WHERE THE TWO ARE MADE TO AGREE OR SAID TO DISAGREE.

    Every `LogicalPlan.<verb>` factory computes the node's output schema from
    its inputs (`filter` copies the child's, `project` re-infers from the expr
    list, `aggregate` re-infers and disambiguates). Decoding through them is
    the right call — they are the tested construction path and the codec then
    depends on no private field layout — but it means the decoded node's schema
    is DERIVED, not RESTORED.

    That is precisely the shape in which a schema difference goes unnoticed:
    the plan TEXT does not contain `output_schema`, so `structural_hash` cannot
    see it, and the round trip would look green while the decoded plan promised
    different columns. So the derivation is CHECKED against the wire, and a
    disagreement is a named, loud failure rather than a silent overwrite."""
    var decoded = _opt_schema_from_wire(w, where)
    var a = _schema_text(p.output_schema)
    var b = _schema_text(decoded)
    if a != b:
        raise Error(
            PLAN_WIRE_OUTPUT_SCHEMA_DIVERGED + ": " + where + " — the factory"
            + " DERIVED an output schema that differs from the one the wire"
            + " CARRIED. derived=" + a + " wire=" + b
        )


def _check_union_branches(p: LogicalPlan) raises:
    """★★ THE ONE NODE `_check_output_schema` CANNOT CHECK, CHECKED.

    Every other arm DERIVES its output schema in the factory, so comparing the
    derivation against the wire catches a message that promised different
    columns. `LogicalPlan.union` takes the schema as an ARGUMENT — its docstring
    says "the caller is responsible for ensuring every child advertises this
    schema (the engine does not coerce)" — so the codec hands the wire's schema
    in and then compares it with itself. A stated tautology is still a
    tautology: WITHOUT THIS CHECK A UNION COULD PROMISE ANY COLUMNS AT ALL AND
    THIS DECODER WOULD AGREE.

    ⚠ WHAT THAT WOULD COST, shown by the `union_output_schema_diverges`
    hostile fixture — a UNION over ONE parquet scan of `[id, qty, name]`
    declaring `[id, qty, name, bonus]`. Without this check the endpoint
    admits it, and the caller is told:

        PLAN_ENDPOINT_EXECUTION_FAILED(20): ... ⚠ The bytes were valid — do not
        report this to the plan's author as a malformed plan.

    THAT ADVICE IS EXACTLY BACKWARDS. The bytes are NOT valid: the plan
    promises a column no branch produces, and the frontend author is told to
    look at the engine. Any refusal that does arrive is an unrelated envelope
    check — remove it and the union's phantom column is what every node above
    it resolves against, which is the wrong-rows class, not the crash class.

    THE CHECK IS THE ENGINE'S OWN CONTRACT, NOT AN INVENTED ONE: "every child
    advertises this schema", compared with `_schema_text` so it is the same
    name / type / nullability comparison `_check_output_schema` makes, and so a
    disagreement reads the same way in both messages.

    ⚠ VIEW_REF AND CSE_REF ARE THE SAME TAUTOLOGY AND GET NO CHECK, because
    there is nothing to compare against: they are LEAVES whose subtree is
    spliced in later by `view_resolution_pass`, in a process that owns the
    registry. Their carried schema is a promise about a plan that does not exist
    yet, and the pass that resolves them is where it can be tested. Named here
    so the omission is a decision rather than the same hole one arm over."""
    ref d = p.union_data_ref()
    if len(d.children) == 0:
        # `LogicalPlan.union` documents "`children` must be non-empty" and
        # nothing enforced it either. A childless UNION advertises a schema
        # produced by nothing at all — the same defect with zero branches.
        raise Error(
            PLAN_WIRE_OUTPUT_SCHEMA_DIVERGED + ": PLAN_UNION carries NO"
            + " children and still advertises the schema "
            + _schema_text(p.output_schema)
            + ". A union of nothing produces nothing, so every column it"
            + " promises is a column no branch can supply."
        )
    var want = _schema_text(p.output_schema)
    for i in range(len(d.children)):
        var got = _schema_text(d.children[i][].output_schema)
        if got != want:
            raise Error(
                PLAN_WIRE_OUTPUT_SCHEMA_DIVERGED + ": PLAN_UNION branch "
                + String(i) + " of " + String(len(d.children))
                + " does not advertise the union's own output schema."
                + " union=" + want + " branch=" + got
                + ". ⚠ The engine DOES NOT COERCE branches to the union's"
                + " schema (`LogicalPlan.union`: \"the caller is responsible\"),"
                + " so a branch that differs is not widened or reordered — the"
                + " rows it produces are handed on under column names the plan"
                + " promised and they do not have. Everything above this node"
                + " resolves against the promise."
            )


def _schema_text(s: Schema) raises -> String:
    var out = String("[")
    for i in range(s.num_columns()):
        if i > 0:
            out += String(", ")
        var f = s.field_at(i)
        out += f.name
        out += String(":")
        out += String(f.arrow_type.type_id)
        out += String(":")
        if f.nullable:
            out += String("N")
        else:
            out += String("-")
    out += String("]")
    return out^


def _plan_tag_of_arm(arm: Int) raises -> UInt8:
    """WHICH ENGINE TAG A SET `node` ARM MEANS. The twin of `_expr_tag_of_arm`
    — read its docstring for why a disagreement with `_plan_to_wire`'s ladder
    surfaces as a NAMED REFUSAL rather than as a wrong plan."""
    if arm == 1:
        return PLAN_SCAN
    if arm == 2:
        return PLAN_FILTER
    if arm == 3:
        return PLAN_PROJECT
    if arm == 4:
        return PLAN_AGGREGATE
    if arm == 5:
        return PLAN_JOIN
    if arm == 6:
        return PLAN_SORT
    if arm == 7:
        return PLAN_LIMIT
    if arm == 8:
        return PLAN_DISTINCT
    if arm == 9:
        return PLAN_TOPN
    if arm == 10:
        return PLAN_UNION
    if arm == 11:
        return PLAN_PARTITION_BY
    if arm == 12:
        return PLAN_PARTITION_TOPN
    if arm == 13:
        return PLAN_ASOF_JOIN
    if arm == 14:
        return PLAN_VIEW_REF
    if arm == 15:
        return PLAN_CSE_REF
    if arm == 16:
        return PLAN_CAST_TO_VARCHAR
    if arm == 0:
        raise _malformed(
            "a WirePlan with NO `node` arm set. The arm IS the node kind — the"
            + " retired `tag` field used to let a message name a kind it did"
            + " not carry, and this is that state, refused."
        )
    raise _malformed(  # cov: unreachable the generated decoder only assigns declared cases
        "a WirePlan whose `node` oneof case is " + String(arm) + ", which"  # cov: unreachable see the line above
        + " plan.proto does not declare. A decoder that guessed an arm here"  # cov: unreachable see the line above
        + " would build a plan nobody wrote."  # cov: unreachable see the line above
    )


def _plan_from_wire(w: WirePlan) raises -> LogicalPlan:
    # ⚠ THE ARM IS THE DISCRIMINATOR, AND THE ONLY ONE — see `_expr_from_wire`
    # and the retirement block above `message WirePlan` in plan.proto.
    var tag = _plan_tag_of_arm(w._oneof0_case)
    var out: LogicalPlan

    if tag == PLAN_SCAN:
        if not w.scan:
            raise _malformed("PLAN_SCAN with no scan payload")  # cov: unreachable the generated decoder sets the oneof case with its payload
        var d = w.scan[0].copy()
        if d.has_table_stats:
            raise Error(
                PLAN_WIRE_UNSUPPORTED_TABLE_STATS
                + ": decoded WireScanNode claims stats the wire cannot carry"
            )
        var source = _source_from_wire(d.source)
        if not d.has_schema:
            # ⚠ NOT A FALLBACK. `ScanData.schema` is `Optional[Schema]` and
            # `LogicalPlan.scan_from_source` — the only construction path this
            # codec uses, and the one BOTH facades use — takes a non-optional
            # schema, so a decoded scan ALWAYS has `Some`. Substituting
            # `source.schema()` for an absent one would turn `None` into
            # `Some` silently: an IR difference no leg of the round-trip test
            # can see, because `ScanData.schema` is neither rendered nor the
            # node's output schema. Refused instead.
            raise Error(
                PLAN_WIRE_UNSUPPORTED_SCHEMALESS_SCAN + ": the encoded scan"
                + " carries no explicit schema (ScanData.schema was None,"
                + " which the legacy `LogicalPlan.scan` factory can produce"
                + " and `scan_from_source` cannot). Decoding it would"
                + " materialize one from the source and silently change None"
                + " to Some."
            )
        var schema = _opt_schema_from_wire(d.schema, "WireScanNode.schema")
        var proj: Optional[List[String]] = None
        if d.has_projection:
            proj = Optional(d.projection.copy())
        var filt: Optional[Expr] = None
        if d.has_filter:
            filt = Optional(_one_expr(d.filter, "WireScanNode.filter"))
        var rc: Optional[Int] = None
        if d.has_row_count:
            rc = Optional(Int(d.row_count))
        out = LogicalPlan.scan_from_source(
            source^, schema^, proj^, filt^, rc^, None,
            source_orientation_from_wire(Int32(d.source_kind.number())),
        )
    elif tag == PLAN_FILTER:
        if not w.filter:
            raise _malformed("PLAN_FILTER with no filter payload")  # cov: unreachable the generated decoder sets the oneof case with its payload
        var d = w.filter[0].copy()
        if d.has_udf:
            # ⚠ THE DECODED UDF IS UNBOUND — `registered_handle_id = None`.
            # The peer resolves `name` against ITS OWN registry.
            out = LogicalPlan.filter_with_udf(
                _one_expr(d.predicate, "WireFilterNode.predicate"),
                _one_child(d.child, "WireFilterNode.child"),
                OwnedPointer[UdfData](
                    _udf_from_wire(
                        _one_udf(d.udf, "WireFilterNode"),
                        "decoded WireFilterNode",
                    )
                ),
            )
        else:
            out = LogicalPlan.filter(
                _one_expr(d.predicate, "WireFilterNode.predicate"),
                _one_child(d.child, "WireFilterNode.child"),
            )
    elif tag == PLAN_PROJECT:
        if not w.project:
            raise _malformed("PLAN_PROJECT with no project payload")  # cov: unreachable the generated decoder sets the oneof case with its payload
        var d = w.project[0].copy()
        var exprs = ExprArray()
        for i in range(len(d.exprs)):
            exprs.append(_expr_from_wire(d.exprs[i]))
        if d.has_udf:
            out = LogicalPlan.project_with_udf(
                exprs^,
                _one_child(d.child, "WireProjectNode"),
                OwnedPointer[UdfData](
                    _udf_from_wire(
                        _one_udf(d.udf, "WireProjectNode"),
                        "decoded WireProjectNode",
                    )
                ),
                d.is_cse_introduced,
            )
        else:
            out = LogicalPlan.project(
                exprs^,
                _one_child(d.child, "WireProjectNode"),
                d.is_cse_introduced,
            )
    elif tag == PLAN_AGGREGATE:
        if not w.aggregate:
            raise _malformed("PLAN_AGGREGATE with no aggregate payload")  # cov: unreachable the generated decoder sets the oneof case with its payload
        var d = w.aggregate[0].copy()
        var gb = ExprArray()
        for i in range(len(d.group_by)):
            gb.append(_expr_from_wire(d.group_by[i]))
        var ax = AggExprArray()
        for i in range(len(d.agg_exprs)):
            ax.append(_agg_expr_from_wire(d.agg_exprs[i]))
        if d.has_udf:
            out = LogicalPlan.aggregate_with_udf(
                gb^,
                ax^,
                _one_child(d.child, "WireAggregateNode"),
                OwnedPointer[UdfData](
                    _udf_from_wire(
                        _one_udf(d.udf, "WireAggregateNode"),
                        "decoded WireAggregateNode",
                    )
                ),
            )
        else:
            out = LogicalPlan.aggregate(
                gb^, ax^, _one_child(d.child, "WireAggregateNode")
            )
        if d.has_estimated_groups:
            raise Error(_estimated_groups_message("decoded WireAggregateNode"))
    elif tag == PLAN_JOIN:
        if not w.join:
            raise _malformed("PLAN_JOIN with no join payload")  # cov: unreachable the generated decoder sets the oneof case with its payload
        var d = w.join[0].copy()
        var residual: Optional[OwnedPointer[Expr]] = None
        if d.has_residual:
            residual = Optional(
                OwnedPointer(_one_expr(d.residual, "WireJoinNode.residual"))
            )
        out = LogicalPlan.join(
            _one_child(d.left, "WireJoinNode.left"),
            _one_child(d.right, "WireJoinNode.right"),
            d.left_on.copy(),
            d.right_on.copy(),
            join_type_from_wire(Int32(d.join_type.number())),
            join_algo_from_wire(Int32(d.algo_hint.number())),
            residual^,
        )
    elif tag == PLAN_SORT:
        if not w.sort:
            raise _malformed("PLAN_SORT with no sort payload")  # cov: unreachable the generated decoder sets the oneof case with its payload
        var d = w.sort[0].copy()
        out = LogicalPlan.sort(
            d.keys.copy(), d.descending.copy(),
            _one_child(d.child, "WireSortNode"),
            Optional(d.nulls_first.copy()),
        )
    elif tag == PLAN_LIMIT:
        if not w.limit:
            raise _malformed("PLAN_LIMIT with no limit payload")  # cov: unreachable the generated decoder sets the oneof case with its payload
        var d = w.limit[0].copy()
        out = LogicalPlan.limit(
            Int(d.n), _one_child(d.child, "WireLimitNode"), Int(d.offset)
        )
    elif tag == PLAN_DISTINCT:
        if not w.distinct:
            raise _malformed("PLAN_DISTINCT with no distinct payload")  # cov: unreachable the generated decoder sets the oneof case with its payload
        var d = w.distinct[0].copy()
        var cols: Optional[List[String]] = None
        if d.has_columns:
            cols = Optional(d.columns.copy())
        out = LogicalPlan.distinct(
            cols^, _one_child(d.child, "WireDistinctNode")
        )
        if d.has_estimated_groups:
            raise Error(_estimated_groups_message("decoded WireDistinctNode"))
    elif tag == PLAN_TOPN:
        if not w.topn:
            raise _malformed("PLAN_TOPN with no topn payload")  # cov: unreachable the generated decoder sets the oneof case with its payload
        var d = w.topn[0].copy()
        out = LogicalPlan.topn(
            d.keys.copy(), d.descending.copy(), Int(d.n),
            _one_child(d.child, "WireTopNNode"),
            Optional(d.nulls_first.copy()),
        )
    elif tag == PLAN_UNION:
        if not w.union_all:
            raise _malformed("PLAN_UNION with no union payload")  # cov: unreachable the generated decoder sets the oneof case with its payload
        var d = w.union_all[0].copy()
        # `UnionData`'s children are a `List`, and `LogicalPlan.union` takes
        # the `List`.
        var kids = List[OwnedPointer[LogicalPlan]]()
        for i in range(len(d.children)):
            kids.append(OwnedPointer(_plan_from_wire(d.children[i])))
        # UNION's factory takes its output schema rather than deriving it
        # (`LogicalPlan.union` — "the caller is responsible", the engine does
        # not coerce). So the wire's schema is RESTORED here, not derived, and
        # `_check_output_schema` below is a tautology for this arm;
        # `_check_union_branches` is what checks it. Said out loud because a
        # reader who assumed otherwise would think this arm is checked by the
        # generic comparison. VIEW_REF and CSE_REF are the same shape, and the
        # comment on each says so.
        out = LogicalPlan.union(
            kids^, _opt_schema_from_wire(w.output_schema, "PLAN_UNION")
        )
        # ★★ AND SAYING IT OUT LOUD IS NOT ENOUGH — the tautology is a HOLE,
        # and this is the check that closes it. See `_check_union_branches`.
        _check_union_branches(out)
    elif tag == PLAN_PARTITION_BY:
        if not w.partition_by:
            raise _malformed("PLAN_PARTITION_BY with no partition_by payload")  # cov: unreachable the generated decoder sets the oneof case with its payload
        var d = w.partition_by[0].copy()
        var pxs = List[PartitionExpr]()
        for i in range(len(d.partition_exprs)):
            pxs.append(_partition_expr_from_wire(d.partition_exprs[i]))
        out = LogicalPlan.partition_by(
            d.partition_keys.copy(), d.order_keys.copy(),
            d.descending.copy(), pxs^,
            _one_child(d.child, "WirePartitionByNode"),
        )
    elif tag == PLAN_PARTITION_TOPN:
        if not w.partition_topn:
            raise _malformed(  # cov: unreachable the generated decoder sets the oneof case with its payload
                "PLAN_PARTITION_TOPN with no partition_topn payload"  # cov: unreachable see the line above
            )
        var d = w.partition_topn[0].copy()
        var rc: Optional[String] = None
        if d.has_output_rank_col_name:
            rc = Optional(String(d.output_rank_col_name))
        # `over_fetch_k` is passed EXPLICITLY. The factory's `-1` default is a
        # sentinel meaning "derive from k", and the value on the wire is what
        # the source node's ctor already resolved — so re-defaulting here would
        # collapse a fused RANK node's tie buffer from `k + 16` back to `k`.
        out = LogicalPlan.partition_topn(
            d.partition_keys.copy(), d.sort_keys.copy(), d.descending.copy(),
            Int(d.k), _one_child(d.child, "WirePartitionTopNNode"),
            window_fn_from_wire(Int32(d.func.number())),
            Int(d.over_fetch_k),
            rc^,
        )
    elif tag == PLAN_ASOF_JOIN:
        if not w.asof_join:
            raise _malformed("PLAN_ASOF_JOIN with no asof_join payload")  # cov: unreachable the generated decoder sets the oneof case with its payload
        var d = w.asof_join[0].copy()
        # All four pre-sort hint lists are passed EXPLICITLY. The factory
        # defaults every one of them to empty, and empty MEANS "not sorted —
        # the compiler must sort this side", so a decoder that let the defaults
        # stand would silently re-introduce a sort the writer had elided. The
        # inverse mistake is worse and is why they are not re-derived from the
        # keys: a hint on a side that is not actually sorted skips the sort and
        # produces wrong rows.
        out = LogicalPlan.asof_join(
            _one_child(d.left, "WireAsofJoinNode.left"),
            _one_child(d.right, "WireAsofJoinNode.right"),
            d.left_keys.copy(), d.right_keys.copy(),
            String(d.left_asof), String(d.right_asof),
            asof_direction_from_wire(Int32(d.strategy.number())),
            _tolerance_from_wire(d.tolerance, "WireAsofJoinNode.tolerance"),
            d.left_sort_keys.copy(), d.left_sort_desc.copy(),
            d.right_sort_keys.copy(), d.right_sort_desc.copy(),
        )
    elif tag == PLAN_VIEW_REF:
        if not w.view_ref:
            raise _malformed("PLAN_VIEW_REF with no view_ref payload")  # cov: unreachable the generated decoder sets the oneof case with its payload
        var d = w.view_ref.value().copy()
        # ★ `ViewRefData.output_schema` IS DERIVED HERE, NOT CARRIED.
        # `view_ref` copies its ONE argument into both the payload slot and
        # the node's `output_schema`, and no producer reassigns either
        # afterwards — so the two are equal in every constructible state and a
        # second `WireSchema` would be a forgeable duplicate (the
        # `ScanData.source_path` situation). With the field present, an
        # encoder that wrote `p.output_schema` where the payload's belonged —
        # a codec that merely ASSUMED they were aliases — would pass every
        # round-trip test. A slot no mutation can disturb tests nothing.
        #
        # The consequence: `_check_output_schema` is a TAUTOLOGY on this arm,
        # exactly as on PLAN_UNION, because the factory RESTORES rather than
        # derives. Stated so nobody reads this arm as checked when it is not.
        #
        # DECODING DOES NOT RESOLVE THE VIEW. The name points into a registry
        # that belongs to whichever process runs `view_resolution_pass`; a
        # decoder that tried to expand it here would either fail on every
        # cross-process plan or splice in a definition the writer never meant.
        out = LogicalPlan.view_ref(
            String(d.view_name),
            _opt_schema_from_wire(w.output_schema, "PLAN_VIEW_REF"),
        )
    elif tag == PLAN_CSE_REF:
        if not w.cse_ref:
            raise _malformed("PLAN_CSE_REF with no cse_ref payload")  # cov: unreachable the generated decoder sets the oneof case with its payload
        var d = w.cse_ref.value().copy()
        # Same shape as VIEW_REF: `cse_ref` copies one schema argument
        # into both slots, the duplicate could not be made to fail, so the
        # payload's copy is derived from the node's and `_check_output_schema`
        # is a tautology here too.
        out = LogicalPlan.cse_ref(
            d.canonical_hash,
            _opt_schema_from_wire(w.output_schema, "PLAN_CSE_REF"),
        )
    elif tag == PLAN_CAST_TO_VARCHAR:
        if not w.cast_to_varchar:
            raise _malformed(  # cov: unreachable the generated decoder sets the oneof case with its payload
                "PLAN_CAST_TO_VARCHAR with no cast_to_varchar payload"  # cov: unreachable see the line above
            )
        var d = w.cast_to_varchar[0].copy()
        out = LogicalPlan.cast_to_varchar(
            _one_child(d.child, "WireCastToVarcharNode.child")
        )
    else:
        # UNREACHABLE BY CONSTRUCTION — `_plan_tag_of_arm` returns only the 16
        # tags the ladder handles. Kept for the same reason as its expr twin.
        raise Error(  # cov: unreachable the if-chain above handles every tag its arm map returns
            PLAN_WIRE_UNSUPPORTED_PLAN_TAG + ": '"  # cov: unreachable see the line above
            + plan_tag_wire_name(plan_tag_to_wire(tag))  # cov: unreachable see the line above
            + "' has no decode arm"  # cov: unreachable see the line above
        )

    _check_output_schema(
        out, w.output_schema, plan_tag_wire_name(plan_tag_to_wire(tag))
    )
    return out^


# =============================================================================
# The public surface
# =============================================================================


def plan_to_bytes(p: LogicalPlan) raises -> List[UInt8]:
    """Encode a `LogicalPlan` as `komira.plan.v1.WirePlanEnvelope` bytes.

    RAISES, by name, on any shape the wire cannot carry — see the COVERAGE
    LEDGER at the top of this file. Nothing is dropped silently.

    The envelope declares `format_version = 4` and carries NO `write_target`:
    a plan alone means "run this and return the rows". To ask a receiver to
    WRITE the rows somewhere, use `plan_to_bytes_with_write_target`."""
    return encode_proto[WirePlanEnvelope](
        WirePlanEnvelope(
            _envelope_version_for(False), Optional(_plan_to_wire(p)), None
        )
    )


def plan_to_bytes_with_write_target(
    p: LogicalPlan, target: WriteTarget
) raises -> List[UInt8]:
    """Encode a plan AND A DESTINATION — `COPY <plan> TO <target>` on the wire.

    The envelope declares `format_version = 5`, which is not decoration: it is
    what makes a reader that does not know field 3 REFUSE these bytes instead of
    skipping the field, running the query, returning rows and writing nothing.
    The version is derived from the shape (`_envelope_version_for`) rather than
    passed in, so no caller can produce the understated envelope that the
    reader's `PLAN_WIRE_WRITE_TARGET_VERSION_UNDERSTATED` check exists to refuse.

    ⚠ THE PAIR IS VALIDATED HERE TOO, not only on decode. A producer that emits
    `(csv, snappy)` has bytes no receiver will run, and learning that on the
    machine holding the SQL that caused it is worth one table lookup."""
    _check_write_target(target)
    return encode_proto[WirePlanEnvelope](
        WirePlanEnvelope(
            _envelope_version_for(True),
            Optional(_plan_to_wire(p)),
            Optional(_write_target_to_wire(target)),
        )
    )


def _check_write_target(target: WriteTarget) raises:
    """The two things about a destination that are wrong REGARDLESS of the
    receiver's filesystem. Everything else — does the directory exist, is it
    writable, is it already a file — is a question only the receiver can answer
    and is deliberately not asked here."""
    if target.path.byte_length() == 0:
        raise Error(
            PLAN_WIRE_UNSUPPORTED_WRITE_TARGET
            + ": the write target's `path` is EMPTY. proto3 cannot distinguish"
            " an empty string from an absent field, so this is the one path"
            " value that is certainly not a destination."
        )
    if not write_target_supported(target.fmt, target.codec):
        raise Error(
            PLAN_WIRE_UNSUPPORTED_WRITE_TARGET
            + ": no file sink writes "
            + target.describe()
            + ". ⚠ BOTH MEMBERS ARE VALID AND THE PAIR IS NOT — `WriteFormat`"
            " and `WriteCompression` are independent enums on the wire (3 x 5 ="
            " 15 encodable combinations against 13 sink arms), so a per-space"
            " check passes and `write_target_supported` is what decides. The"
            " usual cause is snappy, which is a Parquet PAGE codec and not a"
            " whole-file wrapper, so it pairs with parquet and nothing else."
        )


def _write_target_to_wire(target: WriteTarget) raises -> WireWriteTarget:
    return WireWriteTarget(
        target.path,
        WriteFormat(Int(write_format_to_wire(target.fmt))),
        WriteCompression(Int(write_compression_to_wire(target.codec))),
    )


def _write_target_from_wire(w: WireWriteTarget) raises -> WriteTarget:
    """⚠ EVERY ARM VALIDATES BEFORE IT NARROWS. `write_format_from_wire` /
    `write_compression_from_wire` raise on wire 0 and on any value the space
    does not publish — which is the `_params_from_wire` lesson (a wire tag of
    256 narrowed to 0 and decoded as a VALID member). Then the PAIR is checked,
    because the two spaces are independent and their product is not."""
    var target = WriteTarget(
        w.path,
        write_format_from_wire(Int32(w.format.number())),
        write_compression_from_wire(Int32(w.codec.number())),
    )
    _check_write_target(target)
    return target^


struct DecodedPlanEnvelope(Movable):
    """What a `WirePlanEnvelope` decodes to: a plan, and where its rows go.

    ⚠ `write_target` IS `Optional` AND MUST STAY THAT WAY. Absence is the
    ordinary case and means "return the rows" — the behaviour of every
    plain envelope. Making it non-optional with a sentinel path
    would put "no destination" and "a destination named empty-string" in the
    same value, which is the proto3 confusion `_check_write_target` refuses.

    ⚠ THE PLAN IS BEHIND `take_plan()`, NOT A PUBLIC FIELD. `decoded^.plan^` is
    a partial move out of a struct — which this codebase does not allow, and
    the compiler rejects here with "field ... destroyed out of the middle of
    a value". `Optional.take()` is the named replacement, and it is the shape
    `BoundStatement.take_plan` already uses for the identical situation one
    package over."""

    var _plan: Optional[LogicalPlan]
    var write_target: Optional[WriteTarget]

    def __init__(
        out self, var plan: LogicalPlan, var write_target: Optional[WriteTarget]
    ):
        self._plan = Optional(plan^)
        self.write_target = write_target^

    def take_plan(mut self) -> LogicalPlan:
        """Move the plan out, leaving `_plan` in `None`. Consumed exactly once."""
        return self._plan.take()


def plan_envelope_from_bytes(var bytes: List[UInt8]) raises -> DecodedPlanEnvelope:
    """★ THE FULL DECODE — plan AND destination. Use this, not `plan_from_bytes`,
    anywhere a write envelope can arrive.

    `plan_from_bytes` is this function with the destination thrown away, and it
    REFUSES rather than throwing it away silently (see
    `PLAN_WIRE_WRITE_TARGET_DROPPED`)."""
    return _decode_envelope(bytes^)


def plan_from_bytes(var bytes: List[UInt8]) raises -> LogicalPlan:
    """Decode bytes written by `plan_to_bytes` — OR BY ANYTHING ELSE.

    ⚠ THE SECOND HALF OF THAT SENTENCE IS THE WHOLE JOB. A language-agnostic
    format is by definition parsed from bytes some other program produced, so
    this function's contract is not "undo `plan_to_bytes`" — it is "survive
    arbitrary bytes, and say by name why it will not execute them".

    A version this build does not know is a REFUSAL, not a best-effort parse:
    a decoder that cannot tell "written by an older build" from "corrupt" will
    eventually execute one as the other.

    ⚠ AND A WRITE-CARRYING ENVELOPE IS A REFUSAL HERE TOO
    (`PLAN_WIRE_WRITE_TARGET_DROPPED`), because THIS RETURN TYPE CANNOT CARRY A
    DESTINATION. Returning the plan alone would execute the query and return
    correct rows with the user's file never written — the silent-wrong the
    version bump exists to stop, arriving through the front door instead of over
    the wire. Callers that can meet a write envelope use
    `plan_envelope_from_bytes`."""
    var decoded = _decode_envelope(bytes^)
    if decoded.write_target:
        raise Error(
            PLAN_WIRE_WRITE_TARGET_DROPPED
            + ": these bytes carry a write target ("
            + decoded.write_target.value().describe()
            + ") and `plan_from_bytes` returns a `LogicalPlan`, which cannot"
            " express one. Returning the plan alone would run the query and"
            " return rows with NOTHING WRITTEN and no error — call"
            " `plan_envelope_from_bytes` instead, or"
            " `komira_plan_endpoint.execute_plan_bytes`, which performs the"
            " write."
        )
    return decoded.take_plan()


def _decode_envelope(var bytes: List[UInt8]) raises -> DecodedPlanEnvelope:
    # ★ SIZE, VERSION, DEPTH, NODE COUNT — all of it before `decode_proto`
    # touches these bytes. Without this call, 901 bytes of nesting SIGSEGV
    # the process here: the decoder recurses once per nesting level and
    # nothing else counts the levels. The measurement is in
    # `plan_wire_admit.mojo`'s header.
    plan_wire_admit(bytes, plan_wire_supported_versions())

    var env = decode_proto[WirePlanEnvelope](bytes^)
    var supported = plan_wire_supported_versions()
    if not supported.contains(env.format_version):
        # ⚠ NOT DEAD CODE, AND NOT BELT-AND-BRACES EITHER. `plan_wire_admit`
        # finds `format_version` by scanning the raw top-level field stream;
        # this reads what the GENERATED decoder bound. They are two independent
        # readings of the same bytes, and if they ever disagree the scanner has
        # a bug and the gate above is not gating what it claims. Reaching this
        # raise means exactly that, so it is kept and carries the same token.
        raise Error(  # cov: unreachable unless the prescan and the generated decoder diverge
            PLAN_WIRE_VERSION_MISMATCH + ": these bytes declare format_version="  # cov: unreachable see the line above
            + String(Int(env.format_version)) + "; this build speaks "  # cov: unreachable see the line above
            + supported.render()  # cov: unreachable see the line above
            + ". ⚠ REACHED AFTER `plan_wire_admit` ADMITTED THEM, which means"  # cov: unreachable see the line above
            " the prescan and the decoder disagree about where the version is."
        )
    if not env.plan:
        raise _malformed("WirePlanEnvelope with no plan")
    # ⚠ THE SAME TWO-INDEPENDENT-READINGS ARGUMENT, FOR FIELD 3. The prescan
    # decided the capability floor from a raw top-level field-header scan; this
    # is what the generated decoder BOUND. A disagreement means the prescan is
    # looking in the wrong place, and the failure it would produce is the
    # understated envelope reaching an executor — so it is checked rather than
    # assumed.
    if env.write_target and env.format_version < PLAN_WIRE_WRITE_TARGET_MIN_VERSION:
        raise Error(  # cov: unreachable unless the prescan and the generated decoder diverge
            PLAN_WIRE_WRITE_TARGET_VERSION_UNDERSTATED  # cov: unreachable see the line above
            + ": the decoder bound a `write_target` under format_version="  # cov: unreachable see the line above
            + String(Int(env.format_version))  # cov: unreachable see the line above
            + ". ⚠ REACHED AFTER `plan_wire_admit` ADMITTED THEM, which means"  # cov: unreachable see the line above
            " the prescan and the decoder disagree about whether field 3 is"
            " present."
        )
    var write_target = Optional[WriteTarget](None)
    if env.write_target:
        write_target = Optional(_write_target_from_wire(env.write_target.value()))
    var plan = _plan_from_wire(env.plan.value())
    # ★ THE VALUE GATE — the third of three passes. `plan_wire_admit` bounds
    # FRAMING (size, version, depth, node count); the ledger above refuses
    # SHAPES the format cannot carry; this pass checks each VALUE against the
    # schema standing next to it. Without it, protoc-encoded bytes carrying
    # `col_idx: 999999999` are a SIGSEGV at 261 bytes, and an unknown column
    # NAME silently DROPS the filter and returns all six rows of a six-row
    # fixture where four are correct.
    #
    # ⚠ IT RUNS HERE AND NOT IN `komira_plan_endpoint`, for the reason that
    # file already gives for running `plan_wire_admit` twice: a safety property
    # that depends on which entry point the caller chose is not a safety
    # property. And it runs AFTER `_plan_from_wire`, not inside it, because it
    # resolves references against schemas that `_check_output_schema` has to
    # have reconciled first. See `plan_wire_values.mojo`.
    plan_wire_check_values(plan)
    return DecodedPlanEnvelope(plan^, write_target^)


def plan_round_trip(p: LogicalPlan) raises -> LogicalPlan:
    """`plan -> bytes -> plan'`, the whole assertion in one call."""
    return plan_from_bytes(plan_to_bytes(p))


def schema_to_bytes(s: Schema) raises -> List[UInt8]:
    """Encode an Arrow `Schema` as bare `komira.plan.v1.WireSchema` bytes.

    ★ THIS EXISTS FOR THE PRODUCER SIDE, AND THE PRODUCER SIDE IS NOT MOJO.

    `execute_plan_bytes` takes NO CATALOG, by the format's design rule that a
    description of work NAMES ITS OWN INPUTS, because a door that resolved names against a
    catalog would hold half the plan in a second process. So a frontend that
    wants to scan a parquet file must itself emit
    `WireParquetSource{paths, schema, mtime_ns, ...}`, and `schema` is the one
    field it cannot honestly invent.

    ⚠ WHY A FRONTEND CANNOT DERIVE IT FROM ITS OWN PARQUET READER. `WireField`
    carries `dtype_code` and `dict_index_type_id` as well as `arrow_type_id`,
    and `dtype_code` is a CODEC-LOCAL table (`_DT_*`) that exists precisely
    because `DType` has no stable numeric identity — `_field_from_wire` treats
    the wire value as AUTHORITATIVE and overwrites the `Field` ctor's derived
    one. A schema derived by another language's Arrow library would have to
    re-implement `_field_to_wire` to fill those, i.e. keep a second copy of this file's private
    table in another language, which is the two-sources-of-truth disease the
    generated vocabulary exists to prevent. Reading the footer with the
    ENGINE'S OWN reader and encoding it HERE is the only route with one table.

    Bare `WireSchema`, not an envelope: the caller splices these bytes into a
    message it is building (`WireParquetSource.schema`, `WireScanNode.schema`,
    `WirePlan.output_schema`), so wrapping them would only mean unwrapping
    them. There is deliberately no `schema_from_bytes` twin — nothing in this
    process needs to read one back, and an unused decoder is an untested one."""
    return encode_proto[WireSchema](_schema_to_wire(s))


def binding_to_bytes(b: ScanBinding, variant_tag: UInt8) raises -> List[UInt8]:
    """Encode a `ScanBinding` as bare `komira.plan.v1.WireScanBinding` bytes.

    ★ THE FOOTERLESS TWIN OF `schema_to_bytes`, AND IT EXISTS FOR THE SAME
    REASON: THE PRODUCER SIDE IS NOT MOJO. A parquet frontend needs only the
    SCHEMA from the engine, because everything else on `WireParquetSource` is a
    path and an mtime a caller already knows. A CSV or JSONL frontend needs
    strictly more, and the extra fields are the ones it must NOT compute:

      * `fingerprint` / `structural_id` are folds over a SPECIFIC field set —
        `CsvSource.__init__` folds path length, path bytes, mtime,
        `quote_style_tag`, `delimiter`, `has_header`, in that order, with
        FNV-1a-64 — and a frontend reimplementation of that would be a second
        copy of an identity the source ctor already owns. A wrong value there
        is not a decode error: it is a plan-cache identity that silently
        collides or never hits.
      * `kind_id` is `scan_kind_id(kind_name)`, an FNV-1a-32 the registry
        validates against.
      * `snapshot_policy` / `snapshot_token` / `orientation` are the kind's
        DECLARATIONS. A producer that guessed COLUMNAR for `komira.csv` would
        author a plan `ScanKindRegistry.validate` refuses — loudly, which is
        fine — but a producer that guessed SNAPSHOT_NONE would author one that
        is accepted and never invalidated by a file rewrite.

    So the frontend gets the WHOLE message from the engine and splices it into
    `WireScanSource.binding` verbatim, exactly as it already splices
    `schema_to_bytes` output into `WireParquetSource.schema`. One oracle.

    `variant_tag` is a parameter and not read off the binding because
    `SourceVariant` keeps the ORIGINAL tag for a migrated arm — ORC and
    ARROW_ZSTD are distinguishable on the wire and reconstruct as themselves —
    and a `ScanBinding` alone does not know which tag carried it.

    Bare `WireScanBinding`, not an envelope, for `schema_to_bytes`' reason: the
    caller splices these bytes into a message it is building. There is
    deliberately no `binding_from_bytes` twin — nothing in this process reads one
    back, and an unused decoder is an untested one."""
    return encode_proto[WireScanBinding](_binding_to_wire(b, variant_tag))


def scan_params_from_bytes(var bytes: List[UInt8]) raises -> ScanParams:
    """Decode the `params` of a bare `komira.plan.v1.WireScanBinding` into a
    `ScanParams`: the READ half a non-Mojo author needs to name an open scan
    kind's params. The kind then builds the rest of the binding from them.

    ★ WHY THE CARRIER IS A `WireScanBinding` AND NOT A NEW MESSAGE. The params
    an author sends are the SAME typed map the binding carries back:
    `WireParam{key, tag, s|i|f}`. `topic_live`'s `start_offset` is
    `PARAM_I64`, so a stringly `k=v` encoding cannot author that golden at all:
    a typed map is required, and one already exists on the wire. The author
    fills `params`.

    ⛔ THE FIELDS THE KIND COMPUTES ARE REFUSED, NOT IGNORED: `kind_id`,
    `kind_name`, `name`, schema fields, `fingerprint`, `structural_id`,
    `snapshot_token`, `pushdown_extra_cols`, a legacy source type and stats.
    An author that sent one is asking the engine to honour a value this reader
    would otherwise drop, and a silently-dropped fingerprint is the plan-cache
    fault `binding_to_bytes` exists to prevent.

    ⚠ NOT READ, AND NOT REFUSED: `pushdown_gate`, `snapshot_policy`,
    `orientation` and `variant_tag`. They are enum/gate fields every encoder
    of a `WireScanBinding` writes (this package's included), and the kind's
    descriptor states all four, so a value here cannot reach a binding. Only
    `params` is returned.

    Every tag goes through `_params_from_wire`, so its refusal of an unknown
    tag is this reader's too."""
    var w = decode_proto[WireScanBinding](bytes^)
    if (
        w.kind_id != UInt32(0)
        or w.kind_name.byte_length() != 0
        or w.name.byte_length() != 0
        or (Bool(w.schema) and len(w.schema.value().fields) > 0)
        or w.fingerprint != UInt64(0)
        or w.structural_id != UInt64(0)
        or w.snapshot_token != UInt64(0)
        or len(w.pushdown_extra_cols) > 0
        or w.has_legacy_source_type
        or w.has_stats
    ):
        raise Error(
            PLAN_WIRE_MALFORMED
            + ": a scan-params request carries only `params`; this one also"
            + " sets a field the kind computes (kind_id / kind_name / name /"
            + " schema fields / fingerprint / structural_id / snapshot_token /"
            + " pushdown_extra_cols / legacy_source_type / stats). The KIND"
            + " builds those, so an author may not supply them"
        )
    return _params_from_wire(w.params)
