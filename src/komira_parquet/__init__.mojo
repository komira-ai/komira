"""`komira_parquet`: the Parquet reader core.

These parts of the package hold the value decoders of the Parquet encodings:
PLAIN (`plain`, and `plain_flba` for FIXED_LEN_BYTE_ARRAY), RLE /
Bit-Packing Hybrid (`rle`), DELTA_BINARY_PACKED (`delta`),
DELTA_LENGTH_BYTE_ARRAY and DELTA_BYTE_ARRAY (`delta_byte_array`) and
BYTE_STREAM_SPLIT (`byte_stream_split`); the DECIMAL to Decimal128 decoders
(`decimal_decode`); and the run-time arms and counters of the decode and scan
paths (`decode_arm_trace`, `scan_copy_trace`, `payload_sel_trace`,
`staged_filter_trace`). Every public decoder takes Spans.
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
