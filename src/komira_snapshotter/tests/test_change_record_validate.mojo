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
#   (6) ChangeRecord.copy() keeps a record as given, also one validate()
#       rejects: an unknown op tag (below INSERT, above REMOVE) and a stray
#       image survive the copy, so the copy still fails validate() with the
#       original message. A copy that clamps or remaps the tag, or drops an
#       image the op does not use, goes red.
#   (7) Whole-record and whole-batch equality: `_assert_same_record`
#       compares a copy with its original on every ChangeRecord field (op,
#       sequence_number, and the length and every RowCell field of key,
#       new_image and old_image), and `_assert_same_batch` adds the cursor and
#       the exhausted flag. They run over one fixture per kind of record (valid
#       INSERT / MODIFY / REMOVE, unknown tags, stray images, keyless records
#       of every op, empty images, three-cell and mixed-type cells, an
#       all-empty record), alone and inside batches, so a copy that drops or
#       rewrites any field for any one kind of record goes red.
#   (8) validate() over every group (7) fixture, plus a keyless tag -1, stray
#       images and a missing old image under a two-cell key, and valid records
#       with a two-cell key: each gets the exact message (or none) that the
#       ChangeRecord invariants and the documented order of checks give. The
#       expected message is derived from the fixture's shape by
#       `_expected_fault`, which states the invariants, not from the code,
#       and is itself pinned by a literal table. A grid of every op (and an
#       unknown tag below and two above), and key, new_image and old_image
#       lengths 0, 1 and 2 each (162 records) covers every check under every
#       length of every list it could read and every pair of faults one op
#       can have, so a check skipped for one op, one tag, one key length or
#       one length of the other image, or two checks reported in the wrong
#       order, goes red.
# =============================================================================

from std.testing import assert_true, assert_equal, assert_false

from komira_rowcell import (
    RowCell,
    make_boolean_cell,
    make_double_cell,
    make_long_cell,
    make_null_cell,
    make_string_cell,
)
from komira_rowcell.row_cell import CELL_T_LONG

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


# =============================================================================
# (6) ChangeRecord.copy() keeps an invalid record as given.
# =============================================================================
def test_record_copy_keeps_unknown_op_tag() raises:
    """Tags below INSERT, just above REMOVE and far above it are copied
    unchanged with the key, both images and the sequence number; the copy is
    still unknown to the predicates and to validate()."""
    var tags = List[Int]()
    tags.append(-1)
    tags.append(3)
    tags.append(5)
    tags.append(1000)
    for i in range(len(tags)):
        var c = _rec(tags[i], _one(1), _one(2), _one(3)).copy()
        assert_equal(c.op, tags[i])
        assert_equal(len(c.key), 1)
        assert_equal(len(c.new_image), 1)
        assert_equal(len(c.old_image), 1)
        assert_equal(c.key[0].as_long(), 1)
        assert_equal(c.new_image[0].as_long(), 2)
        assert_equal(c.old_image[0].as_long(), 3)
        assert_equal(c.sequence_number, String("seq-1"))
        assert_equal(c.op_name(), String("UNKNOWN"))
        assert_false(c.is_insert())
        assert_false(c.is_modify())
        assert_false(c.is_remove())
        assert_equal(
            _validate_error(c), String(_P) + "unknown op tag " + String(tags[i])
        )


def test_record_copy_keeps_stray_images() raises:
    """An image the op does not use is copied, not dropped: the copy fails
    validate() exactly as the original does."""
    var ins = _rec(CDC_OP_INSERT, _one(1), _one(2), _one(3)).copy()
    assert_equal(len(ins.old_image), 1)
    assert_equal(ins.old_image[0].as_long(), 3)
    assert_equal(
        _validate_error(ins), String(_P) + "INSERT with non-empty old_image"
    )
    var rem = _rec(CDC_OP_REMOVE, _one(1), _one(2), _one(3)).copy()
    assert_equal(len(rem.new_image), 1)
    assert_equal(rem.new_image[0].as_long(), 2)
    assert_equal(
        _validate_error(rem), String(_P) + "REMOVE with non-empty new_image"
    )
    var keyless = _rec(CDC_OP_INSERT, _none(), _one(2), _none()).copy()
    assert_equal(len(keyless.key), 0)
    assert_equal(len(keyless.new_image), 1)
    assert_equal(keyless.new_image[0].as_long(), 2)
    assert_equal(len(keyless.old_image), 0)
    assert_equal(_validate_error(keyless), String(_KEY_EMPTY))


