# =============================================================================
# src/kci_publish/tests/test_publish_never_backward_split.mojo -- what a
#   never-backward run does when its channel is AHEAD of the release: THE
#   SPLIT by history and THE MAIN-LINE FILTER (run.mojo, plan.mojo).
#   Rows of the staged pipeline design's table c (P1); each names the
#   mutant that turns it red.
#
#   (c1) the channel's newest build names a commit whose history holds the
#        release revision (git: rev-parse, then merge-base --is-ancestor):
#        SUPERSEDED, exit 0, no upload, no error id; a dry run the same.
#        Mutant: the split never answers SUPERSEDED;
#   (c3) the same channel, the release NOT on that commit's history:
#        REFUSED, KCI-E-SUPERSEDED, exit 3, no upload; with the main-line
#        filter (gamma) and without it (prod). Mutant: "split by number
#        only" (a higher number alone answers SUPERSEDED);
#   (c3n) the newest build's name holds no commit (`..._x0_5`): it cannot
#        be shown to descend, so REFUSED, exit 3, git never asked; alone,
#        and beside a descending build of the same number. Mutant: "a
#        commit-less newest build does not set UNRELATED" (it answered
#        SUPERSEDED, exit 0);
#   (c4) two newest builds share the top build number: one descends and
#        one does not (in both iteration orders) -> REFUSED, exit 3; both
#        descend -> SUPERSEDED, exit 0, git asked about each. Mutant: "the
#        first descending build decides";
#   (c2) a higher-numbered build of a commit OFF main's history (a branch's
#        break-glass build) is not counted: the release publishes, and the
#        file is reported OFF MAIN. Mutant: "count every build";
#   (c5) the newest build's prefix is ambiguous between a main commit and
#        an off-main one: it counts as main-line, so the release is never
#        published (git cannot resolve the prefix: exit 5). Mutant: "treat
#        ambiguous as off-main";
#   (c6) the descendant read on a prefix git does not know, or on a shallow
#        clone: CANNOT_TELL, exit 5, no upload, never SUPERSEDED. Mutant:
#        "default to SUPERSEDED";
#   (f)  main's history not read with the filter on: exit 5, no upload;
#   (g)  gamma's carried list starts after the previous MAIN-LINE build: a
#        lower off-main build is not "previous".
#
# Hermetic: ScriptedChannel, ScriptedHistory, NoWaitSleeper; no git, no
# network.
# =============================================================================

from std.ffi import external_call
from std.os import makedirs

from komira_libc.posix import _read_env
from std.testing import TestSuite, assert_equal, assert_false, assert_true

from kci_api import EXIT_CANNOT_TELL, EXIT_OK, EXIT_REFUSED, OUTCOME_SUPERSEDED
from kci_pkg_upload import SURFACE_PREFIX_DEV, RegistrySet, ScriptedCredential
from kci_publish import (
    NoWaitSleeper,
    REASON_CANNOT_TELL,
    REASON_PUBLISHED,
    REASON_REFUSED,
    REASON_SUPERSEDED,
    PublishCredential,
    PublishReport,
    PublishTarget,
    RevisionHistory,
    RunOptions,
    ScriptedChannel,
    ScriptedHistory,
    main_line_files,
    newest_build_prefixes,
    off_main_files,
    run_publish_reading,
)
from kci_publish.release_fixture import EXAMPLE_HOST, ExampleRelease, example_channel_path, example_targets


def _root(tag: String) raises -> String:
    var base = _read_env("TEST_TMPDIR")
    if base.byte_length() == 0:
        base = _read_env("TMPDIR")
    if base.byte_length() == 0:
        raise Error("neither TEST_TMPDIR nor TMPDIR is set")
    var d = base + String("/pnbs_") + tag + String("_") + String(Int(external_call["getpid", Int32]()))
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


comptime _REV_PREFIX: String = "01234567"


def _channel(listed: List[String]) raises -> ScriptedChannel:
    var ch = ScriptedChannel(String(EXAMPLE_HOST), example_channel_path(String("example-stable")), String("linux-64"))
    ch.put(String("linux-64"), String("komira_alpha-0.9.0-h00000000_1.conda"), _bytes(String("old a")))
    for i in range(len(listed)):
        ch.put(String("linux-64"), listed[i], _bytes(String("later ") + String(i)))
    return ch^


def _one(f: String) -> List[String]:
    var l = List[String]()
    l.append(f.copy())
    return l^


def _registry(var ch: ScriptedChannel) -> RegistrySet[ScriptedChannel, PublishCredential]:
    var c = PublishCredential()
    c.configure(SURFACE_PREFIX_DEV, String(EXAMPLE_HOST), String(""))
    return RegistrySet[ScriptedChannel, PublishCredential](ch^, c^)


