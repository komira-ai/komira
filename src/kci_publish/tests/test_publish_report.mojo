# =============================================================================
# src/kci_publish/tests/test_publish_report.mojo -- contract step 6: one JSON
#   report per run, no secret in it, and one exit code per verdict.
# =============================================================================
#
# ROWS
#   (1) the whole verb over a channel holding older releases of every name:
#       exit 0; the report at --report has exactly the keys channel,
#       dry_run, exit_code, files, release_commit, set_hash, verdict; one row
#       per file in upload order (alpha, beta, the metapackage last) with
#       state_before absent, action uploaded, state_after present-same,
#       indexed true; the API token resolved by secret NAME from the store;
#   (2) the token string appears in no line and nowhere in the report, on a
#       publish and on a STOP;
#   (3) a STOP (other bytes under the metapackage's name) writes a report
#       too, exit_code 7, verdict STOP_DIFFERENT_BYTES, that file
#       present-different;
#   (4) every exit code has its own verdict word.
#
# Hermetic: TEST_TMPDIR, ScriptedChannel, StaticSecretStore; no network.
# =============================================================================

from std.ffi import external_call
from std.os import getenv, makedirs
from std.testing import assert_equal, assert_false, assert_true

from komira_json import parse_json_value
from komira_secret_store import StaticSecretStore

from kci_pkg_upload import RegistrySet, ScriptedPkgTransport
from kci_publish import (
    EXIT_ALREADY_PUBLISHED,
    EXIT_CANNOT_TELL,
    EXIT_FAILED,
    EXIT_PARTIAL,
    EXIT_PUBLISHED,
    EXIT_READ_BACK_MISMATCH,
    EXIT_REFUSED,
    EXIT_STOP_DIFFERENT_BYTES,
    EXIT_STOP_NEW_NAME,
    EXIT_USAGE,
    PublishCredential,
    PublishFlags,
    PublishReport,
    RunOptions,
    ScriptedChannel,
    publish_flow,
)
from kci_publish.release_fixture import (
    EXAMPLE_CHANNELS,
    EXAMPLE_HOST,
    EXAMPLE_TOKEN_SECRET,
    ExampleRelease,
    write_text_file,
)
from kci_publish.report import verdict_name
from komira_retry import RecordingSleeper


comptime _TOKEN: String = "pfx-report-secret-0123456789abcdefghij"


def _root(tag: String) raises -> String:
    var base = getenv("TEST_TMPDIR")
    if base.byte_length() == 0:
        base = getenv("TMPDIR")
    if base.byte_length() == 0:
        raise Error("neither TEST_TMPDIR nor TMPDIR is set")
    var d = base + String("/prp_") + tag + String("_") + String(Int(external_call["getpid", Int32]()))
    makedirs(d, exist_ok=True)
    return d^


