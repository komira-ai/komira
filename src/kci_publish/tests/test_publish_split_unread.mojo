# =============================================================================
# src/kci_publish/tests/test_publish_split_unread.mojo -- THE SPLIT
#   (run.mojo) when there is nothing to ask git, or no git to ask.
#
#   (u1) a never-backward run whose channel is ahead, with an EMPTY release
#        revision: the split cannot tell (exit 5), says it had no revision
#        to ask about, uploads nothing, and never asks git; with the
#        main-line filter and without it, as a dry run and not;
#   (u2) `run_publish`, which gives no history reader (`UnreadHistory`),
#        over the same channel: exit 5, naming the reader's reason, never
#        SUPERSEDED and never REFUSED;
#   (u3) `UnreadHistory` itself: both reads raise, with the default reason
#        or the one it was given.
#
# Hermetic: ScriptedChannel, ScriptedHistory, NoWaitSleeper; no git, no
# network.
# =============================================================================

from std.ffi import external_call
from std.os import makedirs

from komira_libc.posix import _read_env
from std.testing import TestSuite, assert_equal, assert_false, assert_true

from kci_api import EXIT_CANNOT_TELL
from kci_pkg_upload import SURFACE_PREFIX_DEV, RegistrySet, ScriptedCredential
from kci_publish import (
    NoWaitSleeper,
    REASON_CANNOT_TELL,
    PublishCredential,
    PublishReport,
    PublishTarget,
    RevisionHistory,
    RunOptions,
    ScriptedChannel,
    ScriptedHistory,
    UnreadHistory,
    run_publish,
    run_publish_reading,
)
from kci_publish.release_fixture import EXAMPLE_HOST, ExampleRelease, example_channel_path, example_targets


def _root(tag: String) raises -> String:
    var base = _read_env("TEST_TMPDIR")
    if base.byte_length() == 0:
        base = _read_env("TMPDIR")
    if base.byte_length() == 0:
        raise Error("neither TEST_TMPDIR nor TMPDIR is set")
    var d = base + String("/pspu_") + tag + String("_") + String(Int(external_call["getpid", Int32]()))
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


def _id(prefix: String) -> String:
    """A full commit id starting with the 8 hex `prefix`."""
    return prefix + String("00000000000000000000000000000000")


comptime _AHEAD: String = "komira_alpha-1.0.0-h89abcdef_4.conda"
"""A main build numbered above the release's 3."""


def _registry() raises -> RegistrySet[ScriptedChannel, PublishCredential]:
    var ch = ScriptedChannel(String(EXAMPLE_HOST), example_channel_path(String("example-stable")), String("linux-64"))
    ch.put(String("linux-64"), String("komira_alpha-0.9.0-h00000000_1.conda"), _bytes(String("old a")))
    ch.put(String("linux-64"), String(_AHEAD), _bytes(String("later")))
    var c = PublishCredential()
    c.configure(SURFACE_PREFIX_DEV, String(EXAMPLE_HOST), String(""))
    return RegistrySet[ScriptedChannel, PublishCredential](ch^, c^)


def _history(revision: String) -> RevisionHistory:
    """The release revision's history (it holds the release's own commit,
    not the channel's 89abcdef) and main's (it holds both)."""
    var h = RevisionHistory()
    h.revision = revision.copy()
    h.commits.append(_id(String("01234567")))
    h.commits.append(_id(String("00000000")))
    h.main_line.append(_id(String("89abcdef")))
    h.main_line.append(_id(String("01234567")))
    h.main_line.append(_id(String("00000000")))
    return h^


def _opts(main_line_only: Bool) -> RunOptions:
    var opts = RunOptions(2, 0, 2, 0, 0, 1, 0, concurrency=2)
    opts.never_backward = True
    opts.main_line_only = main_line_only
    return opts^


def _uploads(reg: RegistrySet[ScriptedChannel, PublishCredential], t: List[PublishTarget]) -> Int:
    var n = 0
    for i in range(len(t)):
        n += reg.transport().upload_count(t[i].coordinate.file_name)
    return n


def _cannot_tell(rep: PublishReport, reg: RegistrySet[ScriptedChannel, PublishCredential], t: List[PublishTarget]) raises:
    var all = String("\n").join(rep.lines)
    assert_equal(rep.reason, String(REASON_CANNOT_TELL), all)
    assert_equal(rep.exit_code(), EXIT_CANNOT_TELL, all)
    assert_true(
        rep.has_line_containing(String("CANNOT TELL whether this release is superseded or refused")), all
    )
    assert_false(rep.has_line_containing(String("DESCENDS")), all)
    assert_false(rep.has_line_containing(String("UNRELATED")), all)
    assert_false(rep.has_line_containing(String("WOULD UPLOAD")), all)
    assert_equal(_uploads(reg, t), 0, all)


def test_u1_an_empty_release_revision_cannot_tell_and_never_asks_git() raises:
    var t = _targets(String("u1"))
    for gamma in [True, False]:
        for plan in [False, True]:
            var reg = _registry()
            # git would answer: the prefix resolves and the (empty) revision
            # is on its history, so only the empty-revision check stops it
            var g = ScriptedHistory()
            g.put_commit(String("89abcdef"), _id(String("89abcdef")))
            g.put_ancestor(String(""), _id(String("89abcdef")))
            var src = ScriptedCredential()
            src.serve(SURFACE_PREFIX_DEV, String("Bearer pfx-test-token"))
            var sl = NoWaitSleeper()
            var rep = run_publish_reading(
                t, reg, src, plan, _opts(gamma), sl, PublishReport(), _history(String("")), g
            )
            _cannot_tell(rep, reg, t)
            var all = String("\n").join(rep.lines)
            assert_true(
                rep.has_line_containing(
                    String("CANNOT TELL whether the channel's newest build descends from this release: no newest")
                    + String(" build or no release revision to ask git about")
                ),
                all,
            )
            assert_equal(len(g.asked), 0, String("\n").join(g.asked))


def test_u2_run_publish_gives_no_reader_so_an_ahead_channel_cannot_tell() raises:
    var t = _targets(String("u2"))
    for gamma in [True, False]:
        var reg = _registry()
        var src = ScriptedCredential()
        src.serve(SURFACE_PREFIX_DEV, String("Bearer pfx-test-token"))
        var sl = NoWaitSleeper()
        var rep = run_publish(t, reg, src, False, _opts(gamma), sl, PublishReport(), _history(_id(String("01234567"))))
        _cannot_tell(rep, reg, t)
        assert_true(
            rep.has_line_containing(
                String("CANNOT TELL whether the channel's newest build (commit 89abcdef) descends from this release:")
                + String(" no history reader was given to this publish")
            ),
            String("\n").join(rep.lines),
        )


def _raises(mut h: UnreadHistory, ancestor: Bool) -> String:
    """The message the read raises, or "" when it does not raise."""
    try:
        if ancestor:
            _ = h.is_ancestor(_id(String("01234567")), _id(String("89abcdef")))
        else:
            _ = h.commit_of(String("89abcdef"))
    except e:
        return String(e)
    return String("")


def test_u3_unread_history_answers_nothing_and_says_why() raises:
    var d = UnreadHistory()
    assert_equal(_raises(d, False), String("no history reader was given to this publish"))
    assert_equal(_raises(d, True), String("no history reader was given to this publish"))
    var given = UnreadHistory(String("git is not installed on this runner"))
    assert_equal(_raises(given, False), String("git is not installed on this runner"))
    assert_equal(_raises(given, True), String("git is not installed on this runner"))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
