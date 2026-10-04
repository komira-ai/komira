# =============================================================================
# src/kci_publish/tests/test_publish_channel_state.mojo -- contract step 1:
#   the channel is read by DOWNLOAD before anything is written, and what it
#   holds decides whether the run may write at all.
# =============================================================================
#
# ROWS
#   (1) classification by download: our bytes = present-same, other bytes =
#       present-different, no file = absent -- and a repodata entry naming a
#       file that is not there is ABSENT, not present;
#   (2) one file present with other bytes: STOP_DIFFERENT_BYTES, REFUSED
#       (exit 3: nothing of this run landed) with ZERO write requests,
#       naming the file, and the credential never asked;
#   (3) a set name the channel has never held is REPORTED as new, never
#       refused: the run proceeds and publishes it; a name the channel holds
#       (any older file of it) is not reported; the same report under a dry
#       run, with zero writes; a STOP for other bytes still reports them;
#   (4) every file present and identical: ALREADY_PUBLISHED, NOOP, EXIT 0
#       (the end state holds: not a red job), zero writes;
#   (5) a name listing that cannot be read (noarch answers 503):
#       INDETERMINATE (exit 5), and no name is reported new (the names are
#       not known); a file read that cannot be answered: exit 5, likewise;
#   (6) a set file the DOWNLOAD finds but no listing names yet (the index
#       lags) makes its name HELD: it is not reported new, and when every
#       file is so, the run is ALREADY_PUBLISHED;
#   (7) the SAME COMMAND run again: after a publish it is ALREADY_PUBLISHED
#       (exit 0 both times) and reports no new name (its own uploads hold
#       them, by download), and after a partial publish (exit 6) it resumes
#       and ends 0 without re-uploading what landed -- with the index caught
#       up AND while it still lags, so the verdict does not depend on index
#       timing.
#
# Hermetic: ScriptedChannel; no network.
# =============================================================================

from std.ffi import external_call
from std.os import getenv, makedirs
from std.testing import assert_equal, assert_false, assert_true

from kci_api import EXIT_CANNOT_TELL, EXIT_OK, EXIT_PARTIAL, EXIT_REFUSED
from kci_pkg_upload import SURFACE_PREFIX_DEV, RegistrySet, ScriptedCredential
from kci_publish import (
    NoWaitSleeper,
    REASON_ALREADY_PUBLISHED,
    REASON_CANNOT_TELL,
    REASON_PARTIAL,
    REASON_PUBLISHED,
    REASON_STOP_DIFFERENT_BYTES,
    STATE_ABSENT,
    STATE_DIFFERENT,
    STATE_SAME,
    PublishCredential,
    PublishReport,
    PublishTarget,
    RunOptions,
    ScriptedChannel,
    read_channel,
    run_publish,
)
from kci_publish.release_fixture import EXAMPLE_HOST, ExampleRelease, example_channel_path, example_targets
from kci_publish.scripted_channel import UPLOAD_LOSE_NOT_STORED

def _ends(rep: PublishReport, reason: String, exit_code: Int, msg: String = String("")) raises:
    """`rep` stopped for `reason`, and its exit number (kci_api's) is
    `exit_code`."""
    assert_equal(rep.reason, reason, msg)
    assert_equal(rep.exit_code(), exit_code, msg)



def _root(tag: String) raises -> String:
    var base = getenv("TEST_TMPDIR")
    if base.byte_length() == 0:
        base = getenv("TMPDIR")
    if base.byte_length() == 0:
        raise Error("neither TEST_TMPDIR nor TMPDIR is set")
    var d = base + String("/pcs_") + tag + String("_") + String(Int(external_call["getpid", Int32]()))
    makedirs(d, exist_ok=True)
    return d^


