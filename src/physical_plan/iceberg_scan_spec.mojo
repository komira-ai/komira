# =============================================================================
# iceberg_scan_spec -- the SOURCE_ICEBERG arm of a SourceSpecPod
# =============================================================================
#
# The files of one Iceberg table snapshot as the planner chose them: every data
# file still worth reading, the delete files that apply to them, and the
# columns the plan bound the table at, each with the table's field id. There
# is no projection and no filter here: an Iceberg segment's projection and
# filter are operators. Inert data, like the rest of the IR.
# =============================================================================

from arrow.arrow_types import ArrowType


struct IcebergDeleteSpec(Copyable, Movable):
    """One delete file. `content` is 1 for position deletes (rows named by
    data file path and row position) and 2 for equality deletes (rows whose
    `equality_columns` values equal a row of the file)."""

    var path: String
    """The local path to open."""
    var content: Int
    """1 position deletes, 2 equality deletes."""
    var file_format: String
    """Either PARQUET or AVRO, upper-cased as the manifest stores it."""
    var equality_columns: List[String]
    """Content 2 only: the bound column names of the equality key."""

    def __init__(out self):
        self.path = String("")
        self.content = 0
        self.file_format = String("")
        self.equality_columns = List[String]()

    def __init__(
        out self,
        var path: String,
        content: Int,
        var file_format: String,
        var equality_columns: List[String],
    ):
        self.path = path^
        self.content = content
        self.file_format = file_format^
        self.equality_columns = equality_columns^


struct IcebergDataFileSpec(Copyable, Movable):
    """One data file and the delete files that apply to it."""

    var path: String
    """The local path to open."""
    var stored_path: String
    """The path as the manifest records it; position deletes name this."""
    var position_deletes: List[Int]
    """Indices into `IcebergScanSpec.deletes` of the position deletes."""
    var equality_deletes: List[Int]
    """Indices into `IcebergScanSpec.deletes` of the equality deletes."""

    def __init__(out self):
        self.path = String("")
        self.stored_path = String("")
        self.position_deletes = List[Int]()
        self.equality_deletes = List[Int]()

    def __init__(
        out self,
        var path: String,
        var stored_path: String,
        var position_deletes: List[Int],
        var equality_deletes: List[Int],
    ):
        self.path = path^
        self.stored_path = stored_path^
        self.position_deletes = position_deletes^
        self.equality_deletes = equality_deletes^


struct IcebergScanSpec(Copyable, Movable):
    """The planned scan of one table snapshot. An empty spec reads no file and
    binds no column."""

    var column_names: List[String]
    var column_types: List[ArrowType]
    """One per name, the type the plan bound that column at."""
    var column_field_ids: List[Int]
    """One per name, the Iceberg field id the column has in the table."""
    var data_files: List[IcebergDataFileSpec]
    """In the order the planner listed them, which is the read order."""
    var deletes: List[IcebergDeleteSpec]
    """Every delete file some data file refers to, each listed once."""
    var column_type_names: List[String]
    """Empty, or one per name: the column's Iceberg type as the table spells it
    (`decimal(10,2)`, `timestamptz`). Set, it gives a decimal column its
    precision and scale and a timestamp column its zone; empty, the reader takes
    them from the first data file that holds the column."""

    def __init__(out self):
        self.column_names = List[String]()
        self.column_types = List[ArrowType]()
        self.column_field_ids = List[Int]()
        self.data_files = List[IcebergDataFileSpec]()
        self.deletes = List[IcebergDeleteSpec]()
        self.column_type_names = List[String]()

    def __init__(
        out self,
        var column_names: List[String],
        var column_types: List[ArrowType],
        var column_field_ids: List[Int],
        var data_files: List[IcebergDataFileSpec],
        var deletes: List[IcebergDeleteSpec],
        var column_type_names: List[String] = List[String](),
    ):
        self.column_names = column_names^
        self.column_types = column_types^
        self.column_field_ids = column_field_ids^
        self.data_files = data_files^
        self.deletes = deletes^
        self.column_type_names = column_type_names^
