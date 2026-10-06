# =============================================================================
# scan_binding_resolve_pass — THE EXECUTION-TIME RESOLVE of open-kind scans.
# =============================================================================
#
# RFC v2 "broker and search as plan citizens" §2.1 / §2.3.2 / §5 row P1;
# an internal doc §6.2 (tier 2) and §7.3 (LIVE tokens).
#
# WHAT THIS IS. A mutating plan walk that, for every scan leaf whose binding is
# an OPEN kind — `SourceVariant.is_binding_backed()` and
# `legacy_source_type == SCAN_LEGACY_SOURCE_TYPE_NONE`, i.e. a kind from a
# package core has never heard of (a topic, an index, a log window) — including
# one inside a subquery:
#
#   1. finds the kind's resolver (`SCAN_KIND_NOT_EXECUTABLE`, naming the kind
#      and every registered kind, when there is none);
#   2. makes the PER-EXECUTION binding with core's `resolve_for_execution` —
#      the LIVE token is re-read into a COPY, never written back into a plan;
#   3. calls `open_scan` with the leaf's projection and the conjuncts its
#      pushdown gate accepts (HINTS — see `ScanRequest`);
#   4. checks the payload (every needed column, with its declared type; every
#      batch carrying batch 0's schema — "type" meaning the FULL field type,
#      decimal (precision, scale) and timestamp zone included, never the bare
#      `ArrowType` tag), re-roots the leaf as an ordinary IN_MEMORY scan over
#      the returned Arc — projected to the leaf's own columns, or, with none,
#      to the binding's own columns so the leaf is always the DECLARED
#      relation whatever superset or column order the kind returned — with its
#      WHOLE filter kept as a `PLAN_FILTER` node ABOVE that scan (and a
#      `PLAN_PROJECT` back to the leaf's columns when the filter read others),
#      checks the re-rooted output against what the leaf promised its
#      parents, and only THEN binds that Arc into `scan_registry` through
#      `bind_plan_inmem_payloads`, the one place the (payload, handle) pairing
#      is made;
#   5. records what was resolved (`ResolvedScanSnapshot`, the side channel).
#
# Every other leaf is untouched: parquet, in-memory, and the MIGRATED legacy
# binding arms (csv / orc / avro / arrow / json), which declare a legacy source
# type and are served by their own readers.
#
# WHY RE-ROOT AS IN-MEMORY. It is the precedent
# `komira_engine_dispatch/pipeline_compiler.mojo:pre_resolve_cross_fs_leaves`
# already ships: turn a leaf the walker cannot read into a resident in-memory
# leaf at execution start, so every walker route serves it unchanged. The cost
# is stated in `scan_morsel_resolver.mojo`'s header: P1 drains; it does not
# stream.
#
# ⚠ HAND IT THE PER-EXECUTION PLAN. It re-roots IN PLACE. A plan cache that
# hands its cached plan here would lose the binding leaf (and with it the
# cache key's meaning) after one execution. The cached plan keeps its LIVE
# binding with token 0; each execution resolves a fresh token on its own copy.
#
# ⚠ THIS PASS IS AN ACQUIRE, AND ITS CALLER OWES THE RELEASE. Step 4's bind
# mints a registry slot and takes a SECOND retaining reference on the kind's
# payload Arc — the shape `komira_plan_ir/scan_binding_bind_pass.mojo`'s
# RETENTION section documents as this epic's P0 leak. Nothing here remembers
# what it bound, on purpose: the caller opens `ScanRegistry
# .open_scan_bind_scope()` (`EngineContext.open_scan_bind_scope()`) BEFORE
# calling, and holds that scope across the pass AND the execution; its
# DESTRUCTOR releases every slot minted since it opened, on the unwind path
# too. That path is not hypothetical: in a two-leaf plan whose second leaf
# raises (`SCAN_KIND_NOT_EXECUTABLE`), the first has already bound. A scope
# opened AFTER the pass sits above its slots and releases none of them — one
# drained topic or index resident for the life of a warm context, per
# execution. Every payload check runs before the bind, so a REFUSED leaf mints
# nothing. Pinned by `test_the_pass_is_an_acquire_and_a_scope_opened_before_
# it_releases_it` and `test_a_scope_opened_before_the_pass_releases_on_the_
# unwind_path`, against `resident_payload_rows()`, never `num_bound()`.
#
# THE FILTER IS KEPT, ALL OF IT — AS A `PLAN_FILTER` NODE, NOT ON THE SCAN.
# The pushed conjuncts reach the kind as a pruning hint, and the engine
# re-applies the whole filter above the in-memory scan. A pushdown gate is a
# capability to prune, not a promise of exactness (the parquet zonemap gate has
# the same contract), and a kind that prunes coarsely — a log segment that
# overlaps the window — must not produce wrong rows because the plan trusted
# it. It is a NODE because a scan-level filter on an in-memory scan is a shape
# the optimizer never builds, and a live reader written to that invariant
# skips one: `subquery_executor._try_collect_scalar_inner_source` folds a
# scalar subquery straight off the scan's batch. A node cannot be skipped by
# a reader of the scan (`_rerooted_subtree` has the whole argument).
#
# THE WALK MIRRORS `komira_plan_ir/scan_binding_bind_pass.mojo` ARM FOR ARM,
# including its raise on an unmodelled tag. A hole here is worse than a hole in
# a check: an open-kind leaf underneath it would reach the executor UNRESOLVED.
# The tag-coverage falsifier builds a node for EVERY `PLAN_*` and `EXPR_*` tag
# (`tests/test_scan_binding_resolve_pass.mojo`), so a new tag reds it.
# =============================================================================

from std.memory import ArcPointer

