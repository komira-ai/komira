"""`komira_parquet_writer`: the pieces a Parquet writer is built from.

The Thrift compact serializer for the footer, page headers and page indexes
(`thrift_writer`), the PageHeader i32 ceiling (`page_size_limit`), the
column-chunk statistics (`stats`, and `writer_float_stats` for FLOAT /
DOUBLE), the dictionary encoders (`dict_encoder` for strings,
`dict_encoder_numeric` for fixed-width numbers), the fixed-width bit packer
(`writer_bitpack`), the page index tracker (`writer_page_index`) and the
shared helpers (`writer_helpers`: page-body compression, schema builders).

It writes no file: the record-batch writer that assembles pages into a file
and returns the file's metadata is a later part of this package. It reads no
Parquet file either, and does not depend on the reader (`komira_parquet`).
"""

from .thrift_writer import ThriftCompactWriter, serialize_file_metadata
from .page_size_limit import (
    PARQUET_PAGE_SIZE_MAX,
    check_parquet_page_size,
    parquet_page_size_limit,
    set_parquet_page_size_limit,
)
from .stats import (
    STRING_STATS_TRUNCATION_LEN,
    compute_statistics_float64,
    compute_statistics_int32,
    compute_statistics_int64,
    compute_statistics_string,
)
from .writer_float_stats import (
    FloatMinMax,
    float_column_statistics,
    float_minmax_from_array,
    float_minmax_from_values,
    make_float_statistics,
)
from .dict_encoder import (
    DictEncodingResult,
    encode_dict_column,
    encode_dict_column_large,
)
from .dict_encoder_numeric import (
    NUMERIC_DICT_MAX_CARDINALITY,
    NumericDictEncodingResult,
    encode_numeric_dict_column,
)
from .writer_bitpack import min_bit_width, pack_fixed_width
from .writer_page_index import (
    ColumnPageTracker,
    PageBoundary,
    serialize_column_index,
    serialize_offset_index,
)
from .writer_helpers import (
    make_int32_statistics,
    make_int64_statistics,
    make_schema_elements,
    make_schema_elements_nullable,
)