# =============================================================================
# (7) every field of every kind of record survives a copy.
# =============================================================================
def _assert_same_cells(
    got: List[RowCell], want: List[RowCell], what: String
) raises:
    """Same length and, cell by cell, the same value in every RowCell field
    (type tag, integral, floating, string and null flag), not only the arm
    `equals` compares."""
    assert_equal(len(got), len(want), msg=what + " length")
    for i in range(len(want)):
        var at = what + "[" + String(i) + "]"
        assert_equal(got[i].type_tag, want[i].type_tag, msg=at + " type_tag")
        assert_equal(got[i].i, want[i].i, msg=at + " i")
        assert_equal(got[i].f, want[i].f, msg=at + " f")
        assert_equal(got[i].s, want[i].s, msg=at + " s")
        assert_equal(got[i].null, want[i].null, msg=at + " null")
        assert_true(got[i].equals(want[i]), msg=at + " equals")


def _assert_same_record(
    got: ChangeRecord, want: ChangeRecord, what: String
) raises:
    """Every field of ChangeRecord: op, key, new_image, old_image and
    sequence_number."""
    assert_equal(got.op, want.op, msg=what + " op")
    _assert_same_cells(got.key, want.key, what + " key")
    _assert_same_cells(got.new_image, want.new_image, what + " new_image")
    _assert_same_cells(got.old_image, want.old_image, what + " old_image")
    assert_equal(
        got.sequence_number, want.sequence_number, msg=what + " sequence"
    )


def _assert_same_batch(
    got: ChangeBatch, want: ChangeBatch, what: String
) raises:
    """Every field of ChangeBatch: each record, next_cursor and exhausted."""
    assert_equal(len(got.records), len(want.records), msg=what + " records")
    for i in range(len(want.records)):
        _assert_same_record(
            got.records[i], want.records[i], what + " record " + String(i)
        )
    assert_equal(got.next_cursor, want.next_cursor, msg=what + " cursor")
    assert_equal(got.exhausted, want.exhausted, msg=what + " exhausted")


def _cells(seed: Int64, n: Int) -> List[RowCell]:
    """`n` cells (at most 5) of different types, each value derived from
    `seed`: long, string, double, boolean, null long. Distinct seeds give
    every list of a record different values, so a copy that takes one list
    from another goes red."""
    var out = List[RowCell]()
    if n > 0:
        out.append(make_long_cell(seed))
    if n > 1:
        out.append(make_string_cell(String("c") + String(seed)))
    if n > 2:
        out.append(make_double_cell(Float64(seed) + 0.5))
    if n > 3:
        out.append(make_boolean_cell(seed % 2 == 1))
    if n > 4:
        out.append(make_null_cell(CELL_T_LONG))
    return out^


def _fixture(
    op: Int, nk: Int, nn: Int, no: Int, base: Int64, var seq: String
) -> ChangeRecord:
    """A record with `nk` key cells, `nn` new-image cells and `no` old-image
    cells; the three lists use seeds `base`, `base + 100` and `base + 200`."""
    return ChangeRecord(
        op, _cells(base, nk), _cells(base + 100, nn), _cells(base + 200, no),
        seq^,
    )


