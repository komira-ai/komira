# =============================================================================
# `RowBlock.copy_var_string_cell` — the CROSS-BLOCK REBASE contract.
# =============================================================================
#
# WHAT THIS GUARDS, AND WHY IT IS NOT A ROUND-TRIP TEST
# ----------------------------------------------------
# A var-string cell is an 8-byte (offset, length) descriptor in the row's fixed
# region plus `length` payload bytes in the block's var heap. Var offsets are
# NOT position-stable across blocks: the same logical value lives at a
# different offset in every block that holds it. So copying a cell between two
# RowBlocks is TWO obligations, and only one of them is "move the bytes":
#
#   1. append the payload into the DESTINATION's var heap, and
#   2. REBASE the descriptor to the destination offset the payload landed at.
#
# Getting (2) wrong is a SILENT WRONG ANSWER, not a crash. The descriptor still
# points inside the destination heap, the read still succeeds, and it returns
# WHATEVER ELSE happens to live at that offset. On the grace-hash spill path
# these cells are GROUP KEYS (`_copy_key_into_row` on every insert miss,
# `_copy_full_row_from` on every combine miss, `partition_group_rows_to_sab`
# once per surviving row per sub-partition), so a bad rebase is a wrong GROUP —
# rows folded under a key that is not theirs.
#
# A same-block round trip CANNOT see this: when source and destination heaps
# are at the same fill level the correct offset and the un-rebased offset are
# the SAME NUMBER. Every test here therefore copies between blocks whose var
# heaps are at DELIBERATELY DIFFERENT fill levels, and reads every payload back
# byte-for-byte.
#
# HONEST PROVENANCE: this test was NOT written against a live bug.
# The per-byte `write_u8_at`/`read_u8_at` loop it was written to protect is
# CORRECT — it is only slow, and it sat on the innermost per-group path of the
# STRING-key spill work. The test exists so the bulk-memcpy rewrite of that
# loop cannot quietly drop obligation (2). Its power was demonstrated the only
# way it can be: a deliberately-broken variant of the new code that omits the
# rebase FAILS `test_copy_var_string_cell_rebases_across_fill_levels` on the
# first copied cell.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_row_format.row_block import RowBlock


# -----------------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------------

# One var cell per row at col_offset 0; 8-byte stride (the descriptor itself).
comptime _OFF0 = 0


def _new_block(n_rows: Int) raises -> RowBlock:
    var rb = RowBlock.with_capacity(0, 0, 8)
    rb.reserve_rows(n_rows)
    rb.set_n_rows(n_rows)
    return rb^


def _rep(c: String, n: Int) -> String:
    """`c` repeated `n` times."""
    var s = String("")
    for _i in range(n):
        s += c
    return s


def _assert_payload_is(got: List[UInt8], want: String, where: String) raises:
    """Byte-for-byte equality against `want`, with `where` in the message so a
    failure names the cell rather than just the byte."""
    var wb = want.as_bytes()
    assert_equal(
        len(got),
        len(wb),
        "payload LENGTH mismatch at " + where,
    )
    for i in range(len(wb)):
        assert_equal(
            Int(got[i]),
            Int(wb[i]),
            "payload BYTE " + String(i) + " mismatch at " + where,
        )


def _assert_span_is(got: Span[UInt8, _], want: String, where: String) raises:
    var wb = want.as_bytes()
    assert_equal(
        len(got),
        len(wb),
        "key payload LENGTH mismatch at " + where,
    )
    for i in range(len(wb)):
        assert_equal(
            Int(got[i]),
            Int(wb[i]),
            "key payload BYTE " + String(i) + " mismatch at " + where,
        )


def _payloads() raises -> List[String]:
    """Payloads chosen so that NO two are a prefix of one another at the same
    length, and so the set spans the interesting sizes: empty, one byte, a
    short run, a mid-size sentence, and one past 256 bytes (which forces at
    least one amortized-doubling regrow of the destination var heap DURING the
    copy loop — the moment a stale base pointer or a stale offset shows up).
    """
    var out = List[String]()
    out.append(String(""))
    out.append(String("a"))
    out.append(String("bcd"))
    out.append(String("the quick brown fox jumps over the lazy dog"))
    out.append(_rep("Z", 300))
    out.append(String("tail"))
    out.append(_rep("m", 129))
    out.append(String("~"))
    return out^


