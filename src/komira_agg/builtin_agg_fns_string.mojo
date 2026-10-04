# =============================================================================
# builtin_agg_fns_string.mojo — Built-in AggFn conformers for String inputs
# =============================================================================
#
# Variable-length string-input
# aggregations. We ship:
#
#   CountStr -- counts non-null string rows; State Int64 (POD-safe)
#
# WHAT'S DEFERRED + WHY
# ---------------------
# `MinStr` / `MaxStr` / `FirstStr` / `LastStr` need a State that carries
# a String value (the per-group running lexicographic min/max, or the
# write-once first/write-each last value). String is heap-owning;
# `flush_partial_to_column` Arrow-columnar-dumps the raw State slab as
# bytes — a String field in
# State would corrupt memory at parallel-merge time when the slab is
# bytewise-merged across workers.
#
# The trait declaration `trait PodState(Copyable, Movable,
# Deinitable)` technically permits a String field (String
# conforms to those three traits), so the conformance check is NOT a
# compile-time gate against heap-owning state. The gate is the
# DOCUMENTED CONTRACT in the agg_fn.mojo file header. A String-bearing
# State would compile but UB at flush-partial time.
#
# The DuckDB analogue (src/function/aggregate/distributive/min_max.cpp's
# `Vector::StringMinOperation`) uses a heap-allocated `string_t` with
# a special "pointer-to-cleanup-arena" handle to side-step the
# flush-partial issue. Replicating that requires an arena
# (`OwnedPointer[StringSlab]` or similar) and a `_resolve_string_state`
# operator path in the SDK; that is not done here.
#
# Follow-up: file a separate slot for `agg_fns_string_minmax_first_last`
# with the arena state design + matching `AggFnAcc[F]` integration
# (likely needs a new trait `AggFnArena[F: AggFn, A: Arena]`).
#
# Mojo discipline: no UnsafePointer in signatures, no wildcard origins,
# file < 1000 LOC.
# =============================================================================

from komira_udf.agg_fn import AggFn
from komira_udf.schema_descriptor import schema_of, DT_STRING, DT_I64
from komira_udf.auto_komira_schema import AutoKomiraSchema
from komira_agg.builtin_agg_fns_states import CountState


@fieldwise_init
struct RowStr(Copyable, Movable, AutoKomiraSchema):
    """Single-column input row for a string-typed agg (1-arity InRow).

    Conforms to `AutoKomiraSchema` — mirrors the
    `RowT` siblings in `builtin_agg_fns_states.mojo`. The marker is empty;
    adding it does NOT change any existing CountStr behavior.
    """
    var v: String


@fieldwise_init
struct CountStr(AggFn):
    """COUNT(String) -> Int64. Counts non-null string rows.

    Safe because the State is `CountState` (Int64 — POD); the String
    input value is consumed only inside `update_scalar` and is not
    stashed in State.
    """
    comptime InRow = RowStr
    comptime OutputSchema = schema_of["count_v", DT_I64]()
    comptime OutType = DType.int64
    comptime State = CountState
    comptime UDF_ID = UInt32(0x0004_040C)

    def init(self) -> CountState:
        return CountState(Int64(0))

    def update(self, mut s: CountState, row: RowStr):
        s.count += Int64(1)
        # `row.v` consumed by the implicit drop at scope end; no stash.

    def update_scalar[*Ts: Copyable & Movable](self, mut s: CountState, *vals: *Ts):
        s.count += Int64(1)

    def merge(self, a: CountState, b: CountState) -> CountState:
        return CountState(a.count + b.count)

    def finalize(self, s: CountState) -> Scalar[DType.int64]:
        return s.count
