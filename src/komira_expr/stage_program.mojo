# =============================================================================
# StageProgram engine IR foundation
#
# This module publishes the foundational engine IR for `Stage[Program]`:
#
#   - 3 role traits: FilterLike / ProjectsLike / BreakerLike
#   - 12 BreakerSpec arms: HashAggSpec / SortSpec / TopNSpec / WindowSpec /
#     PartitionUdfSpec / WindowUdfSpec / JoinProbeSpec / DistinctSpec /
#     PartitionTopNSpec / AsofJoinSpec (§5) and JoinBuildSpec /
#     AsofJoinBuildSpec (§5b)
#   - 3 sentinel structs (Optional-shaped slot fillers):
#     NoFilter / NoProjects / NoBreaker
#   - 1 FilterLike conformer over a predicate: PredicateFilter[P]
#   - 1 aggregate marker: StageProgram[Filter, Projects, Breaker]
#   - 1 placeholder ProjectsLike conformer for test coverage:
#     ProjectListStub[arity: Int] (superseded by the typed per-arity-N
#     Project family — kept here for unit-test self-containment).
#
# The consumer these shapes were written for is not in komira: a
# `Stage[Program]` operator template that holds one state per breaker kind
# and comptime-dispatches on `Self.Breaker.tag()`. Every mention below of
# `Stage`, its arms or "the engine" describes that intended consumer, not
# code in the tree. In the tree, `tests/test_stage_program.mojo` pins every
# accessor row, and `ProjectsLike` is implemented by
# `typed_projects.ProjectList` and `komira_op_agg_state.row_map_projects`.
#
# # Design discipline
#
# `Self.<wrapper>.<sub-param>` through an `AnyType`-bound comptime parameter
# does not compile. The SDK chain must carry slots FLAT and trait-bound, not as
# a single AnyType-bound `Program: AnyType` slot.
#
# Traits cannot declare comptime-parameter slots, only `@staticmethod` methods
# returning comptime values. BreakerSpec sub-parameters (n_keys, n_aggs,
# n_sort_keys, topn_n, n_part_keys, n_window_fns, n_probe_keys, join_t) are
# encoded as Int parameters on each per-flavor struct and exposed UNIFORMLY
# through the BreakerLike trait via `@staticmethod fn n_X_static() -> Int`
# accessors that return `-1` for sub-parameters the flavor does NOT carry. The
# Stage[Program] body comptime-dispatches via `Self.Breaker.tag()` and reads
# sub-state via `Self.Breaker.n_X_static()`.
#
# `comptime if Self.<slot>.tag() == CONST:` dispatches correctly per chain
# shape, with branches dead-code eliminated per Program instantiation.
#
# # Optional[T] / sentinel-struct workaround
#
# Mojo accepts `Optional[ParametricStruct[T0, T1]]` as a comptime slot, BUT
# the slots take sentinel structs (NoFilter / NoProjects / NoBreaker)
# instead, because:
#   (a) sentinel structs keep all 3 StageProgram slots trait-bound and
#       uniform (no special Optional unwrap shape),
#   (b) it avoids `Self.Filter.value().X` unwrap noise in the engine body.
#
# The semantic remains: NoFilter IS the None arm of an Optional[FilterLike];
# NoProjects IS the None arm of an Optional[ProjectsLike]; NoBreaker IS the
# None arm of an Optional[BreakerSpec].
#
# # Encapsulation invariants
#
#   - NO UnsafePointer anywhere in this module.
#   - NO wildcard origins anywhere in this module (no fields hold
#     references). Every struct is a single `var sentinel: Int` POD except
#     `PredicateFilter`, which holds its predicate by value (`var pred`).
#   - NO partial-move-via-UnsafePointer shapes.
#
# # Cross-references
#
#   - ExprXBool / ExprXI64 / ExprXF64 / ExprXString trait family:
#     komira_expr.expr_x
# =============================================================================

from std.collections import Optional

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.schema import RecordBatch, RecordBatchBuilder, SchemaBuilder, Field
from komira_arrow.batch_view import BatchView

from komira_udf.column_resolver import ColumnResolver
from komira_expr.expr_x import ExprXBool
from komira_udf.row_transform import RowTransform


# -----------------------------------------------------------------------------
# §1 — Breaker discriminator tags
#
# Module-scope comptime Int constants. Used by `BreakerLike.tag()` returns
# and by the engine's `comptime if Self.Breaker.tag() == BREAKER_X:` dispatch.
# -----------------------------------------------------------------------------

comptime BREAKER_NONE: Int = 0
comptime BREAKER_HASH_AGG: Int = 1
comptime BREAKER_SORT: Int = 2
comptime BREAKER_TOPN: Int = 3
comptime BREAKER_WINDOW: Int = 4
comptime BREAKER_JOIN_PROBE: Int = 5
comptime BREAKER_DISTINCT: Int = 6
comptime BREAKER_PARTITION_TOPN: Int = 7
comptime BREAKER_ASOF_JOIN: Int = 8

# -----------------------------------------------------------------------------
# BUILD-side breaker tags
#
# The two BUILD-side breaker arms — `JoinBuildSpec` / `AsofJoinBuildSpec` —
# name the build side of a hash join and of an asof join: a breaker that
# consumes the build input into a table and emits no batch downstream. The
# table and its handoff to the probe side are not in komira.
#
# Numbering: the query-shape arms are 0..8 and the two build arms follow at
# 9 / 10.
# -----------------------------------------------------------------------------

comptime BREAKER_JOIN_BUILD: Int = 9
comptime BREAKER_ASOF_JOIN_BUILD: Int = 10

# -----------------------------------------------------------------------------
# PARTITION-UDF breaker tag
#
# The `partition_local` stateful-UDF breaker (`komira_udf.PartitionLocalMapFn`):
# buffer every input row, then per partition run the UDF's
# `run_partition_row` scan, emitting one output column appended to the input
# columns. It has its own tag rather than sharing `BREAKER_WINDOW` /
# `WindowSpec`. The operator that runs it is not in komira.
# -----------------------------------------------------------------------------

comptime BREAKER_PARTITION_UDF: Int = 11