def _main() -> List[String]:
    """Main's history in these fixtures: the release revision and every
    main commit the channels name (newest first)."""
    var h = List[String]()
    h.append(_id(String("89abcdef")))
    h.append(_id(String(_REV_PREFIX)))
    h.append(_id(String("abcdef01")))
    h.append(_id(String("00000000")))
    return h^


def _revision_history() -> List[String]:
    """The release revision's own history (`git rev-list <revision>`)."""
    var h = List[String]()
    h.append(_id(String(_REV_PREFIX)))
    h.append(_id(String("00000000")))
    return h^


def _reader(descends: Bool) -> ScriptedHistory:
    """git over these fixtures: every prefix the channels name resolves; the
    release is on 89abcdef's history when `descends`."""
    var g = ScriptedHistory()
    for p in ["89abcdef", "00000000", "feed0000"]:
        g.put_commit(String(p), _id(String(p)))
    if descends:
        g.put_ancestor(_id(String(_REV_PREFIX)), _id(String("89abcdef")))
    return g^


def _run(
    t: List[PublishTarget],
    mut reg: RegistrySet[ScriptedChannel, PublishCredential],
    main_line_only: Bool,
    mut reader: ScriptedHistory,
    plan: Bool = False,
    main_line: List[String] = _main(),
) -> PublishReport:
    var src = ScriptedCredential()
    src.serve(SURFACE_PREFIX_DEV, String("Bearer pfx-test-token"))
    var sl = NoWaitSleeper()
    var opts = RunOptions(2, 0, 2, 0, 0, 1, 0, concurrency=4)
    opts.never_backward = True
    opts.main_line_only = main_line_only
    var h = RevisionHistory()
    h.revision = _id(String(_REV_PREFIX))
    h.commits = _revision_history()
    h.main_line = main_line.copy()
    if len(main_line) == 0:
        h.main_unread = String("`git fetch origin main` failed")
    return run_publish_reading(t, reg, src, plan, opts, sl, PublishReport(), h, reader)


def _uploads(reg: RegistrySet[ScriptedChannel, PublishCredential], t: List[PublishTarget]) -> Int:
    var n = 0
    for i in range(len(t)):
        n += reg.transport().upload_count(t[i].coordinate.file_name)
    return n


comptime _AHEAD: String = "komira_alpha-1.0.0-h89abcdef_4.conda"
"""A main build numbered above the release's 3."""


def test_c1_a_descendant_ahead_is_superseded_with_no_upload() raises:
    var t = _targets(String("c1"))
    for gamma in [True, False]:
        for plan in [False, True]:
            var reg = _registry(_channel(_one(String(_AHEAD))))
            var g = _reader(True)
            var rep = _run(t, reg, gamma, g, plan)
            var all = String("\n").join(rep.lines)
            assert_equal(rep.reason, String(REASON_SUPERSEDED), all)
            assert_equal(rep.outcome(), String(OUTCOME_SUPERSEDED), all)
            assert_equal(rep.exit_code(), EXIT_OK, all)
            assert_equal(rep.error_id, String(""), all)
            assert_true(rep.has_line_containing(String("DESCENDS")), all)
            assert_false(rep.has_line_containing(String("WOULD UPLOAD")), all)
            assert_equal(_uploads(reg, t), 0, all)
            # the split asked git exactly: resolve the prefix, then the
            # release revision on that commit's history
            assert_equal(len(g.asked), 2, String("\n").join(g.asked))
            assert_equal(g.asked[0], String("commit_of 89abcdef"))
            assert_equal(
                g.asked[1],
                String("is_ancestor ") + _id(String(_REV_PREFIX)) + String(" ") + _id(String("89abcdef")),
            )


def test_c3_unrelated_history_is_refused_at_gamma_and_prod() raises:
    var t = _targets(String("c3"))
    for gamma in [True, False]:
        var reg = _registry(_channel(_one(String(_AHEAD))))
        var g = _reader(False)
        var rep = _run(t, reg, gamma, g)
        var all = String("\n").join(rep.lines)
        assert_equal(rep.reason, String(REASON_REFUSED), all)
        assert_equal(rep.error_id, String("KCI-E-SUPERSEDED"), all)
        assert_equal(rep.exit_code(), EXIT_REFUSED, all)
        assert_true(rep.has_line_containing(String("UNRELATED")), all)
        assert_equal(_uploads(reg, t), 0, all)


def _refused(rep: PublishReport, reg: RegistrySet[ScriptedChannel, PublishCredential], t: List[PublishTarget]) raises:
    var all = String("\n").join(rep.lines)
    assert_equal(rep.reason, String(REASON_REFUSED), all)
    assert_equal(rep.error_id, String("KCI-E-SUPERSEDED"), all)
    assert_equal(rep.exit_code(), EXIT_REFUSED, all)
    assert_false(rep.has_line_containing(String("WOULD UPLOAD")), all)
    assert_equal(_uploads(reg, t), 0, all)


