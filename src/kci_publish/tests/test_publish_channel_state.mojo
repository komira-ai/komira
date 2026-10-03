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
#   (2) one file present with other bytes: exit 7 with ZERO write requests,
#       naming the file, and the credential never asked;
#   (3) a set name the channel has never held: unclaimed = exit 8, zero
#       writes; claimed, the run proceeds; a claim for a name the channel
#       holds = 8; a claim for a name not in the set = 8;
#   (4) every file present and identical: exit 6 ("already published"),
#       zero writes;
#   (5) a name listing that cannot be read (noarch answers 503): exit 5,
#       never "new" (no claim demanded); a file read that cannot be answered:
#       exit 5;
#   (6) a set file the DOWNLOAD finds but no listing names yet (the index
#       lags) makes its name HELD: no claim is needed for it, and when every
#       file is so, the run is 6, not 8. A claim for such a name is
#       SATISFIED, not refused: the channel holds only this release's own
#       bytes under it (see (7) for why it must be); a claim for a name that
#       ANOTHER file holds is still 8, also while our own file is unlisted;
#   (7) the SAME COMMAND, claims and all, run again: after exit 0 it is 6,
#       and after a partial publish (exit 9) it resumes and ends 0 without
#       re-uploading what landed -- with the index caught up AND while it
#       still lags, so the verdict does not depend on index timing.
#
# Hermetic: ScriptedChannel; no network.
# =============================================================================

from std.ffi import external_call
from std.os import makedirs

from komira_libc.posix import _read_env
from std.testing import assert_equal, assert_false, assert_true

from kci_pkg_upload import SURFACE_PREFIX_DEV, RegistrySet, ScriptedCredential
from kci_publish import (
    EXIT_PARTIAL,
    NoWaitSleeper,
    EXIT_ALREADY_PUBLISHED,
    EXIT_CANNOT_TELL,
    EXIT_PUBLISHED,
    EXIT_STOP_DIFFERENT_BYTES,
    EXIT_STOP_NEW_NAME,
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
from kci_publish.release_fixture import EXAMPLE_HOST, ExampleRelease, example_targets
from kci_publish.scripted_channel import UPLOAD_LOSE_NOT_STORED


def _root(tag: String) raises -> String:
    var base = _read_env("TEST_TMPDIR")
    if base.byte_length() == 0:
        base = _read_env("TMPDIR")
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


def _channel() -> ScriptedChannel:
    return ScriptedChannel(String(EXAMPLE_HOST), String("example-stable"), String("linux-64"))


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
    claims: List[String],
    mut reg: RegistrySet[ScriptedChannel, PublishCredential],
    mut src: ScriptedCredential,
) -> PublishReport:
    var sl = NoWaitSleeper()
    return run_publish(targets, claims, reg, src, False, RunOptions(2, 0, 2, 0, 0, 1, 0), sl, PublishReport())


def _src() -> ScriptedCredential:
    var s = ScriptedCredential()
    s.serve(SURFACE_PREFIX_DEV, String("Bearer pfx-test-token"))
    return s^


def _none() -> List[String]:
    return List[String]()


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
    var rep = _run(t, _none(), reg, src)
    assert_equal(rep.exit_code, EXIT_STOP_DIFFERENT_BYTES)
    assert_true(rep.has_line_containing(String("STOP different bytes: linux-64/") + t[2].coordinate.file_name))
    assert_equal(reg.transport().write_count(), 0)
    assert_equal(src.asked_count(), 0)
    print("  test_one_different_file_stops_with_zero_writes: PASS")


