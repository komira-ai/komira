# =============================================================================
# src/kci_publish/tests/test_publish_plan_edges.mojo -- plan.mojo at its
#   edges: the refusals of `resolve_targets`, the library order, step 1's
#   count check, the state words, and the build strings that carry no build
#   number or no commit.
# =============================================================================
#
# ROWS
#   (1) `resolve_targets` lists EVERY member it refuses (a file that is not
#       `.conda`, a name that is not the file's), not only the first;
#   (2) libraries come first by set-internal requirement count, whatever
#       order the members arrive in, the metapackage last;
#   (3) `plan_from_state` refuses a channel read whose state count is not
#       the targets';
#   (4) the state words of CANNOT TELL and NOT READ;
#   (5) a build string without `_<digits>`, with nothing after `_`, with 10
#       digits, or a file name that is not `<name>-<version>-<build>.conda`
#       has no build number; 9 digits is one;
#   (6) a listed file with no `.conda` / `.tar.bz2` extension, or whose stem
#       has no `-`, has no build number; a release with no build number
#       supersedes nothing and carries no previous build;
#   (7) a newest listed build whose build string is not `h<8 hex>_<N>` (7
#       hex digits; no leading `h`; a non-hex digit) names no commit:
#       BACKWARD?, never a
#       commit read from the wrong bytes.
#
# Hermetic: TEST_TMPDIR; pure functions; no network.
# =============================================================================

from std.ffi import external_call
from std.os import makedirs

from komira_libc.posix import _read_env
from std.testing import TestSuite, assert_equal, assert_true

from kci_pkg_upload import SUBSTRATE_PREFIX_DEV_CONDA, PackageCoordinate
from kci_release_set.member import ReleaseMember
from kci_publish import (
    STATE_CANNOT_TELL,
    ChannelRead,
    PublishTarget,
    backward_files,
    build_number_of,
    plan_from_state,
    previous_build_number,
    resolve_targets,
    superseding_files,
)
from kci_publish.plan import STATE_NOT_READ, _release_build, newest_listed_build_number, state_name
from kci_publish.release_fixture import ExampleRelease, example_channel, example_loaded, example_targets


def _root(tag: String) raises -> String:
    var base = _read_env("TEST_TMPDIR")
    if base.byte_length() == 0:
        base = _read_env("TMPDIR")
    if base.byte_length() == 0:
        raise Error("neither TEST_TMPDIR nor TMPDIR is set")
    var d = base + String("/ppe_") + tag + String("_") + String(Int(external_call["getpid", Int32]()))
    makedirs(d, exist_ok=True)
    return d^


def _target(file_name: String) -> PublishTarget:
    """komira_alpha 1.0.0 on linux-64 of the example-stable channel, landing
    as `file_name`."""
    return PublishTarget(
        String("komira_alpha"),
        False,
        PackageCoordinate(
            SUBSTRATE_PREFIX_DEV_CONDA,
            String("conda.example.invalid/example/stable"),
            String("komira_alpha"),
            String("1.0.0"),
            String("linux-64"),
            file_name.copy(),
        ),
        String("0000000000000000000000000000000000000000000000000000000000000000"),
        String("/nonexistent/") + file_name,
        0,
    )


def _one(file_name: String) -> List[PublishTarget]:
    var out = List[PublishTarget]()
    out.append(_target(file_name))
    return out^


def _strings(a: String, b: String = String(""), c: String = String(""), d: String = String("")) -> List[String]:
    var out = List[String]()
    out.append(a.copy())
    if b.byte_length() > 0:
        out.append(b.copy())
    if c.byte_length() > 0:
        out.append(c.copy())
    if d.byte_length() > 0:
        out.append(d.copy())
    return out^


def test_resolve_targets_lists_every_refusal() raises:
    var r = ExampleRelease()
    var d = _root(String("refuse"))
    r.write(d)
    var members = example_loaded(r, d).members.copy()
    members[0].manifest.file = String("komira_alpha-1.0.0-h01234567_3.tar.bz2")
    members[1].conda.name = String("komira_gamma")
    var text = String("")
    try:
        _ = resolve_targets(example_channel(String("example-stable")), members)
    except e:
        text = String(e)
    assert_true(
        text.startswith(
            String("PUBLISH step: refused before any read:\n  artifact 'komira_alpha': ")
            + String("'komira_alpha-1.0.0-h01234567_3.tar.bz2' is not a .conda file\n  artifact 'komira_beta': ")
        ),
        text,
    )


