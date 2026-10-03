# =============================================================================
# String Comparison Expression Evaluators
# =============================================================================
#
# Buffer access: offsets and bitmaps go through the typed view API
# (`view_ro` / `view_mut` + `get_typed[Int32]` / `write_u8_at`). Data bytes
# are read through origin-tied typed pointers tied to `col.data`, in the
# `.as_immutable()` → ImmutOrigin shape that the parametric
# `_string_bytes_equal` / `_string_bytes_cmp` callees expect.
#
# =============================================================================
#
# Comparisons for StringArray AND LargeStringArray columns against scalar
# string values, producing BooleanArray (bit-packed, Arrow-compliant) results.
#
# The per-row kernels are parameterized on `OffsetType: DType`
# (DType.int32 for StringArray, DType.int64 for LargeStringArray) via
# `@parameter fn _string_*_kernel[OffsetType]()`. Both array types share one
# body — the only difference is the offset width read out of the offsets
# buffer. This mirrors the Decimal128/Decimal256 + Date32/Date64 pattern.
#
# Unlike numeric comparisons, string comparison is inherently per-element
# (variable length), so SIMD does not directly apply. Optimizations:
#   - Length short-circuit for equality: if lengths differ, the strings
#     cannot be equal -- skip the byte comparison entirely.
#   - Direct byte comparison via raw pointers: avoids String allocation
#     for each element by comparing raw UTF-8 bytes in the Arrow buffers.
#   - Bit-packing in groups of 8 for output, matching the numeric evaluators.
#
# All public functions take a StringArray / LargeStringArray column and a
# String scalar value, returning a BooleanArray where True indicates rows
# that satisfy the comparison.
# =============================================================================

from std.ffi import external_call, c_int
from std.memory import UnsafePointer

from komira_simd.byte_class.byte_equal import bytes_equal
from komira_simd.byte_class.horizontal_reduce import any_true
from komira_counters.string_eq_arm_counter import string_eq_ladder_counter_incr
from komira_column_kernels.string_contains_scan import string_contains_scan_kernel
from komira_arrow.string_array import StringArray
from komira_arrow.large_string_array import LargeStringArray
from komira_arrow.boolean_array import BooleanArray
from komira_arrow.bitmap import Bitmap, bytes_for_bits
from komira_buffer.aligned_buffer_trait import AlignedBufferTrait
from komira_buffer.heap_region import HeapRegion
from komira_buffer.memory_region import MemoryRegion


# =============================================================================
# Scalar-bytes ownership: borrow-tracked refs, NOT wildcard origins
# =============================================================================
#
# CRITICAL CORRECTNESS NOTE. Do not write:
#
#     var val_copy = value                    # local String
#     var val_ptr = UnsafePointer[UInt8](     # raw pointer via unsafe_from_address
#         unsafe_from_address=Int(val_copy.as_c_string_slice().unsafe_ptr())
#     )
#
# That pattern LAUNDERS THE LIFETIME: once the pointer goes through
# `unsafe_from_address=Int(...)`, the Mojo compiler no longer tracks it as a
# borrow of `val_copy`. For small strings (SSO), the String struct lives on
# the stack; when it is destroyed the bytes are reused by the next caller and
# the laundered pointer silently observes different bytes every call: a
# predicate like `c_mktsegment == 'BUILDING'` returns a different match count
# on each run over the same file. A `_ = struct` keepalive is NOT reliable.
#
# Nor wrap the scalar in `OwnedPointer[String]` and then cast the raw pointer
# through `.as_any_origin()` into `ImmutAnyOrigin`. From
# the Mojo docs: "Wildcard origins... effectively disable Mojo's ASAP
# destruction for any values in that scope, as long as the pointer is live.
# Accordingly, the use of wildcard origins is discouraged, and should be used
# as a last resort." Casting to `ImmutAnyOrigin` defeats the lifetime
# tracking.
#
# The design: pass the `String` typed value across function boundaries and
# extract the raw pointer only in the deepest scope where it is used. Mojo's
# borrow checker sees the String as borrowed for the entire body of the impl
# function and keeps it alive. No OwnedPointer, no wildcard origin casts, no
# `unsafe_from_address`. The kernel functions are parametric on the concrete
# origins of the two pointers they read through.
# =============================================================================


# =============================================================================
# Internal: raw byte comparison helpers (parametric on concrete origins)
# =============================================================================
#
# These operate directly on the StringArray's offset and data buffers to avoid
# allocating a String per element. The Arrow layout gives us:
#   offsets[i]   = start byte of string i
#   offsets[i+1] = end byte (exclusive)
#   data[offsets[i] .. offsets[i+1]] = UTF-8 bytes of string i
#
# The helpers are parametric on `data_origin` (the Arrow data buffer's origin,
# carried by `col`) and `val_origin` (the borrowed scalar String's origin,
# carried by `val` in the caller). Mojo propagates both origins through the
# inlined helpers so the borrow tracker keeps both source values alive across
# the per-row loop.
# =============================================================================


@always_inline
def _bytes_eq[
    a_origin: ImmOrigin,
    b_origin: ImmOrigin,
](
    a: UnsafePointer[UInt8, a_origin],
    b: UnsafePointer[UInt8, b_origin],
    n: Int,
) -> Bool:
    """True iff the `n` bytes at `a` and `b` are equal.

    ⭐ EVERY EQUALITY USE IN THIS MODULE ROUTES HERE, NOT THROUGH `_memcmp`.
    `external_call["memcmp"] == 0` is rewritten by LLVM to `bcmp`, and a
    hermetic Zig-based C toolchain links `compiler_rt`'s
    SIX-INSTRUCTIONS-PER-BYTE `bcmp` loop, weak-DEFINED in the executable with
    no PLT entry and no relocation — glibc's `__memcmp_avx2_movbe` is never
    reachable. `bytes_equal` is `@always_inline` and issues NO CALL at any
    width: `movl`/`cmpl` at n=4, `movq`/`cmpq` at n=8, `vmovdqu` +
    `vpxor <mem>` + `vptest` from 16 up.

    Strictly fewer instructions at every width, with no call on either side.
    The widths typical predicates reach here are short (`'MAIL'`/`'SHIP'` =
    4 B, `'Brand#45'` = 8 B).

    ⚠ This path is HOT even for dictionary-encoded columns: a scan that does
    not preserve the dictionary densifies the column first and then compares
    it HERE, PER ROW — population rows, not dictionary cardinality. Where the
    dictionary is preserved, the `dict_filter` arm compares against the
    dictionary instead.

    ⭐ The structurally largest user is `_contains_at`, whose brute-force
    O(n*m) scan would otherwise issue ONE `bcmp` CALL PER CANDIDATE POSITION.

    The local raw-pointer signature is kept deliberately: it is `_`-private to
    this module and the `Span` is built inside, so the encapsulation rule is
    satisfied where it binds — `bytes_equal`'s own public API takes Spans.

    Parametric on the two pointers' concrete origins; both are read-only.
    """
    if n == 0:
        return True
    return bytes_equal(
        Span[UInt8, a_origin](unsafe_ptr=a, length=n),
        Span[UInt8, b_origin](unsafe_ptr=b, length=n),
    )


@always_inline
def _memcmp[
    a_origin: ImmOrigin,
    b_origin: ImmOrigin,
](
    a: UnsafePointer[UInt8, a_origin],
    b: UnsafePointer[UInt8, b_origin],
    n: Int,
) -> Int:
    """Compare n bytes at a and b. Returns 0 if equal, <0 if a<b, >0 if a>b.

    ⚠ ORDERING ONLY, AND IT HAS EXACTLY ONE CALLER — `_string_bytes_cmp`,
    which needs the SIGN. Every EQUALITY use in this module goes through
    `_bytes_eq` above; do not route a new `== 0` / `!= 0` test through here.

    ⛔ This is NOT SIMD-accelerated (see `_bytes_eq`). It exists because a three-way
    compare is a DIFFERENT KERNEL from an equality one — an all-lanes-equal
    test cannot report which side is smaller. A vector ordering kernel
    (compare, `movemask`, `ctz` to the first differing byte) is buildable from
    this package's `movemask` + `bitmask_to_positions` members and is
    deliberately NOT built here: this path has not been shown to be hot.

    Parametric on the two pointers' concrete origins; both are read-only.
    Origins flow through from the caller so Mojo's borrow tracker keeps the
    source values alive across the call.
    """
    if n == 0:
        return 0
    return Int(external_call["memcmp", c_int](a, b, UInt(n)))


@always_inline
def _memmem[
    h_origin: ImmOrigin,
    n_origin: ImmOrigin,
](
    h: UnsafePointer[UInt8, h_origin],
    hlen: Int,
    needle: UnsafePointer[UInt8, n_origin],
    nlen: Int,
) -> Int:
    """Return the index of the first occurrence of `needle[0:nlen]` in
    `h[0:hlen]`, or -1 if absent.

    Uses libc `memmem` — glibc's two-way substring search, SIMD-accelerated
    for the first-byte scan — instead of an O(n*m) brute-force loop. This is
    the substring-search primitive behind the `%lit%lit%` LIKE fast path
    (`_analyze_like_pattern` / `_like_plan_match`), mirroring the structure
    DuckDB's LikeMatcher uses to turn a multi-`%` LIKE into a sequence of
    contains-checks.

    SAFETY: `memmem` returns a pointer INTO `h` (or NULL). The
    `MutExternalOrigin` wildcard cast is the canonical FFI-return boundary
    — the returned pointer is only used to compute an
    integer offset here and never dereferenced or escaped.
    """
    if nlen == 0:
        return 0
    if hlen < nlen:
        return -1
    var res = external_call["memmem", UnsafePointer[UInt8, MutUntrackedOrigin]](
        h, UInt(hlen), needle, UInt(nlen)
    )
    if Int(res) == 0:
        return -1
    return Int(res) - Int(h)


