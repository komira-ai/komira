# The streaming probe's lever witnesses (`join_probe_levers`): the buffer
# reuse setting (off unless configured, and its reset), the share and buffer
# counters, the clause `join_key_share_why` names for every counter shape, and
# the witness line's text.

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_op_join_probe.join_defer_verdict import reset_defer_verdict_counters
from komira_op_join_probe.join_probe_levers import (
    join_key_share_declined_type_count,
    join_key_share_declined_validity_count,
    join_key_share_note_declined,
    join_key_share_note_shared,
    join_key_share_shared_count,
    join_key_share_why,
    join_probe_buf_fresh_count,
    join_probe_buf_note,
    join_probe_buf_reuse_configure,
    join_probe_buf_reuse_count,
    join_probe_buf_reuse_enabled,
    join_probe_buf_reuse_reset_config,
    join_probe_levers_line,
    reset_join_probe_lever_counters,
)


def test_buffer_reuse_setting() raises:
    join_probe_buf_reuse_reset_config()
    assert_false(join_probe_buf_reuse_enabled(), "off unless configured")
    join_probe_buf_reuse_configure(True)
    assert_true(join_probe_buf_reuse_enabled(), "configured on")
    join_probe_buf_reuse_configure(False)
    assert_false(join_probe_buf_reuse_enabled(), "configured off")
    join_probe_buf_reuse_reset_config()


def test_counters_attribute_each_event() raises:
    reset_join_probe_lever_counters()
    join_key_share_note_shared()
    join_key_share_note_shared()
    join_key_share_note_declined(True)
    join_key_share_note_declined(False)
    join_key_share_note_declined(False)
    join_probe_buf_note(True)
    join_probe_buf_note(False)
    join_probe_buf_note(False)
    assert_equal(join_key_share_shared_count(), 2)
    assert_equal(join_key_share_declined_validity_count(), 1)
    assert_equal(join_key_share_declined_type_count(), 2)
    assert_equal(join_probe_buf_reuse_count(), 1)
    assert_equal(join_probe_buf_fresh_count(), 2)
    reset_join_probe_lever_counters()
    assert_equal(join_key_share_shared_count(), 0, "reset")
    assert_equal(join_probe_buf_fresh_count(), 0, "reset")


def test_why_names_the_deciding_clause() raises:
    assert_equal(String(join_key_share_why(0, 0, 0)), "unreached")
    assert_equal(String(join_key_share_why(5, 0, 0)), "shared_all")
    assert_equal(String(join_key_share_why(5, 1, 0)), "mixed")
    assert_equal(String(join_key_share_why(0, 2, 3)), "declined_both")
    assert_equal(String(join_key_share_why(0, 2, 0)), "validity")
    assert_equal(String(join_key_share_why(0, 0, 3)), "type")


def test_witness_line_text() raises:
    reset_join_probe_lever_counters()
    reset_defer_verdict_counters()
    join_probe_buf_reuse_reset_config()
    join_key_share_note_shared()
    var line = join_probe_levers_line("unit")
    assert_true(line.startswith("[JOIN_PROBE_LEVERS] at=unit share=1"), line)
    assert_true(line.find(" why=shared_all ") >= 0, line)
    assert_true(line.find(" buf_reuse=0 ") >= 0, line)
    assert_true(line.find(" defer_why=unreached") >= 0, line)
    reset_join_probe_lever_counters()


def main() raises:
    var suite = TestSuite()
    suite.test[test_buffer_reuse_setting]()
    suite.test[test_counters_attribute_each_event]()
    suite.test[test_why_names_the_deciding_clause]()
    suite.test[test_witness_line_text]()
    suite^.run()