def test_libraries_are_ordered_by_internal_requirements() raises:
    var r = ExampleRelease()
    var d = _root(String("order"))
    r.write(d)
    var loaded = example_loaded(r, d).members.copy()
    var reversed = List[ReleaseMember]()
    for i in range(len(loaded)):
        reversed.append(loaded[len(loaded) - 1 - i].copy())
    var t = resolve_targets(example_channel(String("example-stable")), reversed)
    assert_equal(len(t), 3)
    assert_equal(t[0].artifact, String("komira_alpha"))
    assert_equal(t[1].artifact, String("komira_beta"))
    assert_equal(t[2].artifact, String("komira"))


def test_step_1_refuses_a_read_of_another_count() raises:
    var r = ExampleRelease()
    var d = _root(String("count"))
    r.write(d)
    var t = example_targets(r, d)
    var text = String("")
    try:
        _ = plan_from_state(t, ChannelRead())
    except e:
        text = String(e)
    assert_equal(text, String("PUBLISH step: 3 targets but 0 channel states"))


def test_the_state_words() raises:
    assert_equal(state_name(STATE_CANNOT_TELL), String("cannot-tell"))
    assert_equal(state_name(STATE_NOT_READ), String("not-read"))


def test_build_strings_without_a_build_number() raises:
    assert_equal(build_number_of(_target(String("komira_alpha-1.0.0-h01234567.conda"))), -1)
    assert_equal(build_number_of(_target(String("komira_alpha-1.0.0-h01234567_.conda"))), -1)
    assert_equal(build_number_of(_target(String("komira_alpha-1.0.0-h01234567_1234567890.conda"))), -1)
    assert_equal(build_number_of(_target(String("komira_alpha-1.0.0-h01234567_123456789.conda"))), 123456789)
    assert_equal(build_number_of(_target(String("komira_beta-1.0.0-h01234567_3.conda"))), -1)
    assert_equal(build_number_of(_target(String("komira_alpha-1.0.0-.conda"))), -1)
    assert_equal(build_number_of(_target(String("komira_alpha-1.0.0-h0-1_3.conda"))), -1)
    assert_equal(_release_build(List[PublishTarget]()), String(""))


def test_listed_files_without_a_build_number() raises:
    var listed = _strings(
        String("linux-64/komira_alpha-1.0.0-h01234567_9"),
        String("linux-64/h01234567_8.conda"),
        String("noarch/komira_alpha-1.0.0-h01234567_3.tar.bz2"),
        String("linux-64/komira_alpha-1.0.0-h01234567_2.conda"),
    )
    assert_equal(newest_listed_build_number(listed), 3)
    # a release with no build number supersedes nothing, carries nothing
    var unnumbered = _one(String("komira_alpha-1.0.0-h01234567.conda"))
    assert_equal(len(superseding_files(unnumbered, listed)), 0)
    assert_equal(previous_build_number(unnumbered, listed), -1)


def test_a_newest_build_that_names_no_commit() raises:
    var t = _one(String("komira_alpha-1.0.0-h89abcdef_9.conda"))
    var history = _strings(String("0123456000000000000000000000000000000000"), String("abcdefab00000000000000000000000000000000"))
    # each edge of the two allowed ranges ['0'-'9'] and ['a'-'f'] is tried
    # by a byte just outside it: ':' (58), '`' (96), 'g' (103), in the first
    # and in the last of the 8 digits. '/' (47) cannot be tried: a listed
    # path is split at its last '/', so no build string holds one.
    var bads = _strings(String("h0123456_7"), String("x0123abcd_7"), String("hxyzxyzxy_7"))
    bads.append(String("h0123456g_7"))
    bads.append(String("hg1234567_7"))
    bads.append(String("h0123456`_7"))
    bads.append(String("h`1234567_7"))
    bads.append(String("h0123456:_7"))
    bads.append(String("h:1234567_7"))
    for k in range(len(bads)):
        ref bad = bads[k]
        var listed = _strings(String("linux-64/komira_alpha-1.0.0-") + bad + String(".conda"))
        var out = backward_files(t, listed, history)
        assert_equal(len(out), 1, bad)
        assert_true(
            out[0].startswith(String("BACKWARD? linux-64/komira_alpha-1.0.0-h89abcdef_9.conda: the channel's newest build ")),
            out[0],
        )
    # a commit that is on the history is not backward
    var on = _strings(String("linux-64/komira_alpha-1.0.0-habcdefab_7.conda"))
    assert_equal(len(backward_files(t, on, history)), 0)
    # the four in-range edges '0', '9', 'a', 'f' name a commit too
    var edges = _strings(String("09af09af00000000000000000000000000000000"))
    var on_edges = _strings(String("linux-64/komira_alpha-1.0.0-h09af09af_7.conda"))
    assert_equal(len(backward_files(t, on_edges, edges)), 0)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
