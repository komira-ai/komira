# =============================================================================
# dict_code_bounds — THE dictionary-code range gate (ASSERT=none hardening)
# =============================================================================
#
# ⚠ ONE function, deliberately. Read this before adding a second copy.
#
# THE DEFECT SHAPE. A dictionary-encoded column is two things: a stream of
# integer CODES (per row, off the wire) and a DICTIONARY (per chunk, off the
# wire). Every consumer resolves a row by indexing the dictionary with the
# code. The code is a full Int32 read straight out of an attacker-authored
# file, so an unchecked `dict[code]` reaches up to ~8 GB (4-byte entries) /
# ~16 GB (8-byte entries) past the dictionary allocation, at a granularity
# the attacker picks. Where the dictionary is SMALL — the boolean LUT in
# `count_numeric_dict_predicate` is one byte per distinct entry, often 2 —
# essentially every code is out of range.
#
# None of that was ever caught by a bounds check. The load paths bottom out
# in `ByteView.get_typed` / `PrimitiveArray.get_typed` / `List.__getitem__`,
# all of which guard with `debug_assert` — INERT at `ASSERT=none`, and
# `PrimitiveArray.get_typed` checks only `index >= 0` so it is inert against
# an over-range code at `ASSERT=safe` too. It is not a bounds-check problem;
# a bounds check was never the right mechanism for hostile input.
#
# WHY THIS FILE EXISTS RATHER THAN A THIRD INLINE COPY. An inline min/max
# reduction in the six `komira_parquet` `resolve_*` dictionary gathers
# misses every consumer that does not go through `resolve_*`:
#
#   * `Column.from_numeric_dict{,_codes_view}` -> `dict_value_i64` /
#     `dict_value_f64` (the preserve_dict numeric dict-VECTOR path — codes
#     are handed downstream ungathered, so `resolve_int32` never runs)
#   * `count_numeric_dict_predicate`'s `lut[code]` (the fused count path)
#   * `resolve_as_string_dict` -> `Column.string_dict_value_at`
#
# and the dictionary gather has its own per-lookup form of the same check.
# Four spellings of one check, three of them
# absent where it mattered. The gate is a SHARED PRIMITIVE from here on:
# a new dict-code consumer calls this, and a reviewer greps for this name.
#
# WHY BULK, NOT PER-LOOKUP. Per-lookup is what `gather_dict.mojo` does, and
# it puts a branch inside the vpgather fan-out that the SIMD dict resolvers
# exist to keep clean. This is instead ONE branchless min/max reduction over
# the code stream, run ONCE per column chunk before any gather — the same
# `select`-based single-pass shape as `komira_core/simd_helpers.mojo`.
# A stream proven in range needs no re-checking per row, which is the whole
# point of validating at a boundary. Call it where codes first BIND to a
# dictionary, never inside a per-row loop.
# =============================================================================

from std.sys import simd_width_of, size_of

from komira_core.collections.byte_view import ByteView


def validate_dict_codes[
    code_dt: DType
](codes: ByteView[_], n: Int, dict_len: Int, what: String) raises:
    """Raise unless every dictionary code in `codes[0:n]` lies in [0, dict_len).

    ONE branchless min/max pass over the code stream. Intended to run once
    per column chunk, at the point the codes bind to a dictionary — NOT per
    row and NOT inside a gather loop.

    Parameters:
        code_dt: DType of the codes (`int32` or `int64`).

    Args:
        codes: Byte view over the code stream. Must cover at least
            `n * size_of[Scalar[code_dt]]()` bytes.
        n: Number of codes to check.
        dict_len: Number of entries ACTUALLY present in the dictionary the
            codes index. Pass the container's OWN length (`len(entries)`,
            `array.length`), never a count declared by the file — a
            page-declared `num_values` is itself attacker-supplied and
            validating against it proves nothing.
        what: Caller name, used in the error message so someone debugging a
            truncated file learns which column path rejected it.

    Raises:
        Error naming the observed code range and the dictionary extent.
    """
    if n <= 0:
        return

    comptime sz = size_of[Scalar[code_dt]]()
    if codes.len() < n * sz:
        raise Error(
            "parquet: corrupt dictionary-encoded page: "
            + what
            + " was handed "
            + String(n)
            + " dictionary codes but only "
            + String(codes.len())
            + " bytes of code stream"
        )

    if dict_len <= 0:
        raise Error(
            "parquet: corrupt dictionary page: "
            + what
            + " has "
            + String(n)
            + " codes to resolve but the dictionary holds no entries"
        )

    # SAFETY: module-internal pointer arithmetic over a view whose byte
    # extent was just checked to cover n * sz bytes. The raw pointer does
    # not escape this function; `codes` outlives the loop by construction
    # (it is a borrowed parameter).
    var p = codes._unsafe_ptr().bitcast[Scalar[code_dt]]()

    comptime W: Int = simd_width_of[code_dt]()
    var min_code = p.load[width=1](0)
    var max_code = min_code
    var i = 1
    var simd_end = (n // W) * W
    if simd_end > 0:
        var first = p.load[width=W](0)
        var min_acc = first
        var max_acc = first
        i = W
        while i < simd_end:
            var chunk = p.load[width=W](i)
            min_acc = (min_acc.lt(chunk)).select(min_acc, chunk)
            max_acc = (max_acc.gt(chunk)).select(max_acc, chunk)
            i += W
        min_code = min_acc.reduce_min()
        max_code = max_acc.reduce_max()
    while i < n:
        var v = p.load[width=1](i)
        if v < min_code:
            min_code = v
        if v > max_code:
            max_code = v
        i += 1

    if Int(min_code) < 0 or Int(max_code) >= dict_len:
        raise Error(
            "parquet: corrupt dictionary-encoded page: "
            + what
            + " saw dictionary codes in ["
            + String(Int(min_code))
            + ", "
            + String(Int(max_code))
            + "] but the loaded dictionary holds only "
            + String(dict_len)
            + " entries"
        )