def test_new_names_must_be_claimed() raises:
    var t = _targets(String("names"))
    # a fresh channel: every name is new, none claimed
    var reg = _registry(_channel())
    var src = _src()
    var rep = _run(t, _none(), reg, src)
    assert_equal(rep.exit_code, EXIT_STOP_NEW_NAME)
    assert_true(rep.has_line_containing(String("STOP new name: 'komira_alpha'")))
    assert_true(rep.has_line_containing(String("STOP new name: 'komira'")))
    assert_equal(reg.transport().write_count(), 0)
    # two of three claimed: still 8, naming the third
    var some = List[String]()
    some.append(String("komira_alpha"))
    some.append(String("komira_beta"))
    var reg2 = _registry(_channel())
    var rep2 = _run(t, some, reg2, src)
    assert_equal(rep2.exit_code, EXIT_STOP_NEW_NAME)
    assert_true(rep2.has_line_containing(String("STOP new name: 'komira'")))
    assert_false(rep2.has_line_containing(String("STOP new name: 'komira_alpha'")))
    assert_equal(reg2.transport().write_count(), 0)
    # all claimed: it publishes
    var all = some.copy()
    all.append(String("komira"))
    var reg3 = _registry(_channel())
    var rep3 = _run(t, all, reg3, src)
    assert_equal(rep3.exit_code, EXIT_PUBLISHED, String("\n").join(rep3.lines))
    # a claim for a name the channel holds
    var ch4 = _channel()
    _seed_names(ch4)
    var reg4 = _registry(ch4^)
    var rep4 = _run(t, some, reg4, src)
    assert_equal(rep4.exit_code, EXIT_STOP_NEW_NAME)
    assert_true(rep4.has_line_containing(String("--claim-new-name 'komira_alpha' is already in the channel")))
    assert_equal(reg4.transport().write_count(), 0)
    # a claim for a name not in the set
    var ch5 = _channel()
    _seed_names(ch5)
    var reg5 = _registry(ch5^)
    var stray = List[String]()
    stray.append(String("komira_extra"))
    var rep5 = _run(t, stray, reg5, src)
    assert_equal(rep5.exit_code, EXIT_STOP_NEW_NAME)
    assert_true(rep5.has_line_containing(String("'komira_extra' is not a package of this release set")))
    assert_equal(reg5.transport().write_count(), 0)
    print("  test_new_names_must_be_claimed: PASS")


def test_all_identical_is_already_published() raises:
    var t = _targets(String("same"))
    var ch = _channel()
    ch.put(String("linux-64"), t[0].coordinate.file_name, _bytes(String("alpha conda bytes")))
    ch.put(String("linux-64"), t[1].coordinate.file_name, _bytes(String("beta conda bytes")))
    ch.put(String("linux-64"), t[2].coordinate.file_name, _bytes(String("meta conda bytes")))
    var reg = _registry(ch^)
    var src = _src()
    var rep = _run(t, _none(), reg, src)
    assert_equal(rep.exit_code, EXIT_ALREADY_PUBLISHED)
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
    var rep = _run(t, _none(), reg, src)
    assert_equal(rep.exit_code, EXIT_CANNOT_TELL)
    assert_true(rep.has_line_containing(String("CANNOT TELL which names the channel holds: noarch")))
    assert_false(rep.has_line_containing(String("STOP new name")))
    assert_equal(reg.transport().write_count(), 0)

    var ch2 = _channel()
    _seed_names(ch2)
    ch2.fail_fetch_once(String("linux-64"), t[1].coordinate.file_name)
    var reg2 = _registry(ch2^)
    var rep2 = _run(t, _none(), reg2, src)
    assert_equal(rep2.exit_code, EXIT_CANNOT_TELL)
    assert_true(rep2.has_line_containing(String("CANNOT TELL linux-64/") + t[1].coordinate.file_name))
    assert_equal(reg2.transport().write_count(), 0)
    print("  test_an_unread_listing_is_cannot_tell_never_new: PASS")


def _all_claims() -> List[String]:
    var c = List[String]()
    c.append(String("komira_alpha"))
    c.append(String("komira_beta"))
    c.append(String("komira"))
    return c^


