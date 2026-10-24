"""`komira_parquet_writer`: a Parquet writer's encoders and page builders.

The Thrift compact serializer for the footer, page headers and page indexes
(`thrift_writer`), the PageHeader i32 ceiling (`page_size_limit`), the
column-chunk statistics (`stats`, and `writer_float_stats` for FLOAT /
DOUBLE), the dictionary encoders (`dict_encoder` for strings,
`dict_encoder_numeric` for fixed-width numbers), the fixed-width bit packer
(`writer_bitpack`), the page index tracker (`writer_page_index`) and the
shared helpers (`writer_helpers`: page-body compression, schema builders).

The page builders turn one Arrow column into one column chunk's pages
(`ColumnPage`, `column_page`): PLAIN (`writer_encode`: fixed-width,
BYTE_ARRAY, BOOLEAN, and the definition levels), DELTA_BINARY_PACKED
(`writer_delta`), BYTE_STREAM_SPLIT (`writer_bss`), dictionary pages
(`writer_dict`, `writer_dict_numeric`) and Decimal128 as
FIXED_LEN_BYTE_ARRAY(16) (`decimal_encode`).

The file writer (`writer`: `ParquetFileWriter`) takes whole columns, encodes
each as one page or dictionary chunk, and `close_to_bytes` returns the file:
magic, column chunks, footer, footer length, magic (`file_assembly` builds the
chunk entries and the footer, `encoded_column` is the column-parallel hand-off).
It opens no file: where the bytes go is the caller's decision. It reads no
Parquet file either, and does not depend on the reader (`komira_parquet`);
its tests do, through `test_deps`, to prove the bytes decode.
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
from .column_page import ColumnPage, dtype_to_parquet_type
from .writer_encode import (
    encode_boolean_column_page,
    encode_def_levels_all_valid,
    encode_def_levels_from_bitmap,
    encode_large_string_column_page,
    encode_plain_boolean_data,
    encode_plain_byte_array_data,
    encode_plain_byte_array_data_large,
    encode_plain_column,
    encode_plain_values,
    encode_string_column_page,
)
from .writer_delta import (
    encode_dbp_column_page,
    encode_delta_binary_packed_i32,
    encode_delta_binary_packed_i64,
)
from .writer_bss import encode_bss_column_page, encode_byte_stream_split
from .writer_dict import (
    DICT_CARDINALITY_THRESHOLD,
    encode_dict_indices_rle,
    encode_dict_large_string_column_page,
    encode_dict_string_column_page,
    encode_dict_values_plain,
    write_dictionary_page_header,
)
from .writer_dict_numeric import (
    encode_dict_numeric_column_page,
    encode_dict_values_plain_numeric,
)
from .decimal_encode import (
    decimal128_schema_element,
    encode_decimal128_column_page,
    patch_decimal_schema_elements,
)
from .file_assembly import (
    PARQUET_CREATED_BY,
    append_magic,
    column_chunk_for_page,
    finish_file,
)
from .writer import ParquetFileWriter
from .encoded_column import (
    EncodedColumn,
    encode_column_to_buffer,
    write_batch_parallel_homogeneous,
    write_parquet_file_from_encoded,
)
