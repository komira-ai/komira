# =============================================================================
# src/kci_publish/tests/test_publish_new_names_summary.mojo -- NEW NAMES for
#   a later stage, read anonymously, and the job-summary block an approver
#   reads before approving it.
# =============================================================================
#
# ROWS
#   (1) a later stage's PUBLISH step (`prod`, a PUBLIC channel holding an
#       older file of `komira_alpha` only): READ, NEW = komira_beta and
#       komira, never komira_alpha; ZERO writes; every request anonymous;
#   (2) a PRIVATE channel is NOT READ (its stage's credential is needed),
#       with ZERO requests;
#   (3) a listing that cannot be read is NOT READ (cannot tell), never "no
#       new names";
#   (4) a request step 0 refuses (another revision) is NOT READ, naming why,
#       with ZERO requests;
#   (5) the markdown block: the heading names the channel's path, then each
#       new name; `none` when the channel holds every name; `not read: ...`
#       (and never `none`) when it was not read;
#   (6) a step's own report gives the same block (`new_names_of`).
#
# Hermetic: TEST_TMPDIR, ScriptedChannel; no network.
# =============================================================================

from std.ffi import external_call
from std.os import getenv, makedirs
from std.testing import TestSuite, assert_equal, assert_false, assert_true

from kci_pkg_upload import RegistrySet
from kci_publish import (
    NewNamesReport,
    PublishCredential,
    PublishReport,
    PublishRequest,
    ScriptedChannel,
    lookahead_new_names,
    new_names_markdown,
    new_names_of,
)
from kci_publish.release_fixture import EXAMPLE_HOST, ExampleRelease, example_channel_path, write_example_inputs


def _root(tag: String) raises -> String:
    var base = getenv("TEST_TMPDIR")
    if base.byte_length() == 0:
        base = getenv("TMPDIR")
    if base.byte_length() == 0:
        raise Error("neither TEST_TMPDIR nor TMPDIR is set")
    var d = base + String("/pnn_") + tag + String("_") + String(Int(external_call["getpid", Int32]()))
    makedirs(d, exist_ok=True)
    return d^


def _bytes(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    var b = s.as_bytes()
    for i in range(len(b)):
        out.append(b[i])
    return out^


def _prod_req(tag: String) raises -> PublishRequest:
    """The request the later stage `publish-prod` would run: channel `prod`,
    environment `prod`, not a dry run (the lookahead reads anyway)."""
    return write_example_inputs(ExampleRelease(), _root(tag), String("prod"), False)


def _registry(channel: String) raises -> RegistrySet[ScriptedChannel, PublishCredential]:
    var ch = ScriptedChannel(String(EXAMPLE_HOST), example_channel_path(channel), String("linux-64"))
    ch.put(String("linux-64"), String("komira_alpha-0.9.0-h00000000_1.conda"), _bytes(String("old a")))
    return RegistrySet[ScriptedChannel, PublishCredential](ch^, PublishCredential())


def test_a_later_stage_is_read_anonymously() raises:
    var reg = _registry(String("prod"))
    var r = lookahead_new_names(reg, _prod_req(String("later")))
    assert_true(r.read, r.detail)
    assert_equal(r.stage, String("publish-prod"))
    assert_equal(r.step, String("publish"))
    assert_equal(r.channel, String("prod"))
    assert_equal(r.channel_path, String("example/prod"))
    assert_equal(String(",").join(r.names), String("komira_beta,komira"))
    assert_equal(reg.transport().write_count(), 0)
    assert_true(reg.transport().call_count() > 0)
    for i in range(reg.transport().call_count()):
        assert_equal(reg.transport().call(i).header_value(String("Authorization")), String(""))


def test_a_private_channel_is_not_read() raises:
    var req = write_example_inputs(ExampleRelease(), _root(String("private")), String("example-private"), False)
    var reg = _registry(String("example-private"))
    var r = lookahead_new_names(reg, req)
    assert_false(r.read)
    assert_equal(len(r.names), 0)
    assert_true(r.detail.find(String("channel 'example-private' is PRIVATE; reading it needs the credential of stage 'publish-prod'")) >= 0, r.detail)
    assert_equal(reg.transport().call_count(), 0)


def test_an_unread_listing_is_not_read() raises:
    var ch = ScriptedChannel(String(EXAMPLE_HOST), example_channel_path(String("prod")), String("linux-64"))
    ch.fail_listing(String("noarch"))
    var reg = RegistrySet[ScriptedChannel, PublishCredential](ch^, PublishCredential())
    var r = lookahead_new_names(reg, _prod_req(String("unread")))
    assert_false(r.read)
    assert_equal(len(r.names), 0)
    assert_true(r.detail.find(String("cannot tell which names the channel holds")) >= 0, r.detail)


def test_a_refused_request_is_not_read() raises:
    var req = _prod_req(String("refused"))
    req.revision_id = String("0000000000000000000000000000000000000001")
    var reg = _registry(String("prod"))
    var r = lookahead_new_names(reg, req)
    assert_false(r.read)
    assert_true(r.detail.startswith(String("not read: ")), r.detail)
    assert_true(r.detail.find(String("was built from revision")) >= 0, r.detail)
    assert_equal(reg.transport().call_count(), 0)


def test_the_markdown_block() raises:
    var r = NewNamesReport(String("publish-prod"), String("publish"), String("prod"))
    r.channel_path = String("komira-ai/prod")
    r.read = True
    r.names.append(String("komira_all"))
    var md = new_names_markdown(r)
    assert_equal(
        md,
        String("### NEW NAMES on komira-ai/prod\n\nStage `publish-prod`, step `publish`, channel `prod`.\n\n- `komira_all`\n\n"),
    )
    var held = NewNamesReport(String("publish-prod"), String("publish"), String("prod"))
    held.channel_path = String("komira-ai/prod")
    held.read = True
    assert_true(new_names_markdown(held).find(String("\n\nnone\n")) >= 0)
    var unread = NewNamesReport(String("publish-prod"), String("publish"), String("prod"))
    unread.channel_path = String("komira-ai/prod")
    unread.detail = String("not read: channel 'prod' is PRIVATE")
    var u = new_names_markdown(unread)
    assert_true(u.find(String("### NEW NAMES on komira-ai/prod")) >= 0, u)
    assert_true(u.find(String("\n\nnot read: channel 'prod' is PRIVATE\n")) >= 0, u)
    assert_true(u.find(String("none")) < 0, u)


def test_a_steps_own_report() raises:
    var rep = PublishReport()
    rep.channel = String("gamma")
    rep.channel_path = String("komira-ai/gamma")
    rep.names_known = True
    rep.new_names.append(String("komira_all"))
    var r = new_names_of(rep, String("publish-gamma"), String("publish"))
    assert_true(r.read)
    assert_true(new_names_markdown(r).find(String("### NEW NAMES on komira-ai/gamma")) >= 0)
    var unknown = PublishReport()
    unknown.channel = String("gamma")
    var u = new_names_of(unknown, String("publish-gamma"), String("publish"))
    assert_false(u.read)
    assert_true(new_names_markdown(u).find(String("none")) < 0)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