# -----------------------------------------------------------------------------
# Tests
# -----------------------------------------------------------------------------


def test_copy_var_string_cell_rebases_across_fill_levels() raises:
    """THE CORE GUARD. Source and destination heaps are at different fill
    levels, and the cells are copied in REVERSE order so that a destination
    offset can never coincidentally equal its source offset."""
    var vals = _payloads()
    var n = len(vals)

    var src = _new_block(n)
    for i in range(n):
        src.write_var_string_cell(i, _OFF0, vals[i].as_bytes())

    # Push the destination heap to a fill level that is neither zero nor a
    # multiple of anything the copy could plausibly round to.
    var filler = _rep("F", 37)
    var n_filler = 3
    var dst = _new_block(n_filler + n)
    for j in range(n_filler):
        dst.write_var_string_cell(j, _OFF0, filler.as_bytes())
    var fill_before = dst.var_storage_used
    assert_true(fill_before > 0, "the destination heap must start NON-empty")

    # Copy REVERSED: dst row (n_filler + k) receives src row (n - 1 - k).
    for k in range(n):
        dst.copy_var_string_cell(n_filler + k, _OFF0, src, (n - 1) - k, _OFF0)

    # Every copied payload reads back byte-for-byte.
    var total = 0
    for k in range(n):
        var i = (n - 1) - k
        _assert_payload_is(
            dst.read_var_string_at(n_filler + k, _OFF0),
            vals[i],
            "dst row "
            + String(n_filler + k)
            + " (from src row "
            + String(i)
            + ")",
        )
        total += len(vals[i].as_bytes())

    # The payloads were APPENDED — not written over the filler, not written
    # at the source's offsets.
    assert_equal(
        dst.var_storage_used,
        fill_before + total,
        "destination var cursor must advance by exactly the copied bytes",
    )

    # The filler rows the copy wrote PAST are untouched.
    for j in range(n_filler):
        _assert_payload_is(
            dst.read_var_string_at(j, _OFF0),
            filler,
            "filler row " + String(j),
        )

    # The SOURCE is untouched — a copy is not a move.
    for i in range(n):
        _assert_payload_is(
            src.read_var_string_at(i, _OFF0),
            vals[i],
            "src row " + String(i) + " after the copy",
        )


def test_copy_var_string_cell_survives_two_hops() raises:
    """A -> B -> C, each heap at a different fill level. The spill path really
    does chain these (probe block -> group block -> sub-partition block), so
    one hop is not the whole contract."""
    var vals = _payloads()
    var n = len(vals)

    var a = _new_block(n)
    for i in range(n):
        a.write_var_string_cell(i, _OFF0, vals[i].as_bytes())

    var b_fill = _rep("B", 11)
    var b = _new_block(1 + n)
    b.write_var_string_cell(0, _OFF0, b_fill.as_bytes())
    for i in range(n):
        b.copy_var_string_cell(1 + i, _OFF0, a, i, _OFF0)

    var c_fill = _rep("C", 250)
    var c = _new_block(1 + n)
    c.write_var_string_cell(0, _OFF0, c_fill.as_bytes())
    # Reverse again on the second hop, so the two hops do not cancel out.
    for k in range(n):
        c.copy_var_string_cell(1 + k, _OFF0, b, 1 + ((n - 1) - k), _OFF0)

    for k in range(n):
        _assert_payload_is(
            c.read_var_string_at(1 + k, _OFF0),
            vals[(n - 1) - k],
            "C row " + String(1 + k) + " after two hops",
        )
    _assert_payload_is(c.read_var_string_at(0, _OFF0), c_fill, "C filler")
    _assert_payload_is(b.read_var_string_at(0, _OFF0), b_fill, "B filler")


def test_copy_var_string_cell_into_empty_heap_from_filled() raises:
    """The asymmetric direction: a destination that has NEVER allocated a var
    heap, fed from a source whose cells sit at large offsets. An un-rebased
    descriptor here points past the destination heap entirely."""
    var vals = _payloads()
    var n = len(vals)

    var src = _new_block(n + 1)
    var lead = _rep("L", 512)
    src.write_var_string_cell(0, _OFF0, lead.as_bytes())
    for i in range(n):
        src.write_var_string_cell(1 + i, _OFF0, vals[i].as_bytes())

    var dst = _new_block(n)
    assert_equal(
        dst.var_storage_used, 0, "the destination heap must start EMPTY"
    )
    for i in range(n):
        dst.copy_var_string_cell(i, _OFF0, src, 1 + i, _OFF0)

    for i in range(n):
        _assert_payload_is(
            dst.read_var_string_at(i, _OFF0),
            vals[i],
            "dst row " + String(i) + " (empty-heap destination)",
        )


