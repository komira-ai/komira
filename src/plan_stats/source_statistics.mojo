# =============================================================================
# SourceStatistics -- per-source row/byte/column stats
# =============================================================================
#
# Returned by `MorselSourceImpl.statistics(self)`; consumed by the optimizer
# for cardinality estimation, join-ordering, and pruning decisions.
#
# All fields are Optional -- a source that does not know a particular stat
# sets it to None. Empty SourceStatistics (all None) is the trait-default
# response for sources that know nothing.
#
# There is no `output_ordering` (sortedness metadata) field, so sorts over
# naturally-ordered sources are not elided on the strength of these stats.
# =============================================================================


struct ColumnStatistics(Movable, Copyable, Deinitable):
    """Per-column stats `{null_count, distinct_count, min_bytes, max_bytes}`,
    all Optional. `min_bytes`/`max_bytes` are carried as `List[UInt8]` so any
    physical type (int/float/string/decimal) fits without a generic parameter;
    producers encode to the column's Parquet physical form, consumers decode
    with the column's logical type in hand.
    """

    var null_count: Optional[Int64]
    var distinct_count: Optional[Int64]
    var min_bytes: Optional[List[UInt8]]
    var max_bytes: Optional[List[UInt8]]

    def __init__(out self):
        self.null_count = None
        self.distinct_count = None
        self.min_bytes = None
        self.max_bytes = None

    def __init__(
        out self,
        null_count: Optional[Int64],
        distinct_count: Optional[Int64],
        var min_bytes: Optional[List[UInt8]],
        var max_bytes: Optional[List[UInt8]],
    ):
        self.null_count = null_count
        self.distinct_count = distinct_count
        self.min_bytes = min_bytes^
        self.max_bytes = max_bytes^


struct SourceStatistics(Movable, Copyable, Deinitable):
    """Per-source stats `{num_rows, total_byte_size, per_column}`.

    `per_column` is indexed by the source's pre-projection column order and
    is empty when the source has no per-column stats. All scalar fields are
    Optional.
    """

    var num_rows: Optional[Int64]
    var total_byte_size: Optional[Int64]
    var per_column: List[ColumnStatistics]

    def __init__(out self):
        self.num_rows = None
        self.total_byte_size = None
        self.per_column = List[ColumnStatistics]()

    def __init__(
        out self,
        num_rows: Optional[Int64],
        total_byte_size: Optional[Int64],
        var per_column: List[ColumnStatistics],
    ):
        self.num_rows = num_rows
        self.total_byte_size = total_byte_size
        self.per_column = per_column^