@always_inline
def _string_bytes_equal[
    data_origin: ImmOrigin,
    val_origin: ImmOrigin,
](
    data_ptr: UnsafePointer[UInt8, data_origin],
    elem_start: Int,
    elem_len: Int,
    val_ptr: UnsafePointer[UInt8, val_origin],
    val_len: Int,
) -> Bool:
    """Check if bytes [data_ptr+elem_start .. +elem_len] equal [val_ptr .. +val_len].

    Short-circuits on length mismatch -- O(1) when lengths differ.
    Parametric on both origins; see _memcmp.
    """
    if elem_len != val_len:
        return False
    if elem_len == 0:
        return True
    return _bytes_eq(data_ptr + elem_start, val_ptr, elem_len)


@always_inline
def _string_bytes_cmp[
    data_origin: ImmOrigin,
    val_origin: ImmOrigin,
](
    data_ptr: UnsafePointer[UInt8, data_origin],
    elem_start: Int,
    elem_len: Int,
    val_ptr: UnsafePointer[UInt8, val_origin],
    val_len: Int,
) -> Int:
    """Lexicographic comparison of two byte sequences.

    Returns <0 if elem < val, 0 if equal, >0 if elem > val.
    Follows the same convention as C memcmp, extended for unequal lengths:
    compare the common prefix first, then the shorter string is "less than".
    Parametric on both origins; see _memcmp.
    """
    var min_len = elem_len if elem_len < val_len else val_len
    if min_len > 0:
        var cmp = _memcmp(data_ptr + elem_start, val_ptr, min_len)
        if cmp != 0:
            return cmp
    # Common prefix is equal -- shorter string is "less than"
    return elem_len - val_len


# =============================================================================
# Internal: offset-type-parametric per-row kernels
# =============================================================================
#
# Each kernel is `@parameter fn ...[OffsetType: DType]` — instantiated at
# DType.int32 for StringArray, DType.int64 for
# LargeStringArray. The body reads offsets via `offsets_view.get_typed[
# Scalar[OffsetType]]` and casts to `Int` for arithmetic, so the SAME kernel
# body services both array widths with no code duplication.
#
# The 6 comparison kernels (eq/ne/gt/lt/ge/le) and 4 pattern kernels
# (contains/starts_with/ends_with/like) are all generalized this way.
#
# Why these `def` (not `fn`) functions: matches the module style. The
# borrow tracker keeps the inputs alive across the per-row loop; the kernels
# do not allocate.
# =============================================================================


# =============================================================================
# ⭐ THE NEEDLE-WIDTH HOIST — the per-row runtime ladder, lifted out of the loop
# =============================================================================
#
# THE COST IT REMOVES. `_string_eq_kernel_generic` rejects a row on length
# and only then compares bytes, so **every byte comparison it ever performs is
# exactly `val_len` wide** — and `val_len` is LOOP-INVARIANT. It nonetheless
# reaches that comparison through `bytes_equal`, whose width ladder (`i + W <=
# n`, then `rem >= 16 / 8 / 4 / 2`) is a RUNTIME dispatch on `n`. LLVM does not
# unswitch it out of the nested per-8-row / per-bit loop, so without the hoist
# the ladder is walked PER ROW to select the same width every time.
#
# Without the hoist, a 2-byte needle over a string column emits an inner loop
# that runs `cmp $0x10 / cmp $0x8 / cmp $0x4 / cmp $0x2` — FOUR
# compare-and-branch pairs — to reach ONE `movzwl`: several times DuckDB's
# instruction count per row for the same predicate. (The `i + W <= n`
# bulk-loop guard compares against `n`, not against an immediate, so W=32
# does not show up as a `cmp`.)
#
# THE SHAPE. `W` is chosen ONCE, before the loop, as the largest power of two
# <= `val_len` capped at `_EQ_HOIST_MAX_BLOCK`, and becomes a COMPTIME
# parameter. Each row is then two `W`-byte blocks, `[0, W)` and
# `[val_len - W, val_len)`, exactly the overlap argument `byte_equal.mojo`'s
# header makes for its tail ladder — `W <= val_len <= 2W` is what
# `_eq_block_width` establishes, so the two blocks' union is precisely
# `[0, val_len)`. Nothing is read outside the element.
#
# ⭐ AND THE NEEDLE BLOCKS ARE LOADED ONCE, OUTSIDE THE LOOP. They are
# loop-invariant by definition, so the per-row work is two loads from the
# column plus two register compares.
#
# ⚠ WHY `_EQ_HOIST_MAX_BLOCK` IS 8 AND NOT THE NATIVE SIMD WIDTH. Each
# distinct `W` is a separate instantiation of the body below, and this kernel
# is `@always_inline` into `eval_string_{eq,ne}` and thence into every
# predicate call site. Four arms (1/2/4/8) cover every needle of 1..16 bytes —
# which covers typical categorical/code filters ('g0' 2,
# 'MAIL'/'SHIP' 4, 'BUILDING'/'Brand#45' 8, 'AUTOMOBILE' 10, 'MACHINERY' 9) —
# for four instantiations. Widening to 16/32 would double the arms to buy the
# long-needle case, which is rare AND amortises the ladder over more bytes.
#
# ⭐⭐ AND IF YOU DO WIDEN IT, MOVE `_EQ_HOIST_MAX_BLOCK_LOG2` AND NOTHING
# ELSE. Everything below is DERIVED from it. Hardcoded rungs
# (`if val_len < 8: return 4` then `return _EQ_HOIST_MAX_BLOCK`) would, at a
# cap of 16, give a needle of 8 bytes `W = 16 > val_len`,
# `tail = val_len - W = -8`, and the kernel would load 16 bytes at
# `val_ptr - 8` and at `data_ptr + start - 8` — **BEFORE BOTH OBJECTS** — and
# a value test only catches that by divergence, after the bad read. Two
# things prevent it: the rung ladder is derived (a loop bounded by the cap),
# and `_eq_block_width` ENFORCES its own post-condition — a `W` that fails
# `W <= val_len <= 2W` returns 0 and routes to the generic arm, which is
# always correct.
#
# ⛔ THE GENERIC ARM IS NOT DEAD CODE. An empty needle has no block at all
# (`val_ptr + val_len - W` would be out of bounds), and a needle wider than
# `_EQ_HOIST_MAX_NEEDLE` breaks the two-block covering argument. Both route to
# the runtime ladder deliberately, and `string_eq_arm_counter` makes that
# assertable in BOTH directions from a test.
#
# ⛔ WHAT THIS HOIST REACHES: only the `eval_string_{eq,ne}` /
# `eval_large_string_{eq,ne}` entry points below. An IN-list over strings
# that runs its own loop through `_string_bytes_equal` -> `_bytes_eq` ->
# `bytes_equal` still pays the per-row dispatch; the hoist does not transfer
# to it by inspection (K needles, K widths, so no single comptime `W`).
# =============================================================================

# The widest comptime block this module instantiates.
#
# ⛔ THE INVARIANT `W <= val_len <= 2 * W` HAS **FOUR** ENDS, NOT TWO. The
# second pair is where an out-of-bounds read would live. They are:
#
#   1. THE CAP — `_EQ_HOIST_MAX_BLOCK`, the widest block instantiated.
#   2. THE MAX NEEDLE — `_EQ_HOIST_MAX_NEEDLE`, the widest needle any hoisted
#      arm may accept. Must stay `2 * cap`, or `val_len <= 2W` breaks at the
#      top rung.
#   3. THE RUNG LADDER — `_eq_block_width`'s choice of `W` for a given
#      `val_len`. Must never return a `W` ABOVE `val_len`, or `tail` goes
#      NEGATIVE and both loads run off the front of their objects.
#   4. THE SELECTOR'S ARM LIST — `_string_eqne_kernel_dispatch`. A `W` the
#      ladder can produce but the selector has no arm for silently loses the
#      hoist (correct answers, runtime-ladder instruction count, nothing red).
#
# ⭐ ONLY #1 IS AUTHORED. `_EQ_HOIST_MAX_BLOCK_LOG2` is the single knob; #2,
# #3 and #4 are all derived from it below, so widening the hoist is a
# one-token edit and cannot leave the four out of step. A test covers #4
# from the other side: it sweeps `1 .. _EQ_HOIST_MAX_NEEDLE` and reds by
# NAME on any width the selector fails to hoist.
comptime _EQ_HOIST_MAX_BLOCK_LOG2 = 3
comptime _EQ_HOIST_MAX_BLOCK = 1 << _EQ_HOIST_MAX_BLOCK_LOG2
comptime _EQ_HOIST_MAX_NEEDLE = 2 * _EQ_HOIST_MAX_BLOCK


@always_inline
def _eq_block_width(val_len: Int) -> Int:
    """The comptime block width to compare a `val_len`-byte needle with, or 0
    when no hoisted arm covers it.

    Returns the largest power of two `<= val_len`, capped at
    `_EQ_HOIST_MAX_BLOCK`. The result `W` satisfies `W <= val_len <= 2 * W`,
    which is exactly the precondition the two overlapping blocks in
    `_string_eqne_kernel_w` need in order to cover `[0, val_len)` with no hole.

    ⛔ THE LADDER IS DERIVED FROM THE CAP AND THE POST-CONDITION IS ENFORCED,
    NOT DOCUMENTED. Both halves are load-bearing and neither subsumes the
    other:

      * DERIVED — the loop's ceiling is `_EQ_HOIST_MAX_BLOCK`, so moving the
        cap moves the rungs with it. A hardcoded form
        (`if val_len < 8: return 4` / `return _EQ_HOIST_MAX_BLOCK`) would return
        `W = 16` for `val_len = 8` the moment the cap became 16 — a `tail` of
        -8 and two loads BEFORE their objects.
      * ENFORCED — the final guard returns 0 (→ the generic runtime-width
        arm, which is correct at every width) rather than a `W` that violates
        the contract. It also covers a cap that is NOT a power of two, which
        the derivation alone does not: at a cap of 12 the loop stops at
        `W = 8` while `_EQ_HOIST_MAX_NEEDLE` is 24, and `24 <= 16` is false.

    A degrade to the generic arm is a PERF regression the arm counter sees;
    an unenforced post-condition is an out-of-bounds READ that a value test
    only catches after the fact, if at all. Fail toward the slow answer.
    """
    if val_len < 1 or val_len > _EQ_HOIST_MAX_NEEDLE:
        return 0
    # Largest power of two <= val_len, capped. Runs at most
    # `_EQ_HOIST_MAX_BLOCK_LOG2` times, ONCE PER KERNEL CALL — never per row.
    var w = 1
    while (w * 2) <= _EQ_HOIST_MAX_BLOCK and (w * 2) <= val_len:
        w = w * 2
    if w > val_len or val_len > 2 * w:
        return 0
    return w