def test_copy_var_string_key_cell_tag_and_null_survive_rebase() raises:
    """The NULL-discriminating var-width KEY cells specifically — the payload carries a leading
    NULL-discriminator tag byte, and `copy_var_string_cell` is what moves a key
    from the per-batch probe block into the group block. NULL must stay its own
    group and must not collapse onto the EMPTY STRING."""
    var keys = List[String]()
    keys.append(String(""))  # the EMPTY key — distinct from NULL
    keys.append(String("alpha"))
    keys.append(_rep("z", 300))
    var n_keys = len(keys)

    var probe = _new_block(n_keys + 1)
    for i in range(n_keys):
        probe.write_var_string_key_cell(i, _OFF0, keys[i].as_bytes())
    probe.write_var_string_key_null_cell(n_keys, _OFF0)

    # Group block already holding two keys of its own -> a different fill level.
    var g0 = _rep("Q", 61)
    var g1 = _rep("Q", 17)
    var groups = _new_block(2 + n_keys + 1)
    groups.write_var_string_key_cell(0, _OFF0, g0.as_bytes())
    groups.write_var_string_key_cell(1, _OFF0, g1.as_bytes())

    for i in range(n_keys + 1):
        groups.copy_var_string_cell(2 + i, _OFF0, probe, i, _OFF0)

    for i in range(n_keys):
        assert_false(
            groups.var_string_key_is_null_at(2 + i, _OFF0),
            "copied NON-NULL key read back as NULL at group row "
            + String(2 + i),
        )
        _assert_span_is(
            groups.var_string_key_payload_at(2 + i, _OFF0),
            keys[i],
            "group row " + String(2 + i),
        )

    # The NULL key: still NULL, still a zero-length payload, after the rebase.
    assert_true(
        groups.var_string_key_is_null_at(2 + n_keys, _OFF0),
        "the copied NULL key must still be the NULL group",
    )
    assert_equal(
        len(groups.var_string_key_payload_at(2 + n_keys, _OFF0)),
        0,
        "the NULL key's payload is the tag byte alone",
    )

    # ... and the EMPTY key is NOT it.
    assert_false(
        groups.var_string_key_is_null_at(2, _OFF0),
        "the EMPTY STRING key must not read back as the NULL group",
    )

    # The group block's own pre-existing keys are untouched.
    _assert_span_is(
        groups.var_string_key_payload_at(0, _OFF0), g0, "group row 0"
    )
    _assert_span_is(
        groups.var_string_key_payload_at(1, _OFF0), g1, "group row 1"
    )


def test_copy_var_string_cell_interleaved_with_fresh_writes() raises:
    """Copies INTERLEAVED with direct writes into the same destination. The
    two append paths share one cursor; a rebase that reads the cursor at the
    wrong moment shows up here and nowhere else."""
    var vals = _payloads()
    var n = len(vals)

    var src = _new_block(n)
    for i in range(n):
        src.write_var_string_cell(i, _OFF0, vals[i].as_bytes())

    var fresh = _rep("N", 23)
    var dst = _new_block(2 * n)
    for i in range(n):
        dst.copy_var_string_cell(2 * i, _OFF0, src, i, _OFF0)
        dst.write_var_string_cell(2 * i + 1, _OFF0, fresh.as_bytes())

    for i in range(n):
        _assert_payload_is(
            dst.read_var_string_at(2 * i, _OFF0),
            vals[i],
            "interleaved COPY row " + String(2 * i),
        )
        _assert_payload_is(
            dst.read_var_string_at(2 * i + 1, _OFF0),
            fresh,
            "interleaved WRITE row " + String(2 * i + 1),
        )


def main() raises:
    var s = TestSuite()
    s.test[test_copy_var_string_cell_rebases_across_fill_levels]()
    s.test[test_copy_var_string_cell_survives_two_hops]()
    s.test[test_copy_var_string_cell_into_empty_heap_from_filled]()
    s.test[test_copy_var_string_key_cell_tag_and_null_survive_rebase]()
    s.test[test_copy_var_string_cell_interleaved_with_fresh_writes]()
    s^.run()
