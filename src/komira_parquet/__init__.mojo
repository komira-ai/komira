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

It decodes a column chunk a chunk of rows at a time into a reused buffer
(`subrg_column_cursor`, with `subrg_cursor_pages`, `subrg_dbp_trace` and
`subrg_scan_route_trace`), holds a worker's reusable decode buffers
(`column_decode_context`), decodes a nested leaf with its levels
(`nested_decoder`) and reads one PLAIN page from a file range
(`column_reader`).

It decodes a whole flat column chunk into one column (`column_decoder`, with
its steps in `column_decoder_state`, `column_decoder_pages`,
`column_decoder_values`, `column_decoder_assemble`, `column_decoder_finish`
and `column_decoder_strings`, and the dense-string rebuild counter in
`dict_mat_counter`).

It decides from a footer what a scan reads: the min/max row-group pruner
and its all-match dual (`rg_pruner`), row selections (`row_selection`), the
row groups a row window overlaps (`row_window`) and the Arrow types an
`ARROW:schema` key names (`arrow_schema_hint`); and it reads a column chunk
as stored (`bypass`). It keeps a session's parsed footers
(`runtime_footer_cache`, with the pin budget in `footer_pin_budget`) and
serves a footer's statistics to a planner (`table_stats`).

It reads a local file a row group or a morsel at a time (`morsel_reader`,
with its morsel windows in `morsel_slice`), and decodes a row group from
bytes the caller already holds, with no I/O (`bytes_decode`).

It reads only the pages a filter needs: page indexes (`page_index`,
`page_index_parser`, `page_index_cache`) and the pages a filter can skip
(`page_pruner`); and it holds a scan source's row-group reads
(`parquet_source_helpers`, `parquet_source_constants`,
`parquet_source_page_picks`).
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
from .column_decoder import (
    NumericDictCodes,
    NumericDictCodesHolder,
    decode_column_pages,
)
from .rg_pruner import all_match_row_count, can_prune_row_group, rg_all_match_row_group
from .row_selection import IntervalCursor, RowInterval, RowSelection
from .row_window import ParquetRowWindowResolution, resolve_row_group_window
from .arrow_schema_hint import ArrowSchemaHint, arrow_schema_hint_from_metadata, refine_from_hint
from .bypass import RawColumnChunk, read_raw_column_chunk
from .footer_pin_budget import mmap_pin_budget_from_ram, resolve_mmap_pin_byte_cap
from .runtime_footer_cache import ParquetMetadataCache, SharedParquetFooter
from .table_stats import ParquetStatsProvider, collect_table_stats, read_parquet_table_stats
from .morsel_reader import ColumnProjection, ParquetMorselReader
from .bytes_decode import (
    ByteRange,
    decode_column_chunk_from_bytes,
    decode_row_group_from_bytes,
    row_group_byte_range,
)
from .page_index import (
    ColumnIndex,
    OffsetIndex,
    PageByteRun,
    coalesce_pages,
    read_selected_pages_via_runs,
)
from .page_index_parser import parse_column_index_int64, parse_offset_index
from .page_index_cache import ParquetPageIndexCache, get_or_parse_indexes_copy
from .page_pruner import (
    PageIndexBundle,
    PageSelection,
    PageSelectionSet,
    evaluate_page_filter,
    select_pages_for_unit,
)
