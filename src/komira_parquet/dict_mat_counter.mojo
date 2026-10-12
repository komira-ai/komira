# =============================================================================
# dict_mat_counter — how many times a string dictionary chunk was rebuilt as
#                    a dense StringArray
# =============================================================================
#
# The column decoder returns a BYTE_ARRAY dictionary chunk as a DICTIONARY
# column (codes plus entries) when the caller asks it to keep dictionaries
# (`preserve_dict`), and as a dense STRING column otherwise. The dense form is
# built by `_dict_to_string_array` (column_decoder_strings), which copies every
# row's bytes out of the dictionary. A dictionary-preserving decode of a
# non-null chunk must never build it: the consumer reads the codes in place.
#
# `_dict_to_string_array` adds one to this counter on every call, so a test can
# decode with `preserve_dict=True` and read 0, and decode the same chunk dense
# and read 1. The dense decode, the nullable dense decode and the
# dictionary-to-PLAIN fallback chunk each build it legitimately, so the counter
# is a process-wide call count, not a claim that the function is unused.
#
# Mechanism: a name-keyed, init-once, process-global `Atomic[int64]` through
# the stdlib `_Global` slot, the idiom of `decode_arm_trace` and
# `scan_copy_trace`. One relaxed add per column chunk, never per row.
# =============================================================================

from komira_atomic_alias import AtomicI64
from std.ffi import _Global
from std.memory import OwnedPointer, UnsafePointer, alloc


def _init_dict_mat_counter() -> OwnedPointer[AtomicI64]:
    """`_Global` init_fn (non-raising): allocate the counter once per process,
    initialised to 0."""
    var raw = alloc[AtomicI64](1)
    # SAFETY: module-private init, concrete origin from `alloc`. `Atomic` is
    # not movable by value, so its scalar is initialised in place before the
    # `OwnedPointer` takes ownership; the raw pointer never leaves this
    # function (the return type is `OwnedPointer`).
    raw.unsafe_bitcast[Scalar[DType.int64]]().unsafe_write(Scalar[DType.int64](0))
    return OwnedPointer[AtomicI64](unsafe_from_raw_pointer=raw)


comptime _DICT_MAT_COUNTER = _Global[
    "komira_parquet_dict_to_string_array_calls", _init_dict_mat_counter
]


@always_inline
def dict_mat_counter_incr() raises:
    """Record one `_dict_to_string_array` call. `raises` only to propagate
    `_Global.get_or_create_ptr`'s signature."""
    # SAFETY: `get_or_create_ptr` targets runtime-managed static storage that
    # lives for the process; its pointer is the stdlib `_Global` API's own
    # return type and stays inside this helper.
    _ = _DICT_MAT_COUNTER.get_or_create_ptr()[][].fetch_add(Int64(1))


def dict_to_string_array_call_count() raises -> Int:
    """The process-wide `_dict_to_string_array` call count."""
    # SAFETY: see `dict_mat_counter_incr`.
    return Int(_DICT_MAT_COUNTER.get_or_create_ptr()[][].load())


def reset_dict_to_string_array_call_count() raises:
    """Reset the process-wide call count to 0 (test setup)."""
    # SAFETY: see `dict_mat_counter_incr`.
    _DICT_MAT_COUNTER.get_or_create_ptr()[][].store(Scalar[DType.int64](0))
