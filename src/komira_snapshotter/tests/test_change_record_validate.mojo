# =============================================================================
# test_change_record_validate.mojo — every rejection arm of
# ChangeRecord.validate(), the order its checks report in, the UNKNOWN op name,
# and ChangeBatch.copy().
# =============================================================================
#
# Each rejection is asserted on the EXACT error message (not a substring:
# "empty new_image" is a substring of "non-empty new_image", so a substring
# match could not tell the two arms apart). A record with two faults at once
# asserts which check reports first.
#
#   (1) validate() rejects each malformed shape with its own message: INSERT
#       with no new_image; MODIFY with no new_image / no old_image; REMOVE
#       with no old_image; an unknown op tag (the tag is in the message).
#   (2) Image-length boundaries: a ONE-cell image counts as present, and a
#       ONE-cell stray image counts as present (rejected), so a check written
#       as `> 1` or `<= 1` instead of `!= 0` / `== 0` goes red.
#   (3) Order of checks: an empty key is reported before any image fault; for
#       INSERT a missing new_image before a stray old_image; for MODIFY a
#       missing new_image before a missing old_image; for REMOVE a missing
#       old_image before a stray new_image.
#   (4) cdc_op_name / op_name() map every tag, an out-of-range tag (above and
#       below) to "UNKNOWN"; the is_* predicates are false for other tags.
#   (5) ChangeBatch.copy() carries every record (op, cells, sequence number),
#       the cursor and the exhausted flag, and owns its own lists. The flag is
#       copied as given, also when it disagrees with the cursor (the
#       constructor allows that), so a copy that derives it from the cursor
#       goes red. ChangeRecord.copy() keeps every cell of a three-cell key and
#       of both images in order and on its own side.
# =============================================================================

from std.testing import assert_true, assert_equal, assert_false

from komira_rowcell import RowCell, make_long_cell, make_string_cell

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


comptime _P = "ChangeRecord.validate: "
comptime _KEY_EMPTY = (
    "ChangeRecord.validate: key is empty (a keyless change cannot be"
    " equality-deleted)"
)


def _one(id: Int64) -> List[RowCell]:
    var k = List[RowCell]()
    k.append(make_long_cell(id))
    return k^


def _none() -> List[RowCell]:
    return List[RowCell]()


def _rec(
    op: Int, var key: List[RowCell], var new: List[RowCell],
    var old: List[RowCell]
) -> ChangeRecord:
    return ChangeRecord(op, key^, new^, old^, String("seq-1"))


def _validate_error(rec: ChangeRecord) -> String:
    """The exact message validate() raises, or "" when it accepts."""
    try:
        rec.validate()
    except e:
        return String(e)
    return String("")


# =============================================================================
# (1) every rejection arm, exact message.
# =============================================================================
def test_rejects_insert_without_new_image() raises:
    var rec = _rec(CDC_OP_INSERT, _one(1), _none(), _none())
    assert_equal(
        _validate_error(rec), String(_P) + "INSERT with empty new_image"
    )


def test_rejects_insert_with_old_image_message() raises:
    var rec = _rec(CDC_OP_INSERT, _one(1), _one(1), _one(2))
    assert_equal(
        _validate_error(rec), String(_P) + "INSERT with non-empty old_image"
    )


def test_rejects_modify_without_new_image() raises:
    var rec = _rec(CDC_OP_MODIFY, _one(1), _none(), _one(2))
    assert_equal(
        _validate_error(rec), String(_P) + "MODIFY with empty new_image"
    )


def test_rejects_modify_without_old_image() raises:
    var rec = _rec(CDC_OP_MODIFY, _one(1), _one(2), _none())
    assert_equal(
        _validate_error(rec), String(_P) + "MODIFY with empty old_image"
    )


def test_rejects_remove_without_old_image() raises:
    var rec = _rec(CDC_OP_REMOVE, _one(1), _none(), _none())
    assert_equal(
        _validate_error(rec), String(_P) + "REMOVE with empty old_image"
    )


def test_rejects_remove_with_new_image_message() raises:
    var rec = _rec(CDC_OP_REMOVE, _one(1), _one(2), _one(3))
    assert_equal(
        _validate_error(rec), String(_P) + "REMOVE with non-empty new_image"
    )


def test_rejects_empty_key_message() raises:
    var rec = _rec(CDC_OP_INSERT, _none(), _one(1), _none())
    assert_equal(_validate_error(rec), String(_KEY_EMPTY))


def test_rejects_unknown_op_tags() raises:
    """Tags just above REMOVE, far above it, and below INSERT are all unknown;
    the tag is printed in the message. Images are shaped like a valid MODIFY so
    only the tag is wrong."""
    var r3 = _rec(3, _one(1), _one(2), _one(3))
    assert_equal(_validate_error(r3), String(_P) + "unknown op tag 3")
    var r99 = _rec(99, _one(1), _one(2), _one(3))
    assert_equal(_validate_error(r99), String(_P) + "unknown op tag 99")
    var rneg = _rec(-1, _one(1), _one(2), _one(3))
    assert_equal(_validate_error(rneg), String(_P) + "unknown op tag -1")