@always_inline
def _string_eqne_kernel_w[
    OffsetType: DType,
    W: Int,
    Negate: Bool,
    B_off: AlignedBufferTrait,
    B_data: AlignedBufferTrait,
](
    length: Int,
    offsets: B_off,
    data: B_data,
    val: String,
) -> BooleanArray:
    """Column ==/!= scalar over a COMPTIME `W`-byte block width.

    `Negate = False` is `==`, `True` is `!=` (nulls are applied afterwards by
    `_apply_validity`, exactly as in the generic arms, so a plain negation is
    the whole difference).

    PRECONDITION, established by the caller via `_eq_block_width`:
    `1 <= W <= val.byte_length() <= 2 * W`.

    SAFETY: every load is inside its own object.
      * needle:  `[0, W)` and `[val_len - W, val_len)` — both inside
        `[0, val_len)` because `W <= val_len`.
      * column:  read ONLY after `elem_len == val_len`, so the element spans
        `[start, start + val_len)` and both blocks lie inside it.
    `alignment=1` is load-bearing on every load: Arrow string data is packed,
    so an element begins at an arbitrary byte offset (same reasoning as
    `byte_equal.bytes_equal`).
    """
    var bm = Bitmap.create(length)
    var offsets_view = offsets.view_ro()
    # SAFETY: `data` is borrowed for this function body. `view_ro` ties the
    # ByteView's origin to the borrowed buffer's lifetime; `_unsafe_ptr`
    # returns `UnsafePointer[UInt8, view_origin]`, and `.as_immutable()`
    # preserves the origin tag while flipping to ImmutOrigin. No wildcard
    # origin, and nothing escapes this body.
    var data_view = data.view_ro()
    var data_ptr = data_view._unsafe_ptr().as_imm()
    var val_ptr = val.unsafe_ptr()
    var val_len = val.byte_length()
    var bm_view = bm.buffer.view_mut()

    # ⭐ THE HOIST ITSELF: both needle blocks, and the tail displacement, are
    # computed ONCE here. `tail` is 0 when `val_len == W`, in which case the
    # second block re-reads the first — correct, branchless, and an L1 hit.
    var tail = val_len - W
    var nv0 = val_ptr.load[width=W, alignment=1]()
    var nv1 = (val_ptr + tail).load[width=W, alignment=1]()

    var full_bytes = length >> 3
    for byte_idx in range(full_bytes):
        var base = byte_idx << 3
        var byte_val = UInt8(0)
        # `comptime for` so the bit index is a CONSTANT: `byte_val | 0x04`
        # instead of a `mov $0x1 / shl %cl` variable shift executed once per row.
        comptime for bit in range(8):
            var idx = base + bit
            var start = Int(offsets_view.get_typed[Scalar[OffsetType]](idx))
            var end = Int(offsets_view.get_typed[Scalar[OffsetType]](idx + 1))
            var hit = (end - start) == val_len
            if hit:
                var b0 = (data_ptr + start).load[width=W, alignment=1]()
                var b1 = (data_ptr + start + tail).load[width=W, alignment=1]()
                hit = not (any_true(b0.ne(nv0)) or any_true(b1.ne(nv1)))
            comptime if Negate:
                hit = not hit
            if hit:
                byte_val = byte_val | UInt8(1 << bit)
        bm_view.write_u8_at(byte_idx, byte_val)

    var remaining = length & 7
    if remaining > 0:
        var base = full_bytes << 3
        var byte_val = UInt8(0)
        for bit in range(remaining):
            var idx = base + bit
            var start = Int(offsets_view.get_typed[Scalar[OffsetType]](idx))
            var end = Int(offsets_view.get_typed[Scalar[OffsetType]](idx + 1))
            var hit = (end - start) == val_len
            if hit:
                var b0 = (data_ptr + start).load[width=W, alignment=1]()
                var b1 = (data_ptr + start + tail).load[width=W, alignment=1]()
                hit = not (any_true(b0.ne(nv0)) or any_true(b1.ne(nv1)))
            comptime if Negate:
                hit = not hit
            if hit:
                byte_val = byte_val | (UInt8(1) << UInt8(bit))
        bm_view.write_u8_at(full_bytes, byte_val)

    return BooleanArray.from_bitmap(bm^)


@always_inline
def _string_eqne_kernel_dispatch[
    OffsetType: DType,
    Negate: Bool,
    B_off: AlignedBufferTrait,
    B_data: AlignedBufferTrait,
](
    length: Int,
    offsets: B_off,
    data: B_data,
    val: String,
) -> BooleanArray:
    """THE ARM SELECTOR — picks the comptime block width ONCE, never per row.

    `Negate = False` is `==`, `True` is `!=`; both sides of the selector are
    ONE body because they differ only in that bit, and two hand-maintained
    copies of an arm list is exactly how end #4 of the invariant goes stale.

    ⭐ THE ARM LIST IS DERIVED FROM `_EQ_HOIST_MAX_BLOCK_LOG2`, NOT WRITTEN
    OUT. `comptime for` unrolls to an `if w == <literal>` ladder — one
    compare per arm, per KERNEL CALL, never
    per row — but a cap change grows the arms with it instead of silently
    dropping every needle at the new top rung onto the generic path.

    Falls back to the runtime-width ladder exactly for the needles
    `_eq_block_width` declines (0): empty, too long, or a `W` that failed its
    own post-condition. See the block comment above for the mechanism.
    """
    var w = _eq_block_width(val.byte_length())
    comptime for k in range(_EQ_HOIST_MAX_BLOCK_LOG2 + 1):
        comptime W = 1 << k
        if w == W:
            return _string_eqne_kernel_w[OffsetType, W, Negate](
                length, offsets, data, val
            )
    comptime if Negate:
        return _string_ne_kernel_generic[OffsetType](length, offsets, data, val)
    else:
        return _string_eq_kernel_generic[OffsetType](length, offsets, data, val)


@always_inline
def _string_eq_kernel[
    OffsetType: DType,
    B_off: AlignedBufferTrait,
    B_data: AlignedBufferTrait,
](
    length: Int,
    offsets: B_off,
    data: B_data,
    val: String,
) -> BooleanArray:
    """OffsetType-parametric column == scalar kernel."""
    return _string_eqne_kernel_dispatch[OffsetType, False](
        length, offsets, data, val
    )


@always_inline
def _string_ne_kernel[
    OffsetType: DType,
    B_off: AlignedBufferTrait,
    B_data: AlignedBufferTrait,
](
    length: Int,
    offsets: B_off,
    data: B_data,
    val: String,
) -> BooleanArray:
    """OffsetType-parametric column != scalar kernel."""
    return _string_eqne_kernel_dispatch[OffsetType, True](
        length, offsets, data, val
    )


@always_inline
def _string_eq_kernel_generic[
    OffsetType: DType,
    B_off: AlignedBufferTrait,
    B_data: AlignedBufferTrait,
](
    length: Int,
    offsets: B_off,
    data: B_data,
    val: String,
) -> BooleanArray:
    """RUNTIME-WIDTH column == scalar kernel — the generic fallback arm.

    OffsetType is DType.int32 for StringArray, DType.int64 for LargeStringArray.
    Identical algorithm; only the offset element width differs.

    ⚠ REACHED ONLY for a needle `_eq_block_width` declines (empty, or longer
    than `_EQ_HOIST_MAX_NEEDLE`); `_string_eq_kernel` routes every other width
    to the comptime-width arm. It is NOT dead code and must not be deleted —
    it is the correct answer for those needles, and a test asserts it is taken.
    """
    string_eq_ladder_counter_incr()
    var bm = Bitmap.create(length)
    var offsets_view = offsets.view_ro()
    # SAFETY: `data` is borrowed for this function body. `view_ro` ties the
    # ByteView's origin to the borrowed buffer's lifetime; `_unsafe_ptr`
    # returns `UnsafePointer[UInt8, view_origin]`. `.as_immutable()` preserves
    # the origin tag while flipping to ImmutOrigin (the shape that the
    # parametric `_string_bytes_equal` / `_string_bytes_cmp` callees expect).
    var data_view = data.view_ro()
    var data_ptr = data_view._unsafe_ptr().as_imm()
    var val_ptr = val.unsafe_ptr()
    var val_len = val.byte_length()
    var bm_view = bm.buffer.view_mut()

    var full_bytes = length >> 3
    for byte_idx in range(full_bytes):
        var base = byte_idx << 3
        var byte_val = UInt8(0)
        for bit in range(8):
            var idx = base + bit
            var start = Int(offsets_view.get_typed[Scalar[OffsetType]](idx))
            var end = Int(offsets_view.get_typed[Scalar[OffsetType]](idx + 1))
            var elem_len = end - start
            if _string_bytes_equal(data_ptr, start, elem_len, val_ptr, val_len):
                byte_val = byte_val | (UInt8(1) << UInt8(bit))
        bm_view.write_u8_at(byte_idx, byte_val)

    var remaining = length & 7
    if remaining > 0:
        var base = full_bytes << 3
        var byte_val = UInt8(0)
        for bit in range(remaining):
            var idx = base + bit
            var start = Int(offsets_view.get_typed[Scalar[OffsetType]](idx))
            var end = Int(offsets_view.get_typed[Scalar[OffsetType]](idx + 1))
            var elem_len = end - start
            if _string_bytes_equal(data_ptr, start, elem_len, val_ptr, val_len):
                byte_val = byte_val | (UInt8(1) << UInt8(bit))
        bm_view.write_u8_at(full_bytes, byte_val)

    return BooleanArray.from_bitmap(bm^)


