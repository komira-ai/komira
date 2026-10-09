# =============================================================================
# komira_chat_proto/tests/test_chat_enum_numbers.mojo
#   Every komira.chat.v1 enum value's number and JSON name.
# =============================================================================
#
# An enum value is sent as its number in protobuf binary and as its name in
# JSON. The goldens use one value of each enum, so a renumbered value they do
# not use, or a renamed one, would pass them; this test names every value by
# its number literal (not the generated constant, which moves with the
# `.proto`). A number with no value renders as its decimal text, so the
# number after the last value is pinned too: a value added with that number
# fails it.
# =============================================================================

from std.testing import TestSuite, assert_equal

from komira_chat_proto.chat import ChannelKind, EventKind, FileState


def test_channel_kind() raises:
    assert_equal(ChannelKind(0).json_name(), "CHANNEL_KIND_UNSPECIFIED")
    assert_equal(ChannelKind(1).json_name(), "CHANNEL_KIND_PUBLIC")
    assert_equal(ChannelKind(2).json_name(), "CHANNEL_KIND_PRIVATE")
    assert_equal(ChannelKind(3).json_name(), "CHANNEL_KIND_DM")
    assert_equal(ChannelKind(4).json_name(), "4")


def test_event_kind() raises:
    assert_equal(EventKind(0).json_name(), "EVENT_KIND_UNSPECIFIED")
    assert_equal(EventKind(1).json_name(), "EVENT_KIND_MESSAGE")
    assert_equal(EventKind(2).json_name(), "EVENT_KIND_EDIT")
    assert_equal(EventKind(3).json_name(), "EVENT_KIND_DELETE")
    assert_equal(EventKind(4).json_name(), "EVENT_KIND_JOIN")
    assert_equal(EventKind(5).json_name(), "EVENT_KIND_LEAVE")
    assert_equal(EventKind(6).json_name(), "6")


def test_file_state() raises:
    assert_equal(FileState(0).json_name(), "FILE_STATE_UNSPECIFIED")
    assert_equal(FileState(1).json_name(), "FILE_STATE_PENDING")
    assert_equal(FileState(2).json_name(), "FILE_STATE_COMPLETE")
    assert_equal(FileState(3).json_name(), "3")


def main() raises:
    var suite = TestSuite()
    suite.test[test_channel_kind]()
    suite.test[test_event_kind]()
    suite.test[test_file_state]()
    suite^.run()
