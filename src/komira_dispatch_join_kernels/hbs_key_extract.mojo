# =============================================================================
# hbs_key_extract — the ONE place `HashBuildSink`
# turns its build-key Column into a `PrimitiveArray`, for BOTH the serial and
# the parallel combine.
# =============================================================================
#
# Split out of `hash_build_sink.mojo` rather than added to it: that file is
# already past the 1000-line ceiling, and this body plus its audit is the kind
# of thing that gets read on its own.
# =============================================================================

from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.schema import RecordBatch
from komira_dispatch_join_kernels.hbs_key_share_counter import (
    hbs_key_decline_shape_incr,
    hbs_key_share_incr,
)


def _extract_build_key_array(
    imm build_batch: RecordBatch, key_idx: Int, marker_on: Bool
) raises -> PrimitiveArray[DType.int64]:
    """Materialise the INT64 build-key column as a `PrimitiveArray`.

    UNCONDITIONALLY the scoped zero-copy `Column.share_as_primitive` wherever
    that accessor's own gate admits the column — an Arc refcount bump that
    carries `_offset` through, no allocation and no copy. A column the accessor
    REFUSES (nullable, or a storage type INT64 does not cover) falls back to
    the identical `Column.as_primitive` MEMCPY, which is what every column got
    before.

    There is no switch: the share is taken whenever the accessor admits the
    column. What it removes on a large build side is a single-threaded copy of
    the whole key column on the DRIVER with the worker pool parked (200 MB on
    a 25M-row INT64 key).

    ⚠ A REFUSAL BY THE ACCESSOR (`decline_shape`) is the ONLY way to decline.
    A decline is not readable from a wall — see the marker note below.

    ⚠ TWO CALL SITES SHARE THIS BODY DELIBERATELY (`combine` and
    `combine_parallel`). They had two independently-written `as_primitive` lines
    and the same consumer set; a lever wired to one of them would make whichever
    path a test drove unrepresentative of the path a query drives.

    THE CONSUMER AUDIT that `Column.share_as_primitive` demands of its callers,
    stated here because the predicate that used to carry it is gone. `key_arr`
    reaches exactly five bodies and every one takes an OFFSET-AWARE read-only
    pointer and never writes through it:
      * `HashBuildSink._finalize_dynamic_filter_from_keys` — `keys.length`,
        `keys._typed_ptr_ro()` (`primitive_array.mojo`: `+ self.offset`).
      * `join.HashJoinBuilder.build` / `.build_with_bloom` — `keys.view_ro()`
        (`+ self.offset * sz`), `keys.null_count`, `keys.is_null(i)`
        (offset-aware; unreachable under the share, whose gate refuses a column
        carrying a validity bitmap at all).
      * `hash_build_sink._build_index_parallel` + its `_BloomPrefillTask` —
        `keys._typed_ptr_ro()`, read-only in the fork.
      * `hash_chain_parallel_build.chain_build_parallel`'s `_ChainBuildTask` —
        `kview._unsafe_ptr().bitcast[...]() + keys.offset`.
    NONE calls `set` / `set_valid` / `set_null` / `view_mut` /
    `_unsafe_data_ptr`, so the mutate-through-alias hazard
    cannot arise here. Widening the share to a THIRD call site is a
    new audit, not a bigger number.

    ⚠ AND THE MOVE IS STILL SOUND. `combine_parallel`'s `else` arm MOVES
    `key_arr` into `hash_join_build_parallel`, whose docstring says the
    caller's copy "is already private — `Column.as_primitive` copies — so this
    is free". Under the share it is no longer private, and that sentence is now
    wrong about ownership and still right about lifetime: the moved
    `PrimitiveArray` holds its own Arc reference on the value buffer, so the
    bytes outlive both the borrow and the later `self._batch = build_batch^`
    move (a `RecordBatch` move relocates Arc handles, never the heap bytes).

    ⚠ A ROUTE THAT DECLINES SILENTLY CANNOT BE READ FROM A WALL. The `[HBS_KEY]`
    line states the arm AND both decline terms on EVERY arm (not only the new
    one), because an ABSENT marker is ambiguous — gate refused, or the sink
    never reached — and the two have different fixes. It prints only
    when the caller passes `marker_on`, never on the untraced hot path. The
    two counters in `hbs_key_share_counter.mojo` carry the same verdict for a
    test, which is the only falsifier available: the share and the copy are
    VALUE-IDENTICAL by construction, so no assertion on the answer can see which
    one ran.

    ⚠ THE MARKER'S FORMAT is `[HBS_KEY] arm=share shareable=1 ...`; there is
    no `gate=` term, for the reason stated at the print site. Anything grepping
    for it should key on `arm=`. The form is the one below; read it there.
    """
    ref key_col = build_batch.column_at(key_idx)
    # The accessor's OWN gate is the only remaining term. `take_share` is kept
    # as a named value rather than inlined because the marker below prints it
    # as the DECIDING value and must not re-derive it.
    var shareable = key_col.can_share_as_primitive[DType.int64]()
    var take_share = shareable

    var key_arr: PrimitiveArray[DType.int64]
    if take_share:
        key_arr = key_col.share_as_primitive[DType.int64]()
        hbs_key_share_incr()
    else:
        key_arr = key_col.as_primitive[DType.int64]()
        hbs_key_decline_shape_incr()

    if marker_on:
        print(
            "[HBS_KEY] arm=",
            # `arm=` is the DECIDING value. `shareable=` is now the ONLY term
            # that produces it — the `gate=` term is gone with the lever, and is
            # NOT printed as a constant 1, because a field that can only ever
            # say one thing reads as evidence and carries none.
            # `nullable=` / `type=` disambiguate a `shareable=0`, since
            # `can_share_as_primitive` refuses on BOTH a validity bitmap and an
            # incompatible storage type.
            "share" if take_share else "copy",
            " shareable=", Int(shareable),
            " nullable=", Int(Bool(key_col._validity)),
            " type=", String(key_col.arrow_type),
            " rows=", Int(key_arr.length),
            " offset=", Int(key_arr.offset),
            " bytes=", Int(key_arr.length) * 8,
        )
    return key_arr^
