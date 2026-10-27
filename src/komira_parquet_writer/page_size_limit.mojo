# =============================================================================
# page_size_limit.mojo — the Parquet PageHeader **i32** ceiling, made LOUD.
# =============================================================================
#
# `PageHeader.uncompressed_page_size` and `PageHeader.compressed_page_size` are
# **i32** BY THE PARQUET SPEC (parquet.thrift). This writer serialises them
# through `ThriftCompactWriter.write_i32_field` -> `_zigzag_i32`, whose first
# statement is `var n32 = Int32(n)` — a SILENT TRUNCATING CAST. A page body of
# 2^31 bytes therefore emits a header claiming **-2147483648** bytes, the file
# closes reporting success, and nothing on the write side ever says a word.
#
# WHY IT IS REACHABLE, NOT THEORETICAL
# ------------------------------------
# This writer emits ONE unsplit data page per row group per column. The row
# group cap is `DEFAULT_MAX_ROWS_PER_RG = 122_880`
# (`record_batch_writer.mojo`), so a column whose average value length exceeds
# `2^31 / 122_880` ~= **17.5 KB** wraps the field. Document blobs, JSON
# payloads, base64 attachments and gathered wide-VARCHAR join keys all live
# above that line — this is a size an ordinary column reaches, not an
# adversarial one.
#
# ⚠ THE ARITHMETIC OVERFLOWS ON THE **NARROW** PATH TOO, AND BY A SMALLER
# MARGIN THAN THE DATA ITSELF. `encode_plain_byte_array_data` emits
# `n * 4 + data_length` bytes (a 4-byte length prefix per value), and
# `_assemble_column_page` prepends the def levels on top of that. An Int32
# offsets buffer bounds `data_length` at `INT32_MAX` — but NOT
# `def_len + n * 4 + data_length`. So a `string` column that is itself
# perfectly legal Arrow can still exceed the page-header field. ONE guard, at
# the page-assembly tail where the final body size is known, covers both offset
# widths and every value encoding.
#
# WHAT THIS BUYS
# --------------
# The read side rejects a wrapped header loudly, so the pre-existing failure
# mode was noisy-on-read rather than a wrong answer. That is still a violation
# of fail-fast: the corruption is committed to disk, the writing job exits 0,
# and the defect surfaces in whichever downstream reader touches the file next,
# arbitrarily far from the code that caused it. This converts it into a named
# error at the write.
#
# THE GUARD SHAPE — modelled on `encode_plain_byte_array_data_large`
# ------------------------------------------------------------------
# That function already guards the identical defect class ONE LEVEL DOWN (the
# per-value 4-byte PLAIN length prefix) and raises rather than letting
# `Int32(str_len)` wrap. This is the same check at the page altitude. Both are
# O(1) per page, on the cold path, and cost nothing in steady state.
#
# ⚠ NOT AN ALIAS OF `ARROW_INT32_OFFSET_MAX`, DELIBERATELY. The two constants
# are numerically identical (both are `INT32_MAX`) and conceptually unrelated:
# that one bounds what an **Arrow Int32 offsets buffer** can address, this one
# bounds a **Thrift i32 field in a Parquet PageHeader**. Aliasing them would
# mean a future change to either silently moved the other, and there is no
# reason the Arrow in-memory layout and the Parquet on-disk metadata schema
# must agree forever. They are stated separately and each cites its own spec.
#
# The record-batch writer and the page encoders named above
# (`record_batch_writer`, `encode_plain_byte_array_data`,
# `_assemble_column_page`) are later parts of this package; today the guard's
# caller is `ThriftCompactWriter`'s page-header serialisers.
# =============================================================================

from komira_atomic_alias import AtomicI64
from std.ffi import _Global
from std.memory import OwnedPointer, alloc


comptime PARQUET_PAGE_SIZE_MAX: Int = 2147483647
"""Largest page size representable in a Parquet `PageHeader` size field.

`uncompressed_page_size` / `compressed_page_size` are `i32` in
parquet.thrift, so the inclusive ceiling is `INT32_MAX`.
"""


def _init_page_size_limit_slot() -> OwnedPointer[AtomicI64]:
    """`_Global` init_fn: one process-wide AtomicI64 holding the lowered
    limit, 0 meaning "not lowered"."""
    var raw = alloc[AtomicI64](1)
    # SAFETY: module-private init with a concrete origin from `alloc`.
    # `Atomic` is not movable by value, so its scalar is initialised in place
    # before `OwnedPointer` takes ownership; the raw pointer never leaves this
    # function (the return type is `OwnedPointer`).
    raw.unsafe_bitcast[Scalar[DType.int64]]().unsafe_write(Scalar[DType.int64](0))
    return OwnedPointer[AtomicI64](unsafe_from_raw_pointer=raw)


comptime _PAGE_SIZE_LIMIT = _Global[
    "komira_parquet_writer_page_size_limit", _init_page_size_limit_slot
]