@always_inline
def _string_ne_kernel_generic[
    OffsetType: DType,
    B_off: AlignedBufferTrait,
    B_data: AlignedBufferTrait,
](
    length: Int,
    offsets: B_off,
    data: B_data,
    val: String,
) -> BooleanArray:
    """RUNTIME-WIDTH column != scalar kernel. See `_string_eq_kernel_generic`
    for why this arm exists and when it is reached."""
    string_eq_ladder_counter_incr()
    var bm = Bitmap.create(length)
    var offsets_view = offsets.view_ro()
    var data_view = data.view_ro()
    var data_ptr = data_view._unsafe_ptr().as_imm()
    var val_ptr = val.unsafe_ptr()
    var val_len = val.byte_length()
    var bm_view = bm.buffer.view_mut()

    var full_bytes = length >> 3
    for byte_idx in range(full_bytes):
        var base = byte_idx << 3
        var byte_val = UInt8(0)
        for bit in range(8):
            var idx = base + bit
            var start = Int(offsets_view.get_typed[Scalar[OffsetType]](idx))
            var end = Int(offsets_view.get_typed[Scalar[OffsetType]](idx + 1))
            var elem_len = end - start
            if not _string_bytes_equal(data_ptr, start, elem_len, val_ptr, val_len):
                byte_val = byte_val | (UInt8(1) << UInt8(bit))
        bm_view.write_u8_at(byte_idx, byte_val)

    var remaining = length & 7
    if remaining > 0:
        var base = full_bytes << 3
        var byte_val = UInt8(0)
        for bit in range(remaining):
            var idx = base + bit
            var start = Int(offsets_view.get_typed[Scalar[OffsetType]](idx))
            var end = Int(offsets_view.get_typed[Scalar[OffsetType]](idx + 1))
            var elem_len = end - start
            if not _string_bytes_equal(data_ptr, start, elem_len, val_ptr, val_len):
                byte_val = byte_val | (UInt8(1) << UInt8(bit))
        bm_view.write_u8_at(full_bytes, byte_val)

    return BooleanArray.from_bitmap(bm^)


@always_inline
def _string_gt_kernel[
    OffsetType: DType,
    B_off: AlignedBufferTrait,
    B_data: AlignedBufferTrait,
](
    length: Int,
    offsets: B_off,
    data: B_data,
    val: String,
) -> BooleanArray:
    """OffsetType-parametric column > scalar kernel (lex)."""
    var bm = Bitmap.create(length)
    var offsets_view = offsets.view_ro()
    var data_view = data.view_ro()
    var data_ptr = data_view._unsafe_ptr().as_imm()
    var val_ptr = val.unsafe_ptr()
    var val_len = val.byte_length()
    var bm_view = bm.buffer.view_mut()

    var full_bytes = length >> 3
    for byte_idx in range(full_bytes):
        var base = byte_idx << 3
        var byte_val = UInt8(0)
        for bit in range(8):
            var idx = base + bit
            var start = Int(offsets_view.get_typed[Scalar[OffsetType]](idx))
            var end = Int(offsets_view.get_typed[Scalar[OffsetType]](idx + 1))
            var elem_len = end - start
            if _string_bytes_cmp(data_ptr, start, elem_len, val_ptr, val_len) > 0:
                byte_val = byte_val | (UInt8(1) << UInt8(bit))
        bm_view.write_u8_at(byte_idx, byte_val)

    var remaining = length & 7
    if remaining > 0:
        var base = full_bytes << 3
        var byte_val = UInt8(0)
        for bit in range(remaining):
            var idx = base + bit
            var start = Int(offsets_view.get_typed[Scalar[OffsetType]](idx))
            var end = Int(offsets_view.get_typed[Scalar[OffsetType]](idx + 1))
            var elem_len = end - start
            if _string_bytes_cmp(data_ptr, start, elem_len, val_ptr, val_len) > 0:
                byte_val = byte_val | (UInt8(1) << UInt8(bit))
        bm_view.write_u8_at(full_bytes, byte_val)

    return BooleanArray.from_bitmap(bm^)


@always_inline
def _string_lt_kernel[
    OffsetType: DType,
    B_off: AlignedBufferTrait,
    B_data: AlignedBufferTrait,
](
    length: Int,
    offsets: B_off,
    data: B_data,
    val: String,
) -> BooleanArray:
    """OffsetType-parametric column < scalar kernel (lex)."""
    var bm = Bitmap.create(length)
    var offsets_view = offsets.view_ro()
    var data_view = data.view_ro()
    var data_ptr = data_view._unsafe_ptr().as_imm()
    var val_ptr = val.unsafe_ptr()
    var val_len = val.byte_length()
    var bm_view = bm.buffer.view_mut()

    var full_bytes = length >> 3
    for byte_idx in range(full_bytes):
        var base = byte_idx << 3
        var byte_val = UInt8(0)
        for bit in range(8):
            var idx = base + bit
            var start = Int(offsets_view.get_typed[Scalar[OffsetType]](idx))
            var end = Int(offsets_view.get_typed[Scalar[OffsetType]](idx + 1))
            var elem_len = end - start
            if _string_bytes_cmp(data_ptr, start, elem_len, val_ptr, val_len) < 0:
                byte_val = byte_val | (UInt8(1) << UInt8(bit))
        bm_view.write_u8_at(byte_idx, byte_val)

    var remaining = length & 7
    if remaining > 0:
        var base = full_bytes << 3
        var byte_val = UInt8(0)
        for bit in range(remaining):
            var idx = base + bit
            var start = Int(offsets_view.get_typed[Scalar[OffsetType]](idx))
            var end = Int(offsets_view.get_typed[Scalar[OffsetType]](idx + 1))
            var elem_len = end - start
            if _string_bytes_cmp(data_ptr, start, elem_len, val_ptr, val_len) < 0:
                byte_val = byte_val | (UInt8(1) << UInt8(bit))
        bm_view.write_u8_at(full_bytes, byte_val)

    return BooleanArray.from_bitmap(bm^)


@always_inline
def _string_ge_kernel[
    OffsetType: DType,
    B_off: AlignedBufferTrait,
    B_data: AlignedBufferTrait,
](
    length: Int,
    offsets: B_off,
    data: B_data,
    val: String,
) -> BooleanArray:
    """OffsetType-parametric column >= scalar kernel (lex)."""
    var bm = Bitmap.create(length)
    var offsets_view = offsets.view_ro()
    var data_view = data.view_ro()
    var data_ptr = data_view._unsafe_ptr().as_imm()
    var val_ptr = val.unsafe_ptr()
    var val_len = val.byte_length()
    var bm_view = bm.buffer.view_mut()

    var full_bytes = length >> 3
    for byte_idx in range(full_bytes):
        var base = byte_idx << 3
        var byte_val = UInt8(0)
        for bit in range(8):
            var idx = base + bit
            var start = Int(offsets_view.get_typed[Scalar[OffsetType]](idx))
            var end = Int(offsets_view.get_typed[Scalar[OffsetType]](idx + 1))
            var elem_len = end - start
            if _string_bytes_cmp(data_ptr, start, elem_len, val_ptr, val_len) >= 0:
                byte_val = byte_val | (UInt8(1) << UInt8(bit))
        bm_view.write_u8_at(byte_idx, byte_val)

    var remaining = length & 7
    if remaining > 0:
        var base = full_bytes << 3
        var byte_val = UInt8(0)
        for bit in range(remaining):
            var idx = base + bit
            var start = Int(offsets_view.get_typed[Scalar[OffsetType]](idx))
            var end = Int(offsets_view.get_typed[Scalar[OffsetType]](idx + 1))
            var elem_len = end - start
            if _string_bytes_cmp(data_ptr, start, elem_len, val_ptr, val_len) >= 0:
                byte_val = byte_val | (UInt8(1) << UInt8(bit))
        bm_view.write_u8_at(full_bytes, byte_val)

    return BooleanArray.from_bitmap(bm^)


@always_inline
def _string_le_kernel[
    OffsetType: DType,
    B_off: AlignedBufferTrait,
    B_data: AlignedBufferTrait,
](
    length: Int,
    offsets: B_off,
    data: B_data,
    val: String,
) -> BooleanArray:
    """OffsetType-parametric column <= scalar kernel (lex)."""
    var bm = Bitmap.create(length)
    var offsets_view = offsets.view_ro()
    var data_view = data.view_ro()
    var data_ptr = data_view._unsafe_ptr().as_imm()
    var val_ptr = val.unsafe_ptr()
    var val_len = val.byte_length()
    var bm_view = bm.buffer.view_mut()

    var full_bytes = length >> 3
    for byte_idx in range(full_bytes):
        var base = byte_idx << 3
        var byte_val = UInt8(0)
        for bit in range(8):
            var idx = base + bit
            var start = Int(offsets_view.get_typed[Scalar[OffsetType]](idx))
            var end = Int(offsets_view.get_typed[Scalar[OffsetType]](idx + 1))
            var elem_len = end - start
            if _string_bytes_cmp(data_ptr, start, elem_len, val_ptr, val_len) <= 0:
                byte_val = byte_val | (UInt8(1) << UInt8(bit))
        bm_view.write_u8_at(byte_idx, byte_val)

    var remaining = length & 7
    if remaining > 0:
        var base = full_bytes << 3
        var byte_val = UInt8(0)
        for bit in range(remaining):
            var idx = base + bit
            var start = Int(offsets_view.get_typed[Scalar[OffsetType]](idx))
            var end = Int(offsets_view.get_typed[Scalar[OffsetType]](idx + 1))
            var elem_len = end - start
            if _string_bytes_cmp(data_ptr, start, elem_len, val_ptr, val_len) <= 0:
                byte_val = byte_val | (UInt8(1) << UInt8(bit))
        bm_view.write_u8_at(full_bytes, byte_val)

    return BooleanArray.from_bitmap(bm^)