def _bytes(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    var b = s.as_bytes()
    for i in range(len(b)):
        out.append(b[i])
    return out^


def _targets(tag: String) raises -> List[PublishTarget]:
    var r = ExampleRelease()
    var d = _root(tag)
    r.write(d)
    return example_targets(r, d)


def _channel() raises -> ScriptedChannel:
    return ScriptedChannel(String(EXAMPLE_HOST), example_channel_path(String("example-stable")), String("linux-64"))


def _seed_names(mut ch: ScriptedChannel):
    """An older release of every set name: the names exist, our files do not."""
    ch.put(String("linux-64"), String("komira_alpha-0.9.0-h00000000_1.conda"), _bytes(String("old a")))
    ch.put(String("linux-64"), String("komira_beta-0.9.0-h00000000_1.conda"), _bytes(String("old b")))
    ch.put(String("linux-64"), String("komira-0.9.0-h00000000_1.conda"), _bytes(String("old m")))


def _registry(var ch: ScriptedChannel) -> RegistrySet[ScriptedChannel, PublishCredential]:
    var c = PublishCredential()
    c.configure(SURFACE_PREFIX_DEV, String(EXAMPLE_HOST), String(""))
    return RegistrySet[ScriptedChannel, PublishCredential](ch^, c^)


def _run(
    targets: List[PublishTarget],
    mut reg: RegistrySet[ScriptedChannel, PublishCredential],
    mut src: ScriptedCredential,
    plan: Bool = False,
) -> PublishReport:
    var sl = NoWaitSleeper()
    return run_publish(targets, reg, src, plan, RunOptions(2, 0, 2, 0, 0, 1, 0), sl, PublishReport())


def _names(rep: PublishReport) -> String:
    return String(",").join(rep.new_names)


def _src() -> ScriptedCredential:
    var s = ScriptedCredential()
    s.serve(SURFACE_PREFIX_DEV, String("Bearer pfx-test-token"))
    return s^


def test_classification_by_download() raises:
    var t = _targets(String("classify"))
    var ch = _channel()
    ch.put(String("linux-64"), t[0].coordinate.file_name, _bytes(String("alpha conda bytes")))
    ch.put(String("linux-64"), t[1].coordinate.file_name, _bytes(String("not beta's bytes")))
    ch.list_without_file(String("linux-64"), t[2].coordinate.file_name, t[2].sha256_hex.copy())
    var reg = _registry(ch^)
    var channel_read = read_channel(reg, t)
    assert_equal(channel_read.states[0].kind, STATE_SAME)
    assert_equal(channel_read.states[1].kind, STATE_DIFFERENT)
    assert_equal(channel_read.states[2].kind, STATE_ABSENT, String("a repodata entry with no file behind it is not present"))
    assert_true(channel_read.names_read)
    assert_true(channel_read.holds_name(String("komira")))
    print("  test_classification_by_download: PASS")


def test_one_different_file_stops_with_zero_writes() raises:
    var t = _targets(String("diff"))
    var ch = _channel()
    _seed_names(ch)
    ch.put(String("linux-64"), t[2].coordinate.file_name, _bytes(String("someone else's metapackage")))
    var reg = _registry(ch^)
    var src = _src()
    var rep = _run(t, reg, src)
    _ends(rep, String(REASON_STOP_DIFFERENT_BYTES), EXIT_REFUSED)
    assert_true(rep.has_line_containing(String("STOP different bytes: linux-64/") + t[2].coordinate.file_name))
    # the names were read: every set name is held, so none is new
    assert_true(rep.names_known)
    assert_equal(_names(rep), String(""))
    assert_equal(reg.transport().write_count(), 0)
    assert_equal(src.asked_count(), 0)
    print("  test_one_different_file_stops_with_zero_writes: PASS")


def test_new_names_are_reported_never_refused() raises:
    var t = _targets(String("names"))
    # a fresh channel: every name is new, and the run publishes them all
    var reg = _registry(_channel())
    var src = _src()
    var rep = _run(t, reg, src)
    _ends(rep, String(REASON_PUBLISHED), EXIT_OK, String("\n").join(rep.lines))
    assert_true(rep.names_known)
    assert_equal(_names(rep), String("komira_alpha,komira_beta,komira"))
    assert_true(rep.has_line_containing(String("NEW NAME 'komira': the channel holds no file of it yet")))
    assert_true(reg.transport().holds(String("linux-64"), t[2].coordinate.file_name))
    # a channel holding older files of both libraries, and none of the
    # metapackage: only the metapackage is new, and the run proceeds
    var ch2 = _channel()
    ch2.put(String("linux-64"), String("komira_alpha-0.9.0-h00000000_1.conda"), _bytes(String("old a")))
    ch2.put(String("linux-64"), String("komira_beta-0.9.0-h00000000_1.conda"), _bytes(String("old b")))
    var reg2 = _registry(ch2^)
    var rep2 = _run(t, reg2, src)
    _ends(rep2, String(REASON_PUBLISHED), EXIT_OK, String("\n").join(rep2.lines))
    assert_equal(_names(rep2), String("komira"))
    assert_false(rep2.has_line_containing(String("NEW NAME 'komira_alpha'")))
    # the same channel under a dry run: the same report, and nothing written
    var ch3 = _channel()
    ch3.put(String("linux-64"), String("komira_alpha-0.9.0-h00000000_1.conda"), _bytes(String("old a")))
    ch3.put(String("linux-64"), String("komira_beta-0.9.0-h00000000_1.conda"), _bytes(String("old b")))
    var reg3 = _registry(ch3^)
    var src3 = _src()
    var rep3 = _run(t, reg3, src3, True)
    _ends(rep3, String(REASON_PUBLISHED), EXIT_OK, String("\n").join(rep3.lines))
    assert_equal(_names(rep3), String("komira"))
    assert_equal(reg3.transport().write_count(), 0)
    assert_equal(src3.asked_count(), 0)
    print("  test_new_names_are_reported_never_refused: PASS")


def test_all_identical_is_already_published() raises:
    var t = _targets(String("same"))
    var ch = _channel()
    ch.put(String("linux-64"), t[0].coordinate.file_name, _bytes(String("alpha conda bytes")))
    ch.put(String("linux-64"), t[1].coordinate.file_name, _bytes(String("beta conda bytes")))
    ch.put(String("linux-64"), t[2].coordinate.file_name, _bytes(String("meta conda bytes")))
    var reg = _registry(ch^)
    var src = _src()
    var rep = _run(t, reg, src)
    # NOOP, exit 0: the end state holds; there is no second "green" number
    _ends(rep, String(REASON_ALREADY_PUBLISHED), EXIT_OK)
    assert_equal(rep.outcome(), String("NOOP"))
    assert_true(rep.ok())
    assert_true(rep.has_line_containing(String("already published")))
    assert_equal(reg.transport().write_count(), 0)
    assert_equal(src.asked_count(), 0)
    print("  test_all_identical_is_already_published: PASS")


def test_an_unread_listing_is_cannot_tell_never_new() raises:
    var t = _targets(String("unread"))
    var ch = _channel()
    ch.fail_listing(String("noarch"))
    var reg = _registry(ch^)
    var src = _src()
    var rep = _run(t, reg, src)
    _ends(rep, String(REASON_CANNOT_TELL), EXIT_CANNOT_TELL)
    assert_true(rep.has_line_containing(String("CANNOT TELL which names the channel holds: noarch")))
    # an unread listing never makes a name new
    assert_false(rep.names_known)
    assert_equal(len(rep.new_names), 0)
    assert_false(rep.has_line_containing(String("NEW NAME")))
    assert_equal(reg.transport().write_count(), 0)

    var ch2 = _channel()
    _seed_names(ch2)
    ch2.fail_fetch_once(String("linux-64"), t[1].coordinate.file_name)
    var reg2 = _registry(ch2^)
    var rep2 = _run(t, reg2, src)
    _ends(rep2, String(REASON_CANNOT_TELL), EXIT_CANNOT_TELL)
    assert_true(rep2.has_line_containing(String("CANNOT TELL linux-64/") + t[1].coordinate.file_name))
    assert_false(rep2.names_known)
    assert_equal(len(rep2.new_names), 0)
    assert_equal(reg2.transport().write_count(), 0)
    print("  test_an_unread_listing_is_cannot_tell_never_new: PASS")


def test_a_file_found_by_download_but_not_listed_holds_its_name() raises:
    var t = _targets(String("unlisted"))
    var src = _src()
    # every file ours, present-same by download, none listed: NOOP, no new name
    var ch = _channel()
    ch.put_unlisted(String("linux-64"), t[0].coordinate.file_name, _bytes(String("alpha conda bytes")))
    ch.put_unlisted(String("linux-64"), t[1].coordinate.file_name, _bytes(String("beta conda bytes")))
    ch.put_unlisted(String("linux-64"), t[2].coordinate.file_name, _bytes(String("meta conda bytes")))
    var reg = _registry(ch^)
    var rep = _run(t, reg, src)
    _ends(rep, String(REASON_ALREADY_PUBLISHED), EXIT_OK, String("\n").join(rep.lines))
    assert_true(rep.names_known)
    assert_equal(_names(rep), String(""))
    assert_equal(reg.transport().write_count(), 0)
    # alpha ours by download only, beta and komira held by older listed files:
    # alpha is not new, and the run publishes the rest without re-uploading it
    var ch2 = _channel()
    _seed_names(ch2)
    ch2.put_unlisted(String("linux-64"), t[0].coordinate.file_name, _bytes(String("alpha conda bytes")))
    var reg2 = _registry(ch2^)
    var rep2 = _run(t, reg2, src)
    _ends(rep2, String(REASON_PUBLISHED), EXIT_OK, String("\n").join(rep2.lines))
    assert_equal(_names(rep2), String(""))
    assert_equal(reg2.transport().upload_count(t[0].coordinate.file_name), 0)
    print("  test_a_file_found_by_download_but_not_listed_holds_its_name: PASS")


def test_the_same_command_again_is_stable() raises:
    var t = _targets(String("rerun"))
    var src = _src()
    for lag in range(2):
        var tag = String(" (index lagging)") if lag == 1 else String(" (index current)")
        # after 0: the identical command is NOOP, and reports no new name
        var ch = _channel()
        if lag == 1:
            ch.lag_index()
        var reg = _registry(ch^)
        var rep = _run(t, reg, src)
        _ends(rep, String(REASON_PUBLISHED), EXIT_OK, String("\n").join(rep.lines) + tag)
        var writes = reg.transport().write_count()
        var again = _run(t, reg, src)
        _ends(again, String(REASON_ALREADY_PUBLISHED), EXIT_OK, String("\n").join(again.lines) + tag)
        assert_equal(reg.transport().write_count(), writes, String("the re-run wrote") + tag)
        assert_equal(_names(again), String(""), String("the re-run saw its own uploads as new") + tag)
        if lag == 1:
            reg.transport().catch_up_index()
            var caught_up = _run(t, reg, src)
            _ends(caught_up, String(REASON_ALREADY_PUBLISHED), EXIT_OK, String("\n").join(caught_up.lines) + tag)
        # after 9: the identical command resumes and ends 0
        var chp = _channel()
        if lag == 1:
            chp.lag_index()
        for _ in range(2):
            chp.plan_upload(t[1].coordinate.file_name, UPLOAD_LOSE_NOT_STORED)
        var regp = _registry(chp^)
        var first = _run(t, regp, src)
        _ends(first, String(REASON_PARTIAL), EXIT_PARTIAL, String("\n").join(first.lines) + tag)
        assert_true(regp.transport().holds(String("linux-64"), t[0].coordinate.file_name))
        var resumed = _run(t, regp, src)
        _ends(resumed, String(REASON_PUBLISHED), EXIT_OK, String("\n").join(resumed.lines) + tag)
        assert_equal(regp.transport().upload_count(t[0].coordinate.file_name), 1, String("alpha re-uploaded") + tag)
        assert_true(regp.transport().holds(String("linux-64"), t[2].coordinate.file_name))
    print("  test_the_same_command_again_is_stable: PASS")


def main() raises:
    test_classification_by_download()
    test_one_different_file_stops_with_zero_writes()
    test_new_names_are_reported_never_refused()
    test_all_identical_is_already_published()
    test_an_unread_listing_is_cannot_tell_never_new()
    test_a_file_found_by_download_but_not_listed_holds_its_name()
    test_the_same_command_again_is_stable()
    print("test_publish_channel_state: ALL PASS")
