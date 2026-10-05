# =============================================================================
# src/kci_publish/tests/test_publish_never_backward.mojo -- a stage that
#   never goes backward (kci_cli sets it for a stage without break_glass:
#   prod) refuses to publish a release whose build number is LOWER than a
#   build of the same name and version its channel already lists.
# =============================================================================
#
#   (1) the channel lists a member at the same version with a HIGHER build
#       number: REFUSED, KCI-E-SUPERSEDED, exit 3, retry NEEDS_HUMAN, and no
#       upload request at all (a dry run says the same);
#   (2) the same channel without the rule (a break-glass stage: gamma)
#       publishes;
#   (3) an EQUAL build number of another commit, a LOWER one, and a higher
#       one of ANOTHER version or another name do not supersede;
#   (4) a re-run whose files are all present (equal N) is NOOP, exit 0, even
#       when a higher build is listed: nothing would be written;
#   (5) what a never-backward publish CARRIES: its build number and the
#       highest LOWER build of a member's name and version the channel lists
#       (-1 for none), so kci_cli can name the commits in between.
#
# Hermetic: ScriptedChannel; NoWaitSleeper; no network.
# =============================================================================

from std.ffi import external_call
from std.os import makedirs

from komira_libc.posix import _read_env
from std.testing import assert_equal, assert_true

from kci_api import EXIT_OK, EXIT_REFUSED, RETRY_NEEDS_HUMAN, default_retry
from kci_pkg_upload import SURFACE_PREFIX_DEV, RegistrySet, ScriptedCredential
from kci_publish import (
    NoWaitSleeper,
    REASON_ALREADY_PUBLISHED,
    REASON_PUBLISHED,
    REASON_REFUSED,
    PublishCredential,
    PublishReport,
    PublishTarget,
    RunOptions,
    ScriptedChannel,
    previous_build_number,
    run_publish,
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


def _run(
    targets: List[PublishTarget],
    mut reg: RegistrySet[ScriptedChannel, PublishCredential],
    never_backward: Bool,
    plan: Bool = False,
) -> PublishReport:
    var src = ScriptedCredential()
    src.serve(SURFACE_PREFIX_DEV, String("Bearer pfx-test-token"))
    var sl = NoWaitSleeper()
    var opts = RunOptions(2, 0, 2, 0, 0, 1, 0, concurrency=4)
    opts.never_backward = never_backward
    return run_publish(targets, reg, src, plan, opts, sl, PublishReport())


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
        "komira_alpha-1.0.0-h89abcdef_3.conda",  # equal N, another commit
        "komira_alpha-1.0.0-h89abcdef_2.conda",  # lower N
        "komira_alpha-1.0.1-h89abcdef_9.conda",  # another version
        "komira_gamma-1.0.0-h89abcdef_9.conda",  # another name
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
    # nothing of this version listed (another version's build 9 is not it): -1
    var reg2 = _registry(_channel(String("komira_alpha-1.0.1-h89abcdef_9.conda")))
    var rep2 = _run(t, reg2, True)
    assert_equal(rep2.previous_build, -1)
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


def main() raises:
    test_what_a_release_carries()
    test_a_higher_build_number_supersedes()
    test_without_the_rule_it_publishes()
    test_what_does_not_supersede()
    test_an_equal_rerun_is_noop_even_when_superseded()
