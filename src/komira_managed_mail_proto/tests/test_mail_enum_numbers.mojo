# =============================================================================
# komira_managed_mail_proto/tests/test_mail_enum_numbers.mojo
#   Every komira.managed_mail.v1 enum value's number and JSON name.
# =============================================================================
#
# An enum value is sent as its number in protobuf binary and as its name in
# JSON. The goldens use a few values of each enum, so a renumbered value they
# do not use, or a renamed one, would pass them; this test names every value
# by its number literal (not the generated constant, which moves with the
# `.proto`). A number with no value renders as its decimal text, so the
# number after the last value is pinned too: a value added with that number
# fails it.
# =============================================================================

from std.testing import TestSuite, assert_equal

from komira_managed_mail_proto.mail import Folder, MailboxKind, SubmissionState


def test_mailbox_kind() raises:
    assert_equal(MailboxKind(0).json_name(), "MAILBOX_KIND_UNSPECIFIED")
    assert_equal(MailboxKind(1).json_name(), "MAILBOX_KIND_PERSONAL")
    assert_equal(MailboxKind(2).json_name(), "MAILBOX_KIND_SHARED")
    assert_equal(MailboxKind(3).json_name(), "3")


def test_folder() raises:
    assert_equal(Folder(0).json_name(), "FOLDER_UNSPECIFIED")
    assert_equal(Folder(1).json_name(), "FOLDER_INBOX")
    assert_equal(Folder(2).json_name(), "FOLDER_SENT")
    assert_equal(Folder(3).json_name(), "FOLDER_ARCHIVE")
    assert_equal(Folder(4).json_name(), "FOLDER_TRASH")
    assert_equal(Folder(5).json_name(), "5")


def test_submission_state() raises:
    assert_equal(SubmissionState(0).json_name(), "SUBMISSION_STATE_UNSPECIFIED")
    assert_equal(SubmissionState(1).json_name(), "SUBMISSION_STATE_QUEUED")
    assert_equal(SubmissionState(2).json_name(), "SUBMISSION_STATE_SENT")
    assert_equal(SubmissionState(3).json_name(), "SUBMISSION_STATE_FAILED")
    assert_equal(SubmissionState(4).json_name(), "4")


def main() raises:
    var suite = TestSuite()
    suite.test[test_mailbox_kind]()
    suite.test[test_folder]()
    suite.test[test_submission_state]()
    suite^.run()
