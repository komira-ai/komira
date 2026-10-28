# =============================================================================
# parquet_codes_feed — one row group decoded for a grouped aggregate, keys as
# dictionary codes where the chunk allows it
# =============================================================================
#
# A grouped aggregate whose key is an INT32 / INT64 dictionary-encoded column
# can fold by CODE and resolve `dict_values[code]` once per group, instead of
# resolving and materialising the key for every row. This feed hands such a
# consumer one row group: each KEY column as its preserved codes when the
# chunk is a numeric dictionary chunk, else as the flat decode; the VALUE
# columns always flat, through the same per-chunk decode the flat feed uses.
#
# Contract: for a key delivered as codes, the chunk has a code for every row
# (no null, so `codes[r]` is row r) and `dict_values[codes[r]]` is the flat
# decode of that column at row r; a key with a null, an unsigned 32 / 64-bit
# annotation or a nested footer is delivered flat. The codes form never
# crosses the general `RecordBatch` surface.
# =============================================================================

from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatch
from komira_buffer.heap_region import HeapRegion
from komira_collections.slab import Slab
from komira_fs.file_system import FileSystem
from komira_parquet.column_decoder_assemble import NumericDictCodes
from komira_parquet.file_reader import ParquetFileReader
from komira_parquet.parquet_source_helpers import (
    _decode_columns_subset_per_chunk,
    _decode_numeric_dict_codes_one_col,
)
from komira_parquet_api.metadata import RowGroup, SchemaElement
from komira_parquet_api.types import CONVERTED_TYPE_UINT_32, CONVERTED_TYPE_UINT_64

from .flat_schema import schema_is_flat


comptime KEY_FORM_FLAT: UInt8 = 0
comptime KEY_FORM_CODES: UInt8 = 1


struct KeyColumnCodes(Movable):
    """One key column of one row group, in the form it was delivered in.

    Fields:
        form: `KEY_FORM_CODES` (`codes` holds the dictionary codes and the
            dictionary; `flat` is an empty placeholder) or `KEY_FORM_FLAT`
            (`flat` holds the decoded column; `codes` is empty).
        codes: The present rows' codes and the dictionary widened to Int64.
        flat: The decoded column.
    """

    var form: UInt8
    var codes: NumericDictCodes
    var flat: Column[HeapRegion]

    def __init__(out self, form: UInt8, var codes: NumericDictCodes, var flat: Column[HeapRegion]):
        self.form = form
        self.codes = codes^
        self.flat = flat^

    @staticmethod
    def with_codes(var codes: NumericDictCodes) -> KeyColumnCodes:
        """A key delivered as dictionary codes."""
        var empty_flat = Column.from_primitive(PrimitiveArray[DType.int32].allocate(0))
        return KeyColumnCodes(KEY_FORM_CODES, codes^, empty_flat^)

    @staticmethod
    def with_flat(var flat: Column[HeapRegion]) -> KeyColumnCodes:
        """A key delivered as a decoded column."""
        var empty_codes = NumericDictCodes(PrimitiveArray[DType.int32].allocate(0), List[Int64]())
        return KeyColumnCodes(KEY_FORM_FLAT, empty_codes^, flat^)

    @always_inline
    def has_codes(self) -> Bool:
        """True when the key was delivered as codes."""
        return self.form == KEY_FORM_CODES


struct RowGroupCodesFeed(Movable):
    """One row group of the codes feed.

    Fields:
        keys: The key columns, in the order of the caller's key indices.
        values: The value columns, decoded flat, in the caller's order (an
            empty batch when there are none).
        n_rows: The row group's row count.
    """

    var keys: Slab[KeyColumnCodes]
    var values: RecordBatch
    var n_rows: Int

    def __init__(out self, var keys: Slab[KeyColumnCodes], var values: RecordBatch, n_rows: Int):
        self.keys = keys^
        self.values = values^
        self.n_rows = n_rows

    @always_inline
    def num_keys(self) -> Int:
        """How many key columns the feed holds."""
        return len(self.keys)


def numeric_dict_codes_of[FS: FileSystem](
    reader: ParquetFileReader[FS],
    rg: RowGroup,
    schema: List[SchemaElement],
    col_idx: Int,
) raises -> Optional[NumericDictCodes]:
    """Leaf `col_idx` of `rg` as dictionary codes and entries when it is an
    INT32 / INT64 dictionary chunk of a flat footer; None otherwise, and for a
    UINT_32 / UINT_64 chunk: the entries are widened with sign extension, so a
    value at or above 2^31 (2^63) would come back negative and compare
    wrongly.

    Raises:
        If `col_idx` is not a leaf of `rg` or the chunk does not decode.
    """
    if not schema_is_flat(schema):
        return None
    if col_idx >= 0 and col_idx + 1 < len(schema):
        ref se = schema[col_idx + 1]
        if se.converted_type:
            var ct = se.converted_type.value()
            if ct == CONVERTED_TYPE_UINT_32 or ct == CONVERTED_TYPE_UINT_64:
                return None
    return _decode_numeric_dict_codes_one_col(reader, rg, schema, col_idx)


def decode_rowgroup_codes_feed[FS: FileSystem](
    reader: ParquetFileReader[FS],
    rg: RowGroup,
    schema: List[SchemaElement],
    key_col_indices: List[Int],
    value_col_indices: List[Int],
) raises -> RowGroupCodesFeed:
    """Decode one row group into the codes feed: each key column as codes
    when it is a numeric dictionary chunk with a code for every row (see
    `numeric_dict_codes_of`), else flat; the value columns flat.

    Raises:
        If an index is not a leaf of `rg` or a chunk does not decode.
    """
    var keys = Slab[KeyColumnCodes].with_capacity(len(key_col_indices))
    var n_rows = 0
    for i in range(len(key_col_indices)):
        var col_idx = key_col_indices[i]
        var codes_opt = numeric_dict_codes_of(reader, rg, schema, col_idx)
        # A null drops out of the codes, which would then not line up with the
        # value columns by row: such a key is delivered flat.
        if codes_opt and codes_opt.value().codes.length == Int(rg.num_rows):
            keys.append(KeyColumnCodes.with_codes(codes_opt.take()))
        else:
            var batch = _decode_columns_subset_per_chunk(reader, rg, schema, [col_idx], False)
            var cols = batch.take_columns()
            var col = cols.take_slot_unchecked(0)
            cols.set_len_unchecked(0)
            if col.length() > n_rows:
                n_rows = col.length()
            keys.append(KeyColumnCodes.with_flat(col^))
    var values: RecordBatch
    if len(value_col_indices) > 0:
        values = _decode_columns_subset_per_chunk(reader, rg, schema, value_col_indices, False)
        if values.num_rows() > n_rows:
            n_rows = values.num_rows()
    else:
        values = RecordBatch()
    var declared = Int(rg.num_rows)
    if declared > n_rows:
        n_rows = declared
    return RowGroupCodesFeed(keys^, values^, n_rows)