# =============================================================================
# THREE-VALUED LOGIC — a NULL input row satisfies NO comparison
# =============================================================================
#
# ⚠ THE KERNELS ABOVE CANNOT DO THIS AND MUST NOT BE ASKED TO. Every
# `_string_*_kernel` takes `(length, offsets, data, val)` — the validity
# bitmap is deliberately NOT in the signature, because the kernels are the
# hot per-row loops and a per-row validity branch inside them costs the
# length-short-circuit its value. Validity is applied ONCE, bytewise and
# SIMD-wide, on the finished mask.
#
# WHY IT IS NEEDED. Arrow stores a NULL string as an `(offset, length=0)`
# slot, so a NULL row is BYTE-IDENTICAL to a genuine empty string in the
# offsets+data buffers the kernels see. Without validity, `NULL = ''`
# evaluates TRUE, and `WHERE name = ''` over a column holding N NULL and N
# empty values returns 2N rows instead of N.
#
# ⚠ IT IS NOT ONLY `= ''`. `ne/gt/lt/ge/le` read the same zero-length slot, so
# `NULL != 'bob'` would evaluate TRUE as well. The `= ''` case is merely the
# easiest to notice, because the wrong answer is a wrong ROW COUNT rather
# than a wrong row.
#
# ⚠ WHY THE MASK'S OWN VALIDITY IS NOT SET INSTEAD. The obvious Arrow-shaped
# fix is to return a NULLABLE BooleanArray carrying the input's validity and
# let the consumer decide. That alone fixes nothing: the consumer is
# `filter_to_indices` (`komira_column_kernels/comparison.mojo`), whose
# SIMD block-walk reads the DATA bitmap only and never looks at mask validity.
# A nullable mask would be silently ignored. So the null rows must be
# cleared in `data`, which is also exactly what a FILTER wants: a row whose
# predicate is UNKNOWN is not selected.
#
# ⚠ AND THE NEGATION. `NOT (x = 'bob')` lowers to `eval_not(child_mask)`.
# `_apply_validity` attaches the validity bitmap as well, and `eval_not` is
# Kleene-correct — it copies the validity AND re-clears the data bit `~v` has
# just set, which is what makes UNKNOWN survive a negation for
# `filter_to_indices`, a data-only consumer.
# =============================================================================


@always_inline
def _apply_validity[
    K: MemoryRegion, //,
](var mask: BooleanArray, validity: Optional[Bitmap[K]]) -> BooleanArray:
    """Encode a NULL input row as UNKNOWN: data bit 0, validity bit 0.

    The all-valid fast path (`validity is None`) returns the kernel's mask
    untouched and byte-identical, so a column with no nulls pays nothing.

    ⚠ BOTH BITMAPS, AND NEITHER ONE ALONE. The DATA clear is what
    `filter_to_indices` obeys — it reads data only, so without it a NULL row is
    SELECTED. The VALIDITY copy is what `eval_not` / `eval_and` / `eval_or`
    obey — without it UNKNOWN is indistinguishable from FALSE, and `eval_not`
    turns the cleared bit straight back into a selected row: with the data
    clear alone, `NOT (x = '')` over a NULL row goes False -> True.

    Cost: on a column with no nulls this function takes the early return
    below. On a nullable column the cost is one byte-loop over the mask.

    Args:
        mask: The finished comparison mask. Consumed.
        validity: The input column's validity bitmap (1 = valid, 0 = NULL).

    Returns:
        `mask` with data ANDed by `validity` and `validity` attached, or
        `mask` unchanged when there is no bitmap.
    """
    if not validity:
        return mask^
    ref v = validity.value()
    # ⚠ NOT `Bitmap.and_`, and the reason is the calling convention, not taste.
    # `and_` RAISES (on a length mismatch), and on the pinned Mojo 1.0.0b2 a
    # `def` is NOT implicitly `raises` — so calling it here would force
    # `raises` onto all twelve `eval_string_*` entry points and from there onto
    # every caller in the engine (`cannot call function that may raise in a
    # context that cannot raise`). This loop is the same bytewise AND
    # with no raise, over `read_u8_at`/`write_u8_at` — the same primitives
    # `Bitmap.set`/`clear`/`test` use.
    #
    # The byte count is the MINIMUM of the two, so a malformed column can never
    # read past either buffer. For a well-formed column the two are equal by
    # construction (`validity.length == column length == mask.length`).
    var mask_bytes = bytes_for_bits(mask.length)
    var n_bytes = bytes_for_bits(min(mask.length, v.length))

    var out_v = Bitmap.create(mask.length)
    for b in range(n_bytes):
        var vb = v.buffer.read_u8_at(b)
        var cur = mask.data.buffer.read_u8_at(b)
        mask.data.buffer.write_u8_at(b, cur & vb)
        out_v.buffer.write_u8_at(b, vb)

    # A validity bitmap SHORTER than the mask (malformed column) leaves a tail
    # this cannot speak for. Call that tail VALID — data untouched and no
    # validity — so a malformed column is not silently nulled out.
    # `n_bytes == mask_bytes` for every well-formed column, so this
    # loop does not execute on any real input.
    for b in range(n_bytes, mask_bytes):
        out_v.buffer.write_u8_at(b, UInt8(0xFF))

    # Canonical zeros past `length` on BOTH bitmaps. `Bitmap.null_count()` is
    # `length - popcount(whole bytes)`, so a stray 1 in the pad bits of the
    # last byte would under-count the nulls.
    var trailing = mask.length & 7
    if trailing > 0 and mask_bytes > 0:
        var tmask = UInt8((1 << trailing) - 1)
        var last_v = out_v.buffer.read_u8_at(mask_bytes - 1)
        out_v.buffer.write_u8_at(mask_bytes - 1, last_v & tmask)
        var last_d = mask.data.buffer.read_u8_at(mask_bytes - 1)
        mask.data.buffer.write_u8_at(mask_bytes - 1, last_d & tmask)

    var nc = out_v.null_count()
    mask.validity = out_v^
    mask.null_count = nc
    return mask^


# =============================================================================
# Public API: StringArray (Int32 offsets)
# =============================================================================
#
# Each entry function takes `value: String` by read (borrow) and forwards to
# the OffsetType-parametric kernel instantiated at DType.int32, then applies
# the input's validity via `_apply_validity` (see the block above).
# Borrow tracker handles lifetime; no OwnedPointer / wildcard-origin tricks.
# =============================================================================


@always_inline
def eval_string_eq(col: StringArray[HeapRegion], value: String) -> BooleanArray:
    """Evaluate column == scalar string. Returns BooleanArray (bit-packed).

    Short-circuits on length mismatch -- O(1) rejection when lengths differ.
    Byte comparison is inline (see `_bytes_eq`), with the needle width hoisted
    out of the loop. Forwards to the OffsetType=DType.int32
    instantiation of `_string_eq_kernel`. The LargeStringArray sibling
    (`eval_large_string_eq`) shares the same kernel at DType.int64.
    """
    return _apply_validity(_string_eq_kernel[DType.int32](col.length, col.offsets, col.data, value), col.validity)


@always_inline
def eval_string_ne(col: StringArray[HeapRegion], value: String) -> BooleanArray:
    """Evaluate column != scalar string. Returns BooleanArray (bit-packed)."""
    return _apply_validity(_string_ne_kernel[DType.int32](col.length, col.offsets, col.data, value), col.validity)


@always_inline
def eval_string_gt(col: StringArray[HeapRegion], value: String) -> BooleanArray:
    """Evaluate column > scalar string (lexicographic). Returns BooleanArray.

    Lexicographic comparison: compare common prefix byte-by-byte, then
    shorter string is "less than" if prefix matches.
    """
    return _apply_validity(_string_gt_kernel[DType.int32](col.length, col.offsets, col.data, value), col.validity)


@always_inline
def eval_string_lt(col: StringArray[HeapRegion], value: String) -> BooleanArray:
    """Evaluate column < scalar string (lexicographic). Returns BooleanArray."""
    return _apply_validity(_string_lt_kernel[DType.int32](col.length, col.offsets, col.data, value), col.validity)


@always_inline
def eval_string_ge(col: StringArray[HeapRegion], value: String) -> BooleanArray:
    """Evaluate column >= scalar string (lexicographic). Returns BooleanArray."""
    return _apply_validity(_string_ge_kernel[DType.int32](col.length, col.offsets, col.data, value), col.validity)


@always_inline
def eval_string_le(col: StringArray[HeapRegion], value: String) -> BooleanArray:
    """Evaluate column <= scalar string (lexicographic). Returns BooleanArray."""
    return _apply_validity(_string_le_kernel[DType.int32](col.length, col.offsets, col.data, value), col.validity)


# =============================================================================
# Public API: LargeStringArray (Int64 offsets)
# =============================================================================
#
# Same kernels at OffsetType=DType.int64. Byte-identical semantics; only the
# offset element width differs. The semantic contract is pinned by
# test_d_string_and_large_string_byte_equivalence.
# =============================================================================


@always_inline
def eval_large_string_eq(col: LargeStringArray[HeapRegion], value: String) -> BooleanArray:
    """Evaluate large-string column == scalar string. Int64-offset variant."""
    return _apply_validity(_string_eq_kernel[DType.int64](col.length, col.offsets, col.data, value), col.validity)