# -----------------------------------------------------------------------------
# WINDOW-UDF breaker tag
#
# The custom frame-bearing window-fn breaker (`komira_udf.WindowFn`). A
# sibling of `BREAKER_PARTITION_UDF`: buffer every input row, then per
# partition, for each row r, compute its ROWS frame `[lo(r), hi(r))` and call
# the UDF over it (`FrameView`), emitting one output column. It has its own
# tag, distinct from `BREAKER_WINDOW` and `BREAKER_PARTITION_UDF`. The
# operator that runs it is not in komira.
# -----------------------------------------------------------------------------

comptime BREAKER_WINDOW_UDF: Int = 12


# -----------------------------------------------------------------------------
# §2 — Join-type comptime constants
#
# Carried by `JoinProbeSpec[n_probe_keys, join_t]`. Read via
# `Self.Breaker.join_t_static()`. This module names the join types; it
# neither checks a `join_t` value nor implements any join.
# -----------------------------------------------------------------------------

comptime JOIN_INNER: Int = 1
comptime JOIN_LEFT: Int = 2
comptime JOIN_RIGHT: Int = 3
comptime JOIN_SEMI: Int = 4
comptime JOIN_ANTI: Int = 5
# FULL OUTER: the INNER matches plus the unmatched rows of both sides, each
# null-padded on the other side.
comptime JOIN_OUTER: Int = 6


# -----------------------------------------------------------------------------
# §3 — Role traits
#
# Three role traits bound the three slots on `StageProgram[Filter,
# Projects, Breaker]`. Every conformer is required to be Copyable,
# Movable, and ImplicitlyCopyable so the aggregate marker and its intended
# consumer can instantiate them without ownership friction. `ProjectsLike` is
# the exception: it requires only `(Movable, Deinitable)` (see its docstring).
# -----------------------------------------------------------------------------


trait FilterLike(Copyable, Movable, ImplicitlyCopyable, Deinitable):
    """Role trait for the StageProgram Filter slot.

    Conformers: `NoFilter` (sentinel) and `PredicateFilter[P]`, which wraps
    an `ExprXBool` conformer (tests/test_stage_program.mojo wraps its own
    stubs, e.g. `GtNamed`).

    The Filter slot is Optional-by-convention: `NoFilter` is the
    sentinel for the Optional.None case. We do NOT use stdlib
    `Optional` here because Optional[T] adds visual noise at every
    `Self.Filter.X` read site and would force the engine body to
    `.value()` unwrap before reading sub-state.

    The single trait method `fdescribe()` returns a discriminator /
    identity Int used by tests and by EXPLAIN ANALYZE label
    preservation: `NoFilter` returns 0; production ExprXBool
    conformers return a depth-encoded Int.

    # The executable bridge surface

    `keep_row` / `keep_simd` are the FilterLike EXECUTABLE surface — the
    marker-trait-vs-executable-trait bridge, resolved for the FILTER slot
    the same way it is resolved for
    the BREAKER slot: the executable surface lives on the marker trait so the
    generic `Stage` NoBreaker arm can drive `Self.Filter.keep_simd[W, bo]` /
    `Self.Filter.keep_row[bo]` UNIFORMLY without naming a concrete `Predicate`.
    `NoFilter` returns all-True (the pass-through sentinel; the arm comptime-
    elides the filter pass via `fdescribe() == 0`). `PredicateFilter[P]`
    is the option-(C) wrapper: it stores a `P: Predicate & ImplicitlyCopyable`
    field and delegates `keep_row` to `self.pred.eval_scalar` (and `keep_simd`
    to the conformer's hand-SIMD when available — the wrapper carries the
    Pattern-B per-lane default through `Predicate.eval[W]`).
    """

    @staticmethod
    def fdescribe() -> Int:
        ...

    @staticmethod
    def make_default() -> Self:
        """Construct the slot's default-no-filter value. `NoFilter`
        returns its sentinel; `PredicateFilter[P]` has NO sensible default (it
        must carry a real predicate) so its body is a `comptime assert False`
        — never monomorphized, because the `Stage` convenience `state=`-only
        ctor (the ONLY caller) is used only for sentinel-Filter breaker stages.
        Lets `Stage(state=...)` default-construct the Filter slot without a
        no-arg ctor (the marker structs are `@fieldwise_init`, no no-arg ctor)."""
        ...

    def keep_row[bo: Origin[mut=False]](
        mut self, batch: BatchView[bo], i: Int
    ) raises -> Bool:
        """Evaluate the filter for the single row at logical index `i`.
        Returns True iff the row is kept. `NoFilter` returns True (pass-
        through); `PredicateFilter[P]` delegates to `self.pred.eval_scalar`."""
        ...

    def keep_simd[W: Int, bo: Origin[mut=False]](
        mut self, batch: BatchView[bo], i: Int
    ) raises -> SIMD[DType.bool, W]:
        """Evaluate the filter for W contiguous rows starting at logical index
        `i` (the SIMD-chunk fast path of the NoBreaker filter loop). Out-of-
        bounds lanes are `False`. `NoFilter` returns all-True; `PredicateFilter`
        delegates to the predicate's `eval[W]` (Pattern-B per-lane default or
        the conformer's hand-SIMD override)."""
        ...

    # --- bind: propagate to inner Expr (PredicateFilter wraps it) ---
    def bind(mut self, resolver: ColumnResolver) raises:
        """Walk to populate runtime _idx on every leaf inside the filter's
        Expr tree. NoFilter no-ops; PredicateFilter[P] delegates to
        `self.pred.bind(resolver)`. Default body is no-op for sentinel
        conformers."""
        pass


