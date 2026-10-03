# =============================================================================
# column_resolver.mojo — runtime column-name resolver
# =============================================================================
#
# `ColumnResolver` is the runtime "name -> physical-column-index" resolver
# that the typed-expression layer binds against. (A parametric
# trait-member-alias bridge `F.X[S]()` does not work in Mojo, which is why
# resolution is a runtime value rather than a comptime one.)
#
# ----- Role ------------------------------------------------------------------
#
# The user's typed AST IS the compiled expression. Column-name
# resolution happens at evaluate-time per pipeline through a `ColumnResolver`
# runtime value built from the parquet file's actual footer schema at
# materialize_typed time. Each leaf `Col*[name]` carries a cached
# `_idx: Int` field populated by `bind(resolver)` at Stage init — the
# per-row hot loop reads `self._idx` directly with zero hashmap probes.
#
#   Build time   (per pipeline instance):
#     1. Parquet footer is read; an `arrow_types.schema.Schema` materializes.
#     2. `ColumnResolver.from_arrow_schema(schema)` walks fields, captures
#        (name, index, dtype) per field.
#     3. At Stage init: `expr.bind(resolver)` walks the typed-Expr tree,
#        recursing into binop children; each leaf sets `self._idx =
#        resolver.index_for(self.name)`.
#
#   Run time     (per batch):
#     4. `expr.evaluate(batch)` per row reads `self._idx` directly. The
#        resolver is NOT consulted on the hot path.
#
# The `bind(resolver)` wiring lives on the Expr types.
#
# ----- Scope -----------------------------------------------------------------
#
# Single-file-only. Multi-file heterogeneous-schema scans raise at validate
# time; there is no per-morsel rebind.
#
# Per-column DType is carried so the bind-time pass can
# do defensive validation (`expected_dtype == resolver.dtype_for(name)?`) and
# raise a useful diagnostic if the typed-Expr's leaf DType disagrees with the
# file's actual physical type.
#
# Linear scan inside `index_for` / `dtype_for` / `has` is the baseline
# (typical schemas are 1-100 cols; a `Dict[String, Int]` upgrade is trivial
# if a 1000-col schema ever lands and a bind-time profile shows it).
# =============================================================================


from komira_core.arrow.schema import Schema
from komira_core.arrow.arrow_types import ArrowType