def test_c3n_a_newest_build_naming_no_commit_is_refused() raises:
    var t = _targets(String("c3n"))
    for gamma in [True, False]:
        # alone: build 5 names no commit (the main-line filter counts it)
        var reg = _registry(_channel(_one(String("komira_alpha-1.0.0-x0_5.conda"))))
        var g = _reader(True)
        var rep = _run(t, reg, gamma, g)
        _refused(rep, reg, t)
        assert_true(rep.has_line_containing(String("names no commit")), String("\n").join(rep.lines))
        assert_equal(len(g.asked), 0, String("\n").join(g.asked))
        # beside a descending main build of the same number
        var listed = List[String]()
        listed.append(String("komira_alpha-1.0.0-h89abcdef_5.conda"))
        listed.append(String("komira_alpha-1.0.0-x0_5.conda"))
        var reg2 = _registry(_channel(listed))
        var g2 = _reader(True)
        var rep2 = _run(t, reg2, gamma, g2)
        _refused(rep2, reg2, t)
        assert_true(rep2.has_line_containing(String("DESCENDS")), String("\n").join(rep2.lines))
        assert_true(rep2.has_line_containing(String("names no commit")), String("\n").join(rep2.lines))


def _two_newest() -> List[String]:
    """Two main builds of the top number 4, of two commits."""
    var l = List[String]()
    l.append(String("komira_alpha-1.0.0-h89abcdef_4.conda"))
    l.append(String("komira_alpha-1.0.0-h00000000_4.conda"))
    return l^


def _reader_of(descend: List[String]) -> ScriptedHistory:
    """git over `_two_newest`: both prefixes resolve; the release revision
    is on the history of each commit `descend` names."""
    var g = ScriptedHistory()
    for p in ["89abcdef", "00000000"]:
        g.put_commit(String(p), _id(String(p)))
    for i in range(len(descend)):
        g.put_ancestor(_id(String(_REV_PREFIX)), _id(descend[i]))
    return g^


def test_c4_two_newest_builds_of_one_number() raises:
    var t = _targets(String("c4"))
    for gamma in [True, False]:
        # one descends, one does not: whichever git is asked about first
        for d in ["89abcdef", "00000000"]:
            var reg = _registry(_channel(_two_newest()))
            var g = _reader_of(_one(String(d)))
            var rep = _run(t, reg, gamma, g)
            _refused(rep, reg, t)
            var all = String("\n").join(rep.lines)
            assert_true(rep.has_line_containing(String("DESCENDS")), all)
            assert_true(rep.has_line_containing(String("UNRELATED")), all)
            assert_equal(len(g.asked), 4, String("\n").join(g.asked))
        # every one descends: SUPERSEDED, exit 0
        var both = List[String]()
        both.append(String("89abcdef"))
        both.append(String("00000000"))
        var reg2 = _registry(_channel(_two_newest()))
        var g2 = _reader_of(both)
        var rep2 = _run(t, reg2, gamma, g2)
        var all2 = String("\n").join(rep2.lines)
        assert_equal(rep2.reason, String(REASON_SUPERSEDED), all2)
        assert_equal(rep2.outcome(), String(OUTCOME_SUPERSEDED), all2)
        assert_equal(rep2.exit_code(), EXIT_OK, all2)
        assert_equal(rep2.error_id, String(""), all2)
        assert_false(rep2.has_line_containing(String("UNRELATED")), all2)
        assert_equal(len(g2.asked), 4, String("\n").join(g2.asked))
        assert_equal(_uploads(reg2, t), 0, all2)


def test_c2_an_off_main_build_ahead_is_not_counted() raises:
    var t = _targets(String("c2"))
    var listed = List[String]()
    listed.append(String("komira_alpha-1.0.0-hfeed0000_9.conda"))  # a branch's break-glass build, higher
    listed.append(String("komira_alpha-1.0.0-h00000000_2.conda"))  # main's, lower
    var reg = _registry(_channel(listed))
    var g = _reader(False)
    var rep = _run(t, reg, True, g)
    var all = String("\n").join(rep.lines)
    assert_equal(rep.reason, String(REASON_PUBLISHED), all)
    assert_equal(rep.exit_code(), EXIT_OK, all)
    assert_true(rep.has_line_containing(String("OFF MAIN, not counted")), all)
    assert_true(rep.has_line_containing(String("hfeed0000_9")), all)
    assert_equal(len(g.asked), 0, String("\n").join(g.asked))
    # the pure reading
    var files = List[String]()
    files.append(String("linux-64/komira_alpha-1.0.0-hfeed0000_9.conda"))
    files.append(String("linux-64/komira_alpha-1.0.0-h89abcdef_4.conda"))
    files.append(String("linux-64/komira_alpha-1.0.0-x0_5.conda"))  # names no commit: counted
    var on = main_line_files(files, _main())
    assert_equal(len(on), 2)
    assert_true(on[0].find(String("h89abcdef_4")) >= 0)
    assert_true(on[1].find(String("x0_5")) >= 0)
    var off = off_main_files(files, _main())
    assert_equal(len(off), 1)
    assert_true(off[0].find(String("hfeed0000_9")) >= 0)