def _bytes(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    var b = s.as_bytes()
    for i in range(len(b)):
        out.append(b[i])
    return out^


def _flags(d: String, r: ExampleRelease) raises -> PublishFlags:
    r.write(d + String("/release"))
    write_text_file(d + String("/decls.textproto"), r.declarations_text())
    write_text_file(d + String("/channels.textproto"), String(EXAMPLE_CHANNELS))
    write_text_file(d + String("/rv.txt"), r.release_version_text())
    var f = PublishFlags()
    f.declarations_file = d + String("/decls.textproto")
    f.artifacts_dir = d + String("/release")
    f.channels_file = d + String("/channels.textproto")
    f.channel = String("example-stable")
    f.release_version_file = d + String("/rv.txt")
    f.expect_set_hash = r.set_hash(d + String("/release"))
    f.report_file = d + String("/report.json")
    return f^


def _channel() -> ScriptedChannel:
    var ch = ScriptedChannel(String(EXAMPLE_HOST), String("example-stable"), String("linux-64"))
    ch.put(String("linux-64"), String("komira_alpha-0.9.0-h00000000_1.conda"), _bytes(String("old a")))
    ch.put(String("linux-64"), String("komira_beta-0.9.0-h00000000_1.conda"), _bytes(String("old b")))
    ch.put(String("linux-64"), String("komira-0.9.0-h00000000_1.conda"), _bytes(String("old m")))
    return ch^


def _flow(f: PublishFlags, var ch: ScriptedChannel) -> PublishReport:
    var reg = RegistrySet[ScriptedChannel, PublishCredential](ch^, PublishCredential())
    var store = StaticSecretStore()
    store.put(String(EXAMPLE_TOKEN_SECRET), String(_TOKEN))
    var sl = RecordingSleeper()
    return publish_flow(f, reg, ScriptedPkgTransport(), store, RunOptions(2, 0, 2, 0, 0, 2, 0), sl)


def _no_token(rep: PublishReport, report_text: String) raises:
    assert_false(rep.has_line_containing(String(_TOKEN)))
    assert_false(rep.has_line_containing(String(String(_TOKEN)[byte=0:16])))
    assert_true(report_text.find(String(String(_TOKEN)[byte=0:16])) < 0, report_text)


def test_the_report_of_a_publish() raises:
    var r = ExampleRelease()
    var d = _root(String("ok"))
    var f = _flags(d, r)
    var rep = _flow(f, _channel())
    assert_equal(rep.exit_code, EXIT_PUBLISHED, String("\n").join(rep.lines))
    var text = open(f.report_file, "r").read()
    assert_true(text.endswith(String("}\n")))
    var doc = parse_json_value(text)
    var keys = List[String]()
    keys.append(String("channel"))
    keys.append(String("dry_run"))
    keys.append(String("exit_code"))
    keys.append(String("files"))
    keys.append(String("release_commit"))
    keys.append(String("set_hash"))
    keys.append(String("verdict"))
    assert_equal(doc.num_members(), len(keys))
    for i in range(len(keys)):
        assert_equal(doc.key_at(i), keys[i])
    assert_equal(doc.get(String("channel")).as_string(), String("example-stable"))
    assert_equal(doc.get(String("verdict")).as_string(), String("PUBLISHED"))
    assert_equal(doc.get(String("set_hash")).as_string(), f.expect_set_hash)
    assert_equal(doc.get(String("release_commit")).as_string(), r.commit)
    assert_false(doc.get(String("dry_run")).as_bool())
    var files = doc.get(String("files"))
    assert_equal(files.array_len(), 3)
    var order = List[String]()
    order.append(String("komira_alpha"))
    order.append(String("komira_beta"))
    order.append(String("komira"))
    for i in range(3):
        var row = files.element_at(i)
        assert_equal(row.get(String("name")).as_string(), order[i])
        assert_equal(row.get(String("file")).as_string(), String("linux-64/") + r.file_name(order[i]))
        assert_equal(row.get(String("sha256")).as_string(), r.sha256_of(order[i]))
        assert_equal(row.get(String("state_before")).as_string(), String("absent"))
        assert_equal(row.get(String("action")).as_string(), String("uploaded"))
        assert_equal(row.get(String("state_after")).as_string(), String("present-same"))
        assert_true(row.get(String("indexed")).as_bool())
    _no_token(rep, text)
    print("  test_the_report_of_a_publish: PASS")


def test_a_stop_writes_a_report_too() raises:
    var r = ExampleRelease()
    var d = _root(String("stop"))
    var f = _flags(d, r)
    var ch = _channel()
    ch.put(String("linux-64"), r.file_name(String("komira")), _bytes(String("not our metapackage")))
    var rep = _flow(f, ch^)
    assert_equal(rep.exit_code, EXIT_STOP_DIFFERENT_BYTES, String("\n").join(rep.lines))
    var text = open(f.report_file, "r").read()
    var doc = parse_json_value(text)
    assert_equal(doc.get(String("exit_code")).serialize(), String("7"))
    assert_equal(doc.get(String("verdict")).as_string(), String("STOP_DIFFERENT_BYTES"))
    var meta_row = doc.get(String("files")).element_at(2)
    assert_equal(meta_row.get(String("state_before")).as_string(), String("present-different"))
    assert_equal(meta_row.get(String("action")).as_string(), String("none"))
    _no_token(rep, text)
    print("  test_a_stop_writes_a_report_too: PASS")


def test_one_verdict_word_per_exit_code() raises:
    var codes = List[Int]()
    codes.append(EXIT_PUBLISHED)
    codes.append(EXIT_USAGE)
    codes.append(EXIT_REFUSED)
    codes.append(EXIT_FAILED)
    codes.append(EXIT_CANNOT_TELL)
    codes.append(EXIT_ALREADY_PUBLISHED)
    codes.append(EXIT_STOP_DIFFERENT_BYTES)
    codes.append(EXIT_STOP_NEW_NAME)
    codes.append(EXIT_PARTIAL)
    codes.append(EXIT_READ_BACK_MISMATCH)
    var want = List[Int]()
    want.append(0)
    for c in range(2, 11):
        want.append(c)
    for i in range(len(codes)):
        assert_equal(codes[i], want[i])
        for j in range(i):
            assert_true(verdict_name(codes[i]) != verdict_name(codes[j]))
        assert_false(verdict_name(codes[i]).startswith(String("EXIT(")))
    print("  test_one_verdict_word_per_exit_code: PASS")


def main() raises:
    test_the_report_of_a_publish()
    test_a_stop_writes_a_report_too()
    test_one_verdict_word_per_exit_code()
    print("test_publish_report: ALL PASS")