def _fixtures(mut labels: List[String]) -> List[ChangeRecord]:
    """One record per kind the copy could treat differently. Each has its own
    sequence number, so a copy that takes it from another record goes red."""
    var r = List[ChangeRecord]()
    # valid records, one-cell and multi-cell
    labels.append("valid INSERT")
    r.append(_fixture(CDC_OP_INSERT, 1, 3, 0, 1, String("s-ins")))
    labels.append("valid MODIFY")
    r.append(_fixture(CDC_OP_MODIFY, 2, 5, 4, 2, String("s-mod")))
    labels.append("valid REMOVE")
    r.append(_fixture(CDC_OP_REMOVE, 1, 0, 5, 3, String("s-rem")))
    labels.append("three-cell INSERT")
    r.append(_fixture(CDC_OP_INSERT, 3, 3, 0, 4, String("s-ins3")))
    labels.append("three-cell MODIFY")
    r.append(_fixture(CDC_OP_MODIFY, 3, 3, 3, 5, String("s-mod3")))
    labels.append("three-cell REMOVE")
    r.append(_fixture(CDC_OP_REMOVE, 3, 0, 3, 6, String("s-rem3")))
    # unknown op tags, every list present
    var tags = List[Int]()
    tags.append(-1)
    tags.append(3)
    tags.append(5)
    tags.append(1000)
    for i in range(len(tags)):
        labels.append(String("unknown tag ") + String(tags[i]))
        r.append(
            _fixture(
                tags[i], 2, 3, 3, Int64(10 + i), String("s-u") + String(tags[i])
            )
        )
    # stray images
    labels.append("INSERT with stray old_image")
    r.append(_fixture(CDC_OP_INSERT, 1, 2, 3, 20, String("s-sins")))
    labels.append("REMOVE with stray new_image")
    r.append(_fixture(CDC_OP_REMOVE, 1, 3, 2, 21, String("s-srem")))
    # keyless, every op and an unknown tag
    labels.append("keyless INSERT")
    r.append(_fixture(CDC_OP_INSERT, 0, 2, 0, 30, String("s-kins")))
    labels.append("keyless MODIFY")
    r.append(_fixture(CDC_OP_MODIFY, 0, 2, 3, 31, String("s-kmod")))
    labels.append("keyless REMOVE")
    r.append(_fixture(CDC_OP_REMOVE, 0, 0, 3, 32, String("s-krem")))
    labels.append("keyless unknown tag 7")
    r.append(_fixture(7, 0, 3, 2, 33, String("s-kunk")))
    # empty images, every op and an unknown tag
    labels.append("INSERT with no images")
    r.append(_fixture(CDC_OP_INSERT, 2, 0, 0, 40, String("s-eins")))
    labels.append("MODIFY with no images")
    r.append(_fixture(CDC_OP_MODIFY, 2, 0, 0, 41, String("s-emod")))
    labels.append("REMOVE with no images")
    r.append(_fixture(CDC_OP_REMOVE, 2, 0, 0, 42, String("s-erem")))
    labels.append("unknown tag 4 with no images")
    r.append(_fixture(4, 2, 0, 0, 43, String("s-eunk")))
    # nothing at all: no key, no images, empty sequence number
    labels.append("all empty")
    r.append(_fixture(CDC_OP_INSERT, 0, 0, 0, 50, String("")))
    return r^


def test_record_copy_equals_original_for_every_kind() raises:
    var labels = List[String]()
    var recs = _fixtures(labels)
    assert_equal(len(recs), 21)
    for i in range(len(recs)):
        var c = recs[i].copy()
        _assert_same_record(c, recs[i], labels[i])
        # The copy owns its lists: growing the copy leaves the original as
        # built, and the original still equals a fresh build of the fixture.
        c.key.append(make_long_cell(-9))
        c.new_image.append(make_long_cell(-9))
        c.old_image.append(make_long_cell(-9))
        c.sequence_number = String("changed")
    var labels2 = List[String]()
    var again = _fixtures(labels2)
    for i in range(len(recs)):
        _assert_same_record(recs[i], again[i], labels[i] + " (original)")


def test_batch_copy_equals_original_for_every_kind() raises:
    """A batch holding every fixture, under each flag/cursor combination, and
    the two empty batches the constructors make."""
    var cursors = List[String]()
    cursors.append(String("iter-live"))
    cursors.append(String(""))
    for ci in range(len(cursors)):
        for flag in range(2):
            var labels = List[String]()
            var b = ChangeBatch(
                _fixtures(labels), String(cursors[ci]), flag == 1
            )
            var what = String("batch cursor '") + cursors[ci] + "' exhausted "
            what += String(flag)
            _assert_same_batch(b.copy(), b, what)
    _assert_same_batch(
        ChangeBatch.empty_live(String("tok")).copy(),
        ChangeBatch.empty_live(String("tok")),
        String("empty_live"),
    )
    _assert_same_batch(
        ChangeBatch.end_of_segment().copy(),
        ChangeBatch.end_of_segment(),
        String("end_of_segment"),
    )


# =============================================================================
# (8) validate() over every kind of record.
# =============================================================================
def _expected_fault(op: Int, nk: Int, nn: Int, no: Int) -> String:
    """The message validate() must give a record with `nk` key cells, `nn`
    new-image cells and `no` old-image cells, from the ChangeRecord
    invariants in the order validate() documents: the key is non-empty
    (checked first, for every op and tag); INSERT has a new image and no old
    image (missing new reported first); MODIFY has both (new first); REMOVE
    has an old image and no new image (missing old first); any other tag is
    unknown. "" when the record is valid."""
    if nk == 0:
        return String(_KEY_EMPTY)
    if op == CDC_OP_INSERT:
        if nn == 0:
            return String(_P) + "INSERT with empty new_image"
        if no != 0:
            return String(_P) + "INSERT with non-empty old_image"
        return String("")
    if op == CDC_OP_MODIFY:
        if nn == 0:
            return String(_P) + "MODIFY with empty new_image"
        if no == 0:
            return String(_P) + "MODIFY with empty old_image"
        return String("")
    if op == CDC_OP_REMOVE:
        if no == 0:
            return String(_P) + "REMOVE with empty old_image"
        if nn != 0:
            return String(_P) + "REMOVE with non-empty new_image"
        return String("")
    return String(_P) + "unknown op tag " + String(op)