# =============================================================================
# (2) one-cell images: present when wanted, rejected when stray.
# =============================================================================
def test_one_cell_images_accepted() raises:
    assert_equal(
        _validate_error(_rec(CDC_OP_INSERT, _one(1), _one(1), _none())),
        String(""),
    )
    assert_equal(
        _validate_error(_rec(CDC_OP_MODIFY, _one(1), _one(1), _one(2))),
        String(""),
    )
    assert_equal(
        _validate_error(_rec(CDC_OP_REMOVE, _one(1), _none(), _one(2))),
        String(""),
    )


def test_typed_constructors_validate_with_one_cell_images() raises:
    make_insert_record(_one(1), _one(1), String("s1")).validate()
    make_modify_record(_one(1), _one(2), _one(3), String("s2")).validate()
    make_remove_record(_one(1), _one(2), String("s3")).validate()


# =============================================================================
# (3) order of checks: two faults at once, the first check reports.
# =============================================================================
def test_empty_key_reported_before_image_faults() raises:
    # INSERT with no new_image AND an empty key.
    var a = _rec(CDC_OP_INSERT, _none(), _none(), _one(1))
    assert_equal(_validate_error(a), String(_KEY_EMPTY))
    # REMOVE with no old_image AND an empty key.
    var b = _rec(CDC_OP_REMOVE, _none(), _one(1), _none())
    assert_equal(_validate_error(b), String(_KEY_EMPTY))
    # unknown tag AND an empty key.
    var c = _rec(7, _none(), _one(1), _one(1))
    assert_equal(_validate_error(c), String(_KEY_EMPTY))


def test_insert_missing_new_reported_before_stray_old() raises:
    var rec = _rec(CDC_OP_INSERT, _one(1), _none(), _one(2))
    assert_equal(
        _validate_error(rec), String(_P) + "INSERT with empty new_image"
    )


def test_modify_missing_new_reported_before_missing_old() raises:
    var rec = _rec(CDC_OP_MODIFY, _one(1), _none(), _none())
    assert_equal(
        _validate_error(rec), String(_P) + "MODIFY with empty new_image"
    )


def test_remove_missing_old_reported_before_stray_new() raises:
    var rec = _rec(CDC_OP_REMOVE, _one(1), _one(2), _none())
    assert_equal(
        _validate_error(rec), String(_P) + "REMOVE with empty old_image"
    )


# =============================================================================
# (4) op names and predicates.
# =============================================================================
def test_op_name_unknown_tags() raises:
    assert_equal(cdc_op_name(3), String("UNKNOWN"))
    assert_equal(cdc_op_name(-1), String("UNKNOWN"))
    assert_equal(cdc_op_name(1000), String("UNKNOWN"))


def test_record_op_name_and_predicates() raises:
    var ins = make_insert_record(_one(1), _one(1), String("s"))
    var mod = make_modify_record(_one(1), _one(1), _one(2), String("s"))
    var rem = make_remove_record(_one(1), _one(1), String("s"))
    var unk = _rec(5, _one(1), _one(1), _one(1))
    var neg = _rec(-1, _one(1), _one(1), _one(1))
    assert_equal(ins.op_name(), String("INSERT"))
    assert_equal(mod.op_name(), String("MODIFY"))
    assert_equal(rem.op_name(), String("REMOVE"))
    assert_equal(unk.op_name(), String("UNKNOWN"))
    assert_true(ins.is_insert())
    assert_false(ins.is_modify())
    assert_false(ins.is_remove())
    assert_false(mod.is_insert())
    assert_true(mod.is_modify())
    assert_false(mod.is_remove())
    assert_false(rem.is_insert())
    assert_false(rem.is_modify())
    assert_true(rem.is_remove())
    assert_false(unk.is_insert())
    assert_false(unk.is_modify())
    assert_false(unk.is_remove())
    assert_equal(neg.op_name(), String("UNKNOWN"))
    assert_false(neg.is_insert())
    assert_false(neg.is_modify())
    assert_false(neg.is_remove())


# =============================================================================
# (5) ChangeBatch.copy().
# =============================================================================
def _two_record_batch(var cursor: String, exhausted: Bool) -> ChangeBatch:
    var recs = List[ChangeRecord]()
    var row = List[RowCell]()
    row.append(make_long_cell(1))
    row.append(make_string_cell(String("alpha")))
    recs.append(make_insert_record(_one(1), row^, String("s-10")))
    recs.append(make_remove_record(_one(2), _one(20), String("s-11")))
    return ChangeBatch(recs^, cursor^, exhausted)


