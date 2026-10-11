# =============================================================================
# src/kci_publish/tests/test_publish_never_backward.mojo -- a run that
#   never goes backward (kci_cli sets it for a push to main, and for prod on
#   any run) refuses to publish a release whose build number is LOWER than
#   any build its channel already lists, of any name and any version, when
#   the release is on none of those builds' histories (THE SPLIT, run.mojo;
#   the other answers are test_publish_never_backward_split.mojo's).
# =============================================================================
#
#   (1) the channel lists a member at the same version with a HIGHER build
#       number: REFUSED, KCI-E-SUPERSEDED, exit 3, retry NEEDS_HUMAN, and no
#       upload request at all (a dry run says the same);
#   (2) the same channel without the rule (a break-glass stage: gamma)
#       publishes;
#   (3) a LOWER build number does not supersede, nor does an EQUAL one with
#       the release's own build string (another name of the same commit);
#       a HIGHER one of ANOTHER version (a version bump) or of a name this
#       release does not carry does (3b), and so does an EQUAL number with
#       ANOTHER build string (3c: two builds of one number cannot be
#       ordered by a consumer);
#   (4) a re-run whose files are all present (equal N) is NOOP, exit 0, even
#       when a higher build is listed: nothing would be written;
#   (5) what a never-backward publish CARRIES: its build number and the
#       highest LOWER build the channel lists, of any name and version (-1
#       for none), so kci_cli can name the commits in between;
#   (6) the commit the channel's NEWEST build names (`h<8 hex>` of its
#       highest build number, any name and version) must be on the history
#       of the release revision (`RevisionHistory`, kci_cli's
#       `git rev-list <revision>`): a lower-numbered release that does
#       descend from it publishes, one that does not is REFUSED,
#       KCI-E-SUPERSEDED, with no upload (a dry run too); a newest build
#       whose build string names no commit is refused the same way. Build
#       numbers alone cannot say it: they count first-parent commits, and a
#       merge whose FIRST parent is a branch gives main's new tip a LOWER
#       number than an older tip it contains;
#   (7) a history that was not read (empty) when the channel lists a
#       numbered build cannot tell: INDETERMINATE, exit 5, no upload, the
#       reason it was not read in the lines.
#
# Hermetic: ScriptedChannel; NoWaitSleeper; no network.
# =============================================================================

from std.ffi import external_call
from std.os import makedirs

from komira_libc.posix import _read_env
from std.testing import assert_equal, assert_true

from kci_api import EXIT_CANNOT_TELL, EXIT_OK, EXIT_REFUSED, RETRY_NEEDS_HUMAN, default_retry
from kci_pkg_upload import SURFACE_PREFIX_DEV, RegistrySet, ScriptedCredential
from kci_publish import (
    NoWaitSleeper,
    REASON_ALREADY_PUBLISHED,
    REASON_CANNOT_TELL,
    REASON_PUBLISHED,
    REASON_REFUSED,
    PublishCredential,
    PublishReport,
    PublishTarget,
    RevisionHistory,
    RunOptions,
    ScriptedChannel,
    ScriptedHistory,
    backward_files,
    previous_build_number,
    run_publish_reading,
    superseding_files,
)
from kci_publish.release_fixture import EXAMPLE_HOST, ExampleRelease, example_channel_path, example_targets


def _root(tag: String) raises -> String:
    var base = _read_env("TEST_TMPDIR")
    if base.byte_length() == 0:
        base = _read_env("TMPDIR")
    if base.byte_length() == 0:
        raise Error("neither TEST_TMPDIR nor TMPDIR is set")
    var d = base + String("/pnb_") + tag + String("_") + String(Int(external_call["getpid", Int32]()))
    makedirs(d, exist_ok=True)
    return d^


