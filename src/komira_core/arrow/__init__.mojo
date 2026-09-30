from .copyable_shared_aligned_buffer import CopyableSharedAlignedBuffer
from .arrow_types import (
    ArrowType,
    decimal_format_string,
    decimal256_format_string,
    timestamp_format_string,
    union_format_string,
    parse_format_string,
    extract_decimal_params,
    extract_timestamp_timezone,
    extract_union_type_ids,
)
from .constants import SIMD_WIDTH_F64, SIMD_WIDTH_F32, SIMD_WIDTH_I64, SIMD_WIDTH_I32, SIMD_WIDTH_I16, SIMD_WIDTH_I8, SIMD_WIDTH_U8, SIMD_WIDTH_U64, NUM_CORES, CACHE_LINE_BYTES, DEFAULT_MORSEL_ROWS
from .binary_array import BinaryArray
from .bitmap import Bitmap
from .bitmap_ops import select_into
from .ipc import serialize_primitive_batch, deserialize_primitive_batch
from .large_binary_array import LargeBinaryArray
from .large_string_array import LargeStringArray
from .list_array import ListArray
from .map_array import MapArray
from .boolean_array import BooleanArray
from .c_data_interface import CArrowSchema, CArrowArray, ARROW_FLAG_NULLABLE, ARROW_FLAG_DICTIONARY_ORDERED, ARROW_FLAG_MAP_KEYS_SORTED, export_schema, export_primitive, release_c_schema, release_c_array
from .column import Column
from .concat import _concat_columns, _arrow_type_byte_width, concat_record_batches_nway
from .csv_emit import (
    emit_record_batch_csv,
    emit_record_batch_csv_to,
    emit_parity_batch,
)
from .decimal_array import Decimal128Array
from .decimal256_array import Decimal256Array
from .interval_mdn_array import IntervalMonthDayNanoArray, INTERVAL_MDN_BYTE_WIDTH
from .dictionary_array import StringDictionaryArray
from .dictionary_merge import merge_dict_columns
from .primitive_array import PrimitiveArray
from .shared_aligned_buffer import SharedAlignedBuffer
from .string_array import StringArray
from .struct_array import StructArray
from .union_array import UnionArray
from .schema import Field, Schema, SchemaBuilder, RecordBatch, RecordBatchBuilder
from .record_batch_compare import (
    RecordBatchDiff,
    record_batch_diff,
    record_batch_byte_equal,
)
from komira_core.io.heap_region import HeapRegion
# Column-native foundation. The codec-bridging shim lives in the engine
# runtime's spill package (NOT here): it imports the spill codec from
# komira_engine_runtime, and komira_core cannot depend on the engine
# runtime (that is a build cycle — engine depends on core).
# Callers that need the boundary bridge import
# `from komira_engine_runtime.spill.column_native_shims import ...`.
from .column_native import (
    ColumnAppendix,
    ColumnDescriptor,
    ColumnNativeBatch,
    ColumnNativeBatchBuilder,
    ColumnNativeBatchHeader,
    UnifiedColumnFormat,
)
from .column_native_nested import ListColumnFormat, StructColumnFormat