def test_a_file_found_by_download_but_not_listed_holds_its_name() raises:
    var t = _targets(String("unlisted"))
    var src = _src()
    # every file ours, present-same by download, none listed: 6, not 8
    var ch = _channel()
    ch.put_unlisted(String("linux-64"), t[0].coordinate.file_name, _bytes(String("alpha conda bytes")))
    ch.put_unlisted(String("linux-64"), t[1].coordinate.file_name, _bytes(String("beta conda bytes")))
    ch.put_unlisted(String("linux-64"), t[2].coordinate.file_name, _bytes(String("meta conda bytes")))
    var reg = _registry(ch^)
    var rep = _run(t, _none(), reg, src)
    assert_equal(rep.exit_code, EXIT_ALREADY_PUBLISHED, String("\n").join(rep.lines))
    assert_false(rep.has_line_containing(String("STOP new name")))
    assert_equal(reg.transport().write_count(), 0)
    # alpha ours by download only, beta and komira held by older listed files:
    # no claim is needed for alpha, and the run publishes the rest
    var ch2 = _channel()
    _seed_names(ch2)
    ch2.put_unlisted(String("linux-64"), t[0].coordinate.file_name, _bytes(String("alpha conda bytes")))
    var reg2 = _registry(ch2^)
    var rep2 = _run(t, _none(), reg2, src)
    assert_equal(rep2.exit_code, EXIT_PUBLISHED, String("\n").join(rep2.lines))
    assert_false(rep2.has_line_containing(String("STOP new name: 'komira_alpha'")))
    assert_equal(reg2.transport().upload_count(t[0].coordinate.file_name), 0)
    # the same channel state with a claim for alpha: satisfied, not refused
    var ch3 = _channel()
    ch3.put(String("linux-64"), String("komira_beta-0.9.0-h00000000_1.conda"), _bytes(String("old b")))
    ch3.put(String("linux-64"), String("komira-0.9.0-h00000000_1.conda"), _bytes(String("old m")))
    ch3.put_unlisted(String("linux-64"), t[0].coordinate.file_name, _bytes(String("alpha conda bytes")))
    var reg3 = _registry(ch3^)
    var alpha = List[String]()
    alpha.append(String("komira_alpha"))
    var rep3 = _run(t, alpha, reg3, src)
    assert_equal(rep3.exit_code, EXIT_PUBLISHED, String("\n").join(rep3.lines))
    assert_true(rep3.has_line_containing(String("CLAIM --claim-new-name 'komira_alpha' is satisfied")))
    # but a claim for a name an OLDER file holds is refused, even though our
    # own file of it is present (and unlisted)
    var ch4 = _channel()
    _seed_names(ch4)
    ch4.put_unlisted(String("linux-64"), t[0].coordinate.file_name, _bytes(String("alpha conda bytes")))
    var reg4 = _registry(ch4^)
    var rep4 = _run(t, alpha, reg4, src)
    assert_equal(rep4.exit_code, EXIT_STOP_NEW_NAME, String("\n").join(rep4.lines))
    assert_true(rep4.has_line_containing(String("--claim-new-name 'komira_alpha' is already in the channel")))
    assert_equal(reg4.transport().write_count(), 0)
    print("  test_a_file_found_by_download_but_not_listed_holds_its_name: PASS")


def test_the_same_command_again_is_stable() raises:
    var t = _targets(String("rerun"))
    var src = _src()
    for lag in range(2):
        var tag = String(" (index lagging)") if lag == 1 else String(" (index current)")
        # after 0: the identical command, claims and all, is 6
        var ch = _channel()
        if lag == 1:
            ch.lag_index()
        var reg = _registry(ch^)
        var rep = _run(t, _all_claims(), reg, src)
        assert_equal(rep.exit_code, EXIT_PUBLISHED, String("\n").join(rep.lines) + tag)
        var writes = reg.transport().write_count()
        var again = _run(t, _all_claims(), reg, src)
        assert_equal(again.exit_code, EXIT_ALREADY_PUBLISHED, String("\n").join(again.lines) + tag)
        assert_equal(reg.transport().write_count(), writes, String("the re-run wrote") + tag)
        var unclaimed = _run(t, _none(), reg, src)
        assert_equal(unclaimed.exit_code, EXIT_ALREADY_PUBLISHED, String("\n").join(unclaimed.lines) + tag)
        if lag == 1:
            reg.transport().catch_up_index()
            var caught_up = _run(t, _all_claims(), reg, src)
            assert_equal(caught_up.exit_code, EXIT_ALREADY_PUBLISHED, String("\n").join(caught_up.lines) + tag)
        # after 9: the identical command resumes and ends 0
        var chp = _channel()
        if lag == 1:
            chp.lag_index()
        for _ in range(2):
            chp.plan_upload(t[1].coordinate.file_name, UPLOAD_LOSE_NOT_STORED)
        var regp = _registry(chp^)
        var first = _run(t, _all_claims(), regp, src)
        assert_equal(first.exit_code, EXIT_PARTIAL, String("\n").join(first.lines) + tag)
        assert_true(regp.transport().holds(String("linux-64"), t[0].coordinate.file_name))
        var resumed = _run(t, _all_claims(), regp, src)
        assert_equal(resumed.exit_code, EXIT_PUBLISHED, String("\n").join(resumed.lines) + tag)
        assert_equal(regp.transport().upload_count(t[0].coordinate.file_name), 1, String("alpha re-uploaded") + tag)
        assert_true(regp.transport().holds(String("linux-64"), t[2].coordinate.file_name))
    print("  test_the_same_command_again_is_stable: PASS")


def main() raises:
    test_classification_by_download()
    test_one_different_file_stops_with_zero_writes()
    test_new_names_must_be_claimed()
    test_all_identical_is_already_published()
    test_an_unread_listing_is_cannot_tell_never_new()
    test_a_file_found_by_download_but_not_listed_holds_its_name()
    test_the_same_command_again_is_stable()
    print("test_publish_channel_state: ALL PASS")
