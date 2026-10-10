"""`komira_parquet`: the Parquet reader core.

These parts of the package hold the value decoders of the Parquet encodings:
PLAIN (`plain`, and `plain_flba` for FIXED_LEN_BYTE_ARRAY), RLE /
Bit-Packing Hybrid (`rle`), DELTA_BINARY_PACKED (`delta`),
DELTA_LENGTH_BYTE_ARRAY and DELTA_BYTE_ARRAY (`delta_byte_array`) and
BYTE_STREAM_SPLIT (`byte_stream_split`); the DECIMAL to Decimal128 decoders
(`decimal_decode`); the dictionary decoder (`dictionary`, with its gathers in
`dictionary_resolve` and `dict_gather_fused`) and the definition-level bitmap
(`def_level_bitmap`); the nested-type level helpers (`nested`); the
schema-to-Arrow type mapping and array helpers of the column decoder
(`decode_helpers`, `null_expand`); and the run-time arms and counters of the
decode and scan paths (`decode_arm_trace`, `scan_copy_trace`,
`payload_sel_trace`, `staged_filter_trace`). Every public decoder takes Spans.

It also reads a file's footer and metadata: the file reader over any
`FileSystem` (`file_reader`), the Thrift Compact reader (`thrift_compact`),
the footer parsers (`metadata_parser`, `footer_header`), the page header
parser (`page_header_parser`), bloom filters and the row-group bloom pruner
(`bloom_reader`, `bloom_pruner`), a row-count cache (`num_rows_cache`) and
the partition-predicate mapping (`partition_pred_bridge`). The column
chunk page walk in front of the selection gathers (`gather`) reads the
selected rows of a chunk.
"""

from .byte_stream_split import (
    decode_byte_stream_split_float32,
    decode_byte_stream_split_float64,
)
from .rle import RleDecoder, decode_rle_int32, decode_def_levels, decode_levels, bit_width_for_max_level, read_uleb128
from .delta import (
    DeltaDecoder,
    delta_binary_packed_byte_count,
)
from .delta_byte_array import (
    decode_delta_length_byte_array,
    decode_delta_byte_array,
)
from .plain import (
    decode_plain_int32,
    decode_plain_int64,
    decode_plain_float32,
    decode_plain_float64,
    decode_plain_int32_zero_copy,
    decode_plain_int64_zero_copy,
    decode_plain_float32_zero_copy,
    decode_plain_float64_zero_copy,
    decode_plain_boolean,
    decode_plain_byte_array,
    decode_plain_int96_to_int64,
)
from .plain_flba import (
    decode_plain_fixed_len_byte_array,
    decode_plain_flba_decimal_to_float64,
)
from .decimal_decode import (
    decode_plain_flba_decimal_to_i128,
    decode_int32_buf_to_decimal128,
    decode_int64_buf_to_decimal128,
)
from .dictionary import DictionaryDecoder
from .def_level_bitmap import DefLevelResult, decode_def_levels_to_bitmap
from .nested import (
    DecodedLeaf,
    NestedFieldInfo,
    LeafInfo,
    compute_leaf_levels,
    reconstruct_struct_column,
    reconstruct_list_column,
    reconstruct_map_column,
)
from .file_reader import (
    ParquetFilePreamble,
    ParquetFileReader,
    read_parquet_preamble,
)
from .thrift_compact import (
    ParquetMetadataSummary,
    ThriftCompactReader,
    parse_metadata_summary,
)
from .metadata_parser import parse_full_metadata
from .footer_header import (
    ParquetFooterNumRows,
    ParquetHeaderAndSchema,
    find_arrow_schema_value,
    parse_metadata_header_and_schema,
    parse_metadata_num_rows_only,
)
from .page_header_parser import PageHeaderResult
from .gather import decode_column_with_selection
from .bloom_reader import BloomFilterHeaderInfo, load_bloom_filter, parse_bloom_filter_header
from .bloom_pruner import can_prune_row_group_by_bloom
from .num_rows_cache import ParquetNumRowsCache
from .partition_pred_bridge import pod_from_predicate, predicate_from_pod
