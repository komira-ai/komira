# =============================================================================
# komira_async.fs.column_set — ColumnSet POD
# =============================================================================
# Leaf-index based (names are an SDK-level concern).
#
# `ColumnSet` is the typed projection passed to `ColumnarReader.read_columnar`
# and the capability sub-traits' decode methods. v0.1 ships the leaf-index
# representation; v0.2 may add `from_names(schema, names)` ctor.
#
# Pointer discipline:
#   * ZERO UnsafePointer in any public method signature.
#   * Indexes carrier is `List[Int]` — Mojo's canonical int-list shape.
# =============================================================================


@fieldwise_init
struct ColumnSet(Movable, Copyable):
    """Typed projection — which leaf columns to decode.

    Two modes:
      * `project_all=True` — every leaf column in the file's schema is
        decoded. Used when the planner pushes no projection (e.g.
        `SELECT * FROM ...`).
      * `project_all=False` — only columns whose 0-based leaf index is in
        `_indices` are decoded. The output batch's column order matches
        `_indices`.

    Leaf-index basis:
      Column ids are 0-based positions into the file's flattened
      schema (Parquet: `FileMetaData.schema[idx + 1]` per schema-element
      semantics; idx 0 is the root group). Names are an SDK-level concern;
      the planner translates names → indexes during query compilation.

    Field set:
      var project_all: Bool
      var _indices: List[Int]    # 0-based leaf column indexes

    This struct is intentionally thin — it mirrors the legacy
    `komira_parquet.morsel_reader.ColumnProjection` shape so the bytes-
    decode entry can accept either as long as the methods are delegated.
    """

    var project_all: Bool
    var _indices: List[Int]

    @staticmethod
    def all() -> ColumnSet:
        """Project every leaf column."""
        return ColumnSet(project_all=True, _indices=List[Int]())

    @staticmethod
    def columns(var indices: List[Int]) -> ColumnSet:
        """Project the listed leaf columns in order. The output batch's
        columns match `indices` element-wise."""
        return ColumnSet(project_all=False, _indices=indices^)

    @always_inline
    def num_projected(self, total_cols: Int) -> Int:
        """Returns how many columns this set will decode given a file
        with `total_cols` leaf columns. `total_cols` is the file's
        schema-leaf count from FMT.parse_schema."""
        if self.project_all:
            return total_cols
        return len(self._indices)

    @always_inline
    def is_projected(self, col_idx: Int) -> Bool:
        """Whether leaf column `col_idx` is in the projection. Linear
        scan because typical projections are 1-10 columns and locality
        wins over hash-set overhead."""
        if self.project_all:
            return True
        var n = len(self._indices)
        for i in range(n):
            if self._indices[i] == col_idx:
                return True
        return False

    @always_inline
    def explicit_indices_ref(self) -> ref [self._indices] List[Int]:
        """The explicit leaf-index list (valid only when `project_all` is
        False). Borrow — no copy. For `project_all` sets this is empty;
        callers must gate on `project_all` first."""
        return self._indices

    def projected_indices(self, total_cols: Int) -> List[Int]:
        """Returns the list of column indices to decode given a file
        with `total_cols` leaf columns. For `project_all` this is
        [0, total_cols); for explicit projection this returns a copy
        of `_indices`."""
        if self.project_all:
            var result = List[Int](capacity=total_cols)
            for i in range(total_cols):
                result.append(i)
            return result^
        return self._indices.copy()