trait ProjectsLike(Movable, Deinitable):
    """Role trait for the StageProgram Projects slot.

    Conformers: `NoProjects`, the placeholder `ProjectListStub[arity: Int]`
    (so unit tests can exercise non-pass-through Projects shapes), the
    variadic `ProjectList[*Outs]` in `typed_projects.mojo`, and
    `RowMapProjects` in `komira_op_agg_state.row_map_projects`.

    # Why the bound is `(Movable, Deinitable)`
    #
    # The leaf ExprX conformers (`ColXI64[name]`, etc.) carry a runtime
    # `_idx = -1` that `bind(resolver)` populates, so `ProjectList[*Outs]`
    # stores a `_outs: Tuple[*Self.Outs]` instance field and `emit_projected`
    # uses `self._outs[k].project_one` instance dispatch (a bound leaf carries
    # `_idx >= 0` after `bind`); `bind` walks `self._outs[k].bind(resolver)`.
    # That storage shape is NOT ImplicitlyCopyable when an `Outs` element is
    # not, so the ProjectsLike bound is `(Movable, Deinitable)`.
    #
    # Every holder of a ProjectsLike needs only that:
    #   (a) A `Stage[F, Projects: ProjectsLike, B, BState]` (not in komira)
    #       would store `var projects: Self.Projects`, which needs only
    #       Movable.
    #   (b) `StageProgram[F, Projects: ProjectsLike, B]`: POD `var sentinel:
    #       Int` aggregate — type parameters are pure compile-time witnesses,
    #       no instance storage of Projects, so the StageProgram's
    #       `(Copyable, Movable, ImplicitlyCopyable)` self-bound is
    #       satisfiable regardless of Projects's own bound.
    #   (c) The sentinel conformers (NoProjects, ProjectListStub) are POD
    #       Ints, hence trivially Movable +
    #       Deinitable (and incidentally Copyable).


    `pdescribe()`: discriminator / identity Int for tests + EXPLAIN
    ANALYZE label preservation. NoProjects returns 0;
    ProjectListStub returns the arity; production conformers return
    a stable schema-shape hash.

    # The executable bridge surface

    `emit_projected` is the ProjectsLike EXECUTABLE surface — the same
    trait-bridge resolution as the BREAKER slot. The generic
    `Stage` NoBreaker arm hands the surviving-row index list to
    `Self.Projects.emit_projected[bo](batch, survivors)`; the concrete
    conformer (`ProjectList[*Outs]`) is where `*Outs` is in scope, so it
    `@parameter for`-fans-out over the output pack and builds one column per
    `Outs[k]` (each output column's DType is `Outs[k].dtype_at[0]()`, its
    values come from `Outs[k].eval_scalar_s`). `NoProjects` raises (the
    pass-through arm comptime-elides it via `pdescribe() == 0` and emits via
    `gather_batch` instead — `NoProjects` carries no output schema, so a
    projected emit through it is a wiring error).
    """

    @staticmethod
    def pdescribe() -> Int:
        ...

    @staticmethod
    def make_default() -> Self:
        """Construct the slot's default-no-projects value. `NoProjects`
        returns its sentinel; `ProjectList[*Outs]` has NO sensible default —
        its body is a `comptime assert False` (never monomorphized; the `Stage`
        convenience `state=`-only ctor is used only for sentinel-Projects
        breaker stages). See `FilterLike.make_default`."""
        ...

    def emit_projected[bo: Origin[mut=False]](
        mut self, batch: BatchView[bo], survivors: List[Int]
    ) raises -> RecordBatch:
        """Build the projected output `RecordBatch` over the surviving rows.

        `survivors` is the post-filter logical-row-index list (in input
        order). The conformer evaluates each output expression `Outs[k]` per
        surviving row and emits one output column per `k` in pack order, with
        a fresh output schema (field `k` named `out{k}`, DType
        `Outs[k].dtype_at[0]()`). `NoProjects` raises — pass-through emits via
        `gather_batch`, never through this method.

        `self` is `mut` so the
        production `ProjectList[*Outs]` conformer can dispatch
        `self._outs[k].project_one[...]` through the trait's `mut self`
        `project_one` overload (the bound Out instance's runtime `_idx` —
        populated by `bind` — is consulted in `eval_scalar_s`)."""
        ...

    # --- bind: propagate to projected Exprs -------------------------
    def bind(mut self, resolver: ColumnResolver) raises:
        """Walk to populate runtime _idx on every leaf inside the project
        Expr pack. NoProjects and ProjectListStub keep this no-op default;
        `ProjectList[*Outs]` (typed_projects.mojo) overrides it to call
        `bind` on each stored output instance."""
        pass


