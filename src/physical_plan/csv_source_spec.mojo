# =============================================================================
# csv_source_spec -- the SOURCE_CSV arm of a SourceSpecPod
# =============================================================================
#
# One local CSV file (or its `.gz` / `.zst` / `.lz4` form), the dialect it is
# read with and every column of the file, in file order, with the type the
# plan bound it at. There is no projection and no filter here: a CSV segment's
# projection and filter are operators. Inert data, like the rest of the IR.
# =============================================================================

from arrow.arrow_types import ArrowType


struct CsvSourceSpec(Copyable, Movable):
    """The file, its dialect and its bound columns. An empty spec holds the CSV
    defaults: a comma, a header row, RFC 4180 quoting (tag 0), no line skipped,
    no column."""

    var path: String
    var delimiter: UInt8
    var has_header: Bool
    var quote_style_tag: Int
    """0 RFC 4180, 1 Excel, 2 POSIX (`csv.csv_options`)."""
    var skip: Int
    """The raw lines dropped before the header (0 drops none)."""
    var column_names: List[String]
    var column_types: List[ArrowType]
    """One per name, the type the plan bound that column at."""

    def __init__(out self):
        self.path = String("")
        self.delimiter = UInt8(ord(","))
        self.has_header = True
        self.quote_style_tag = 0
        self.skip = 0
        self.column_names = List[String]()
        self.column_types = List[ArrowType]()

    def __init__(
        out self,
        var path: String,
        delimiter: UInt8,
        has_header: Bool,
        quote_style_tag: Int,
        var column_names: List[String],
        var column_types: List[ArrowType],
        skip: Int = 0,
    ):
        self.path = path^
        self.delimiter = delimiter
        self.has_header = has_header
        self.quote_style_tag = quote_style_tag
        self.skip = skip
        self.column_names = column_names^
        self.column_types = column_types^
