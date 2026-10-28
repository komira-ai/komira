# =============================================================================
# SelectionVector — Struct + Gather + Compose
# =============================================================================

from std.sys import size_of

from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.boolean_array import BooleanArray


# SelectionVector.from_bool_mask is pure Mojo (no FFI helper); see
# `filter_to_indices` (core/eval/comparison.mojo) for why an FFI fast path
# is avoided here.


struct SelectionVector(Movable):
    """A compact array of selected row indices.

    Backed by PrimitiveArray[DType.int32]. Indices are stored in ascending
    order, which enables merge-based compose (intersection) in O(n+m).
    """

    var indices: PrimitiveArray[DType.int32]

    def __init__(out self, var indices: PrimitiveArray[DType.int32]):
        self.indices = indices^

    @staticmethod
    def from_bool_mask(mask: BooleanArray) raises -> SelectionVector:
        """Convert a BooleanArray filter result into a SelectionVector.

        Pure Mojo, routed through the scalar implementation: an FFI helper called
        from worker threads is exposed to allocator interactions across the
        language boundary (see `filter_to_indices`).
        """
        return SelectionVector._from_bool_mask_scalar(mask)

    @staticmethod
    def _from_bool_mask_scalar(mask: BooleanArray) raises -> SelectionVector:
        """Scalar reference path — used only for correctness testing.

        Production callers use from_bool_mask above.
        """
        # Writes through `result.set_typed[Scalar[DType.int32]](write_pos, ...)`.
        # The typed setter is @always_inline + debug_assert-bounds-checked,
        # preserving codegen. The mask is read through view_ro.
        var count = mask.true_count()
        var result = PrimitiveArray[DType.int32].allocate(count)
        var bm_view = mask.data.buffer.view_ro()
        var length = mask.length
        var full_bytes = length >> 3
        var write_pos = 0

        for byte_idx in range(full_bytes):
            var byte_val = bm_view.read_u8_at(byte_idx)
            if byte_val == 0:
                continue
            var base = byte_idx << 3
            if byte_val & UInt8(1) != 0:
                result.set_typed[Scalar[DType.int32]](write_pos, Scalar[DType.int32](base))
                write_pos += 1
            if byte_val & UInt8(2) != 0:
                result.set_typed[Scalar[DType.int32]](write_pos, Scalar[DType.int32](base + 1))
                write_pos += 1
            if byte_val & UInt8(4) != 0:
                result.set_typed[Scalar[DType.int32]](write_pos, Scalar[DType.int32](base + 2))
                write_pos += 1
            if byte_val & UInt8(8) != 0:
                result.set_typed[Scalar[DType.int32]](write_pos, Scalar[DType.int32](base + 3))
                write_pos += 1
            if byte_val & UInt8(16) != 0:
                result.set_typed[Scalar[DType.int32]](write_pos, Scalar[DType.int32](base + 4))
                write_pos += 1
            if byte_val & UInt8(32) != 0:
                result.set_typed[Scalar[DType.int32]](write_pos, Scalar[DType.int32](base + 5))
                write_pos += 1
            if byte_val & UInt8(64) != 0:
                result.set_typed[Scalar[DType.int32]](write_pos, Scalar[DType.int32](base + 6))
                write_pos += 1
            if byte_val & UInt8(128) != 0:
                result.set_typed[Scalar[DType.int32]](write_pos, Scalar[DType.int32](base + 7))
                write_pos += 1

        var remaining = length & 7
        if remaining > 0:
            var byte_val = bm_view.read_u8_at(full_bytes)
            var base = full_bytes << 3
            for bit in range(remaining):
                if byte_val & (UInt8(1) << UInt8(bit)) != 0:
                    result.set_typed[Scalar[DType.int32]](write_pos, Scalar[DType.int32](base + bit))
                    write_pos += 1

        return SelectionVector(result^)

    def gather[dtype: DType](self, source: PrimitiveArray[dtype]) -> PrimitiveArray[dtype]:
        """Materialize: copy only the selected rows from source into a new array.

        For each index in self.indices, reads source[index] and writes it
        sequentially into the output. Output length == self.length().
        """
        # Indices/source/result go through `get_typed` / `set_typed`
        # (offset-aware, @always_inline, debug_assert-checked).
        var n = self.length()
        var result = PrimitiveArray[dtype].allocate(n)
        for i in range(n):
            var idx = Int(self.indices.get_typed[Scalar[DType.int32]](i))
            result.set_typed[Scalar[dtype]](i, source.get_typed[Scalar[dtype]](idx))
        return result^

    @always_inline
    def length(self) -> Int:
        """Number of selected row indices."""
        return self.indices.length

    @always_inline
    def is_all(self, total_rows: Int) -> Bool:
        """Fast path check: returns True when ALL rows are selected."""
        return self.indices.length == total_rows

    @staticmethod
    def all(total_rows: Int) -> SelectionVector:
        """Build a SelectionVector containing every row index [0..total_rows).

        Used as the initial "no narrowing yet" state by
        `evaluate_conjunction_select`. The indices are in ascending order
        (Arrow invariant), so subsequent `compose_mask` calls fold
        naturally into a narrower selection.
        """
        # Writes through `set_typed`.
        var result = PrimitiveArray[DType.int32].allocate(total_rows)
        for i in range(total_rows):
            result.set_typed[Scalar[DType.int32]](i, Scalar[DType.int32](i))
        return SelectionVector(result^)

    def compose_mask(self, sub_mask: BooleanArray) -> SelectionVector:
        """Narrow this selection by a sub-mask defined over its active rows.

        `SelectionVector::compose` with a predicate mask.

        Semantics: `sub_mask` has `self.length()` bits — one per currently
        active row in `self`. Entry `i` being True means "keep the i-th
        index in self". The result is a new SelectionVector whose indices
        are the subset of self.indices at positions where sub_mask is True.

        Invariant preserved: input is ascending; output is a subset, so
        it is ascending too (merge-safe for downstream `compose`).

        Performance: O(len(self)) — byte-at-a-time bitmap scan with a
        zero-byte skip and a BRANCHLESS per-bit compaction (see the note on
        the loop below). `_from_bool_mask_scalar` carries a conditional-store
        shape; it is a different call site with a different selectivity
        profile.
        """
        var pass_count = sub_mask.true_count()
        if pass_count == 0:
            return SelectionVector(PrimitiveArray[DType.int32].allocate(0))

        # result/src go through `get_typed` / `set_typed`; bm through view_ro.
        #
        # BRANCHLESS COMPACTION. The store is UNCONDITIONAL and the cursor
        # advances BY THE BIT, so no instruction in the inner loop depends on the
        # DATA. A per-bit branch (`if byte_val & (1 << k) != 0: store`) on a mask
        # whose selectivity is near 0.5 is a coin flip no predictor can learn: on a
        # compound-AND filter it costs millions of mispredicts per run more than
        # DuckDB, which matches a model built from exactly these eight arms.
        # DuckDB's own `ColumnSegment::FilterSelection` is branchless for the same
        # reason: an unconditional `mov %r8d,(%rbx,%rdi,4)` followed by
        # `add %rax,%rdi`.
        #
        # THE `+ 1` IS LOAD-BEARING, NOT SLACK. An unconditional store writes
        # at `write_pos` even for a CLEAR bit, so every clear bit AFTER the
        # last set one targets index `pass_count` -- one past the last valid
        # element. That slot is scratch: it is written, never read, and the
        # logical length is shrunk back to `pass_count` below, so no consumer
        # can observe it. Sizing the buffer at `pass_count` instead would be a
        # heap overflow on any mask that does not end in a set bit (a lone
        # `0b00000001` overflows it seven times).
        var result = PrimitiveArray[DType.int32].allocate(pass_count + 1)
        var bm_view = sub_mask.data.buffer.view_ro()
        var length = sub_mask.length
        var write_pos = 0

        # An unconditional LOAD needs an index entry behind EVERY bit position
        # in the region scanned branchlessly. The contract is
        # `sub_mask.length == self.length()` (see the docstring); clamping here
        # means a caller that breaks it gets the per-bit treatment of the
        # unbacked tail rather than an out-of-bounds read of `self.indices`.
        var full_bytes = min(length, self.indices.length) >> 3

        # The zero-byte skip STAYS. It is not a data-dependent branch in the
        # same sense: on a low-selectivity mask it fires on most bytes and
        # skips eight elements at a time, and when it fires that often it is
        # itself well predicted. At p=0.5 it costs about a thousandth of the
        # mispredicts that per-bit arms would.
        for byte_idx in range(full_bytes):
            var byte_val = bm_view.read_u8_at(byte_idx)
            if byte_val == 0:
                continue  # skip 8 elements at once
            var base = byte_idx << 3
            # Unrolled bit extraction — LSB-first Arrow convention. Store at
            # the cursor, THEN advance by the bit: a clear bit leaves the
            # cursor where it is and the next store overwrites what it wrote.
            result.set_typed[Scalar[DType.int32]](write_pos, self.indices.get_typed[Scalar[DType.int32]](base))
            write_pos += Int(byte_val & UInt8(1))
            result.set_typed[Scalar[DType.int32]](write_pos, self.indices.get_typed[Scalar[DType.int32]](base + 1))
            write_pos += Int((byte_val >> UInt8(1)) & UInt8(1))
            result.set_typed[Scalar[DType.int32]](write_pos, self.indices.get_typed[Scalar[DType.int32]](base + 2))
            write_pos += Int((byte_val >> UInt8(2)) & UInt8(1))
            result.set_typed[Scalar[DType.int32]](write_pos, self.indices.get_typed[Scalar[DType.int32]](base + 3))
            write_pos += Int((byte_val >> UInt8(3)) & UInt8(1))
            result.set_typed[Scalar[DType.int32]](write_pos, self.indices.get_typed[Scalar[DType.int32]](base + 4))
            write_pos += Int((byte_val >> UInt8(4)) & UInt8(1))
            result.set_typed[Scalar[DType.int32]](write_pos, self.indices.get_typed[Scalar[DType.int32]](base + 5))
            write_pos += Int((byte_val >> UInt8(5)) & UInt8(1))
            result.set_typed[Scalar[DType.int32]](write_pos, self.indices.get_typed[Scalar[DType.int32]](base + 6))
            write_pos += Int((byte_val >> UInt8(6)) & UInt8(1))
            result.set_typed[Scalar[DType.int32]](write_pos, self.indices.get_typed[Scalar[DType.int32]](base + 7))
            write_pos += Int((byte_val >> UInt8(7)) & UInt8(1))

        # Tail: every bit the branchless full-byte loop did not cover — the
        # `length & 7` bits of the final partial byte, plus (only when a caller
        # breaks the length contract above) any byte with no index behind it.
        # At most 7 iterations on any contract-honouring call.
        for i in range(full_bytes << 3, length):
            var tail_byte = bm_view.read_u8_at(i >> 3)
            if tail_byte & (UInt8(1) << UInt8(i & 7)) != 0:
                result.set_typed[Scalar[DType.int32]](write_pos, self.indices.get_typed[Scalar[DType.int32]](i))
                write_pos += 1

        # Drop the scratch slot. The buffer keeps its spare element of
        # capacity; the ARRAY reports exactly `pass_count` elements over
        # exactly `pass_count * size_of[int32]` bytes, which is byte-for-byte
        # what the conditional-store form returned.
        result.data.set_length(pass_count * size_of[Scalar[DType.int32]]())
        result.length = pass_count

        return SelectionVector(result^)

    @staticmethod
    def compose(a: SelectionVector, b: SelectionVector) -> SelectionVector:
        """Intersect two selections (AND logic).

        Both SelectionVectors store indices in ascending order, so this
        uses a merge-style two-pointer scan in O(n+m) time.
        """
        # Reads through `get_typed`.
        var out = List[Scalar[DType.int32]]()
        var i = 0
        var j = 0
        var a_len = a.length()
        var b_len = b.length()
        while i < a_len and j < b_len:
            var ai = a.indices.get_typed[Scalar[DType.int32]](i)
            var bj = b.indices.get_typed[Scalar[DType.int32]](j)
            if ai == bj:
                out.append(ai)
                i += 1
                j += 1
            elif ai < bj:
                i += 1
            else:
                j += 1

        if len(out) == 0:
            return SelectionVector(PrimitiveArray[DType.int32].allocate(0))

        var result = PrimitiveArray[DType.int32].from_list(out)
        return SelectionVector(result^)