trait BreakerLike(Copyable, Movable, ImplicitlyCopyable, Deinitable):
    """Role trait for the StageProgram Breaker slot.

    Conformers: `NoBreaker` + the 12 BreakerSpec arms of §5 and §5b.

    UNIFORM accessor surface: every conformer
    implements all 9 accessors, returning `-1` for slots the flavor
    does NOT carry. This is the canonical Mojo 1.0.0b1 idiom — traits
    cannot declare comptime-parameter slots, so each sub-parameter is
    exposed via a `@staticmethod` accessor returning a comptime Int.

    Per-flavor accessor population:

    | Flavor        | tag             | n_keys | n_aggs | n_sort_keys | topn_n | n_part_keys | n_window_fns | n_probe_keys | join_t |
    |---------------|-----------------|--------|--------|-------------|--------|-------------|--------------|--------------|--------|
    | NoBreaker     | BREAKER_NONE    | -1     | -1     | -1          | -1     | -1          | -1           | -1           | -1     |
    | HashAggSpec   | BREAKER_HASH_AGG| K      | A      | -1          | -1     | -1          | -1           | -1           | -1     |
    | SortSpec      | BREAKER_SORT    | -1     | -1     | S           | -1     | -1          | -1           | -1           | -1     |
    | TopNSpec      | BREAKER_TOPN    | -1     | -1     | S           | N      | -1          | -1           | -1           | -1     |
    | WindowSpec    | BREAKER_WINDOW  | -1     | -1     | -1          | -1     | P           | W            | -1           | -1     |
    | JoinProbeSpec | BREAKER_JOIN_PROBE| -1   | -1     | -1          | -1     | -1          | -1           | Pk           | JT     |
    | PartitionUdfSpec | BREAKER_PARTITION_UDF | -1 | -1 | -1        | -1     | P           | -1           | -1           | -1     |
    | WindowUdfSpec | BREAKER_WINDOW_UDF| -1   | -1     | -1          | -1     | P           | -1           | -1           | -1     |
    | DistinctSpec  | BREAKER_DISTINCT| K      | -1     | -1          | -1     | -1          | -1           | -1           | -1     |
    | PartitionTopNSpec | BREAKER_PARTITION_TOPN | -1 | -1 | S        | N      | P           | -1           | -1           | -1     |
    | AsofJoinSpec  | BREAKER_ASOF_JOIN | -1   | -1     | -1          | -1     | -1          | -1           | Pk           | -1     |
    | JoinBuildSpec | BREAKER_JOIN_BUILD | K     | Pl     | -1          | -1     | -1          | -1           | -1           | -1     |
    | AsofJoinBuildSpec | BREAKER_ASOF_JOIN_BUILD | K | Pl | -1       | -1     | -1          | -1           | -1           | -1     |

    `Pl` is the build arms' payload count, carried in the n_aggs slot.

    The Stage[Program] body comptime-dispatches via
    `comptime if Self.Breaker.tag() == BREAKER_HASH_AGG: ...` and
    reads sub-state via `comptime n_keys = Self.Breaker.n_keys_static()`.
    Mojo dead-code-
    eliminates the non-matching arms per Program instantiation.
    """

    @staticmethod
    def tag() -> Int:
        ...

    @staticmethod
    def n_keys_static() -> Int:
        ...

    @staticmethod
    def n_aggs_static() -> Int:
        ...

    @staticmethod
    def n_sort_keys_static() -> Int:
        ...

    @staticmethod
    def topn_n_static() -> Int:
        ...

    @staticmethod
    def n_part_keys_static() -> Int:
        ...

    @staticmethod
    def n_window_fns_static() -> Int:
        ...

    @staticmethod
    def n_probe_keys_static() -> Int:
        ...

    @staticmethod
    def join_t_static() -> Int:
        ...

    # --- bind: propagate to Exprs inside the BreakerSpec ---------
    def bind(mut self, resolver: ColumnResolver) raises:
        """The BreakerSpec marker arms (HashAggSpec / SortSpec / etc.) are
        POD `var sentinel: Int` markers carrying NO Expr fields. The Expr
        instances that need bind live on the breaker STATE (HashAggTable's
        keys + aggregators, SortBuffer's keys, Stage_Window's pred/part_key/
        val fields). Those live on `Stage.state: Self.BState` and on the
        Stage_Window/Sort/TopN primitives which carry their own bind.

        Default body is no-op for the spec markers."""
        pass


# -----------------------------------------------------------------------------
# §4 — Sentinel structs
#
# Three POD `var sentinel: Int` structs filling the Optional.None arm
# of each role trait. Each is its own type so the engine can dispatch
# on `Self.Filter is NoFilter` (compile-time identity) or — more
# idiomatically — branch on `Self.Filter.fdescribe() == 0`.
# -----------------------------------------------------------------------------


@fieldwise_init
struct NoFilter(FilterLike):
    """Sentinel for the StageProgram Filter slot.

    Indicates "no filter applied — every input row passes". The
    engine's Stage[Program].process_batch body comptime-elides the
    filter pass when `Self.Filter.fdescribe() == 0`.
    """

    var sentinel: Int

    @staticmethod
    def fdescribe() -> Int:
        return 0

    @staticmethod
    def make_default() -> Self:
        """The `NoFilter` sentinel (convenience-ctor default)."""
        return NoFilter(0)

    def keep_row[bo: Origin[mut=False]](
        mut self, batch: BatchView[bo], i: Int
    ) raises -> Bool:
        """Pass-through: every row is kept."""
        return True

    def keep_simd[W: Int, bo: Origin[mut=False]](
        mut self, batch: BatchView[bo], i: Int
    ) raises -> SIMD[DType.bool, W]:
        """Pass-through: every lane kept (the NoBreaker arm comptime-elides
        the filter pass when `fdescribe() == 0`, so this is never reached in
        practice; the all-True body keeps the conformance honest)."""
        return SIMD[DType.bool, W](fill=True)


@fieldwise_init
struct NoProjects(ProjectsLike):
    """Sentinel for the StageProgram Projects slot.

    Indicates "pass-through schema — emit input batch's schema
    unchanged". Engine compiles a gather-by-survivor-index emit
    path (no per-column Expr eval).
    """

    var sentinel: Int

    @staticmethod
    def pdescribe() -> Int:
        return 0

    @staticmethod
    def make_default() -> Self:
        """The `NoProjects` sentinel (convenience-ctor default)."""
        return NoProjects(0)

    def emit_projected[bo: Origin[mut=False]](
        mut self, batch: BatchView[bo], survivors: List[Int]
    ) raises -> RecordBatch:
        """Raise-stub — pass-through emits via `gather_batch` (the NoBreaker
        arm comptime-elides this when `pdescribe() == 0`). `NoProjects` carries
        no output schema, so reaching here is a wiring error.

        `mut self` (the instance-dispatch trait shape)."""
        raise Error(
            "NoProjects.emit_projected: pass-through must emit via gather_batch"
        )


@fieldwise_init
struct NoBreaker(BreakerLike):
    """Sentinel for the StageProgram Breaker slot.

    Indicates "no pipeline-breaker — stage is non-breaker (filter +
    project only)". `finalize()` returns None on the resulting
    Stage; `process_batch` returns per-batch emit.
    """

    var sentinel: Int

    @staticmethod
    def tag() -> Int:
        return BREAKER_NONE

    @staticmethod
    def n_keys_static() -> Int:
        return -1

    @staticmethod
    def n_aggs_static() -> Int:
        return -1

    @staticmethod
    def n_sort_keys_static() -> Int:
        return -1

    @staticmethod
    def topn_n_static() -> Int:
        return -1

    @staticmethod
    def n_part_keys_static() -> Int:
        return -1

    @staticmethod
    def n_window_fns_static() -> Int:
        return -1

    @staticmethod
    def n_probe_keys_static() -> Int:
        return -1

    @staticmethod
    def join_t_static() -> Int:
        return -1