def _bytes(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    var b = s.as_bytes()
    for i in range(len(b)):
        out.append(b[i])
    return out^


def _targets(tag: String) raises -> List[PublishTarget]:
    var r = ExampleRelease()  # version 1.0.0, build h01234567_3
    var d = _root(tag)
    r.write(d)
    return example_targets(r, d)


def _channel(listed: String) raises -> ScriptedChannel:
    var ch = ScriptedChannel(String(EXAMPLE_HOST), example_channel_path(String("example-stable")), String("linux-64"))
    ch.put(String("linux-64"), String("komira_alpha-0.9.0-h00000000_1.conda"), _bytes(String("old a")))
    if listed.byte_length() > 0:
        ch.put(String("linux-64"), listed, _bytes(String("later")))
    return ch^


def _registry(var ch: ScriptedChannel) -> RegistrySet[ScriptedChannel, PublishCredential]:
    var c = PublishCredential()
    c.configure(SURFACE_PREFIX_DEV, String(EXAMPLE_HOST), String(""))
    return RegistrySet[ScriptedChannel, PublishCredential](ch^, c^)


def _id(prefix: String) -> String:
    """A full commit id starting with the 8 hex `prefix`."""
    return prefix + String("00000000000000000000000000000000")


def _history() -> List[String]:
    """The release revision's history every commit the fixtures' channels
    name is on (h00000000, h89abcdef, h11111111), newest first, as `git
    rev-list` prints it."""
    var h = List[String]()
    h.append(_id(String("01234567")))
    h.append(_id(String("89abcdef")))
    h.append(_id(String("11111111")))
    h.append(_id(String("00000000")))
    return h^


def _run_with(
    targets: List[PublishTarget],
    mut reg: RegistrySet[ScriptedChannel, PublishCredential],
    never_backward: Bool,
    plan: Bool,
    history: List[String],
    unread: String,
) -> PublishReport:
    var src = ScriptedCredential()
    src.serve(SURFACE_PREFIX_DEV, String("Bearer pfx-test-token"))
    var sl = NoWaitSleeper()
    var opts = RunOptions(2, 0, 2, 0, 0, 1, 0, concurrency=4)
    opts.never_backward = never_backward
    var h = RevisionHistory()
    h.revision = _id(String("01234567"))
    h.commits = history.copy()
    h.unread = unread.copy()
    # THE SPLIT (run.mojo): every commit the fixtures' channels name
    # resolves, and the release is on none of their histories, so each
    # refusal here stays REFUSED (test_publish_never_backward_split.mojo
    # holds the other answers)
    var reader = ScriptedHistory()
    for p in ["89abcdef", "fedcba98", "11111111", "00000000"]:
        reader.put_commit(String(p), _id(String(p)))
    return run_publish_reading(targets, reg, src, plan, opts, sl, PublishReport(), h, reader)


def _run(
    targets: List[PublishTarget],
    mut reg: RegistrySet[ScriptedChannel, PublishCredential],
    never_backward: Bool,
    plan: Bool = False,
) -> PublishReport:
    return _run_with(targets, reg, never_backward, plan, _history(), String(""))


def _uploads(reg: RegistrySet[ScriptedChannel, PublishCredential], t: List[PublishTarget]) -> Int:
    var n = 0
    for i in range(len(t)):
        n += reg.transport().upload_count(t[i].coordinate.file_name)
    return n


def test_a_higher_build_number_supersedes() raises:
    var t = _targets(String("higher"))
    var reg = _registry(_channel(String("komira_alpha-1.0.0-h89abcdef_4.conda")))
    var rep = _run(t, reg, True)
    var all = String("\n").join(rep.lines)
    assert_equal(rep.reason, String(REASON_REFUSED), all)
    assert_equal(rep.error_id, String("KCI-E-SUPERSEDED"), all)
    assert_equal(rep.exit_code(), EXIT_REFUSED, all)
    assert_equal(default_retry(rep.exit_code()), String(RETRY_NEEDS_HUMAN))
    assert_true(rep.has_line_containing(String("linux-64/komira_alpha-1.0.0-h89abcdef_4.conda")), all)
    assert_true(rep.has_line_containing(String("build number 4")), all)
    assert_equal(_uploads(reg, t), 0, String("a superseded release sent an upload"))
    # a dry run refuses the same, and writes nothing either
    var reg2 = _registry(_channel(String("komira_alpha-1.0.0-h89abcdef_4.conda")))
    var plan = _run(t, reg2, True, True)
    assert_equal(plan.error_id, String("KCI-E-SUPERSEDED"), String("\n").join(plan.lines))
    assert_equal(_uploads(reg2, t), 0)


def test_without_the_rule_it_publishes() raises:
    var t = _targets(String("norule"))
    var reg = _registry(_channel(String("komira_alpha-1.0.0-h89abcdef_4.conda")))
    var rep = _run(t, reg, False)
    assert_equal(rep.reason, String(REASON_PUBLISHED), String("\n").join(rep.lines))
    assert_equal(rep.exit_code(), EXIT_OK)


def test_what_does_not_supersede() raises:
    var t = _targets(String("not"))
    for listed in [
        "komira_alpha-1.0.0-h89abcdef_2.conda",  # lower N
        "komira_alpha-1.0.1-h89abcdef_2.conda",  # another version, lower N
        "komira_gamma-1.0.0-h01234567_3.conda",  # another name, equal N, the release's own build string
        "komira_alpha-1.0.0-h89abcdef_x9.conda",  # no build number after `_`
    ]:
        var reg = _registry(_channel(String(listed)))
        var rep = _run(t, reg, True)
        assert_equal(rep.reason, String(REASON_PUBLISHED), String(listed) + String(": ") + String("\n").join(rep.lines))
    # the pure reading: the metapackage `komira` is not `komira_alpha`
    var listed = List[String]()
    listed.append(String("linux-64/komira_alpha-1.0.0-h89abcdef_4.conda"))
    listed.append(String("noarch/komira-1.0.0-h89abcdef_2.conda"))
    var hits = superseding_files(t, listed)
    assert_equal(len(hits), 1)
    assert_true(hits[0].find(String("komira_alpha-1.0.0-h89abcdef_4.conda")) >= 0, hits[0])


def test_a_later_build_of_any_name_or_version_supersedes() raises:
    # (3b) never backward across a version bump, and for a name this
    # release does not carry (a name prod never listed for it): a higher N
    # anywhere in the channel means this revision does not descend from what
    # the channel has
    var t = _targets(String("anyname"))
    for listed in [
        "komira_alpha-1.0.1-h89abcdef_9.conda",  # a later version
        "komira_alpha-0.9.0-h89abcdef_9.conda",  # an earlier version
        "komira_gamma-1.0.0-h89abcdef_9.conda",  # another name
        "komira_gamma-2.0.0-h89abcdef_9.tar.bz2",  # another name and format
    ]:
        var reg = _registry(_channel(String(listed)))
        var rep = _run(t, reg, True)
        var all = String(listed) + String(": ") + String("\n").join(rep.lines)
        assert_equal(rep.error_id, String("KCI-E-SUPERSEDED"), all)
        assert_equal(rep.exit_code(), EXIT_REFUSED, all)
        assert_true(rep.has_line_containing(String(listed)), all)
        assert_equal(_uploads(reg, t), 0, all)
    # the pure reading names each later file once, whatever the targets,
    # and an equal number of another build string (3c); the release's own
    # build string at an equal number is not named
    var listed = List[String]()
    listed.append(String("noarch/komira-2.0.0-h89abcdef_7.conda"))
    listed.append(String("linux-64/komira_beta-1.0.0-h89abcdef_3.conda"))
    listed.append(String("linux-64/komira_beta-1.0.0-h01234567_3.conda"))
    var hits = superseding_files(t, listed)
    assert_equal(len(hits), 2)
    assert_true(hits[0].find(String("noarch/komira-2.0.0-h89abcdef_7.conda (build number 7)")) >= 0, hits[0])
    assert_true(hits[1].find(String("linux-64/komira_beta-1.0.0-h89abcdef_3.conda (build h89abcdef_3)")) >= 0, hits[1])


def test_an_equal_rerun_is_noop_even_when_superseded() raises:
    var t = _targets(String("rerun"))
    var ch = _channel(String("komira_alpha-1.0.0-h89abcdef_4.conda"))
    var r = ExampleRelease()
    for i in range(len(r.members)):
        ch.put(String("linux-64"), r.file_name(r.members[i].name), _bytes(r.members[i].content))
    var reg = _registry(ch^)
    var rep = _run(t, reg, True)
    assert_equal(rep.reason, String(REASON_ALREADY_PUBLISHED), String("\n").join(rep.lines))
    assert_equal(rep.exit_code(), EXIT_OK)


def test_what_a_release_carries() raises:
    var t = _targets(String("carries"))  # build 3
    # lower builds 1 and 2 of komira_alpha 1.0.0 listed: the previous is 2
    var ch = _channel(String("komira_alpha-1.0.0-h89abcdef_2.conda"))
    ch.put(String("linux-64"), String("komira_alpha-1.0.0-h11111111_1.conda"), _bytes(String("one")))
    var reg = _registry(ch^)
    var rep = _run(t, reg, True)
    assert_equal(rep.reason, String(REASON_PUBLISHED), String("\n").join(rep.lines))
    assert_equal(rep.build_number, 3)
    assert_equal(rep.previous_build, 2)
    # another version's and another name's lower builds count: the highest
    # lower build in the channel (the base channel's 0.9.0 build 1 alone: 1)
    var reg2 = _registry(_channel(String("komira_beta-2.0.0-h89abcdef_9.conda")))
    var rep2 = _run(t, reg2, False)
    assert_equal(rep2.previous_build, -1)
    var reg2b = _registry(_channel(String("komira_beta-2.0.0-h89abcdef_2.conda")))
    var rep2b = _run(t, reg2b, True)
    assert_equal(rep2b.previous_build, 2, String("\n").join(rep2b.lines))
    # without the rule nothing is read for it
    var reg3 = _registry(_channel(String("komira_alpha-1.0.0-h89abcdef_2.conda")))
    var rep3 = _run(t, reg3, False)
    assert_equal(rep3.previous_build, -1)
    # the pure reading: an equal or higher build is not "previous"
    var listed = List[String]()
    listed.append(String("linux-64/komira_alpha-1.0.0-h89abcdef_3.conda"))
    listed.append(String("linux-64/komira_alpha-1.0.0-h89abcdef_7.conda"))
    assert_equal(previous_build_number(t, listed), -1)
    listed.append(String("linux-64/komira_alpha-1.0.0-h89abcdef_1.conda"))
    assert_equal(previous_build_number(t, listed), 1)


def test_an_equal_number_of_another_build_supersedes() raises:
    # (3c) the release is h01234567_3: an equal number naming another commit
    var t = _targets(String("equal"))
    for listed in [
        "komira_alpha-1.0.0-h89abcdef_3.conda",  # same name and version
        "komira_gamma-1.0.0-h89abcdef_3.conda",  # another name
    ]:
        var reg = _registry(_channel(String(listed)))
        var rep = _run(t, reg, True)
        var all = String(listed) + String(": ") + String("\n").join(rep.lines)
        assert_equal(rep.error_id, String("KCI-E-SUPERSEDED"), all)
        assert_equal(rep.exit_code(), EXIT_REFUSED, all)
        assert_true(rep.has_line_containing(String(listed)), all)
        assert_equal(_uploads(reg, t), 0, all)


def test_the_newest_build_must_be_on_the_revisions_history() raises:
    # (6) build 2 names hfedcba9: lower than ours (3), and not on the
    # history: main moved past it through a merge whose first parent is a
    # branch, and this revision is an older tip that merge contains
    var t = _targets(String("history"))
    var off = String("komira_alpha-1.0.0-hfedcba98_2.conda")
    var reg = _registry(_channel(off))
    var rep = _run(t, reg, True)
    var all = String("\n").join(rep.lines)
    assert_equal(rep.error_id, String("KCI-E-SUPERSEDED"), all)
    assert_equal(rep.exit_code(), EXIT_REFUSED, all)
    assert_true(rep.has_line_containing(String("linux-64/") + off), all)
    assert_true(rep.has_line_containing(String("not on the history")), all)
    assert_equal(_uploads(reg, t), 0, all)
    var reg_plan = _registry(_channel(off))
    var plan = _run(t, reg_plan, True, True)
    assert_equal(plan.error_id, String("KCI-E-SUPERSEDED"), String("\n").join(plan.lines))
    assert_equal(_uploads(reg_plan, t), 0)
    # the same channel, the revision descending from that build: published
    var h = _history()
    h.append(_id(String("fedcba98")))
    var reg_on = _registry(_channel(off))
    var on = _run_with(t, reg_on, True, False, h, String(""))
    assert_equal(on.reason, String(REASON_PUBLISHED), String("\n").join(on.lines))
    # only the NEWEST build is asked: an older one off the history (build 1
    # here, below the newest, 2, which is on it) does not refuse
    var ch = _channel(String("komira_alpha-1.0.0-h89abcdef_2.conda"))
    ch.put(String("linux-64"), String("komira_beta-1.0.0-hfedcba98_1.conda"), _bytes(String("old b")))
    var reg_old = _registry(ch^)
    var old = _run(t, reg_old, True)
    assert_equal(old.reason, String(REASON_PUBLISHED), String("\n").join(old.lines))
    # a newest build whose build string names no commit: refused
    var listed = List[String]()
    listed.append(String("linux-64/komira_alpha-1.0.0-x0_2.conda"))
    var none = backward_files(t, listed, _history())
    assert_equal(len(none), 1)
    assert_true(none[0].find(String("names no commit")) >= 0, none[0])
    # the pure reading: one line per newest file off the history; none when
    # the channel lists no numbered build
    listed = List[String]()
    listed.append(String("linux-64/komira_alpha-1.0.0-hfedcba98_2.conda"))
    listed.append(String("noarch/komira-1.0.0-hfedcba98_2.conda"))
    listed.append(String("linux-64/komira_alpha-1.0.0-h89abcdef_1.conda"))
    assert_equal(len(backward_files(t, listed, _history())), 2)
    assert_equal(len(backward_files(t, listed, h)), 0)
    assert_equal(len(backward_files(t, List[String](), List[String]())), 0)


def test_an_unread_history_cannot_tell() raises:
    # (7) git could not list the revision's history: never a pass
    var t = _targets(String("unread"))
    var reg = _registry(_channel(String("komira_alpha-1.0.0-h89abcdef_2.conda")))
    var rep = _run_with(t, reg, True, False, List[String](), String("RUNNER_TEMP is not set"))
    var all = String("\n").join(rep.lines)
    assert_equal(rep.reason, String(REASON_CANNOT_TELL), all)
    assert_equal(rep.exit_code(), EXIT_CANNOT_TELL, all)
    assert_true(rep.has_line_containing(String("RUNNER_TEMP is not set")), all)
    assert_equal(_uploads(reg, t), 0, all)
    # without the rule the history is not asked for
    var reg2 = _registry(_channel(String("komira_alpha-1.0.0-h89abcdef_2.conda")))
    var rep2 = _run_with(t, reg2, False, False, List[String](), String("RUNNER_TEMP is not set"))
    assert_equal(rep2.reason, String(REASON_PUBLISHED), String("\n").join(rep2.lines))


def main() raises:
    test_an_equal_number_of_another_build_supersedes()
    test_the_newest_build_must_be_on_the_revisions_history()
    test_an_unread_history_cannot_tell()
    test_what_a_release_carries()
    test_a_later_build_of_any_name_or_version_supersedes()
    test_a_higher_build_number_supersedes()
    test_without_the_rule_it_publishes()
    test_what_does_not_supersede()
    test_an_equal_rerun_is_noop_even_when_superseded()
