# =============================================================================
# test_change_stream_seam.mojo — the ChangeStreamListener seam falsifiers.
# =============================================================================
#
# The seam-model falsifiers (pure — no wire, no store, no network):
#
#   (1) The typed constructors produce the right op<->image shape:
#         INSERT -> op INSERT, new_image only, old_image empty
#         MODIFY -> op MODIFY, both images present
#         REMOVE -> op REMOVE, old_image only, new_image empty
#       AND `validate()` REJECTS a malformed record (INSERT with an old_image /
#       REMOVE with a new_image / an empty key) — the falsifier that proves the
#       invariant is load-bearing, not decorative.
#   (2) The sequence_number is CARRIED verbatim through construction + copy (it
#       feeds the Iceberg per-entry seq + the checkpoint).
#   (3) The cells are the shared `RowCell` type + deep-copy correctly (the
#       String arm gets a fresh String, so a copied record does not alias).
#   (4) `ChangeBatch` distinguishes empty-LIVE (keep polling) from EXHAUSTED
#       (segment ended) — the load-bearing DynamoDB shard-iteration distinction.
# =============================================================================

from std.testing import assert_true, assert_equal, assert_false

from komira_rowcell import (
    CELL_T_LONG,
    CELL_T_STRING,
    RowCell,
    make_long_cell,
    make_string_cell,
)

from komira_snapshotter.change_stream_trait import (
    CDC_OP_INSERT,
    CDC_OP_MODIFY,
    CDC_OP_REMOVE,
    ChangeRecord,
    ChangeBatch,
    make_insert_record,
    make_modify_record,
    make_remove_record,
    cdc_op_name,
)


def _key(id: Int64) -> List[RowCell]:
    var k = List[RowCell]()
    k.append(make_long_cell(id))
    return k^


def _row(id: Int64, var name: String) -> List[RowCell]:
    var r = List[RowCell]()
    r.append(make_long_cell(id))
    r.append(make_string_cell(name^))
    return r^


# =============================================================================
# (1) op<->image shape.
# =============================================================================
def test_insert_record_shape() raises:
    """INSERT: op INSERT, new_image present, old_image empty, key present."""
    var rec = make_insert_record(
        _key(1), _row(1, String("alice")), String("seq-100")
    )
    assert_equal(rec.op, CDC_OP_INSERT)
    assert_true(rec.is_insert())
    assert_false(rec.is_modify())
    assert_equal(len(rec.key), 1)
    assert_equal(len(rec.new_image), 2)
    assert_equal(len(rec.old_image), 0)  # INSERT has NO before-image
    rec.validate()  # must not raise


def test_modify_record_shape() raises:
    """MODIFY: op MODIFY, BOTH images present (old = equality-delete target,
    new = append)."""
    var rec = make_modify_record(
        _key(2),
        _row(2, String("bob")),      # old
        _row(2, String("bobby")),    # new
        String("seq-200"),
    )
    assert_equal(rec.op, CDC_OP_MODIFY)
    assert_true(rec.is_modify())
    assert_equal(len(rec.old_image), 2)
    assert_equal(len(rec.new_image), 2)
    # The old image carries the BEFORE value; the new carries AFTER.
    assert_equal(rec.old_image[1].as_string(), String("bob"))
    assert_equal(rec.new_image[1].as_string(), String("bobby"))
    rec.validate()


def test_remove_record_shape() raises:
    """REMOVE: op REMOVE, old_image present (equality-delete target), new_image
    empty."""
    var rec = make_remove_record(
        _key(3), _row(3, String("carol")), String("seq-300")
    )
    assert_equal(rec.op, CDC_OP_REMOVE)
    assert_true(rec.is_remove())
    assert_equal(len(rec.old_image), 2)
    assert_equal(len(rec.new_image), 0)  # REMOVE has NO after-image
    rec.validate()


# =============================================================================
# (1b) validate() REJECTS malformed records — the invariant is load-bearing.
# =============================================================================
def test_validate_rejects_insert_with_old_image() raises:
    """A malformed INSERT that carries an old_image is REJECTED by validate().
    FALSIFIER: if validate() did not enforce the op<->image invariant, this
    would silently pass and the snapshotter would emit a spurious delete."""
    # Construct the malformed record directly (bypass the typed constructor).
    var rec = ChangeRecord(
        CDC_OP_INSERT,
        _key(1),
        _row(1, String("x")),   # new_image
        _row(1, String("y")),   # old_image — ILLEGAL for INSERT
        String("seq-1"),
    )
    var raised = False
    try:
        rec.validate()
    except:
        raised = True
    assert_true(raised, msg="validate() must reject INSERT with an old_image")


def test_validate_rejects_remove_with_new_image() raises:
    """A malformed REMOVE that carries a new_image is REJECTED by validate()."""
    var rec = ChangeRecord(
        CDC_OP_REMOVE,
        _key(1),
        _row(1, String("x")),   # new_image — ILLEGAL for REMOVE
        _row(1, String("y")),   # old_image
        String("seq-1"),
    )
    var raised = False
    try:
        rec.validate()
    except:
        raised = True
    assert_true(raised, msg="validate() must reject REMOVE with a new_image")