@always_inline
def eval_large_string_ne(col: LargeStringArray[HeapRegion], value: String) -> BooleanArray:
    """Evaluate large-string column != scalar string. Int64-offset variant."""
    return _apply_validity(_string_ne_kernel[DType.int64](col.length, col.offsets, col.data, value), col.validity)


@always_inline
def eval_large_string_gt(col: LargeStringArray[HeapRegion], value: String) -> BooleanArray:
    """Evaluate large-string column > scalar string. Int64-offset variant."""
    return _apply_validity(_string_gt_kernel[DType.int64](col.length, col.offsets, col.data, value), col.validity)


@always_inline
def eval_large_string_lt(col: LargeStringArray[HeapRegion], value: String) -> BooleanArray:
    """Evaluate large-string column < scalar string. Int64-offset variant."""
    return _apply_validity(_string_lt_kernel[DType.int64](col.length, col.offsets, col.data, value), col.validity)


@always_inline
def eval_large_string_ge(col: LargeStringArray[HeapRegion], value: String) -> BooleanArray:
    """Evaluate large-string column >= scalar string. Int64-offset variant."""
    return _apply_validity(_string_ge_kernel[DType.int64](col.length, col.offsets, col.data, value), col.validity)


@always_inline
def eval_large_string_le(col: LargeStringArray[HeapRegion], value: String) -> BooleanArray:
    """Evaluate large-string column <= scalar string. Int64-offset variant."""
    return _apply_validity(_string_le_kernel[DType.int64](col.length, col.offsets, col.data, value), col.validity)


# =============================================================================
# String pattern matching operations: CONTAINS, STARTS_WITH, ENDS_WITH, LIKE
# =============================================================================
#
# Same `@parameter fn _*_kernel[OffsetType]` generalization as the
# comparison kernels above. Both StringArray (Int32
# offsets) and LargeStringArray (Int64 offsets) share the same body.
# =============================================================================


@always_inline
def _string_contains_kernel[
    OffsetType: DType,
    B_off: AlignedBufferTrait,
    B_data: AlignedBufferTrait,
](
    length: Int,
    offsets: B_off,
    data: B_data,
    pattern: String,
) -> BooleanArray:
    """OffsetType-parametric substring CONTAINS kernel."""
    # ★ The same whole-buffer scan the `%lit%` LIKE takes (see
    # `string_contains_scan.mojo`); it replaces the brute-force per-row
    # `_bytes_contains` below for every needle it accepts. It declines an
    # empty or 1-byte needle, so the empty-pattern branch below is untouched.
    var scanned = string_contains_scan_kernel[OffsetType](
        length, offsets, data, pattern.as_bytes()
    )
    if scanned:
        return scanned.take()

    var bm = Bitmap.create(length)
    var offsets_view = offsets.view_ro()
    var data_view = data.view_ro()
    var data_ptr = data_view._unsafe_ptr().as_imm()
    var bm_view = bm.buffer.view_mut()

    var pat_ptr = pattern.unsafe_ptr()
    var pat_len = pattern.byte_length()

    # Empty pattern matches everything
    if pat_len == 0:
        for byte_idx in range((length + 7) >> 3):
            bm_view.write_u8_at(byte_idx, UInt8(0xFF))
        # Clear unused trailing bits
        var rem = length & 7
        if rem > 0:
            var last_byte_idx = length >> 3
            bm_view.write_u8_at(last_byte_idx, UInt8((1 << rem) - 1))
        return BooleanArray.from_bitmap(bm^)

    var full_bytes = length >> 3
    for byte_idx in range(full_bytes):
        var base = byte_idx << 3
        var byte_val = UInt8(0)
        for bit in range(8):
            var idx = base + bit
            var start = Int(offsets_view.get_typed[Scalar[OffsetType]](idx))
            var end = Int(offsets_view.get_typed[Scalar[OffsetType]](idx + 1))
            var elem_len = end - start
            if _bytes_contains(data_ptr, start, elem_len, pat_ptr, pat_len):
                byte_val = byte_val | (UInt8(1) << UInt8(bit))
        bm_view.write_u8_at(byte_idx, byte_val)

    var remaining = length & 7
    if remaining > 0:
        var base = full_bytes << 3
        var byte_val = UInt8(0)
        for bit in range(remaining):
            var idx = base + bit
            var start = Int(offsets_view.get_typed[Scalar[OffsetType]](idx))
            var end = Int(offsets_view.get_typed[Scalar[OffsetType]](idx + 1))
            var elem_len = end - start
            if _bytes_contains(data_ptr, start, elem_len, pat_ptr, pat_len):
                byte_val = byte_val | (UInt8(1) << UInt8(bit))
        bm_view.write_u8_at(full_bytes, byte_val)

    return BooleanArray.from_bitmap(bm^)


@always_inline
def _string_starts_with_kernel[
    OffsetType: DType,
    B_off: AlignedBufferTrait,
    B_data: AlignedBufferTrait,
](
    length: Int,
    offsets: B_off,
    data: B_data,
    prefix: String,
) -> BooleanArray:
    """OffsetType-parametric STARTS_WITH kernel."""
    var bm = Bitmap.create(length)
    var offsets_view = offsets.view_ro()
    var data_view = data.view_ro()
    var data_ptr = data_view._unsafe_ptr().as_imm()
    var bm_view = bm.buffer.view_mut()

    var pre_ptr = prefix.unsafe_ptr()
    var pre_len = prefix.byte_length()

    var full_bytes = length >> 3
    for byte_idx in range(full_bytes):
        var base = byte_idx << 3
        var byte_val = UInt8(0)
        for bit in range(8):
            var idx = base + bit
            var start = Int(offsets_view.get_typed[Scalar[OffsetType]](idx))
            var end = Int(offsets_view.get_typed[Scalar[OffsetType]](idx + 1))
            var elem_len = end - start
            if elem_len >= pre_len and (pre_len == 0 or _bytes_eq(data_ptr + start, pre_ptr, pre_len)):
                byte_val = byte_val | (UInt8(1) << UInt8(bit))
        bm_view.write_u8_at(byte_idx, byte_val)

    var remaining = length & 7
    if remaining > 0:
        var base = full_bytes << 3
        var byte_val = UInt8(0)
        for bit in range(remaining):
            var idx = base + bit
            var start = Int(offsets_view.get_typed[Scalar[OffsetType]](idx))
            var end = Int(offsets_view.get_typed[Scalar[OffsetType]](idx + 1))
            var elem_len = end - start
            if elem_len >= pre_len and (pre_len == 0 or _bytes_eq(data_ptr + start, pre_ptr, pre_len)):
                byte_val = byte_val | (UInt8(1) << UInt8(bit))
        bm_view.write_u8_at(full_bytes, byte_val)

    return BooleanArray.from_bitmap(bm^)


@always_inline
def _string_ends_with_kernel[
    OffsetType: DType,
    B_off: AlignedBufferTrait,
    B_data: AlignedBufferTrait,
](
    length: Int,
    offsets: B_off,
    data: B_data,
    suffix: String,
) -> BooleanArray:
    """OffsetType-parametric ENDS_WITH kernel."""
    var bm = Bitmap.create(length)
    var offsets_view = offsets.view_ro()
    var data_view = data.view_ro()
    var data_ptr = data_view._unsafe_ptr().as_imm()
    var bm_view = bm.buffer.view_mut()

    var suf_ptr = suffix.unsafe_ptr()
    var suf_len = suffix.byte_length()

    var full_bytes = length >> 3
    for byte_idx in range(full_bytes):
        var base = byte_idx << 3
        var byte_val = UInt8(0)
        for bit in range(8):
            var idx = base + bit
            var start = Int(offsets_view.get_typed[Scalar[OffsetType]](idx))
            var end = Int(offsets_view.get_typed[Scalar[OffsetType]](idx + 1))
            var elem_len = end - start
            if elem_len >= suf_len and (suf_len == 0 or _bytes_eq(data_ptr + end - suf_len, suf_ptr, suf_len)):
                byte_val = byte_val | (UInt8(1) << UInt8(bit))
        bm_view.write_u8_at(byte_idx, byte_val)

    var remaining = length & 7
    if remaining > 0:
        var base = full_bytes << 3
        var byte_val = UInt8(0)
        for bit in range(remaining):
            var idx = base + bit
            var start = Int(offsets_view.get_typed[Scalar[OffsetType]](idx))
            var end = Int(offsets_view.get_typed[Scalar[OffsetType]](idx + 1))
            var elem_len = end - start
            if elem_len >= suf_len and (suf_len == 0 or _bytes_eq(data_ptr + end - suf_len, suf_ptr, suf_len)):
                byte_val = byte_val | (UInt8(1) << UInt8(bit))
        bm_view.write_u8_at(full_bytes, byte_val)

    return BooleanArray.from_bitmap(bm^)


# =============================================================================
# LIKE fast path — `%lit%lit%` decomposition into sequential substring search
# =============================================================================
#
# The generic `_like_match` (below) is a per-character backtracking matcher run
# once per row. For a pattern like `%special%requests%` over ~1.5M rows (TPC-H
# q13's `o_comment NOT LIKE '%special%requests%'`) that is O(s_len * backtrack)
# per row — a significant share of that query's CPU time.
#
# DuckDB avoids this: its LikeMatcher decomposes a `%`-delimited pattern (no `_`
# wildcards) into an ordered list of literal segments, each matched with a fast
# `Contains` (substring search). We mirror that structure here. For any pattern
# WITHOUT a `_` wildcard we precompute a `_LikePlan` ONCE per column, then per
# row do: optional prefix-anchor memcmp, optional suffix-anchor memcmp, and an
# in-order `memmem` substring search for each interior segment. This is
# byte-for-byte equivalent to `_like_match` on `_`-free patterns (SQL LIKE is a
# boolean existence test and `%`-only globs admit a greedy leftmost match with
# no length coupling between segments, so leftmost-first search never yields a
# false negative). Patterns containing `_` fall back to `_like_match`.
#
# ALWAYS ON in production (about a quarter off q13, neutral elsewhere).
# Correctness is guarded by a byte-oracle test that diffs the fast path
# against `_like_match` across a pattern/string corpus.
#
# The generic `_like_match` arm is the byte oracle, AND it is the live
# production path for every pattern containing `_`. Tests reach it for every
# pattern through the defaulted parameter
# `eval_string_like(col, pattern, use_fastpath=False)`; production never
# passes the argument.
# =============================================================================