from komira_arrow.arrow_types import ArrowType
from komira_arrow.record_batch import RecordBatch
from komira_arrow.schema import Schema, SchemaBuilder
from komira_collections.slab import Slab
from komira_plan_ir.corr_subquery import corr_data_inner_plan_ref
from komira_plan_expr.expr import (
    Expr,
    BIN_AND,
    EXPR_COL_REF,
    EXPR_COL_IDX,
    EXPR_LITERAL,
    EXPR_BINARY_OP,
    EXPR_UNARY_OP,
    EXPR_CAST,
    EXPR_ALIAS,
    EXPR_STRING_OP,
    EXPR_WHEN,
    EXPR_IN_LIST,
    EXPR_BETWEEN,
    EXPR_SORT_KEY,
    EXPR_AGG_FN,
    EXPR_WINDOW_FN,
    EXPR_CORRELATED_SUBQUERY,
    EXPR_REGEXP,
    EXPR_STRUCT_FIELD,
    EXPR_STRUCT_FIELD_IDX,
    EXPR_MAP_GET,
    EXPR_JSON_EXTRACT,
    EXPR_EXTRACT,
    EXPR_MATH_FN,
    EXPR_MATH_FN2,
    EXPR_SUBSTRING,
    EXPR_STRING_FN,
    EXPR_STRING_FN_N,
    EXPR_UDF_CALL,
    expr_tag_name,
)
from komira_plan_expr.expr_helpers import flatten_and_conjuncts
from komira_plan_expr.expr_walk import ordered_name_sink, walk_expr_column_refs
from komira_plan_ir.logical_plan import (
    LogicalPlan,
    PLAN_SCAN,
    PLAN_FILTER,
    PLAN_PROJECT,
    PLAN_AGGREGATE,
    PLAN_JOIN,
    PLAN_SORT,
    PLAN_LIMIT,
    PLAN_DISTINCT,
    PLAN_TOPN,
    PLAN_PARTITION_BY,
    PLAN_PARTITION_TOPN,
    PLAN_ASOF_JOIN,
    PLAN_UNION,
    PLAN_VIEW_REF,
    PLAN_CSE_REF,
    PLAN_CAST_TO_VARCHAR,
    plan_tag_name,
)
from komira_plan_ir.scan_binding_bind_pass import bind_plan_inmem_payloads
from komira_scan_source.in_memory_source import InMemorySource
from komira_scan_source.scan_binding import (
    ScanBinding,
    SCAN_LEGACY_SOURCE_TYPE_NONE,
)
from komira_scan_source.scan_params import ScanParams
from komira_scan_source.scan_registry import ScanRegistry
from komira_scan_source.scan_resolver import resolve_for_execution
from komira_scan_source.source_variant import SourceVariant
from komira_morsel.scan_morsel_resolver import (
    ScanMorselResolvers,
    ScanRequest,
    SCAN_KIND_NOT_EXECUTABLE,
    SCAN_REQUEST_NO_LIMIT,
)


comptime SCAN_RESOLVE_PASS_UNMODELLED_TAG: StaticString = (
    "SCAN_RESOLVE_PASS_UNMODELLED_TAG"
)
"""NAMED ERROR — the resolve walk met a `PLAN_*` tag it has no arm for.
Distinct from the bind pass's and the gate's tokens, so a reader knows WHICH of
the three same-shaped walks grew the hole."""

comptime SCAN_RESOLVE_PASS_UNMODELLED_EXPR_TAG: StaticString = (
    "SCAN_RESOLVE_PASS_UNMODELLED_EXPR_TAG"
)
"""NAMED ERROR — the resolve walk met an `EXPR_*` tag it has no arm for.
`EXPR_CORRELATED_SUBQUERY` carries a whole plan, so an unmodelled expression
tag can hide an open-kind leaf that would reach the executor unresolved."""

comptime SCAN_OPENED_SCHEMA_MISMATCH: StaticString = (
    "SCAN_OPENED_SCHEMA_MISMATCH"
)
"""NAMED ERROR — a kind's `open_scan` returned batches that do not carry a
column the plan needs, with the type the kind's own binding declared — or
batches that disagree with one another. "Type" is the FULL field type
(`_field_type_diff`): a DECIMAL128(18,4) where (18,2) was declared is a retyped
column, not a match. Raised rather than executed: a missing or retyped column
is wrong rows downstream."""


struct ResolvedScanSnapshot(Copyable, Movable, Deinitable):
    """What one execution resolved for one open-kind scan leaf: the snapshot it
    read and the kind's side channel (`ScanOpened.resolved`, RFC v2 §2.3.2).

    `snapshot_token` is the PER-EXECUTION token (for a LIVE kind, the one
    `resolve_snapshot` returned; for a PINNED kind, the pinned one). The cached
    plan never carries it. `resolved` keys are the kind's; nothing here reads
    them. `rows` is how many rows the kind drained.
    """

    var kind_id: UInt32
    var kind_name: String
    var name: String
    var snapshot_policy: UInt8
    var snapshot_token: UInt64
    var resolved: ScanParams
    var rows: Int

    def __init__(
        out self,
        kind_id: UInt32,
        var kind_name: String,
        var name: String,
        snapshot_policy: UInt8,
        snapshot_token: UInt64,
        var resolved: ScanParams,
        rows: Int,
    ):
        self.kind_id = kind_id
        self.kind_name = kind_name^
        self.name = name^
        self.snapshot_policy = snapshot_policy
        self.snapshot_token = snapshot_token
        self.resolved = resolved^
        self.rows = rows

    def copy(self) -> Self:
        return Self(
            kind_id=self.kind_id,
            kind_name=String(self.kind_name),
            name=String(self.name),
            snapshot_policy=self.snapshot_policy,
            snapshot_token=self.snapshot_token,
            resolved=self.resolved.copy(),
            rows=self.rows,
        )

    def render(self) -> String:
        """One line, every field: `<kind_name> <name> policy=<p> token=<t>
        rows=<n> resolved={<k=v, ...>}`, the side channel in sorted-key order
        (`ScanParams.render`). What a consumer that cannot name this type — a
        `komira.so` linker at the `komira_core`-only floor — reads it as."""
        return (
            self.kind_name
            + String(" ")
            + self.name
            + String(" policy=")
            + String(Int(self.snapshot_policy))
            + String(" token=")
            + String(self.snapshot_token)
            + String(" rows=")
            + String(self.rows)
            + String(" resolved={")
            + self.resolved.render()
            + String("}")
        )


# =============================================================================
# §1 — the leaf
# =============================================================================


def _is_open_binding_leaf(plan: LogicalPlan) -> Bool:
    """True iff `plan` is a scan over an OPEN kind: binding-backed, with no
    legacy source type. Precondition: `plan.tag == PLAN_SCAN` and `_scan`."""
    ref sd = plan._scan.value()[]
    if not sd.source.is_binding_backed():
        return False
    return (
        sd.source.binding_ref().legacy_source_type
        == SCAN_LEGACY_SOURCE_TYPE_NONE
    )


