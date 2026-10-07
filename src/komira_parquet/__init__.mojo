"""`komira_parquet`: the Parquet reader core.

The package holds the value decoders of the Parquet encodings: RLE /
Bit-Packing Hybrid (`rle`), DELTA_BINARY_PACKED (`delta`),
DELTA_LENGTH_BYTE_ARRAY and DELTA_BYTE_ARRAY (`delta_byte_array`) and
BYTE_STREAM_SPLIT (`byte_stream_split`), with the run-time arms and counters
of the decode path (`decode_arm_trace`). Every public decoder takes Spans.

It also reads a file's footer and metadata: the file reader over any
`FileSystem` (`file_reader`), the Thrift Compact reader (`thrift_compact`),
the footer parsers (`metadata_parser`, `footer_header`), the page header
parser (`page_header_parser`), bloom filters and the row-group bloom pruner
(`bloom_reader`, `bloom_pruner`), a row-count cache (`num_rows_cache`) and
the partition-predicate mapping (`partition_pred_bridge`).
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
from .bloom_reader import BloomFilterHeaderInfo, load_bloom_filter, parse_bloom_filter_header
from .bloom_pruner import can_prune_row_group_by_bloom
from .num_rows_cache import ParquetNumRowsCache
from .partition_pred_bridge import pod_from_predicate, predicate_from_pod
