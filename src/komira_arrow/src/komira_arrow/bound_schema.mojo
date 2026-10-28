# =============================================================================
# bound_schema.mojo — name -> column-index memoization for UDF column primitives
# =============================================================================
#
# The bind-time descriptor the untyped-UDF dispatch chain consumes: a
# `Dict[String, Int]` (name -> index) + a `List[DType]` (index -> dtype).
#
# Why this primitive exists. The user authors an untyped UDF with name-keyed
# column reads (`view.i64("age")`). The bind step resolves
# every referenced column name against the scan's runtime schema ONCE at
# lowering. The hot per-row path then reads through a `UntypedRowView`
# borrowing this `BoundSchema` — the per-row name -> index probe is a single
# `Dict[String, Int]` lookup (~50 ns hash + compare), NOT a linear `Schema.
# column_index` scan (O(n) string compares, ~100-500 ns for 5-20 columns).
#
# Lifetime contract. `BoundSchema` is built once at
# lowering and is **MOVED onto the evaluator adapter (or the lowered plan
# segment)** after `bind`; the `UntypedRowView` borrows it from there via
# `Pointer[BoundSchema, mo]`. NEVER copied per row — the inner `Dict` + 2x
# `List` would form a per-row heap-alloc storm AND a wildcard-origin
# hazard if the dict were ever re-bitcast under the row-view's lifetime.
# `BoundSchema` is `Movable + Deinitable` ONLY — NOT `Copyable`
# (Dict[String, Int] isn't `ImplicitlyCopyable` anyway).
#
# Encapsulation invariants:
#   - NO UnsafePointer in any public method signature.
#   - NO wildcard origins.
#   - NO unsafe_from_address.
#   - Public API exposes Int / DType / String / raises Error only.
#
# Cross-references:
#   - `UntypedRowView` — the consumer.
#   - `komira_arrow.schema` — the source `Schema` we build from.
# =============================================================================

from std.collections import Dict

from komira_arrow.schema import Schema


struct BoundSchema(Movable, Deinitable):
    """Memoized name -> column-index + index -> DType map for an Arrow Schema.

    Built ONCE at the UDF bind step (per query / per scan), then MOVED onto
    the evaluator adapter (or lowered plan segment). The per-row
    `UntypedRowView` borrows it via `Pointer[BoundSchema, mo]` — never
    copied per row.

    The `Dict[String, Int]` is the canonical hot-path probe. The
    `List[DType]` lets accessor `_at(idx)` confirm DType without a second
    lookup. The `List[String]` cache is for diagnostics only (the
    "no field named 'X'; known: a, b, c" error path).

    Fields:
        _name_to_index: hash map column-name -> column-index (the probe).
        _dtypes: parallel list column-index -> DType (the DType check).
        _names: parallel list column-index -> name (for diagnostics).
    """

    var _name_to_index: Dict[String, Int]
    var _dtypes: List[DType]
    var _names: List[String]

    def __init__(out self, ref schema: Schema) raises:
        """Build a `BoundSchema` from any Arrow `Schema`.

        Walks `schema.num_columns()`, populates the Dict + parallel lists.
        Raises on duplicate column names (a real bind-time error — the
        scan schema cannot have two fields with the same name).
        """
        self._name_to_index = Dict[String, Int]()
        self._dtypes = List[DType]()
        self._names = List[String]()
        var n = schema.num_columns()
        for i in range(n):
            var name = schema.field_name(i)
            if name in self._name_to_index:
                raise Error(
                    "BoundSchema: duplicate column name '"
                    + name
                    + "' in schema (indices "
                    + String(self._name_to_index[name])
                    + " and "
                    + String(i)
                    + ")"
                )
            self._name_to_index[name] = i
            self._dtypes.append(schema.field_dtype(i))
            self._names.append(name)

    @always_inline
    def num_columns(self) -> Int:
        """Number of columns in the bound schema."""
        return len(self._dtypes)

    def index_of(self, name: String) raises -> Int:
        """Look up the column index for `name`.

        Raises with a diagnostic listing known column names if `name` is not
        a column. ~50 ns hash + string compare on the happy path.
        """
        if name not in self._name_to_index:
            var known = String("")
            for i in range(len(self._names)):
                if i > 0:
                    known += ", "
                known += self._names[i]
            raise Error(
                "BoundSchema.index_of: no field named '"
                + name
                + "'; known columns: ["
                + known
                + "]"
            )
        return self._name_to_index[name]

    @always_inline
    def dtype_at(self, idx: Int) raises -> DType:
        """DType of the column at index `idx`.

        Raises on out-of-range `idx`. Used by `UntypedRowView` accessors to
        runtime-check the caller-requested DType against the actual column
        DType — a cheap branch-predicted comparison per accessor call.
        """
        if idx < 0 or idx >= len(self._dtypes):
            raise Error(
                "BoundSchema.dtype_at: index "
                + String(idx)
                + " out of range [0, "
                + String(len(self._dtypes))
                + ")"
            )
        return self._dtypes[idx]

    def name_at(self, idx: Int) raises -> String:
        """Name of the column at index `idx`. Used for diagnostics."""
        if idx < 0 or idx >= len(self._names):
            raise Error(
                "BoundSchema.name_at: index "
                + String(idx)
                + " out of range [0, "
                + String(len(self._names))
                + ")"
            )
        return self._names[idx]

    def contains(self, name: String) -> Bool:
        """Whether the schema has a column named `name`. Non-raising probe."""
        return name in self._name_to_index