def _list_has(names: List[String], name: String) -> Bool:
    for i in range(len(names)):
        if names[i] == name:
            return True
    return False


def _schema_index(schema: Schema, name: String) -> Int:
    for i in range(schema.num_columns()):
        if schema.field_name(i) == name:
            return i
    return -1


def _needed_columns(
    schema: Schema, projection: List[String], filter: Optional[Expr]
) -> List[String]:
    """The columns the re-rooted leaf needs: its projection plus every column
    its (kept) filter reads — in the binding schema's order, then any name the
    schema does not carry, first-seen. What `ScanRequest.projection` names."""
    var need = List[String]()
    for i in range(len(projection)):
        need.append(String(projection[i]))
    if filter:
        var sink = ordered_name_sink(need)
        walk_expr_column_refs(filter.value(), sink)
    var out = List[String]()
    for i in range(schema.num_columns()):
        var name = schema.field_name(i)
        if _list_has(need, name) and not _list_has(out, name):
            out.append(name^)
    for i in range(len(need)):
        if not _list_has(out, need[i]):
            out.append(String(need[i]))
    return out^


def _pushable_conjuncts(
    binding: ScanBinding, filter: Expr
) -> Optional[Expr]:
    """The AND of the conjuncts of `filter` the kind's own gate accepts, or
    None. A HINT for the kind; the filter itself stays on the leaf."""
    var conj = flatten_and_conjuncts(filter)
    var acc: Optional[Expr] = None
    for i in range(len(conj)):
        if not binding.supports_filter_pushdown(conj[i]):
            continue
        if acc:
            var left = acc.take()
            acc = Optional(Expr.binary(BIN_AND, left^, conj[i].copy()))
        else:
            acc = Optional(conj[i].copy())
    return acc^


def _field_type_diff(a: Schema, ai: Int, b: Schema, bi: Int) -> String:
    """THE ONE FIELD-TYPE COMPARATOR of this pass: `""` when field `ai` of `a`
    and field `bi` of `b` have the same TYPE, else what differs, `a`'s side
    first. All three payload checks — the declared type
    (`_check_payload_schema`), every batch against batch 0
    (`_check_every_batch`), and the re-rooted output against the leaf's
    promise (`_check_same_output`) — ask it, so none of them can be looser than
    another.

    ⚠ THE `ArrowType` TAG IS NOT THE TYPE. `ArrowType` is one `UInt8`, and
    DECIMAL128 is 18 whatever its (precision, scale): a (18,4) column read
    under an (18,2) schema is every value off by 100x with no error. So after
    the tag it compares every parameter `Schema` carries, the way core's
    `record_batch_compare._schema_diff` compares decimals:
      * DECIMAL128 / DECIMAL256 — precision and scale;
      * TIMESTAMP* — the timezone. A naive and a zoned timestamp share a tag
        and differ only in `field_tz`, and the zone is what an instant means;
      * DICTIONARY — the index type (its value type is its one child, below);
      * UNION_SPARSE / UNION_DENSE — the type-id list;
      * every type with children (LIST, LARGE_LIST, FIXED_SIZE_LIST, *_VIEW,
        STRUCT, MAP, DICTIONARY) — the child count and each child's tag, and
        a STRUCT's child NAMES (a struct field is read by name).
    NOT compared, on purpose: nullability (not part of the type — a column
    declared nullable is legally served by a batch holding no null, and every
    array carries its own validity), field flags and kv-metadata. NOT
    comparable, because `Schema` has no slot to compare: a FIXED_SIZE_BINARY
    byte width, a FIXED_SIZE_LIST size, and a nested child's OWN parameters (a
    child is one tag). Those drift unseen until `Schema` carries them.
    """
    var ta = a.field_arrow_type(ai)
    var tb = b.field_arrow_type(bi)
    if not (ta == tb):
        return String("type ") + String(ta) + String(" vs ") + String(tb)
    if ta == ArrowType.DECIMAL128 or ta == ArrowType.DECIMAL256:
        var pa = a.field_decimal_precision(ai)
        var sa = a.field_decimal_scale(ai)
        var pb = b.field_decimal_precision(bi)
        var sb = b.field_decimal_scale(bi)
        if pa != pb or sa != sb:
            return (
                String("decimal (precision, scale) (")
                + String(pa)
                + String(",")
                + String(sa)
                + String(") vs (")
                + String(pb)
                + String(",")
                + String(sb)
                + String(")")
            )
    if ta.is_timestamp() and a.field_tz(ai) != b.field_tz(bi):
        return (
            String("timestamp timezone '")
            + a.field_tz(ai)
            + String("' vs '")
            + b.field_tz(bi)
            + String("'")
        )
    if ta == ArrowType.DICTIONARY and not (
        a.field_dict_index_type(ai) == b.field_dict_index_type(bi)
    ):
        return (
            String("dictionary index type ")
            + String(a.field_dict_index_type(ai))
            + String(" vs ")
            + String(b.field_dict_index_type(bi))
        )
    # THE LENGTH COMPARE GUARDS THE INDEX, the same way the child count
    # guards the child loop below: the element loop walks `ua` and reads
    # `ub[k]`. With `ua` holding MORE ids it would read past `ub`'s last;
    # with FEWER it would end early and accept [0] under [0, 1]. Both
    # directions are pinned.
    if ta.is_union():
        var ua = a.field_union_type_ids(ai)
        var ub = b.field_union_type_ids(bi)
        var same = len(ua) == len(ub)
        if same:
            for k in range(len(ua)):
                if ua[k] != ub[k]:
                    same = False
                    break
        if not same:
            return String("union type ids")
    # THE CHILD COUNT FIRST, AND IT MUST STAY FIRST: the loop below walks
    # `a`'s children and reads `b`'s at the same k. With `a` holding MORE,
    # it would read past `b`'s last child (`Schema.field_child_arrow_type`
    # does no range check of its own); with FEWER, it would end early and
    # accept a STRUCT{x} under a STRUCT{x, y}. Both directions are pinned.
    var na = a.field_num_children(ai)
    var nb = b.field_num_children(bi)
    if na != nb:
        return (
            String("child count ") + String(na) + String(" vs ") + String(nb)
        )
    for k in range(na):
        var ca = a.field_child_arrow_type(ai, k)
        var cb = b.field_child_arrow_type(bi, k)
        if not (ca == cb):
            return (
                String("child ")
                + String(k)
                + String(" type ")
                + String(ca)
                + String(" vs ")
                + String(cb)
            )
        if ta == ArrowType.STRUCT and a.field_child_name(
            ai, k
        ) != b.field_child_name(bi, k):
            return (
                String("struct child ")
                + String(k)
                + String(" name '")
                + a.field_child_name(ai, k)
                + String("' vs '")
                + b.field_child_name(bi, k)
                + String("'")
            )
    return String("")