struct ColumnResolver(Movable, Copyable, Deinitable):
    """Runtime "name -> physical-column-index" resolver built from a parquet
    file's actual footer schema at `materialize_typed` time.

    Carries per-column DType AND per-column
    ArrowType so the
    bind pass can do defensive validation against the typed-Expr's declared
    leaf type.

    DType vs ArrowType — why both:
        DType (Mojo numeric / fixed-width) is sufficient for the original
        4-DType validation surface (INT64 / FLOAT64 / INT32 / BOOL — the
        substrate test fixtures). But it LOSES INFO for STRING, DECIMAL128,
        DATE32, TIMESTAMP-with-tz, DICTIONARY, and nested types — all of
        those collapse to `DType.invalid` because Mojo's DType enum has no
        slot for them. ArrowType is the Arrow logical-type enum and IS the
        load-bearing identifier for those cases (`ArrowType.STRING`,
        `ArrowType.DATE32`, etc.). Bind-time validation MUST consult
        `arrow_type_for(name)` for non-numeric leaves; `dtype_for(name)`
        remains a useful convenience for the numeric-leaf fast path.

    Lifetime: built once per pipeline instance. Consulted by leaf-Expr
    `bind(resolver)` methods at Stage init. NOT consulted on the per-row
    hot path — leaves cache the resolved Int index in their own state.
    """

    var _names:       List[String]
    var _indices:     List[Int]
    var _dtypes:      List[DType]
    var _arrow_types: List[ArrowType]

    # ------------------------------------------------------------------ ctors

    def __init__(out self):
        """Empty resolver (no columns). Useful for unit-tests, sentinel
        states, and for the "schema not yet known" stage of a pipeline."""
        self._names       = List[String]()
        self._indices     = List[Int]()
        self._dtypes      = List[DType]()
        self._arrow_types = List[ArrowType]()

    def __init__(
        out self,
        var names:        List[String],
        var indices:      List[Int],
        var dtypes:       List[DType],
        var arrow_types:  List[ArrowType],
    ) raises:
        """Explicit ctor used by tests + direct construction. Raises if the
        four parallel lists have mismatching lengths.

        The `indices` list typically holds 0..len(names)-1 (one-to-one
        physical layout), but the ctor does not enforce that — callers may
        present a permutation when bridging from a re-projected sub-schema.
        """
        if len(names) != len(indices):
            raise Error(
                String("ColumnResolver: names ("),
                String(len(names)),
                String(") and indices ("),
                String(len(indices)),
                String(") lists must be the same length"),
            )
        if len(names) != len(dtypes):
            raise Error(
                String("ColumnResolver: names ("),
                String(len(names)),
                String(") and dtypes ("),
                String(len(dtypes)),
                String(") lists must be the same length"),
            )
        if len(names) != len(arrow_types):
            raise Error(
                String("ColumnResolver: names ("),
                String(len(names)),
                String(") and arrow_types ("),
                String(len(arrow_types)),
                String(") lists must be the same length"),
            )
        self._names       = names^
        self._indices     = indices^
        self._dtypes      = dtypes^
        self._arrow_types = arrow_types^

    @staticmethod
    def from_arrow_schema(schema: Schema) raises -> ColumnResolver:
        """Build a ColumnResolver from the file's `arrow_types.schema.Schema`.

        Walks `schema._names` / `schema._dtypes` / `schema._arrow_types` and
        assigns physical indices in declaration order (i.e. the resolver's
        index_for(name) returns the same Int as the column's position in the
        file).

        This is the load-bearing constructor: parquet-side callers obtain
        a `Schema` from the footer (via the existing
        `ParquetFileReader.schema()` / `RecordBatch.schema()` accessor)
        and pass it here. The resolver then drives bind-pass on the
        typed-Expr tree.

        Both DType + ArrowType are captured per field: ArrowType is the load-bearing identifier for STRING /
        DECIMAL128 / DATE32 / TIMESTAMP-with-tz / DICTIONARY / nested types
        where Mojo's DType enum reports `DType.invalid`.
        """
        var n = schema.num_columns()
        var names       = List[String]()
        var indices     = List[Int]()
        var dtypes      = List[DType]()
        var arrow_types = List[ArrowType]()
        for i in range(n):
            names.append(schema.field_name(i))
            indices.append(i)
            dtypes.append(schema.field_dtype(i))
            arrow_types.append(schema.field_arrow_type(i))
        return ColumnResolver(names^, indices^, dtypes^, arrow_types^)

    # ----------------------------------------------------------------- lookup

    def index_for(self, name: String) raises -> Int:
        """Resolve `name` to its physical column index. Raises with a
        helpful diagnostic if the name is not present (includes the full
        list of available names so the user can spot a typo).

        Linear-scan implementation (the baseline; see header comment for
        the upgrade-to-Dict criterion). N is typically 1-100; cost is
        well-amortized because the resolver is consulted at BIND time only,
        not on the per-row hot path.
        """
        for i in range(len(self._names)):
            if self._names[i] == name:
                return self._indices[i]
        # Build the available-names diagnostic. Format: "[a, b, c]"
        var available = String("[")
        for i in range(len(self._names)):
            if i > 0:
                available += String(", ")
            available += self._names[i]
        available += String("]")
        raise Error(
            String("ColumnResolver: column '"),
            name,
            String("' not found in file schema; available: "),
            available,
        )

    def dtype_for(self, name: String) raises -> DType:
        """Return the file's physical DType for `name`. Raises if `name`
        is not present (same diagnostic shape as `index_for`).

        Used at bind time for defensive validation: the typed-Expr's leaf
        carries its declared DType (e.g. `ColXF64[name]` claims F64); the
        bind pass compares to `dtype_for(name)` and raises if the file
        actually carries a different DType for that name.

        Note: `DType` LOSES INFO for STRING / DECIMAL128 / DATE32 /
        TIMESTAMP-with-tz / DICTIONARY / nested types — those collapse to
        `DType.invalid`. Prefer `arrow_type_for(name)` for those cases.
        """
        for i in range(len(self._names)):
            if self._names[i] == name:
                return self._dtypes[i]
        var available = String("[")
        for i in range(len(self._names)):
            if i > 0:
                available += String(", ")
            available += self._names[i]
        available += String("]")
        raise Error(
            String("ColumnResolver: column '"),
            name,
            String("' not found in file schema; available: "),
            available,
        )

    def arrow_type_for(self, name: String) raises -> ArrowType:
        """Return the file's Arrow logical type for `name`. Raises if `name`
        is not present (same diagnostic shape as `index_for`).

        This is the load-bearing accessor for bind-time defensive
        validation against non-numeric leaves: a `ColXString[name]` leaf
        compares its declared `ArrowType.STRING` against
        `arrow_type_for(name)` and raises if the file actually carries a
        different Arrow type for that name. `dtype_for(name)` cannot answer
        for STRING / DECIMAL128 / DATE32 / TIMESTAMP-with-tz / DICTIONARY /
        nested cases — all of those collapse to `DType.invalid` in Mojo's
        DType enum.
        """
        for i in range(len(self._names)):
            if self._names[i] == name:
                return self._arrow_types[i]
        var available = String("[")
        for i in range(len(self._names)):
            if i > 0:
                available += String(", ")
            available += self._names[i]
        available += String("]")
        raise Error(
            String("ColumnResolver: column '"),
            name,
            String("' not found in file schema; available: "),
            available,
        )

    def has(self, name: String) -> Bool:
        """Non-raising membership probe — returns True iff `name` is
        present in the resolver. Useful for callers that want to take an
        alternate path on absence rather than raise."""
        for i in range(len(self._names)):
            if self._names[i] == name:
                return True
        return False

    def len(self) -> Int:
        """Number of columns this resolver knows about."""
        return len(self._names)
