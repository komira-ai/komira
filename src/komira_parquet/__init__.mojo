"""`komira_parquet`: the Parquet reader core.

This part of the package holds the value decoders of the Parquet encodings:
RLE / Bit-Packing Hybrid (`rle`), DELTA_BINARY_PACKED (`delta`),
DELTA_LENGTH_BYTE_ARRAY and DELTA_BYTE_ARRAY (`delta_byte_array`) and
BYTE_STREAM_SPLIT (`byte_stream_split`), with the run-time arms and counters
of the decode path (`decode_arm_trace`). Every public decoder takes Spans.
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