def _refuse_schema(
    binding: ScanBinding, what: String, column: String, detail: String = ""
) raises:
    var why = String("")
    if detail.byte_length() > 0:
        why = String(" (") + detail + String(")")
    raise Error(
        String(SCAN_OPENED_SCHEMA_MISMATCH)
        + String(": scan kind '")
        + binding.kind_name
        + String("' opened '")
        + binding.name
        + String("' without ")
        + what
        + String(" '")
        + column
        + String("' that the plan reads")
        + why
        + String(". A kind must return every column")
        + String(" its request names, with the type its binding declared.")
    )


def _check_payload_schema(
    binding: ScanBinding, payload: Schema, required: List[String]
) raises:
    """Every column the leaf needs is present, and — where the binding declares
    it — has the declared type, parameters included (`_field_type_diff`)."""
    for i in range(len(required)):
        var at = _schema_index(payload, required[i])
        if at < 0:
            _refuse_schema(binding, String("column"), required[i])
        var declared = _schema_index(binding.schema, required[i])
        if declared < 0:
            continue
        var diff = _field_type_diff(payload, at, binding.schema, declared)
        if diff.byte_length() > 0:
            _refuse_schema(
                binding,
                String("the declared type of column"),
                required[i],
                String("returned vs declared: ") + diff,
            )


def _check_every_batch(
    binding: ScanBinding,
    batches: ArcPointer[Slab[RecordBatch]],
    payload: Schema,
) raises:
    """Every batch carries batch 0's schema: the same column names and FULL
    types (`_field_type_diff` — a DECIMAL128(18,4) under batch 0's (18,2), or
    a timestamp that lost its zone, is drift), in the same order, at the same
    width.

    `_check_payload_schema` reads batch 0 only, and
    `InMemorySource.from_shared_batches` checks each later batch's column COUNT
    only. The in-memory leaf reads EVERY batch under batch 0's schema, so a
    later batch that renames, reorders or retypes a column (keeping the count)
    would pass both and be read as the wrong column, or its buffers as the
    wrong type. A kind stitching live and compacted chunks is a realistic
    source of that drift. The cost is per batch and per column, never per row.

    The WIDTH is checked first, and must be: every per-column read below
    indexes batch 0's schema by the later batch's column index, so a WIDER
    later batch would read past batch 0's last field (`Schema.field_name` is
    an unchecked list index) rather than be refused by name.

    Strict over EVERY column, not only the ones the plan needs: an unneeded
    column that drifts is still an in-memory source whose one schema is false,
    and the one live payload reader known to bypass the scan's PROJECTION
    (`subquery_executor._try_collect_scalar_inner_source`, whose in-memory arm
    returns the leaf's one batch whole) reads it. That reader also ignores a
    scan-level FILTER, which is why this pass never puts one on the re-rooted
    scan (`_rerooted_subtree`)."""
    ref slab = batches[]
    for bi in range(1, len(slab)):
        ref got = slab[bi].schema
        var width = got.num_columns()
        if width != payload.num_columns():
            raise Error(
                String(SCAN_OPENED_SCHEMA_MISMATCH)
                + String(": scan kind '")
                + binding.kind_name
                + String("' opened '")
                + binding.name
                + String("' with batch ")
                + String(bi)
                + String(" carrying ")
                + String(width)
                + String(" columns where batch 0 carries ")
                + String(payload.num_columns())
                + String(". Every batch a kind returns must carry one schema.")
            )
        for c in range(width):
            var diff = String("")
            if got.field_name(c) == payload.field_name(c):
                diff = _field_type_diff(got, c, payload, c)
                if diff.byte_length() == 0:
                    continue
            else:
                diff = String("a different name")
            raise Error(
                String(SCAN_OPENED_SCHEMA_MISMATCH)
                + String(": scan kind '")
                + binding.kind_name
                + String("' opened '")
                + binding.name
                + String("' with batch ")
                + String(bi)
                + String(" carrying column ")
                + String(c)
                + String(" as '")
                + got.field_name(c)
                + String("' (")
                + got.field_at_unchecked(c).format_string()
                + String(") where batch 0 carries '")
                + payload.field_name(c)
                + String("' (")
                + payload.field_at_unchecked(c).format_string()
                + String("): ")
                + diff
                + String(". The leaf reads every batch under batch 0's")
                + String(" schema, so a renamed, reordered or retyped column is")
                + String(" wrong rows. Every batch a kind returns must carry one")
                + String(" schema: the same names and types, in the same order.")
            )


def _check_same_output(
    binding: ScanBinding, before: Schema, after: Schema
) raises:
    """The re-rooted subtree produces exactly the columns (names, order, FULL
    types — `_field_type_diff`) the binding leaf promised its parents.

    ⚠ OPEN, and not settled by any test in this package: whether the promise
    `before` still carries a DICTIONARY index type and a union's type ids
    once the OPTIMIZER has projected the leaf. This pass compares whatever
    `before` holds; if the optimizer's projection drops either parameter, a
    correct plan would be refused here. Only a real optimized plan can answer
    it, so it is an end-to-end assertion in the `komira.so` test that wires
    this pass into `EngineContext`, not a welded one here."""
    if before.num_columns() != after.num_columns():
        raise Error(
            String(SCAN_OPENED_SCHEMA_MISMATCH)
            + String(": re-rooting scan '")
            + binding.name
            + String("' of kind '")
            + binding.kind_name
            + String("' changed its output from ")
            + String(before.num_columns())
            + String(" to ")
            + String(after.num_columns())
            + String(" columns")
        )
    for i in range(before.num_columns()):
        if before.field_name(i) != after.field_name(i):
            _refuse_schema(
                binding, String("output column"), before.field_name(i)
            )
        var diff = _field_type_diff(after, i, before, i)
        if diff.byte_length() > 0:
            _refuse_schema(
                binding,
                String("output column"),
                before.field_name(i),
                String("re-rooted vs promised: ") + diff,
            )