def test_batch_copy_carries_records_cursor_and_live_flag() raises:
    var b = _two_record_batch(String("iter-7"), False)
    var c = b.copy()
    assert_equal(c.__len__(), 2)
    assert_equal(c.next_cursor, String("iter-7"))
    assert_false(c.is_exhausted())
    assert_equal(c.records[0].op, CDC_OP_INSERT)
    assert_equal(c.records[0].sequence_number, String("s-10"))
    assert_equal(len(c.records[0].key), 1)
    assert_equal(len(c.records[0].new_image), 2)
    assert_equal(len(c.records[0].old_image), 0)
    assert_equal(c.records[0].new_image[1].as_string(), String("alpha"))
    assert_equal(c.records[0].key[0].as_long(), 1)
    assert_equal(c.records[1].op, CDC_OP_REMOVE)
    assert_equal(c.records[1].sequence_number, String("s-11"))
    assert_equal(len(c.records[1].key), 1)
    assert_equal(len(c.records[1].new_image), 0)
    assert_equal(len(c.records[1].old_image), 1)
    assert_equal(c.records[1].old_image[0].as_long(), 20)
    assert_equal(c.records[1].key[0].as_long(), 2)


def test_batch_copy_carries_exhausted_flag() raises:
    var b = _two_record_batch(String(""), True)
    var c = b.copy()
    assert_true(c.is_exhausted())
    assert_equal(c.next_cursor, String(""))
    assert_equal(c.__len__(), 2)
    # The flag is copied, not rebuilt from the cursor: the constructor accepts
    # a flag and a cursor that disagree, and the copy keeps both as given.
    var odd = ChangeBatch(List[ChangeRecord](), String(""), False).copy()
    assert_false(odd.is_exhausted())
    assert_equal(odd.next_cursor, String(""))
    var odd2 = ChangeBatch(List[ChangeRecord](), String("tok"), True).copy()
    assert_true(odd2.is_exhausted())
    assert_equal(odd2.next_cursor, String("tok"))
    var e = ChangeBatch.end_of_segment().copy()
    assert_true(e.is_exhausted())
    assert_equal(e.__len__(), 0)
    assert_equal(e.next_cursor, String(""))


def _three(a: Int64, b: Int64, c: Int64) -> List[RowCell]:
    var out = List[RowCell]()
    out.append(make_long_cell(a))
    out.append(make_long_cell(b))
    out.append(make_long_cell(c))
    return out^


def test_record_copy_keeps_every_cell_in_order() raises:
    """A MODIFY with three-cell key and images: the copy keeps each list's
    length and every cell in place, and keeps the images on their own sides
    (old before, new after), as make_modify_record placed them."""
    var r = make_modify_record(
        _three(1, 2, 3), _three(10, 11, 12), _three(20, 21, 22), String("s-9")
    )
    assert_equal(r.old_image[0].as_long(), 10)
    assert_equal(r.new_image[0].as_long(), 20)
    var c = r.copy()
    assert_equal(c.op, CDC_OP_MODIFY)
    assert_equal(c.sequence_number, String("s-9"))
    assert_equal(len(c.key), 3)
    assert_equal(len(c.old_image), 3)
    assert_equal(len(c.new_image), 3)
    for i in range(3):
        assert_equal(c.key[i].as_long(), Int64(1 + i))
        assert_equal(c.old_image[i].as_long(), Int64(10 + i))
        assert_equal(c.new_image[i].as_long(), Int64(20 + i))


def test_batch_copy_owns_its_lists() raises:
    var b = _two_record_batch(String("iter-8"), False)
    var c = b.copy()
    b.records.append(make_remove_record(_one(3), _one(30), String("s-12")))
    b.records[0].new_image.append(make_long_cell(5))
    b.next_cursor = String("changed")
    assert_equal(b.__len__(), 3)
    assert_equal(c.__len__(), 2)
    assert_equal(len(c.records[0].new_image), 2)
    assert_equal(c.next_cursor, String("iter-8"))


def main() raises:
    test_rejects_insert_without_new_image()
    test_rejects_insert_with_old_image_message()
    test_rejects_modify_without_new_image()
    test_rejects_modify_without_old_image()
    test_rejects_remove_without_old_image()
    test_rejects_remove_with_new_image_message()
    test_rejects_empty_key_message()
    test_rejects_unknown_op_tags()
    test_one_cell_images_accepted()
    test_typed_constructors_validate_with_one_cell_images()
    test_empty_key_reported_before_image_faults()
    test_insert_missing_new_reported_before_stray_old()
    test_modify_missing_new_reported_before_missing_old()
    test_remove_missing_old_reported_before_stray_new()
    test_op_name_unknown_tags()
    test_record_op_name_and_predicates()
    test_batch_copy_carries_records_cursor_and_live_flag()
    test_batch_copy_carries_exhausted_flag()
    test_record_copy_keeps_every_cell_in_order()
    test_batch_copy_owns_its_lists()
    print("test_change_record_validate: ALL PASS")
