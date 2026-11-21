# =============================================================================
# fs.explicit_file_discovery -- ExplicitFileDiscovery: a fixed file list with
# optional constant partition columns
# =============================================================================
# A `FileDiscovery` over a file list that is already known: either the files a
# path, glob or directory names (`open`, the same listing `EagerGlobDiscovery`
# makes), or a list a caller hands over with the partition column values it
# already derived for each file (`from_files`). It lists nothing at
# `partition_values_at` time and never reads a path: the paths and the
# partition text are fixed when it is built.
#
# `from_files` keeps the caller's file order. A partition column has a name and
# an Arrow type (the `Field`), and every file has one decoded value text per
# column; the empty text stands for NULL, as the Parquet source reads it.
# `open` has no partition columns.
#
# Storage follows `PrunedHiveDiscovery`: the paths and the partition values
# are `Slab[String]` arenas, with the values of file `f`, column `c` at
# `f * num_columns + c`. No `List` sits inside a slab element, and nothing here
# takes or returns a pointer.

from arrow.arrow_types import ArrowType
from arrow.schema import Field
from containers.slab import Slab
from fs.file_discovery import (
    EagerGlobDiscovery,
    FileDiscovery,
    PartitionSchema,
    PartitionValues,
)
from fs.file_system import FileSystem


@fieldwise_init
struct ExplicitFileDiscovery(FileDiscovery, Movable, Deinitable):
    """A fixed, materialized file list with constant partition columns.

    Field set:
      var _paths: Slab[String]
        The files, in the order they were given (`open`: sorted).
      var _values: Slab[String]
        Decoded partition text, file-major: file `f`, column `c` is at
        `f * len(_col_names) + c`. Empty when there are no partition columns.
      var _col_names: List[String]
      var _col_types: List[ArrowType]
        The partition columns, in order.
    """

    var _paths: Slab[String]
    var _values: Slab[String]
    var _col_names: List[String]
    var _col_types: List[ArrowType]

    @staticmethod
    def open[
        FS: FileSystem
    ](mut fs: FS, path_spec: String) raises -> ExplicitFileDiscovery:
        """The files `path_spec` (a file, a directory or a glob) names, sorted,
        with no partition columns: exactly `EagerGlobDiscovery.open`'s paths.

        Raises:
            What `EagerGlobDiscovery.open` raises (no match, a bad glob, a
            listing failure).
        """
        var eager = EagerGlobDiscovery.open(fs, path_spec)
        var paths = Slab[String].create(max(eager.num_paths(), 1))
        for i in range(eager.num_paths()):
            paths.append(eager.path_at(i))
        return ExplicitFileDiscovery(
            _paths=paths^,
            _values=Slab[String].create(1),
            _col_names=List[String](),
            _col_types=List[ArrowType](),
        )

    @staticmethod
    def from_files(
        paths: List[String],
        partition_cols: List[Field],
        partition_values: List[List[String]],
    ) raises -> ExplicitFileDiscovery:
        """A discovery over `paths` in the given order, with `partition_cols`
        as constant columns whose value for file `f` is
        `partition_values[f][c]` (decoded text; "" is NULL).

        Raises:
            If `paths` is empty, `partition_values` does not hold one row per
            path, or a row does not hold one value per partition column.
        """
        if len(paths) == 0:
            raise Error("ExplicitFileDiscovery: the file list is empty")
        var ncols = len(partition_cols)
        if ncols == 0 and len(partition_values) == 0:
            pass
        elif len(partition_values) != len(paths):
            raise Error(
                String("ExplicitFileDiscovery: ")
                + String(len(partition_values))
                + " partition value rows for "
                + String(len(paths))
                + " files"
            )
        for f in range(len(partition_values)):
            if len(partition_values[f]) != ncols:
                raise Error(
                    String("ExplicitFileDiscovery: file '")
                    + paths[f]
                    + "' has "
                    + String(len(partition_values[f]))
                    + " partition values for "
                    + String(ncols)
                    + " partition columns"
                )
        var path_slab = Slab[String].create(len(paths))
        for i in range(len(paths)):
            path_slab.append(paths[i].copy())
        var value_slab = Slab[String].create(max(len(paths) * ncols, 1))
        if ncols > 0:
            for f in range(len(paths)):
                for c in range(ncols):
                    value_slab.append(partition_values[f][c].copy())
        var names = List[String]()
        var types = List[ArrowType]()
        for c in range(ncols):
            names.append(partition_cols[c].name.copy())
            types.append(partition_cols[c].arrow_type)
        return ExplicitFileDiscovery(
            _paths=path_slab^,
            _values=value_slab^,
            _col_names=names^,
            _col_types=types^,
        )

    # -------------------------------------------------------------------------
    # FileDiscovery trait surface
    # -------------------------------------------------------------------------

    @staticmethod
    def is_lazy() -> Bool:
        """Eager: every path is materialized when the discovery is built."""
        return False

    @always_inline
    def num_paths(self) -> Int:
        """Number of files."""
        return self._paths.len()

    @always_inline
    def path_at(self, idx: Int) raises -> String:
        """The path at `idx`. Caller asserts `idx < num_paths()`."""
        return self._paths[idx].copy()

    def partition_values_at(self, idx: Int) raises -> PartitionValues:
        """File `idx`'s partition `(name, value)` pairs, one per partition
        column in column order; empty when there are none."""
        var keys = List[String]()
        var vals = List[String]()
        var ncols = len(self._col_names)
        for c in range(ncols):
            keys.append(self._col_names[c].copy())
            vals.append(self._values[idx * ncols + c].copy())
        return PartitionValues(keys=keys^, values=vals^)

    def partition_schema(self) -> PartitionSchema:
        """The partition column names, in column order."""
        var names = List[String]()
        for c in range(len(self._col_names)):
            names.append(self._col_names[c].copy())
        return PartitionSchema(names=names^)

    @always_inline
    def num_partition_cols(self) -> Int:
        """Number of partition columns the source appends."""
        return len(self._col_names)

    def partition_col_type_at(self, idx: Int) -> ArrowType:
        """The Arrow type of partition column `idx`."""
        return self._col_types[idx]

    def partition_col_name_at(self, idx: Int) -> String:
        """The name of partition column `idx`."""
        return self._col_names[idx].copy()