def _validate_fixtures(mut labels: List[String]) -> List[ChangeRecord]:
    """The group (7) fixtures, then the records they do not cover: a keyless
    unknown tag below INSERT, each image fault and each valid op under a
    two-cell key."""
    var r = _fixtures(labels)
    labels.append("keyless unknown tag -1")
    r.append(_fixture(-1, 0, 2, 2, 60, String("s-kneg")))
    labels.append("two-cell-key INSERT with stray old_image")
    r.append(_fixture(CDC_OP_INSERT, 2, 1, 1, 61, String("s-2sins")))
    labels.append("two-cell-key REMOVE with stray new_image")
    r.append(_fixture(CDC_OP_REMOVE, 2, 1, 1, 62, String("s-2srem")))
    labels.append("two-cell-key MODIFY without old_image")
    r.append(_fixture(CDC_OP_MODIFY, 2, 1, 0, 63, String("s-2nmod")))
    labels.append("two-cell-key valid INSERT")
    r.append(_fixture(CDC_OP_INSERT, 2, 1, 0, 64, String("s-2ins")))
    labels.append("two-cell-key valid MODIFY")
    r.append(_fixture(CDC_OP_MODIFY, 2, 1, 1, 65, String("s-2mod")))
    labels.append("two-cell-key valid REMOVE")
    r.append(_fixture(CDC_OP_REMOVE, 2, 0, 1, 66, String("s-2rem")))
    return r^


def test_validate_every_kind_exact_message() raises:
    var labels = List[String]()
    var recs = _validate_fixtures(labels)
    assert_equal(len(recs), 28)
    assert_equal(len(labels), 28)
    # The fixtures cover every outcome: valid, the key fault, each of the six
    # image faults and an unknown tag.
    var want_valid = 0
    var want_key = 0
    for i in range(len(recs)):
        var want = _expected_fault(
            recs[i].op,
            len(recs[i].key),
            len(recs[i].new_image),
            len(recs[i].old_image),
        )
        if want == String(""):
            want_valid += 1
        elif want == String(_KEY_EMPTY):
            want_key += 1
        assert_equal(_validate_error(recs[i]), want, msg=labels[i])
    assert_equal(want_valid, 9)
    assert_equal(want_key, 6)
    # The derivation itself, pinned per fixture so a wrong `_expected_fault`
    # cannot hide a wrong validate(): one expected message per label.
    var table = List[String]()
    table.append(String(""))  # valid INSERT
    table.append(String(""))  # valid MODIFY
    table.append(String(""))  # valid REMOVE
    table.append(String(""))  # three-cell INSERT
    table.append(String(""))  # three-cell MODIFY
    table.append(String(""))  # three-cell REMOVE
    table.append(String(_P) + "unknown op tag -1")
    table.append(String(_P) + "unknown op tag 3")
    table.append(String(_P) + "unknown op tag 5")
    table.append(String(_P) + "unknown op tag 1000")
    table.append(String(_P) + "INSERT with non-empty old_image")
    table.append(String(_P) + "REMOVE with non-empty new_image")
    table.append(String(_KEY_EMPTY))  # keyless INSERT
    table.append(String(_KEY_EMPTY))  # keyless MODIFY, both images present
    table.append(String(_KEY_EMPTY))  # keyless REMOVE
    table.append(String(_KEY_EMPTY))  # keyless unknown tag 7
    table.append(String(_P) + "INSERT with empty new_image")
    table.append(String(_P) + "MODIFY with empty new_image")
    table.append(String(_P) + "REMOVE with empty old_image")
    table.append(String(_P) + "unknown op tag 4")
    table.append(String(_KEY_EMPTY))  # all empty
    table.append(String(_KEY_EMPTY))  # keyless unknown tag -1
    table.append(String(_P) + "INSERT with non-empty old_image")
    table.append(String(_P) + "REMOVE with non-empty new_image")
    table.append(String(_P) + "MODIFY with empty old_image")
    table.append(String(""))  # two-cell-key valid INSERT
    table.append(String(""))  # two-cell-key valid MODIFY
    table.append(String(""))  # two-cell-key valid REMOVE
    assert_equal(len(table), len(recs))
    for i in range(len(recs)):
        assert_equal(_validate_error(recs[i]), table[i], msg=labels[i])