def set_parquet_page_size_limit(limit: Int) raises:
    """Lower the page-body byte total above which the writer refuses to emit.

    A test seam, set by a program from its own flag (the package reads no
    environment). Reaching the real ceiling honestly costs 2 GiB of page body
    in one row group, a fixture no test can afford; lowering the trip point
    runs the SAME guard, on the SAME page-assembly path, over a few
    kilobytes. It moves the threshold only: it selects no other code path,
    relaxes no check and switches no encoder.

    It can only ever lower the ceiling. A value that is not positive, or one
    above `PARQUET_PAGE_SIZE_MAX`, restores the real ceiling, so a mistake
    cannot raise the trip point past the i32 field and re-arm the silent
    wrap this module exists to prevent. The setting is process-wide.

    Args:
        limit: The new ceiling in bytes, in `[1, PARQUET_PAGE_SIZE_MAX]`;
            any other value restores `PARQUET_PAGE_SIZE_MAX`.
    """
    var stored = Int64(0)
    if limit > 0 and limit < PARQUET_PAGE_SIZE_MAX:
        stored = Int64(limit)
    _PAGE_SIZE_LIMIT.get_or_create_ptr()[][].store(stored)


def parquet_page_size_limit() raises -> Int:
    """The page-body byte total above which this writer REFUSES to emit.

    `PARQUET_PAGE_SIZE_MAX` unless a program lowered it with
    `set_parquet_page_size_limit`.

    Returns:
        `PARQUET_PAGE_SIZE_MAX` normally; the lowered limit when one is set.
    """
    var v = Int(_PAGE_SIZE_LIMIT.get_or_create_ptr()[][].load())
    if v <= 0 or v > PARQUET_PAGE_SIZE_MAX:
        return PARQUET_PAGE_SIZE_MAX
    return v


def parquet_page_size_overflow(
    site: StaticString,
    imm column: String,
    imm field: StaticString,
    size: Int,
    limit: Int,
) -> Error:
    """Build the named `ParquetPageSizeOverflow` error. COLD path only.

    Args:
        site: Function that detected the overflow.
        column: Column name if the caller knows one, else empty.
        field: The PageHeader field that would have been truncated.
        size: The byte count that does not fit.
        limit: The ceiling in force (production, or a lowered test seam).

    Returns:
        An `Error` naming the column, the field, the size, the limit and the
        wrapped value the silent narrowing would have written.
    """
    var col_part: String
    if column.byte_length() == 0:
        col_part = String("<unnamed column>")
    else:
        col_part = String("column '") + column + String("'")
    return Error(
        String("ParquetPageSizeOverflow: ")
        + col_part
        + String(" at ")
        + String(site)
        + String(" produced a page whose ")
        + String(field)
        + String(" is ")
        + String(size)
        + String(" bytes, which exceeds the Parquet PageHeader i32 limit of ")
        + String(limit)
        + String(". PageHeader sizes are i32 in parquet.thrift; writing this")
        + String(" would silently wrap the field to ")
        + String(_wrap_to_int32(size))
        + String(" and emit a file that looks written and does not parse.")
        + String(" Write this column with a smaller `max_rows_per_rg` so each")
        + String(" row group's page stays under the ceiling.")
    )


def _wrap_to_int32(v: Int) -> Int:
    """Two's-complement narrowing of `v` to 32 bits, computed arithmetically.

    Used only to SHOW the caller the bogus value the silent narrowing would
    have produced. Masked rather than `Int32(v)` so the message does not
    itself depend on the conversion semantics it is describing.

    Args:
        v: The 64-bit value that was about to be narrowed.

    Returns:
        The signed 32-bit value `v` would have become.
    """
    var m = v & 0xFFFFFFFF
    if m >= 0x80000000:
        m -= 0x100000000
    return m


def check_parquet_page_size(
    site: StaticString,
    imm column: String,
    imm field: StaticString,
    size: Int,
) raises:
    """Raise `ParquetPageSizeOverflow` if `size` will not fit a PageHeader i32.

    Call this once per page, AFTER the body size is known and BEFORE the header
    is serialised. Also refuses a NEGATIVE size: a length that has already gone
    negative is an upstream overflow, and passing it through would write a
    plausible-looking header for a page that cannot exist.

    Args:
        site: Function performing the check.
        column: Column name if known, else empty.
        field: The PageHeader field this size will be written to.
        size: The byte count about to be narrowed to i32.

    Raises:
        Error: named `ParquetPageSizeOverflow`, when `size` will not fit.
    """
    var limit = parquet_page_size_limit()
    if size < 0 or size > limit:
        raise parquet_page_size_overflow(site, column, field, size, limit)


def check_parquet_page_size(
    site: StaticString,
    imm field: StaticString,
    size: Int,
) raises:
    """Column-name-less overload for emitters with no name in scope.

    Args:
        site: Function performing the check.
        field: The PageHeader field this size will be written to.
        size: The byte count about to be narrowed to i32.

    Raises:
        Error: named `ParquetPageSizeOverflow`, when `size` will not fit.
    """
    var limit = parquet_page_size_limit()
    if size < 0 or size > limit:
        raise parquet_page_size_overflow(site, String(), field, size, limit)