def _rerooted_subtree(
    var ims: InMemorySource,
    var payload_schema: Schema,
    keep: List[String],
    filter: Optional[Expr],
) raises -> LogicalPlan:
    """The subtree that replaces an open-kind leaf: an IN_MEMORY scan over the
    kind's payload, and — when the leaf had a filter — that WHOLE filter as a
    `PLAN_FILTER` node above it, then a `PLAN_PROJECT` back to `keep` when the
    filter read columns `keep` does not carry.

    THE LEAF ALWAYS RE-PROJECTS TO THE DECLARED RELATION. `keep` is the leaf's
    own projection or, with none (the SELECT * shape), the binding's columns
    in the binding's order — NOT "no projection", which would make the output
    the PAYLOAD's schema, and a kind returning the superset or the column
    order `ScanRequest` permits would be refused by `_check_same_output` on
    exactly that shape and accepted on every other.

    ⚠ THE KEPT FILTER IS A NODE, NEVER THE SCAN'S OWN `filter`. A scan-level
    filter on an in-memory scan is a shape the optimizer never builds
    (`InMemorySource`'s pushdown gate rejects every conjunct,
    `komira_optimizer/optimizer_filter.mojo`, the PLAN_SCAN push arm), and at
    least one live reader of in-memory scans is written to that invariant and
    skips it: `komira_sdk_exec/subquery_executor
    ._try_collect_scalar_inner_source` returns the scan's one batch whole and
    never reads `sd.filter`, so an ungrouped scalar-subquery fold over a
    re-rooted leaf that CARRIED its filter would fold the UNFILTERED rows — a
    wrong number, no error — for exactly the coarse-pruning kind the module
    header promises is safe. A `PLAN_FILTER` between the aggregate and the
    scan is what that fold already declines on (`child.tag != PLAN_SCAN`), and
    no scan-level reader can skip an operator node. Pinned by
    `test_the_kept_filter_is_a_filter_node_above_an_unfiltered_scan`.
    """
    if not filter:
        return LogicalPlan.scan_from_source(
            SourceVariant(ims^), payload_schema^, Optional(keep.copy())
        )
    # The scan produces `keep` plus every column the filter reads (first
    # seen), so the Filter above it can evaluate; the Project drops those
    # extra columns again.
    var scan_cols = keep.copy()
    var refs = List[String]()
    var sink = ordered_name_sink(refs)
    walk_expr_column_refs(filter.value(), sink)
    for i in range(len(refs)):
        if not _list_has(scan_cols, refs[i]):
            scan_cols.append(String(refs[i]))
    var widened = len(scan_cols) != len(keep)
    var scan = LogicalPlan.scan_from_source(
        SourceVariant(ims^), payload_schema^, Optional(scan_cols^)
    )
    var filtered = LogicalPlan.filter(filter.value().copy(), scan^)
    if not widened:
        return filtered^
    # THE PROJECT'S SCHEMA IS RESTATED FROM ITS CHILD. `LogicalPlan.project`
    # infers each output field through `expr_walk.PlanColRefFields`, a
    # narrower clone that drops a dictionary's index type and a union's type
    # ids. This Project only SELECTS columns, so its output is exactly its
    # child's fields; without the restatement a DICTIONARY(INT8) column would
    # come out as DICTIONARY(INT32) and `_check_same_output` would refuse a
    # correct plan. Pinned by
    # `test_a_dictionary_keeps_its_index_type_through_the_project`.
    var selected = SchemaBuilder()
    var exprs = Slab[Expr]()
    for i in range(len(keep)):
        var at = _schema_index(filtered.output_schema, keep[i])
        if at < 0:
            raise Error(
                String(SCAN_OPENED_SCHEMA_MISMATCH)
                + String(": the re-rooted scan lost column '")
                + keep[i]
                + String("' the leaf projects")
            )
        selected.add_field(filtered.output_schema.field_at_unchecked(at))
        exprs.append(Expr.col_ref(String(keep[i])))
    var out = LogicalPlan.project(exprs^, filtered^)
    out.output_schema = selected.build()
    return out^


def _resolve_one_leaf(
    mut plan: LogicalPlan,
    resolvers: ScanMorselResolvers,
    scan_registry: ScanRegistry,
    mut snapshots: List[ResolvedScanSnapshot],
) raises:
    """Resolve, open and re-root ONE open-kind scan leaf. See the module
    header for the five steps."""
    ref sd = plan._scan.value()[]
    ref cached = sd.source.binding_ref()
    if not resolvers.contains(cached.kind_id):
        raise Error(
            String(SCAN_KIND_NOT_EXECUTABLE)
            + String(": scan '")
            + cached.name
            + String("' is of kind '")
            + cached.kind_name
            + String("' (id ")
            + String(cached.kind_id)
            + String("), which no resolver on this context serves;")
            + String(" registered: ")
            + resolvers.render_kinds()
            + String(". The plan is valid; this context cannot execute it")
            + String(" until that kind is registered.")
        )
    ref r = resolvers.get(cached.kind_id)
    # (2) the PER-EXECUTION binding. A copy by construction; `cached` — the
    # plan's own binding — keeps its token.
    var exec_binding = resolve_for_execution(r, cached)

    # (3) the request: hints only. `keep` is the leaf's OWN output columns:
    # its projection, or — with none, the SELECT * shape — the binding's
    # columns in the binding's order (see `_rerooted_subtree`).
    var pred: Optional[Expr] = None
    if sd.filter:
        pred = _pushable_conjuncts(exec_binding, sd.filter.value())
    var keep = List[String]()
    if sd.projection:
        keep = sd.projection.value().copy()
    else:
        for i in range(exec_binding.schema.num_columns()):
            keep.append(exec_binding.schema.field_name(i))
    var required = _needed_columns(exec_binding.schema, keep, sd.filter)
    var proj: Optional[List[String]] = None
    if sd.projection:
        proj = Optional(required.copy())
    var opened = r.open_scan(
        ScanRequest(exec_binding.copy(), proj^, pred^, SCAN_REQUEST_NO_LIMIT)
    )

    # (4) re-root over the returned Arc. An empty drain becomes ONE 0-row batch
    # carrying the binding's schema — the documented spelling of "an empty
    # in-memory relation with a known schema" (`InMemorySource
    # .from_record_batches`), so no walker route meets a zero-batch leaf.
    var payload_schema: Schema
    var batches: ArcPointer[Slab[RecordBatch]]
    if opened.num_batches() == 0:
        payload_schema = exec_binding.schema.copy()
        var one = Slab[RecordBatch].create(1)
        one.append(RecordBatch.empty_from_schema(payload_schema.copy()))
        batches = ArcPointer[Slab[RecordBatch]](one^)
    else:
        payload_schema = opened.batches[][0].schema.copy()
        batches = opened.batches.copy()
    _check_payload_schema(exec_binding, payload_schema, required)
    _check_every_batch(exec_binding, batches, payload_schema)
    var rows = opened.num_rows()

    var ims = InMemorySource.from_shared_batches(
        batches^, payload_schema.copy(), Optional[String](String(cached.name))
    )
    var leaf = _rerooted_subtree(ims^, payload_schema^, keep, sd.filter)
    # EVERY CHECK BEFORE THE BIND. The bind is the ACQUIRE (a registry slot and
    # a second reference on the payload Arc); a leaf refused after it would
    # leave that slot for the caller's scope to find. `leaf.output_schema`
    # exists as soon as the subtree is built, so nothing forces the check to
    # wait.
    _check_same_output(exec_binding, plan.output_schema, leaf.output_schema)
    _ = bind_plan_inmem_payloads(scan_registry, leaf)

    # (5) the side channel.
    snapshots.append(
        ResolvedScanSnapshot(
            kind_id=exec_binding.kind_id,
            kind_name=String(exec_binding.kind_name),
            name=String(exec_binding.name),
            snapshot_policy=exec_binding.snapshot_policy,
            snapshot_token=exec_binding.snapshot_token,
            resolved=opened.resolved.copy(),
            rows=rows,
        )
    )
    plan = leaf^