def test_c5_an_ambiguous_prefix_counts_as_main_line() raises:
    # abcdef01 is a prefix of a main commit (in `_main`) and, in this
    # clone, of another commit off main: git cannot resolve it to one
    var t = _targets(String("c5"))
    var reg = _registry(_channel(_one(String("komira_alpha-1.0.0-habcdef01_9.conda"))))
    var g = _reader(True)
    g.refuse_prefix(String("abcdef01"), String("short object ID abcdef01 is ambiguous"))
    var rep = _run(t, reg, True, g)
    var all = String("\n").join(rep.lines)
    assert_equal(rep.reason, String(REASON_CANNOT_TELL), all)
    assert_equal(rep.exit_code(), EXIT_CANNOT_TELL, all)
    assert_true(rep.has_line_containing(String("is ambiguous")), all)
    assert_false(rep.has_line_containing(String("OFF MAIN")), all)
    assert_equal(_uploads(reg, t), 0, all)


def test_c6_a_descendant_read_git_cannot_answer_is_exit_5() raises:
    var t = _targets(String("c6"))
    # a prefix git does not know
    var reg = _registry(_channel(_one(String(_AHEAD))))
    var unknown = ScriptedHistory()
    var rep = _run(t, reg, False, unknown)
    var all = String("\n").join(rep.lines)
    assert_equal(rep.reason, String(REASON_CANNOT_TELL), all)
    assert_equal(rep.exit_code(), EXIT_CANNOT_TELL, all)
    assert_true(rep.has_line_containing(String("names no commit (unknown)")), all)
    assert_equal(_uploads(reg, t), 0, all)
    # a shallow clone: merge-base cannot answer
    var reg2 = _registry(_channel(_one(String(_AHEAD))))
    var shallow = _reader(True)
    shallow.refuse_ancestor(_id(String("89abcdef")))
    var rep2 = _run(t, reg2, True, shallow)
    var all2 = String("\n").join(rep2.lines)
    assert_equal(rep2.reason, String(REASON_CANNOT_TELL), all2)
    assert_equal(rep2.exit_code(), EXIT_CANNOT_TELL, all2)
    assert_true(rep2.has_line_containing(String("shallow")), all2)
    assert_equal(_uploads(reg2, t), 0, all2)


def test_f_main_history_not_read_cannot_tell() raises:
    var t = _targets(String("unreadmain"))
    var reg = _registry(_channel(_one(String("komira_alpha-1.0.0-h00000000_2.conda"))))
    var g = _reader(False)
    var rep = _run(t, reg, True, g, False, List[String]())
    var all = String("\n").join(rep.lines)
    assert_equal(rep.reason, String(REASON_CANNOT_TELL), all)
    assert_equal(rep.exit_code(), EXIT_CANNOT_TELL, all)
    assert_true(rep.has_line_containing(String("`git fetch origin main` failed")), all)
    assert_equal(_uploads(reg, t), 0, all)


def test_g_carried_starts_after_the_previous_main_line_build() raises:
    var t = _targets(String("carried"))  # build 3
    var listed = List[String]()
    listed.append(String("komira_alpha-1.0.0-hfeed0000_2.conda"))  # off main, lower
    var reg = _registry(_channel(listed))  # main's h00000000_1 is in the base channel
    var g = _reader(False)
    var rep = _run(t, reg, True, g)
    assert_equal(rep.reason, String(REASON_PUBLISHED), String("\n").join(rep.lines))
    assert_equal(rep.build_number, 3)
    assert_equal(rep.previous_build, 1)


def test_newest_build_prefixes() raises:
    var files = List[String]()
    files.append(String("linux-64/komira_alpha-1.0.0-h89abcdef_4.conda"))
    files.append(String("noarch/komira-1.0.0-h89abcdef_4.conda"))
    files.append(String("linux-64/komira_beta-1.0.0-h11111111_4.conda"))
    files.append(String("linux-64/komira_beta-1.0.0-h22222222_3.conda"))
    var p = newest_build_prefixes(files)
    assert_equal(len(p), 2)
    assert_equal(p[0], String("89abcdef"))
    assert_equal(p[1], String("11111111"))
    assert_equal(len(newest_build_prefixes(List[String]())), 0)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