struct _LikePlan(Copyable, Movable):
    """Precomputed decomposition of a `_`-free SQL LIKE pattern into literal
    segments (offsets into the pattern buffer) plus start/end anchoring."""

    var applicable: Bool
    """False if the pattern contains `_` (fall back to `_like_match`)."""
    var exact: Bool
    """True if the pattern has no `%` at all (pure equality to seg 0)."""
    var anchored_start: Bool
    """First literal segment is anchored to the string start (no leading `%`)."""
    var anchored_end: Bool
    """Last literal segment is anchored to the string end (no trailing `%`)."""
    var seg_off: List[Int]
    """Byte offset of each NON-EMPTY literal segment within the pattern."""
    var seg_len: List[Int]
    """Byte length of each NON-EMPTY literal segment (parallel to seg_off)."""

    def __init__(out self):
        self.applicable = True
        self.exact = False
        self.anchored_start = False
        self.anchored_end = False
        self.seg_off = List[Int]()
        self.seg_len = List[Int]()


@always_inline
def _plan_is_bare_contains(plan: _LikePlan) -> Bool:
    """True iff the plan is exactly `%lit%` (after `%%` collapse): one
    non-empty literal segment, anchored at neither end. That is "the string
    contains `lit`", which `string_contains_scan_kernel` answers."""
    return (
        not plan.exact
        and len(plan.seg_off) == 1
        and not plan.anchored_start
        and not plan.anchored_end
    )


def _analyze_like_pattern(pattern: String) -> _LikePlan:
    """Parse `pattern` into a `_LikePlan`. Only `%` and `_` are LIKE
    metacharacters (mirrors `_like_match` — everything else, including `\\`, is
    a literal). Any `_` makes the plan inapplicable (caller falls back)."""
    var plan = _LikePlan()
    var p = pattern.unsafe_ptr()
    var plen = pattern.byte_length()

    var has_pct = False
    for i in range(plen):
        var c = p[i]
        if c == UInt8(ord("_")):
            plan.applicable = False
            return plan^
        if c == UInt8(ord("%")):
            has_pct = True

    if not has_pct:
        # No wildcards at all — exact byte equality to the whole pattern.
        plan.exact = True
        plan.seg_off.append(0)
        plan.seg_len.append(plen)
        return plan^

    plan.anchored_start = plen > 0 and p[0] != UInt8(ord("%"))
    plan.anchored_end = plen > 0 and p[plen - 1] != UInt8(ord("%"))

    # Split on `%`, keeping only non-empty literal segments (consecutive `%%`
    # collapse — an empty segment matches trivially).
    var seg_start = 0
    var i = 0
    while i <= plen:
        if i == plen or p[i] == UInt8(ord("%")):
            var slen = i - seg_start
            if slen > 0:
                plan.seg_off.append(seg_start)
                plan.seg_len.append(slen)
            seg_start = i + 1
        i += 1
    return plan^


@always_inline
def _like_plan_match[
    s_origin: ImmOrigin,
    p_origin: ImmOrigin,
](
    s_ptr: UnsafePointer[UInt8, s_origin],
    s_len: Int,
    p_ptr: UnsafePointer[UInt8, p_origin],
    plan: _LikePlan,
) -> Bool:
    """Match one string against a precomputed `_LikePlan` (segments point into
    the pattern buffer `p_ptr`). Byte-equivalent to `_like_match` for `_`-free
    patterns."""
    var nseg = len(plan.seg_off)

    if plan.exact:
        if s_len != plan.seg_len[0]:
            return False
        return _bytes_eq(s_ptr, p_ptr + plan.seg_off[0], s_len)

    if nseg == 0:
        # Pattern was all `%` (e.g. "%", "%%") — matches everything.
        return True

    var cursor = 0
    var end_limit = s_len
    var i0 = 0
    var iN = nseg

    if plan.anchored_start:
        var l0 = plan.seg_len[0]
        if s_len < l0:
            return False
        if not _bytes_eq(s_ptr, p_ptr + plan.seg_off[0], l0):
            return False
        cursor = l0
        i0 = 1

    if plan.anchored_end:
        var last = nseg - 1
        var ll = plan.seg_len[last]
        if s_len - cursor < ll:
            return False
        if not _bytes_eq(s_ptr + (s_len - ll), p_ptr + plan.seg_off[last], ll):
            return False
        end_limit = s_len - ll
        iN = nseg - 1

    # Interior segments must appear in order within [cursor, end_limit).
    var i = i0
    while i < iN:
        var sl = plan.seg_len[i]
        var avail = end_limit - cursor
        if avail < sl:
            return False
        var idx = _memmem(s_ptr + cursor, avail, p_ptr + plan.seg_off[i], sl)
        if idx < 0:
            return False
        cursor = cursor + idx + sl
        i += 1

    return cursor <= end_limit


@always_inline
def _like_row_dispatch[
    s_origin: ImmOrigin,
    p_origin: ImmOrigin,
](
    s_ptr: UnsafePointer[UInt8, s_origin],
    s_len: Int,
    p_ptr: UnsafePointer[UInt8, p_origin],
    p_len: Int,
    plan: _LikePlan,
    use_fast: Bool,
) -> Bool:
    """Per-row LIKE dispatch: `_like_plan_match` when the `%lit%lit%` fast path
    applies + is enabled, else the generic backtracking `_like_match`. The
    `use_fast` branch is loop-invariant (hoisted by the caller)."""
    if use_fast:
        return _like_plan_match(s_ptr, s_len, p_ptr, plan)
    return _like_match(s_ptr, s_len, p_ptr, p_len)


@always_inline
def _string_like_kernel[
    OffsetType: DType,
    B_off: AlignedBufferTrait,
    B_data: AlignedBufferTrait,
](
    length: Int,
    offsets: B_off,
    data: B_data,
    pattern: String,
    use_fastpath: Bool = True,
) -> BooleanArray:
    """OffsetType-parametric SQL LIKE kernel.

    `use_fastpath` is the TEST-ONLY differential knob (default True = production):
    False forces every row through the generic backtracking `_like_match`, which
    is the byte oracle the `%lit%lit%` decomposition is diffed against."""
    # Precompute the `%lit%lit%` decomposition once per column; pattern
    # applicability (and the test-only `use_fastpath` knob) are loop-invariant.
    var plan = _analyze_like_pattern(pattern)
    var use_fast = plan.applicable and use_fastpath

    # ★ A bare `%lit%` is ONE substring scan over the whole data buffer, not a
    # libc `memmem` per row — `string_contains_scan.mojo` has the mechanism
    # (per-row `memmem` dominates a `%lit%` filter over a large column). A decline
    # (1-byte needle, unprovable buffer bounds) falls through to the per-row
    # loop below, unchanged.
    if use_fast and _plan_is_bare_contains(plan):
        var s0 = plan.seg_off[0]
        var scanned = string_contains_scan_kernel[OffsetType](
            length, offsets, data, pattern.as_bytes()[s0 : s0 + plan.seg_len[0]]
        )
        if scanned:
            return scanned.take()

    var bm = Bitmap.create(length)
    var offsets_view = offsets.view_ro()
    var data_view = data.view_ro()
    var data_ptr = data_view._unsafe_ptr().as_imm()
    var bm_view = bm.buffer.view_mut()

    var pat_ptr = pattern.unsafe_ptr()
    var pat_len = pattern.byte_length()

    var full_bytes = length >> 3
    for byte_idx in range(full_bytes):
        var base = byte_idx << 3
        var byte_val = UInt8(0)
        for bit in range(8):
            var idx = base + bit
            var start = Int(offsets_view.get_typed[Scalar[OffsetType]](idx))
            var end = Int(offsets_view.get_typed[Scalar[OffsetType]](idx + 1))
            var elem_len = end - start
            if _like_row_dispatch(
                data_ptr + start, elem_len, pat_ptr, pat_len, plan, use_fast
            ):
                byte_val = byte_val | (UInt8(1) << UInt8(bit))
        bm_view.write_u8_at(byte_idx, byte_val)

    var remaining = length & 7
    if remaining > 0:
        var base = full_bytes << 3
        var byte_val = UInt8(0)
        for bit in range(remaining):
            var idx = base + bit
            var start = Int(offsets_view.get_typed[Scalar[OffsetType]](idx))
            var end = Int(offsets_view.get_typed[Scalar[OffsetType]](idx + 1))
            var elem_len = end - start
            if _like_row_dispatch(
                data_ptr + start, elem_len, pat_ptr, pat_len, plan, use_fast
            ):
                byte_val = byte_val | (UInt8(1) << UInt8(bit))
        bm_view.write_u8_at(full_bytes, byte_val)

    return BooleanArray.from_bitmap(bm^)