# =============================================================================
# §2 — the walk (plan half)
# =============================================================================


def resolve_plan_binding_leaves(
    mut plan: LogicalPlan,
    resolvers: ScanMorselResolvers,
    scan_registry: ScanRegistry,
    mut snapshots: List[ResolvedScanSnapshot],
) raises -> Int:
    """Resolve and re-root every OPEN-kind scan leaf in `plan` (including one
    inside a subquery) for THIS execution. Returns the number of leaves
    RE-ROOTED — not the number of registry slots minted, which can be larger
    (the per-leaf bind also binds a plain in-memory leaf inside the kept
    filter's subquery) — and appends one `ResolvedScanSnapshot` per leaf, in
    walk order.

    ⚠ AN ACQUIRE: THE CALLER OWES THE RELEASE. Each re-rooted leaf is bound
    into `scan_registry`, which mints a slot and takes a second reference on
    the kind's payload Arc. Open `scan_registry.open_scan_bind_scope()` (or
    `EngineContext.open_scan_bind_scope()`) BEFORE this call and hold the
    returned scope across this pass AND the execution; its destructor releases
    every slot minted since it opened, including on the unwind path (a leaf
    that raises after an earlier one bound). Assert the pairing against
    `ScanRegistry.resident_payload_rows()`, never `num_bound()`.

    ⚠ ORDER, the one `EngineContext.bind_plan_inmem_payloads` documents for
    its own bind, which this pass also performs:
      (1) AFTER the epoch gate (`check_scan_bindings_at_entry`). The per-leaf
          bind walks the kept filter and would REBIND an in-memory leaf there
          carrying another context's handle, laundering the
          `SCAN_BINDING_EPOCH_MISMATCH` refusal. (A cached open-kind leaf
          carries no handle, so the gate passes it.)
      (2) AFTER `_apply_scan_dedup`. `_inline_one_registry_scan` fires on
          `has_carrier_binding()` and rebuilds the node inline WITHOUT its
          binding, so a re-rooted leaf handed to it loses the handle this pass
          minted.
      (3) Scope opened BEFORE this pass (above), and this pass BEFORE the
          door's own `bind_plan_inmem_payloads`, which then finds these leaves
          live-bound and mints nothing for them.
    Never in an EXPLAIN-only path: it drains the kind.

    Hand it the PER-EXECUTION plan (see the module header): it re-roots in
    place, and on a raise the plan may be partly re-rooted.

    `scan_registry` is BORROWED, not `mut`: binding mutates the registry's
    Arc-held store, not the handle, and every bind verb takes `read self`
    (`scan_registry.mojo`, the BINDING section header). Taking it `mut` here
    would force a `mut` ripple through every widening frame that already
    binds with a `read` registry.

    Raises `SCAN_KIND_NOT_EXECUTABLE` for a leaf whose kind has no resolver,
    whatever the kind raises from `resolve_snapshot` / `open_scan`,
    `SCAN_OPENED_SCHEMA_MISMATCH` for a payload that does not carry what the
    plan reads, and `SCAN_RESOLVE_PASS_UNMODELLED_TAG` /
    `SCAN_RESOLVE_PASS_UNMODELLED_EXPR_TAG` for a tag this walk has no arm for.
    """
    var tag = plan.tag
    if tag == PLAN_SCAN:
        # A scan with no payload is a corrupt node and the integrity gate's
        # finding, not this walk's (the gate and the bind pass agree).
        if not plan._scan:
            return 0
        var n = 0
        # A SCAN IS NOT A LEAF FOR THIS WALK: its pushed filter is an `Expr`
        # and can carry a subquery. Descend it FIRST, so the filter the
        # re-rooted leaf keeps already carries resolved subquery leaves.
        ref sd = plan._scan.value()[]
        if sd.filter:
            n += resolve_expr_binding_leaves(
                sd.filter.value(), resolvers, scan_registry, snapshots
            )
        if _is_open_binding_leaf(plan):
            _resolve_one_leaf(plan, resolvers, scan_registry, snapshots)
            n += 1
        return n

    if tag == PLAN_VIEW_REF or tag == PLAN_CSE_REF:
        # Genuine leaves, for the bind pass's reasons: a VIEW_REF's subtree is
        # not spliced in yet, and a CSE_REF names a canonical occurrence walked
        # where it lives. Neither payload carries an `Expr`.
        return 0

    # ---- SINGLE CHILD, WITH EXPRESSIONS --------------------------------------
    if tag == PLAN_FILTER:
        if not plan._filter:
            return 0
        ref f = plan._filter.value()[]
        var n = resolve_expr_binding_leaves(
            f.predicate, resolvers, scan_registry, snapshots
        )
        return n + resolve_plan_binding_leaves(
            f.child[], resolvers, scan_registry, snapshots
        )
    if tag == PLAN_PROJECT:
        if not plan._project:
            return 0
        ref p = plan._project.value()[]
        var n = 0
        for i in range(len(p.exprs)):
            n += resolve_expr_binding_leaves(
                p.exprs[i], resolvers, scan_registry, snapshots
            )
        return n + resolve_plan_binding_leaves(
            p.child[], resolvers, scan_registry, snapshots
        )
    if tag == PLAN_AGGREGATE:
        if not plan._aggregate:
            return 0
        ref a = plan._aggregate.value()[]
        var n = 0
        for i in range(len(a.group_by)):
            n += resolve_expr_binding_leaves(
                a.group_by[i], resolvers, scan_registry, snapshots
            )
        for i in range(len(a.agg_exprs)):
            ref ae = a.agg_exprs[i]
            if ae.child:
                n += resolve_expr_binding_leaves(
                    ae.child.value(), resolvers, scan_registry, snapshots
                )
            if ae.child1:
                n += resolve_expr_binding_leaves(
                    ae.child1.value(), resolvers, scan_registry, snapshots
                )
            if ae.child2:
                n += resolve_expr_binding_leaves(
                    ae.child2.value(), resolvers, scan_registry, snapshots
                )
            if ae.child3:
                n += resolve_expr_binding_leaves(
                    ae.child3.value(), resolvers, scan_registry, snapshots
                )
        return n + resolve_plan_binding_leaves(
            a.child[], resolvers, scan_registry, snapshots
        )

    # ---- SINGLE CHILD, NO EXPRESSIONS ------------------------------------------
    # Each carries column NAMES, not `Expr` values (the bind pass and the gate
    # state the same, per payload), so only the child is descended.
    if tag == PLAN_SORT:
        if not plan._sort:
            return 0
        return resolve_plan_binding_leaves(
            plan._sort.value()[].child[], resolvers, scan_registry, snapshots
        )
    if tag == PLAN_LIMIT:
        if not plan._limit:
            return 0
        return resolve_plan_binding_leaves(
            plan._limit.value()[].child[], resolvers, scan_registry, snapshots
        )
    if tag == PLAN_DISTINCT:
        if not plan._distinct:
            return 0
        return resolve_plan_binding_leaves(
            plan._distinct.value()[].child[], resolvers, scan_registry, snapshots
        )
    if tag == PLAN_TOPN:
        if not plan._topn:
            return 0
        return resolve_plan_binding_leaves(
            plan._topn.value()[].child[], resolvers, scan_registry, snapshots
        )
    if tag == PLAN_PARTITION_BY:
        if not plan._partition_by:
            return 0
        return resolve_plan_binding_leaves(
            plan._partition_by.value()[].child[],
            resolvers,
            scan_registry,
            snapshots,
        )
    if tag == PLAN_PARTITION_TOPN:
        if not plan._partition_topn:
            return 0
        return resolve_plan_binding_leaves(
            plan._partition_topn.value()[].child[],
            resolvers,
            scan_registry,
            snapshots,
        )
    if tag == PLAN_CAST_TO_VARCHAR:
        if not plan._cast_to_varchar:
            return 0
        return resolve_plan_binding_leaves(
            plan._cast_to_varchar.value()[].child[],
            resolvers,
            scan_registry,
            snapshots,
        )

    # ---- TWO OR MORE CHILDREN ---------------------------------------------------
    if tag == PLAN_JOIN:
        if not plan._join:
            return 0
        ref j = plan._join.value()[]
        var n = resolve_plan_binding_leaves(
            j.left[], resolvers, scan_registry, snapshots
        )
        n += resolve_plan_binding_leaves(
            j.right[], resolvers, scan_registry, snapshots
        )
        if j.residual:
            n += resolve_expr_binding_leaves(
                j.residual.value()[], resolvers, scan_registry, snapshots
            )
        return n
    if tag == PLAN_ASOF_JOIN:
        if not plan._asof_join:
            return 0
        ref aj = plan._asof_join.value()[]
        var n = resolve_plan_binding_leaves(
            aj.left[], resolvers, scan_registry, snapshots
        )
        return n + resolve_plan_binding_leaves(
            aj.right[], resolvers, scan_registry, snapshots
        )
    if tag == PLAN_UNION:
        if not plan._union:
            return 0
        ref u = plan._union.value()[]
        var n = 0
        for i in range(u.num_children()):
            n += resolve_plan_binding_leaves(
                u.children[i][], resolvers, scan_registry, snapshots
            )
        return n

    raise Error(
        String(SCAN_RESOLVE_PASS_UNMODELLED_TAG)
        + String(": the open-kind scan resolve walk has no arm for plan tag ")
        + String(Int(tag))
        + String(" (")
        + plan_tag_name(tag)
        + String("). An open-kind scan underneath it would reach the executor")
        + String(" UNRESOLVED. Add the arm in scan_binding_resolve_pass.mojo")
        + String(" (and in scan_binding_bind_pass.mojo, which has the same")
        + String(" obligation) — descend its children AND every Expr it")
        + String(" carries, or return 0 with a comment saying why it is a")
        + String(" genuine leaf.")
    )