# -----------------------------------------------------------------------------
# §4b — PredicateFilter[P] — the option-(C) FilterLike-wraps-Predicate conformer
#
# The marker-slot↔executable-trait bridge for the FILTER slot.
# `PredicateFilter[P]` stores a `Predicate` conformer and exposes the
# `FilterLike` executable surface (`keep_row` / `keep_simd`) by delegating to
# `P.eval_scalar` / `P.eval[W]`. This is the precise shape required:
#
#   - `FilterLike` requires `ImplicitlyCopyable`; the bare `Predicate` trait
#     surface is `(Movable, Copyable, Deinitable)` — NOT
#     `ImplicitlyCopyable`. A `var pred: P` field with `P: Predicate` alone
#     makes the wrapper non-`ImplicitlyCopyable` ("cannot synthesize copy
#     constructor because field 'pred' has non-copyable type 'P'"). So the
#     wrapper's parameter bound is TIGHTENED to `P: Predicate &
#     ImplicitlyCopyable` (a hard constraint). Every in-tree `ExprXBool`
#     conformer already refines `Predicate` AND is `ImplicitlyCopyable`, so
#     built-in filters wrap directly.
#   - The Filter slot DIFFERS from the Projects slot: `Predicate.eval_scalar`
#     is `mut self`, so the wrapper STORES the predicate value as a real field
#     (unlike `ProjectList`'s storage-free `*Outs` type pack — `RowTransform`
#     output exprs are read statically through the type parameter).
#
# `fdescribe()` returns a nonzero discriminator so the `Stage` NoBreaker arm
# runs the filter pass (it comptime-elides the pass only for `NoFilter`, whose
# `fdescribe() == 0`).
# -----------------------------------------------------------------------------


@fieldwise_init
struct PredicateFilter[P: ExprXBool](FilterLike):
    """The option-(C) `FilterLike`-wraps-`ExprXBool` conformer.

    Stores an `ExprXBool` value and drives the `FilterLike` executable surface
    by calling the conformer's HAND-SIMD `eval_simd[W]` / hand-scalar
    `eval_scalar_s` STATICS directly through the type parameter `P`.

    PERF: the bound was previously `P: Predicate &
    ImplicitlyCopyable` and `keep_simd` delegated to the instance method
    `pred.eval[W]` — the inherited `Predicate.eval[W]` Pattern-B per-lane
    fan-out default. Because an `ExprXBool` conformer CANNOT override
    `Predicate.eval[W]` (`expr_x.mojo` FINDING #1 — a refining trait cannot
    override a parent's already-defaulted method), that path NEVER reached the
    conformer's real `eval_simd` — every typed filter ran a SCALAR per-lane
    eval (each lane re-loading every column with `load[1]`). On TPC-H Q6 over
    6M lineitem rows this made the filter ~80-150ms (the entire typed-Stage
    bottleneck; the accumulate was near-free by comparison). Tightening the
    bound to `P: ExprXBool` lets `keep_simd` call `P.eval_simd[W]` — the
    conformer's vectorized W-wide column loads + lane compares — restoring the
    hot-path SIMD. `ExprXBool` already refines
    `ImplicitlyCopyable`, so the bound carries it transitively (the field
    stays copyable; `FilterLike`'s `ImplicitlyCopyable` requirement holds).
    Every in-tree `PredicateFilter[...]` was already instantiated with an
    `ExprXBool` conformer, so the tightening is a no-op on the call surface
    and a real perf win on the hot path.
    """

    var pred: Self.P

    @staticmethod
    def fdescribe() -> Int:
        """Nonzero so the `Stage` NoBreaker arm runs the filter pass (only
        `NoFilter`'s `fdescribe() == 0` triggers the pass-through elision)."""
        return 1

    @staticmethod
    def make_default() -> Self:
        """NO default — a `PredicateFilter` must carry a real predicate VALUE.
        `comptime assert False` makes any instantiation a hard compile error;
        this is NEVER monomorphized because the only caller (the `Stage`
        convenience `state=`-only ctor) is used solely for sentinel-`NoFilter`
        breaker stages. A `PredicateFilter` NoBreaker stage uses the 3-arg
        `Stage(filter, projects, state)` ctor instead."""
        comptime assert False, (
            "PredicateFilter has no default — use Stage(filter, projects, state)"
        )

    @always_inline
    def keep_row[bo: Origin[mut=False]](
        mut self, batch: BatchView[bo], i: Int
    ) raises -> Bool:
        """Call the conformer's hand-scalar `eval_scalar_s` — the fast path
        (NOT the `Predicate.eval_scalar` delegating instance method).

        Instance dispatch via FIELD access
        (`self.pred.eval_scalar_s`) — the `var pred: Self.P` field was already
        stored on this struct from prior work; the call site simply switches
        from static `Self.P.eval_scalar_s` to instance `self.pred.eval_scalar_s`."""
        return self.pred.eval_scalar_s[bo](batch, i)

    @always_inline
    def keep_simd[W: Int, bo: Origin[mut=False]](
        mut self, batch: BatchView[bo], i: Int
    ) raises -> SIMD[DType.bool, W]:
        """Call the conformer's HAND-SIMD `eval_simd[W]` directly — the
        vectorized W-wide column loads + lane compares. This is the hot-path
        SIMD; it does NOT route through the slow inherited `Predicate.eval[W]`
        per-lane fan-out (which an `ExprXBool` cannot override; see the struct
        doc PERF note). There is no in-bounds masking here: the caller must
        keep `i + W <= n` and handle the remainder with `keep_row`.

        Instance dispatch via FIELD access."""
        return self.pred.eval_simd[W, bo](batch, i)

    def bind(mut self, resolver: ColumnResolver) raises:
        """Delegate to the wrapped ExprXBool predicate's bind."""
        self.pred.bind(resolver)


@always_inline
def predicate_filter[
    P: ExprXBool
](var pred: P) -> PredicateFilter[P]:
    """Factory for a `PredicateFilter` over an `ExprXBool` conformer.

    The ergonomic call-site entry point: `predicate_filter(GtXI64(...))`.
    """
    return PredicateFilter[P](pred=pred^)