# =============================================================================
# ★ THE EIGHT PATTERN ENTRY POINTS APPLY VALIDITY TOO.
# =============================================================================
#
# It is tempting to argue that a pattern cannot match the zero-length slot
# Arrow stores under a NULL. Two of them can —
#
#     WHERE note LIKE ''      would select EXACTLY the NULL rows
#     WHERE note LIKE '%'     would select EVERY row, NULLs included
#
# — because `_like_match` with an empty (or all-`%`) pattern returns True on a
# zero-length string, and `_bytes_contains` returns True for `pat_len == 0`.
#
# ⛔ AND THE DANGEROUS HALF IS THE ONE NO PATTERN NEEDS TO MATCH. A NULL row
# comes back FALSE from every OTHER pattern, which is the right ROW SET at a
# bare filter and the WRONG VALUE under a negation: `NOT (note LIKE 'z%')`
# would turn each of those FALSEs into a selected row, where SQL says
# `NOT UNKNOWN` is UNKNOWN and a WHERE over UNKNOWN selects nothing (DuckDB
# 1.5.3 agrees). A wrong answer that looks like a bigger correct one.
#
# ⚠ SO THE RULE IS **NOT** "make the kernels skip NULL rows". Clearing the
# data bit alone is still wrong under a NOT; `_apply_validity` sets BOTH
# bitmaps, and the
# validity half is what `eval_not` / `eval_and` / `eval_or` read. See the
# block above `_apply_validity` for why neither one alone is sufficient.
#
# ⚠ THE KERNELS THEMSELVES STILL TAKE `(length, offsets, data, val)` AND MUST.
# Validity is applied ONCE on the finished mask, bytewise, for exactly the
# reason stated above: a per-row validity branch inside these loops costs the
# `%lit%lit%` decomposition and the length short-circuit their value.
#
# ⭐ WHY AT THE KERNEL RATHER THAN AT THE FILTER FUNNEL. `_eval_predicate`
# builds a row-selecting mask at more than twenty sites across ten files, and
# only the ones that go through `conjunction._collapse_nulls_to_false` had a
# compensating collapse — a parquet decode-filter pushdown loop is one that
# does not. A NULL contract that every caller has to remember is one that
# some caller will not.
# =============================================================================


def eval_string_contains(col: StringArray[HeapRegion], pattern: String) -> BooleanArray:
    """Check if each string contains the pattern substring (Int32 offsets)."""
    return _apply_validity(
        _string_contains_kernel[DType.int32](col.length, col.offsets, col.data, pattern),
        col.validity,
    )


def eval_string_starts_with(col: StringArray[HeapRegion], prefix: String) -> BooleanArray:
    """Check if each string starts with the given prefix (Int32 offsets)."""
    return _apply_validity(
        _string_starts_with_kernel[DType.int32](col.length, col.offsets, col.data, prefix),
        col.validity,
    )


def eval_string_ends_with(col: StringArray[HeapRegion], suffix: String) -> BooleanArray:
    """Check if each string ends with the given suffix (Int32 offsets)."""
    return _apply_validity(
        _string_ends_with_kernel[DType.int32](col.length, col.offsets, col.data, suffix),
        col.validity,
    )


def eval_string_like(
    col: StringArray[HeapRegion], pattern: String, use_fastpath: Bool = True
) -> BooleanArray:
    """SQL LIKE pattern matching. % = any chars, _ = one char (Int32 offsets).

    `use_fastpath` is TEST-ONLY (default True = the production `%lit%lit%` memmem
    decomposition). Passing False forces the generic backtracking `_like_match`
    reference kernel — the byte oracle."""
    return _apply_validity(
        _string_like_kernel[DType.int32](
            col.length, col.offsets, col.data, pattern, use_fastpath
        ),
        col.validity,
    )


def eval_large_string_contains(col: LargeStringArray[HeapRegion], pattern: String) -> BooleanArray:
    """Check if each string contains the pattern substring (Int64 offsets)."""
    return _apply_validity(
        _string_contains_kernel[DType.int64](col.length, col.offsets, col.data, pattern),
        col.validity,
    )


def eval_large_string_starts_with(col: LargeStringArray[HeapRegion], prefix: String) -> BooleanArray:
    """Check if each string starts with the given prefix (Int64 offsets)."""
    return _apply_validity(
        _string_starts_with_kernel[DType.int64](col.length, col.offsets, col.data, prefix),
        col.validity,
    )


def eval_large_string_ends_with(col: LargeStringArray[HeapRegion], suffix: String) -> BooleanArray:
    """Check if each string ends with the given suffix (Int64 offsets)."""
    return _apply_validity(
        _string_ends_with_kernel[DType.int64](col.length, col.offsets, col.data, suffix),
        col.validity,
    )


def eval_large_string_like(
    col: LargeStringArray[HeapRegion], pattern: String, use_fastpath: Bool = True
) -> BooleanArray:
    """SQL LIKE pattern matching. % = any chars, _ = one char (Int64 offsets).

    `use_fastpath`: see `eval_string_like` (TEST-ONLY, default True)."""
    return _apply_validity(
        _string_like_kernel[DType.int64](
            col.length, col.offsets, col.data, pattern, use_fastpath
        ),
        col.validity,
    )


# =============================================================================
# Internal: substring search (brute-force for now)
# =============================================================================


@always_inline
def _bytes_contains[
    data_origin: ImmOrigin,
    pat_origin: ImmOrigin,
](
    data_ptr: UnsafePointer[UInt8, data_origin],
    start: Int,
    elem_len: Int,
    pat_ptr: UnsafePointer[UInt8, pat_origin],
    pat_len: Int,
) -> Bool:
    """Check if data[start..start+elem_len] contains pat[0..pat_len].

    Simple O(n*m) brute-force search. Candidates for replacement are
    Boyer-Moore or SIMD.

    Parametric on both origins (see _memcmp).
    """
    if pat_len == 0:
        return True
    if elem_len < pat_len:
        return False
    var limit = elem_len - pat_len
    for i in range(limit + 1):
        if _bytes_eq(data_ptr + start + i, pat_ptr, pat_len):
            return True
    return False


# =============================================================================
# Internal: SQL LIKE pattern matching
# =============================================================================
#
# ★ `_` IS ONE **CHARACTER**, NOT ONE BYTE. A character is one UTF-8 code
# point, whose byte length its LEAD byte states. A `_` that advanced ONE byte
# would match a fragment of a character over multi-byte UTF-8 — against
# DuckDB 1.5.3: `'é' LIKE '_'` is true, `'é' LIKE '__'` is false, and
# `'naïve' LIKE 'na_ve'` is true; a byte-wise `_` gets all three wrong. `%`'s
# backtrack widens by one CHARACTER for the same reason, so a `_` never starts
# on a continuation byte.
#
# ⚠ WHY LITERAL BYTES STAY BYTES. A pattern character is a complete UTF-8
# sequence and so is every string character, and UTF-8 is self-synchronising: a
# pattern lead byte can only equal a string LEAD byte, and then the two
# sequences have the same length. So a byte-at-a-time literal compare lands on
# the same character boundary a code-point compare would, and the `%lit%lit%`
# fast path above (`_`-free, memmem per segment) stays exactly equivalent.
#
# ⚠ INVALID UTF-8 still makes PROGRESS: a stray continuation byte counts as a
# one-byte character and a truncated sequence is clipped to the string's end,
# so neither loop can overrun or stall.
#
# ⭐ ONE MATCHER. `like_match_string` below is the String-level entry that
# row-at-a-time expression evaluators delegate to, so no caller carries its
# own byte-at-a-time copy of this loop.
# =============================================================================


@always_inline
def _utf8_char_len(lead: UInt8, rest: Int) -> Int:
    """Byte length of the character whose UTF-8 LEAD byte is `lead`, clipped
    to the `rest` bytes that remain (`rest >= 1`). A byte that cannot lead a
    sequence (ASCII, or a stray continuation byte) is 1."""
    var n = 1
    if lead >= UInt8(0xF0):
        n = 4
    elif lead >= UInt8(0xE0):
        n = 3
    elif lead >= UInt8(0xC0):
        n = 2
    return n if n <= rest else rest


def _like_match[
    s_origin: ImmOrigin,
    p_origin: ImmOrigin,
](
    s_ptr: UnsafePointer[UInt8, s_origin],
    s_len: Int,
    p_ptr: UnsafePointer[UInt8, p_origin],
    p_len: Int,
) -> Bool:
    """Match string s against SQL LIKE pattern p.

    % = match zero or more characters
    _ = match exactly one character (one UTF-8 code point — see the block above)
    Other characters = literal match

    Uses an iterative algorithm with backtracking for % wildcards,
    avoiding recursion overhead. Parametric on both origins (see _memcmp).
    """
    var si = 0  # String position
    var pi = 0  # Pattern position
    var star_pi = -1  # Position after last % in pattern
    var star_si = -1  # String position when last % was matched

    while si < s_len:
        if pi < p_len and (p_ptr + pi)[] == UInt8(ord("_")):
            # _ matches one CHARACTER
            si += _utf8_char_len((s_ptr + si)[], s_len - si)
            pi += 1
        elif pi < p_len and (p_ptr + pi)[] == UInt8(ord("%")):
            # % matches zero or more characters -- save backtrack point
            star_pi = pi + 1
            star_si = si
            pi += 1
        elif pi < p_len and (p_ptr + pi)[] == (s_ptr + si)[]:
            # Literal match
            si += 1
            pi += 1
        elif star_pi >= 0:
            # Mismatch -- backtrack to last % and widen it by one CHARACTER
            pi = star_pi
            star_si += _utf8_char_len((s_ptr + star_si)[], s_len - star_si)
            si = star_si
        else:
            return False

    # Consume trailing % in pattern
    while pi < p_len and (p_ptr + pi)[] == UInt8(ord("%")):
        pi += 1

    return pi == p_len


def like_match_string(text: String, pattern: String) -> Bool:
    """SQL `text LIKE pattern` over two Strings — the ONE row-at-a-time LIKE
    matcher (`%` any run of characters, `_` one character, no escape).

    The String-level entry for callers outside this module; it runs
    `_like_match` over the two strings' bytes, so it cannot drift from the
    columnar kernel."""
    # SAFETY: both pointers borrow `text` / `pattern`, which outlive this call;
    # `_like_match` reads [0, byte_length) of each and never writes.
    return _like_match(
        text.unsafe_ptr(), text.byte_length(),
        pattern.unsafe_ptr(), pattern.byte_length(),
    )