def test_validate_rejects_empty_key() raises:
    """A keyless change is REJECTED — a keyless record cannot be equality-
    deleted, so it must fail fast + loud."""
    var rec = ChangeRecord(
        CDC_OP_INSERT,
        List[RowCell](),            # empty key — ILLEGAL
        _row(1, String("x")),
        List[RowCell](),
        String("seq-1"),
    )
    var raised = False
    try:
        rec.validate()
    except:
        raised = True
    assert_true(raised, msg="validate() must reject an empty key")


# =============================================================================
# (2) sequence_number carried verbatim through construction + copy.
# =============================================================================
def test_sequence_number_carried() raises:
    """The sequence_number is carried verbatim (it feeds the Iceberg per-entry
    seq + the checkpoint — a dropped/rewritten seq breaks merge ordering).
    """
    var rec = make_insert_record(
        _key(7), _row(7, String("g")), String("00000000000000000000123456")
    )
    assert_equal(
        rec.sequence_number, String("00000000000000000000123456")
    )
    var dup = rec.copy()
    assert_equal(
        dup.sequence_number, String("00000000000000000000123456")
    )


# =============================================================================
# (3) cells are the shared RowCell type + deep-copy does not alias.
# =============================================================================
def test_copy_deep_copies_cells() raises:
    """copy() deep-copies the cell lists — mutating the ORIGINAL's list length
    after copy does not change the COPY (the copy owns its own cells)."""
    var rec = make_modify_record(
        _key(9),
        _row(9, String("before")),
        _row(9, String("after")),
        String("seq-9"),
    )
    var dup = rec.copy()
    # Both carry the same string values but as independent Strings.
    assert_equal(dup.old_image[1].as_string(), String("before"))
    assert_equal(dup.new_image[1].as_string(), String("after"))
    # The copy is structurally independent — appending to the original's key
    # does not grow the copy's key.
    rec.key.append(make_long_cell(999))
    assert_equal(len(rec.key), 2)
    assert_equal(len(dup.key), 1)  # copy unaffected


# =============================================================================
# (4) ChangeBatch live-vs-exhausted distinction.
# =============================================================================
def test_batch_empty_live_is_not_exhausted() raises:
    """An empty batch with a LIVE cursor means 'no new records yet, keep polling'
    — NOT end-of-stream. FALSIFIER: if empty were conflated with exhausted, the
    snapshotter would stop tailing a live shard the instant it caught up."""
    var b = ChangeBatch.empty_live(String("iterator-token-abc"))
    assert_equal(b.__len__(), 0)
    assert_false(b.is_exhausted())
    assert_equal(b.next_cursor, String("iterator-token-abc"))


def test_batch_end_of_segment_is_exhausted() raises:
    """An end-of-segment batch is exhausted with an EMPTY cursor (a null
    NextShardIterator = the shard closed)."""
    var b = ChangeBatch.end_of_segment()
    assert_equal(b.__len__(), 0)
    assert_true(b.is_exhausted())
    assert_equal(b.next_cursor, String(""))


def test_batch_carries_records_and_cursor() raises:
    """A non-empty batch carries its records in stream order AND the resume
    cursor for the next poll."""
    var recs = List[ChangeRecord]()
    recs.append(
        make_insert_record(_key(1), _row(1, String("a")), String("s1"))
    )
    recs.append(
        make_remove_record(_key(2), _row(2, String("b")), String("s2"))
    )
    var b = ChangeBatch(recs^, String("next-iter"), False)
    assert_equal(b.__len__(), 2)
    assert_false(b.is_exhausted())
    assert_equal(b.records[0].op, CDC_OP_INSERT)
    assert_equal(b.records[1].op, CDC_OP_REMOVE)
    assert_equal(b.records[1].sequence_number, String("s2"))
    assert_equal(b.next_cursor, String("next-iter"))


def test_op_name() raises:
    assert_equal(cdc_op_name(CDC_OP_INSERT), String("INSERT"))
    assert_equal(cdc_op_name(CDC_OP_MODIFY), String("MODIFY"))
    assert_equal(cdc_op_name(CDC_OP_REMOVE), String("REMOVE"))


def main() raises:
    test_insert_record_shape()
    test_modify_record_shape()
    test_remove_record_shape()
    test_validate_rejects_insert_with_old_image()
    test_validate_rejects_remove_with_new_image()
    test_validate_rejects_empty_key()
    test_sequence_number_carried()
    test_copy_deep_copies_cells()
    test_batch_empty_live_is_not_exhausted()
    test_batch_end_of_segment_is_exhausted()
    test_batch_carries_records_and_cursor()
    test_op_name()
    print("test_change_stream_seam: ALL PASS")