# -----------------------------------------------------------------------------
# §5 — BreakerSpec arms (the query-shape side; §5b holds the build arms)
#
# Each arm encodes its sub-state via comptime-Int parameters. The uniform BreakerLike trait surface is
# implemented by every arm with `-1` for fields the flavor does NOT
# carry. A consumer reads sub-state via `Self.Breaker.<accessor>_static()`
# calls, resolved at compile time. An arm carries its counts only: no arm
# holds or names the state that would execute it.
# -----------------------------------------------------------------------------


@fieldwise_init
struct HashAggSpec[n_keys: Int, n_aggs: Int](BreakerLike):
    """HashAgg breaker — `n_keys` group-by keys, `n_aggs` aggregates.

    Carried through `n_keys_static()` and `n_aggs_static()`. `n_keys == 0`
    is the scalar-aggregate shape: one group over every row.
    """

    var sentinel: Int

    @staticmethod
    def tag() -> Int:
        return BREAKER_HASH_AGG

    @staticmethod
    def n_keys_static() -> Int:
        return Self.n_keys

    @staticmethod
    def n_aggs_static() -> Int:
        return Self.n_aggs

    @staticmethod
    def n_sort_keys_static() -> Int:
        return -1

    @staticmethod
    def topn_n_static() -> Int:
        return -1

    @staticmethod
    def n_part_keys_static() -> Int:
        return -1

    @staticmethod
    def n_window_fns_static() -> Int:
        return -1

    @staticmethod
    def n_probe_keys_static() -> Int:
        return -1

    @staticmethod
    def join_t_static() -> Int:
        return -1


@fieldwise_init
struct SortSpec[n_sort_keys: Int](BreakerLike):
    """Sort breaker — `n_sort_keys` ORDER BY columns.

    Carried through `n_sort_keys_static()`.
    """

    var sentinel: Int

    @staticmethod
    def tag() -> Int:
        return BREAKER_SORT

    @staticmethod
    def n_keys_static() -> Int:
        return -1

    @staticmethod
    def n_aggs_static() -> Int:
        return -1

    @staticmethod
    def n_sort_keys_static() -> Int:
        return Self.n_sort_keys

    @staticmethod
    def topn_n_static() -> Int:
        return -1

    @staticmethod
    def n_part_keys_static() -> Int:
        return -1

    @staticmethod
    def n_window_fns_static() -> Int:
        return -1

    @staticmethod
    def n_probe_keys_static() -> Int:
        return -1

    @staticmethod
    def join_t_static() -> Int:
        return -1


@fieldwise_init
struct TopNSpec[n_sort_keys: Int, N: Int](BreakerLike):
    """TopN breaker — `n_sort_keys` ORDER BY + LIMIT N.

    Carried through `n_sort_keys_static()` and `topn_n_static()`.
    """

    var sentinel: Int

    @staticmethod
    def tag() -> Int:
        return BREAKER_TOPN

    @staticmethod
    def n_keys_static() -> Int:
        return -1

    @staticmethod
    def n_aggs_static() -> Int:
        return -1

    @staticmethod
    def n_sort_keys_static() -> Int:
        return Self.n_sort_keys

    @staticmethod
    def topn_n_static() -> Int:
        return Self.N

    @staticmethod
    def n_part_keys_static() -> Int:
        return -1

    @staticmethod
    def n_window_fns_static() -> Int:
        return -1

    @staticmethod
    def n_probe_keys_static() -> Int:
        return -1

    @staticmethod
    def join_t_static() -> Int:
        return -1


@fieldwise_init
struct WindowSpec[n_part_keys: Int, n_window_fns: Int](BreakerLike):
    """Window breaker — `n_part_keys` PARTITION BY keys, `n_window_fns`
    windowed aggregates.

    Carried through `n_part_keys_static()` and `n_window_fns_static()`.
    """

    var sentinel: Int

    @staticmethod
    def tag() -> Int:
        return BREAKER_WINDOW

    @staticmethod
    def n_keys_static() -> Int:
        return -1

    @staticmethod
    def n_aggs_static() -> Int:
        return -1

    @staticmethod
    def n_sort_keys_static() -> Int:
        return -1

    @staticmethod
    def topn_n_static() -> Int:
        return -1

    @staticmethod
    def n_part_keys_static() -> Int:
        return Self.n_part_keys

    @staticmethod
    def n_window_fns_static() -> Int:
        return Self.n_window_fns

    @staticmethod
    def n_probe_keys_static() -> Int:
        return -1

    @staticmethod
    def join_t_static() -> Int:
        return -1


@fieldwise_init
struct PartitionUdfSpec[n_part_keys: Int](BreakerLike):
    """Partition-UDF breaker — `n_part_keys` PARTITION BY keys, one
    value-additive output column (the `partition_local` stateful UDF).

    Carried through `n_part_keys_static()`; the tag is
    `BREAKER_PARTITION_UDF` (see §1), distinct from `WindowSpec`'s.
    """

    var sentinel: Int

    @staticmethod
    def tag() -> Int:
        return BREAKER_PARTITION_UDF

    @staticmethod
    def n_keys_static() -> Int:
        return -1

    @staticmethod
    def n_aggs_static() -> Int:
        return -1

    @staticmethod
    def n_sort_keys_static() -> Int:
        return -1

    @staticmethod
    def topn_n_static() -> Int:
        return -1

    @staticmethod
    def n_part_keys_static() -> Int:
        return Self.n_part_keys

    @staticmethod
    def n_window_fns_static() -> Int:
        return -1

    @staticmethod
    def n_probe_keys_static() -> Int:
        return -1

    @staticmethod
    def join_t_static() -> Int:
        return -1