def test_validate_shape_grid() raises:
    """Every op, an unknown tag below INSERT and two above REMOVE, and key,
    new_image and old_image lengths 0, 1 and 2 each: 162 records, each with
    the message `_expected_fault` derives. Every list a check could read
    spans 0, 1 and 2 cells, so a check skipped when another list (the key or
    the other image) holds a given length goes red, not only one skipped for
    the list it checks. The per-outcome counts are worked out by hand from
    the invariants, so a wrong `_expected_fault` goes red here too."""
    var ops = List[Int]()
    ops.append(-1)
    ops.append(CDC_OP_INSERT)
    ops.append(CDC_OP_MODIFY)
    ops.append(CDC_OP_REMOVE)
    ops.append(3)
    ops.append(1000)
    var outcomes = List[String]()
    var counts = List[Int]()
    var n = 0
    for oi in range(len(ops)):
        for nk in range(3):
            for nn in range(3):
                for no in range(3):
                    var rec = _fixture(
                        ops[oi], nk, nn, no, Int64(70 + n), String("s-g")
                    )
                    var want = _expected_fault(ops[oi], nk, nn, no)
                    var what = (
                        String("grid op ") + String(ops[oi]) + " key "
                        + String(nk) + " new " + String(nn) + " old "
                        + String(no)
                    )
                    assert_equal(_validate_error(rec), want, msg=what)
                    n += 1
                    var found = False
                    for j in range(len(outcomes)):
                        if outcomes[j] == want:
                            counts[j] += 1
                            found = True
                    if not found:
                        outcomes.append(want)
                        counts.append(1)
    assert_equal(n, 162)
    # Hand count, 9 image shapes per op and key length: any keyless record
    # (6 tags x 9) is the key fault. With a key (2 lengths): INSERT reports
    # a missing new image for the 3 old lengths, is valid with new 1 or 2 and
    # no old (2 shapes), and has a stray old image otherwise (4 shapes);
    # MODIFY reports a missing new image for the 3 old lengths, a missing old
    # image for new 1 or 2 (2 shapes), and is valid otherwise (4 shapes);
    # REMOVE reports a missing old image for the 3 new lengths, is valid with
    # old 1 or 2 and no new (2 shapes), and has a stray new image otherwise
    # (4 shapes); each unknown tag is the tag fault for all 9 shapes.
    var want_out = List[String]()
    var want_cnt = List[Int]()
    want_out.append(String(_KEY_EMPTY))
    want_cnt.append(54)
    want_out.append(String(""))
    want_cnt.append(16)
    want_out.append(String(_P) + "INSERT with empty new_image")
    want_cnt.append(6)
    want_out.append(String(_P) + "INSERT with non-empty old_image")
    want_cnt.append(8)
    want_out.append(String(_P) + "MODIFY with empty new_image")
    want_cnt.append(6)
    want_out.append(String(_P) + "MODIFY with empty old_image")
    want_cnt.append(4)
    want_out.append(String(_P) + "REMOVE with empty old_image")
    want_cnt.append(6)
    want_out.append(String(_P) + "REMOVE with non-empty new_image")
    want_cnt.append(8)
    want_out.append(String(_P) + "unknown op tag -1")
    want_cnt.append(18)
    want_out.append(String(_P) + "unknown op tag 3")
    want_cnt.append(18)
    want_out.append(String(_P) + "unknown op tag 1000")
    want_cnt.append(18)
    var total = 0
    for i in range(len(want_cnt)):
        total += want_cnt[i]
    assert_equal(total, 162)
    assert_equal(len(outcomes), len(want_out))
    for i in range(len(want_out)):
        var got = 0
        for j in range(len(outcomes)):
            if outcomes[j] == want_out[i]:
                got = counts[j]
        assert_equal(got, want_cnt[i], msg=want_out[i])


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
    test_record_copy_keeps_unknown_op_tag()
    test_record_copy_keeps_stray_images()
    test_record_copy_equals_original_for_every_kind()
    test_batch_copy_equals_original_for_every_kind()
    test_validate_every_kind_exact_message()
    test_validate_shape_grid()
    print("test_change_record_validate: ALL PASS")