# =============================================================================
# §3 — the walk (expression half)
# =============================================================================


def resolve_expr_binding_leaves(
    mut expr: Expr,
    resolvers: ScanMorselResolvers,
    scan_registry: ScanRegistry,
    mut snapshots: List[ResolvedScanSnapshot],
) raises -> Int:
    """The EXPRESSION half of the walk: an `EXPR_CORRELATED_SUBQUERY` carries a
    whole `LogicalPlan`, so every expression a plan node carries is descended.
    Every `EXPR_*` tag has an arm; one without raises
    `SCAN_RESOLVE_PASS_UNMODELLED_EXPR_TAG`."""
    var tag = expr.tag
    if tag == EXPR_CORRELATED_SUBQUERY:
        if not expr._corr_subq:
            return 0
        ref cs = expr._corr_subq.value()[]
        return resolve_plan_binding_leaves(
            corr_data_inner_plan_ref(cs), resolvers, scan_registry, snapshots
        )

    # ---- GENUINE LEAVES ------------------------------------------------------
    if tag == EXPR_COL_REF or tag == EXPR_COL_IDX or tag == EXPR_LITERAL:
        return 0
    if tag == EXPR_WINDOW_FN:
        # `WindowFnData` carries column names and an op, no child `Expr`.
        return 0
    if tag == EXPR_BETWEEN or tag == EXPR_SORT_KEY:
        # Declared with no payload field and no factory; enumerated so that a
        # payload arriving extends an arm instead of discovering a hole.
        return 0

    # ---- ONE CHILD -------------------------------------------------------------
    if tag == EXPR_UNARY_OP:
        if not expr._unary:
            return 0
        return resolve_expr_binding_leaves(
            expr._unary.value().child[], resolvers, scan_registry, snapshots
        )
    if tag == EXPR_CAST:
        if not expr._cast:
            return 0
        return resolve_expr_binding_leaves(
            expr._cast.value().child[], resolvers, scan_registry, snapshots
        )
    if tag == EXPR_ALIAS:
        if not expr._alias:
            return 0
        return resolve_expr_binding_leaves(
            expr._alias.value().child[], resolvers, scan_registry, snapshots
        )
    if tag == EXPR_STRING_OP:
        if not expr._string_op:
            return 0
        return resolve_expr_binding_leaves(
            expr._string_op.value().child[], resolvers, scan_registry, snapshots
        )
    if tag == EXPR_IN_LIST:
        if not expr._in_list:
            return 0
        return resolve_expr_binding_leaves(
            expr._in_list.value().child[], resolvers, scan_registry, snapshots
        )
    if tag == EXPR_AGG_FN:
        if not expr._agg_fn:
            return 0
        return resolve_expr_binding_leaves(
            expr._agg_fn.value().child[], resolvers, scan_registry, snapshots
        )
    if tag == EXPR_REGEXP:
        if not expr._regexp:
            return 0
        return resolve_expr_binding_leaves(
            expr._regexp.value().child[], resolvers, scan_registry, snapshots
        )
    if tag == EXPR_STRUCT_FIELD:
        if not expr._struct_field:
            return 0
        return resolve_expr_binding_leaves(
            expr._struct_field.value().parent[],
            resolvers,
            scan_registry,
            snapshots,
        )
    if tag == EXPR_STRUCT_FIELD_IDX:
        if not expr._struct_field_idx:
            return 0
        return resolve_expr_binding_leaves(
            expr._struct_field_idx.value().parent[],
            resolvers,
            scan_registry,
            snapshots,
        )
    if tag == EXPR_JSON_EXTRACT:
        if not expr._json_extract:
            return 0
        return resolve_expr_binding_leaves(
            expr._json_extract.value().parent[],
            resolvers,
            scan_registry,
            snapshots,
        )
    if tag == EXPR_EXTRACT:
        if not expr._extract:
            return 0
        return resolve_expr_binding_leaves(
            expr._extract.value().child[], resolvers, scan_registry, snapshots
        )
    if tag == EXPR_MATH_FN:
        if not expr._math_fn:
            return 0
        return resolve_expr_binding_leaves(
            expr._math_fn.value().child[], resolvers, scan_registry, snapshots
        )
    if tag == EXPR_SUBSTRING:
        if not expr._substring:
            return 0
        return resolve_expr_binding_leaves(
            expr._substring.value().child[], resolvers, scan_registry, snapshots
        )
    if tag == EXPR_STRING_FN:
        if not expr._string_fn:
            return 0
        return resolve_expr_binding_leaves(
            expr._string_fn.value().child[], resolvers, scan_registry, snapshots
        )
    if tag == EXPR_UDF_CALL:
        if not expr._udf_call:
            return 0
        return resolve_expr_binding_leaves(
            expr._udf_call.value().child[], resolvers, scan_registry, snapshots
        )

    # ---- N CHILDREN -------------------------------------------------------------
    if tag == EXPR_STRING_FN_N:
        if not expr._string_fn_n:
            return 0
        var n = 0
        for i in range(expr.string_fn_n_num_args()):
            n += resolve_expr_binding_leaves(
                expr._string_fn_n.value().args[i],
                resolvers,
                scan_registry,
                snapshots,
            )
        return n
    if tag == EXPR_BINARY_OP:
        if not expr._binary:
            return 0
        ref b = expr._binary.value()
        var n = resolve_expr_binding_leaves(
            b.left[], resolvers, scan_registry, snapshots
        )
        return n + resolve_expr_binding_leaves(
            b.right[], resolvers, scan_registry, snapshots
        )
    if tag == EXPR_MATH_FN2:
        if not expr._math_fn2:
            return 0
        ref m = expr._math_fn2.value()
        var n = resolve_expr_binding_leaves(
            m.left[], resolvers, scan_registry, snapshots
        )
        return n + resolve_expr_binding_leaves(
            m.right[], resolvers, scan_registry, snapshots
        )
    if tag == EXPR_MAP_GET:
        if not expr._map_get:
            return 0
        ref g = expr._map_get.value()
        var n = resolve_expr_binding_leaves(
            g.parent[], resolvers, scan_registry, snapshots
        )
        return n + resolve_expr_binding_leaves(
            g.key[], resolvers, scan_registry, snapshots
        )
    if tag == EXPR_WHEN:
        if not expr._when:
            return 0
        ref w = expr._when.value()
        var n = 0
        for i in range(len(w.cases)):
            n += resolve_expr_binding_leaves(
                w.cases[i].condition[], resolvers, scan_registry, snapshots
            )
            n += resolve_expr_binding_leaves(
                w.cases[i].result[], resolvers, scan_registry, snapshots
            )
        return n + resolve_expr_binding_leaves(
            w.default[], resolvers, scan_registry, snapshots
        )

    raise Error(
        String(SCAN_RESOLVE_PASS_UNMODELLED_EXPR_TAG)
        + String(": the open-kind scan resolve walk has no arm for expression")
        + String(" tag ")
        + String(Int(tag))
        + String(" (")
        + expr_tag_name(tag)
        + String("). EXPR_CORRELATED_SUBQUERY proves an expression can contain")
        + String(" a whole LogicalPlan, so an unmodelled expression tag can")
        + String(" hide an open-kind scan that reaches the executor")
        + String(" UNRESOLVED. Add the arm in scan_binding_resolve_pass.mojo")
        + String(" — descend its child expressions, or return 0 with a comment")
        + String(" saying why it cannot contain a plan.")
    )