@fieldwise_init
struct WindowUdfSpec[n_part_keys: Int](BreakerLike):
    """Window-UDF breaker — `n_part_keys` PARTITION BY keys, one value-additive
    output column (the custom FRAME-bearing window fn).

    Carried through `n_part_keys_static()`; the tag is `BREAKER_WINDOW_UDF`
    (see §1), distinct from `WindowSpec` (built-in window functions) and
    `PartitionUdfSpec` (the partition-UDF sibling)."""

    var sentinel: Int

    @staticmethod
    def tag() -> Int:
        return BREAKER_WINDOW_UDF

    @staticmethod
    def n_keys_static() -> Int:
        return -1

    @staticmethod
    def n_aggs_static() -> Int:
        return -1

    @staticmethod
    def n_sort_keys_static() -> Int:
        return -1

    @staticmethod
    def topn_n_static() -> Int:
        return -1

    @staticmethod
    def n_part_keys_static() -> Int:
        return Self.n_part_keys

    @staticmethod
    def n_window_fns_static() -> Int:
        return -1

    @staticmethod
    def n_probe_keys_static() -> Int:
        return -1

    @staticmethod
    def join_t_static() -> Int:
        return -1


@fieldwise_init
struct JoinProbeSpec[n_probe_keys: Int, join_t: Int](BreakerLike):
    """JoinProbe breaker — `n_probe_keys` probe keys and `join_t`, one of
    the JOIN_* constants of §2 (INNER / LEFT / RIGHT / SEMI / ANTI /
    OUTER).

    This struct only carries the two values, through
    `n_probe_keys_static()` and `join_t_static()`. It does not check
    `join_t`; which values a probe accepts is decided by the join operator
    that reads it, which is not in this package.
    """

    var sentinel: Int

    @staticmethod
    def tag() -> Int:
        return BREAKER_JOIN_PROBE

    @staticmethod
    def n_keys_static() -> Int:
        return -1

    @staticmethod
    def n_aggs_static() -> Int:
        return -1

    @staticmethod
    def n_sort_keys_static() -> Int:
        return -1

    @staticmethod
    def topn_n_static() -> Int:
        return -1

    @staticmethod
    def n_part_keys_static() -> Int:
        return -1

    @staticmethod
    def n_window_fns_static() -> Int:
        return -1

    @staticmethod
    def n_probe_keys_static() -> Int:
        return Self.n_probe_keys

    @staticmethod
    def join_t_static() -> Int:
        return Self.join_t


@fieldwise_init
struct DistinctSpec[n_keys: Int](BreakerLike):
    """Distinct breaker — dedup rows by `n_keys` key columns, emit each distinct
    key combination once.

    The DISTINCT key count is carried through `n_keys_static()`: the
    BreakerLike trait has no DISTINCT-specific accessor.

    An accumulate-then-drain breaker (like HashAgg / Sort), not a per-batch
    emitter (like JoinProbe). DISTINCT semantics permit unordered output.
    """

    var sentinel: Int

    @staticmethod
    def tag() -> Int:
        return BREAKER_DISTINCT

    @staticmethod
    def n_keys_static() -> Int:
        return Self.n_keys

    @staticmethod
    def n_aggs_static() -> Int:
        return -1

    @staticmethod
    def n_sort_keys_static() -> Int:
        return -1

    @staticmethod
    def topn_n_static() -> Int:
        return -1

    @staticmethod
    def n_part_keys_static() -> Int:
        return -1

    @staticmethod
    def n_window_fns_static() -> Int:
        return -1

    @staticmethod
    def n_probe_keys_static() -> Int:
        return -1

    @staticmethod
    def join_t_static() -> Int:
        return -1


@fieldwise_init
struct PartitionTopNSpec[n_part_keys: Int, n_sort_keys: Int, N: Int](
    BreakerLike
):
    """PartitionTopN breaker — top-N rows per partition.

    `n_part_keys` PARTITION BY keys, `n_sort_keys` ORDER BY columns, LIMIT `N`
    per partition. The "top-K per group" query shape (SQL `ROW_NUMBER() OVER
    (PARTITION BY ... ORDER BY ...) <= N`).

    An accumulate-then-drain breaker (like HashAgg / Sort / TopN /
    Distinct), not a per-batch emitter (like JoinProbe). Carried through
    `n_part_keys_static()`, `n_sort_keys_static()` and `topn_n_static()`.
    """

    var sentinel: Int

    @staticmethod
    def tag() -> Int:
        return BREAKER_PARTITION_TOPN

    @staticmethod
    def n_keys_static() -> Int:
        return -1

    @staticmethod
    def n_aggs_static() -> Int:
        return -1

    @staticmethod
    def n_sort_keys_static() -> Int:
        return Self.n_sort_keys

    @staticmethod
    def topn_n_static() -> Int:
        return Self.N

    @staticmethod
    def n_part_keys_static() -> Int:
        return Self.n_part_keys

    @staticmethod
    def n_window_fns_static() -> Int:
        return -1

    @staticmethod
    def n_probe_keys_static() -> Int:
        return -1

    @staticmethod
    def join_t_static() -> Int:
        return -1


@fieldwise_init
struct AsofJoinSpec[n_probe_keys: Int](BreakerLike):
    """AsofJoin breaker — temporal forward-match join.

    Each probe row matches the most-recent build row whose temporal key is
    `<= ` the probe's temporal key (the "as-of" forward-search). `n_probe_keys`
    is the probe-side temporal-key column count (1 — a single Int64
    temporal key, no partition by-keys; the >=1-by-key partitioned asof is a
    future widen, as JoinProbe took single-key INNER first).

    Like JoinProbe (and unlike HashAgg / Sort / TopN / Distinct /
    PartitionTopN), a per-batch emitter: each probe batch yields its joined
    rows. There is no join_t axis (`join_t_static()` returns -1): asof is
    always a forward INNER match, so an unmatched probe row emits nothing.
    Carried through `n_probe_keys_static()`.
    """

    var sentinel: Int

    @staticmethod
    def tag() -> Int:
        return BREAKER_ASOF_JOIN

    @staticmethod
    def n_keys_static() -> Int:
        return -1

    @staticmethod
    def n_aggs_static() -> Int:
        return -1

    @staticmethod
    def n_sort_keys_static() -> Int:
        return -1

    @staticmethod
    def topn_n_static() -> Int:
        return -1

    @staticmethod
    def n_part_keys_static() -> Int:
        return -1

    @staticmethod
    def n_window_fns_static() -> Int:
        return -1

    @staticmethod
    def n_probe_keys_static() -> Int:
        return Self.n_probe_keys

    @staticmethod
    def join_t_static() -> Int:
        return -1


