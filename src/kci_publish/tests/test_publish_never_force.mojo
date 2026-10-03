# =============================================================================
# src/kci_publish/tests/test_publish_never_force.mojo -- contract step 2:
#   never an overwrite. Over EVERY request recorded by every publish scenario
#   (a clean run, a lost answer, a 409 of our bytes, a 409 of other bytes,
#   bounded retries, a rejection, a read-back mismatch), no path, query,
#   header or form-part header says `force`, and the channel counted no
#   force request.
#
# Hermetic: ScriptedChannel; NoWaitSleeper; no network.
# =============================================================================

from std.ffi import external_call
from std.os import makedirs

from komira_libc.posix import _read_env
from std.testing import assert_equal, assert_true

from komira_http_core.codec.types import HTTP_METHOD_POST

from kci_pkg_upload import SURFACE_PREFIX_DEV, PkgRequest, RegistrySet, ScriptedCredential
from kci_publish import PublishCredential, PublishReport, PublishTarget, RunOptions, ScriptedChannel, run_publish
from kci_publish.release_fixture import EXAMPLE_HOST, ExampleRelease, example_targets
from kci_publish.scripted_channel import (
    UPLOAD_ANSWER_400,
    UPLOAD_ANSWER_500,
    UPLOAD_LOSE_NOT_STORED,
    UPLOAD_STORE,
    UPLOAD_STORE_ANSWER_409,
    UPLOAD_STORE_LOSE_ANSWER,
    UPLOAD_STORE_OTHER_BYTES,
)
from kci_publish import NoWaitSleeper


def _root(tag: String) raises -> String:
    var base = _read_env("TEST_TMPDIR")
    if base.byte_length() == 0:
        base = _read_env("TMPDIR")
    if base.byte_length() == 0:
        raise Error("neither TEST_TMPDIR nor TMPDIR is set")
    var d = base + String("/pnf_") + tag + String("_") + String(Int(external_call["getpid", Int32]()))
    makedirs(d, exist_ok=True)
    return d^


def _bytes(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    var b = s.as_bytes()
    for i in range(len(b)):
        out.append(b[i])
    return out^


def _lower(s: String) -> String:
    var out = String("")
    var b = s.as_bytes()
    for i in range(len(b)):
        var c = b[i]
        if c >= UInt8(65) and c <= UInt8(90):
            c += UInt8(32)
        out += chr(Int(c))
    return out^


def _part_head(body: List[UInt8]) -> String:
    """The form part's headers: everything before the first blank line."""
    var out = String("")
    for i in range(len(body)):
        if i + 3 < len(body) and body[i] == UInt8(13) and body[i + 1] == UInt8(10) and body[i + 2] == UInt8(13) and body[i + 3] == UInt8(10):
            break
        out += chr(Int(body[i]))
    return out^


def _assert_no_force(req: PkgRequest, scenario: String) raises:
    var where = scenario + String(": ") + req.host + req.path
    assert_true(_lower(req.path).find(String("force")) < 0, where)
    for i in range(len(req.header_names)):
        assert_true(_lower(req.header_names[i]).find(String("force")) < 0, where)
        assert_true(_lower(req.header_values[i]).find(String("force")) < 0, where)
    if req.method == HTTP_METHOD_POST:
        assert_true(_lower(_part_head(req.body)).find(String("force")) < 0, where)


def _scenario(t: List[PublishTarget], kind: Int, name: String) raises -> Int:
    var ch = ScriptedChannel(String(EXAMPLE_HOST), String("example-stable"), String("linux-64"))
    ch.put(String("linux-64"), String("komira_alpha-0.9.0-h00000000_1.conda"), _bytes(String("old a")))
    ch.put(String("linux-64"), String("komira_beta-0.9.0-h00000000_1.conda"), _bytes(String("old b")))
    ch.put(String("linux-64"), String("komira-0.9.0-h00000000_1.conda"), _bytes(String("old m")))
    for _ in range(3):
        ch.plan_upload(t[0].coordinate.file_name, kind)
    if name == String("mismatch"):
        ch.other_bytes_on_fetch(String("linux-64"), t[1].coordinate.file_name, 3)
    var c = PublishCredential()
    c.configure(SURFACE_PREFIX_DEV, String(EXAMPLE_HOST), String(""))
    var reg = RegistrySet[ScriptedChannel, PublishCredential](ch^, c^)
    var src = ScriptedCredential()
    src.serve(SURFACE_PREFIX_DEV, String("Bearer pfx-test-token"))
    var sl = NoWaitSleeper()
    var rep = run_publish(t, List[String](), reg, src, False, RunOptions(2, 0, 3, 0, 0, 1, 0), sl, PublishReport())
    ref got = reg.transport()
    assert_equal(got.force_request_count(), 0, name)
    var posts = 0
    for i in range(got.call_count()):
        var req = got.call(i)
        _assert_no_force(req, name)
        if req.method == HTTP_METHOD_POST:
            posts += 1
    assert_true(posts > 0, name + String(": the scenario made no upload, so it checks nothing (exit ") + String(rep.exit_code) + String(")"))
    return got.call_count()


def test_no_request_of_any_scenario_says_force() raises:
    var r = ExampleRelease()
    var d = _root(String("all"))
    r.write(d)
    var t = example_targets(r, d)
    var total = 0
    total += _scenario(t, UPLOAD_STORE, String("clean"))
    total += _scenario(t, UPLOAD_STORE_LOSE_ANSWER, String("lost answer"))
    total += _scenario(t, UPLOAD_STORE_ANSWER_409, String("409 ours"))
    total += _scenario(t, UPLOAD_STORE_OTHER_BYTES, String("409 other"))
    total += _scenario(t, UPLOAD_LOSE_NOT_STORED, String("retries"))
    total += _scenario(t, UPLOAD_ANSWER_500, String("5xx"))
    total += _scenario(t, UPLOAD_ANSWER_400, String("rejected"))
    total += _scenario(t, UPLOAD_STORE, String("mismatch"))
    assert_true(total > 50, String("only ") + String(total) + String(" requests were checked"))
    print("  test_no_request_of_any_scenario_says_force: PASS (" + String(total) + " requests)")


def main() raises:
    test_no_request_of_any_scenario_says_force()
    print("test_publish_never_force: ALL PASS")