# -----------------------------------------------------------------------------
# §5b — BUILD-side BreakerSpec arms — JoinBuildSpec / AsofJoinBuildSpec
#
#
# The two BUILD-side pipeline-breaker arms. Unlike the PROBE arms
# (`JoinProbeSpec` / `AsofJoinSpec`, per-batch emitters), a BUILD arm names a
# breaker that consumes the build-side input into a hash-join / asof build
# table and emits no downstream batch. The build tables and their handoff to
# a probe are not in komira.
#
# Both carry the build-key arity through `n_keys_static()` and the payload
# column count through `n_aggs_static()`: the BreakerLike trait has no
# payload-specific accessor.
# -----------------------------------------------------------------------------


@fieldwise_init
struct JoinBuildSpec[n_keys: Int, n_payload: Int](BreakerLike):
    """Hash-join BUILD breaker — names the build side of a hash join.

    `n_keys` build-key columns, `n_payload` build-payload columns, carried
    through `n_keys_static()` and `n_aggs_static()` (the payload count). A
    pipeline breaker that emits no downstream batch. The build table is not
    in komira.
    """

    var sentinel: Int

    @staticmethod
    def tag() -> Int:
        return BREAKER_JOIN_BUILD

    @staticmethod
    def n_keys_static() -> Int:
        return Self.n_keys

    @staticmethod
    def n_aggs_static() -> Int:
        return Self.n_payload

    @staticmethod
    def n_sort_keys_static() -> Int:
        return -1

    @staticmethod
    def topn_n_static() -> Int:
        return -1

    @staticmethod
    def n_part_keys_static() -> Int:
        return -1

    @staticmethod
    def n_window_fns_static() -> Int:
        return -1

    @staticmethod
    def n_probe_keys_static() -> Int:
        return -1

    @staticmethod
    def join_t_static() -> Int:
        return -1


@fieldwise_init
struct AsofJoinBuildSpec[n_keys: Int, n_payload: Int](BreakerLike):
    """Asof-join BUILD breaker — names the build side of an asof join.

    `n_keys` partition by-key columns (0 for no by-key), `n_payload`
    build-payload columns, carried through `n_keys_static()` and
    `n_aggs_static()` (the payload count). A pipeline breaker that emits no
    downstream batch, like `JoinBuildSpec`. The asof build table is not in
    komira.
    """

    var sentinel: Int

    @staticmethod
    def tag() -> Int:
        return BREAKER_ASOF_JOIN_BUILD

    @staticmethod
    def n_keys_static() -> Int:
        return Self.n_keys

    @staticmethod
    def n_aggs_static() -> Int:
        return Self.n_payload

    @staticmethod
    def n_sort_keys_static() -> Int:
        return -1

    @staticmethod
    def topn_n_static() -> Int:
        return -1

    @staticmethod
    def n_part_keys_static() -> Int:
        return -1

    @staticmethod
    def n_window_fns_static() -> Int:
        return -1

    @staticmethod
    def n_probe_keys_static() -> Int:
        return -1

    @staticmethod
    def join_t_static() -> Int:
        return -1


# -----------------------------------------------------------------------------
# §6 — Placeholder ProjectsLike conformer for unit-test coverage
#
# `ProjectListStub[arity: Int]` is a minimal placeholder ProjectsLike
# conformer carrying a single comptime-Int `arity` so the unit
# tests can exercise non-pass-through Projects shapes without the
# production `ProjectList[*Outs]` (`typed_projects.mojo`), which
# supersedes it.
#
# pdescribe() returns the arity Int.
# -----------------------------------------------------------------------------


@fieldwise_init
struct ProjectListStub[arity: Int](ProjectsLike):
    """Placeholder ProjectsLike conformer for unit-test coverage.

    Superseded by the production `ProjectList[*Outs]`. Kept here for
    unit-test self-containment.
    """

    var sentinel: Int

    @staticmethod
    def pdescribe() -> Int:
        return Self.arity

    @staticmethod
    def make_default() -> Self:
        """The `ProjectListStub[arity]` marker (convenience-ctor default —
        unit-test stub; never used by a breaker stage)."""
        return ProjectListStub[Self.arity](0)

    def emit_projected[bo: Origin[mut=False]](
        mut self, batch: BatchView[bo], survivors: List[Int]
    ) raises -> RecordBatch:
        """Raise-stub — `ProjectListStub` is a unit-test marker only (it
        carries an `arity` Int, not real `Outs` expressions). The production
        projected emit lives on `ProjectList[*Outs]` (typed_projects.mojo).

        `mut self` (the instance-dispatch trait shape)."""
        raise Error(
            "ProjectListStub.emit_projected: marker stub — use ProjectList"
        )


# -----------------------------------------------------------------------------
# §7 — StageProgram aggregate marker
#
# Engine-side IR for a single fused stage's compile-time shape.
#
# Three slots:
#   - Filter   (FilterLike   — optional via `NoFilter` sentinel)
#   - Projects (ProjectsLike — optional via `NoProjects` sentinel)
#   - Breaker  (BreakerLike  — optional via `NoBreaker` sentinel)
#
# The intended consumer, a `Stage[Program]` template (not in komira),
# takes a StageProgram as its parameter and comptime-branches on
# `Self.Breaker.tag()` to pick the per-breaker code path. A builder of the
# three slots carries them flat (per the AnyType-erasure caveat in the module
# header) and forms a `StageProgram` from them.
#
# tests/test_stage_program.mojo pins the accessor row of NoBreaker and of
# every BreakerSpec arm.
# -----------------------------------------------------------------------------


@fieldwise_init
struct StageProgram[
    Filter: FilterLike,
    Projects: ProjectsLike,
    Breaker: BreakerLike,
](Copyable, Movable, ImplicitlyCopyable):
    """Engine-side compile-time IR for one fused Stage's shape.

    POD aggregate marker; the actual per-slot conformer types ARE
    the compile-time information. Its intended consumer, a `Stage[Program]`
    template, is not in komira.
    """

    var sentinel: Int
