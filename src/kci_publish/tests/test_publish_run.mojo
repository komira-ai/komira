# =============================================================================
# src/kci_publish/tests/test_publish_run.mojo -- contract steps 2 to 4:
#   members uploaded, settled by download, every member read back, the
#   metapackage last.
# =============================================================================
#
# ROWS
#   (1) a clean publish: each file uploaded EXACTLY once; the metapackage's
#       upload comes after the last member read-back in the recorded order;
#       the write credential asked ONCE; exit 0;
#   (2) a member already present-same is not uploaded but IS read back;
#   (3) the upload's answer lost after the bytes landed: re-read
#       present-same = done, one upload;
#   (4) the answer lost and nothing stored, every attempt: bounded retry
#       (upload_attempts uploads, never more), then PARTIAL (9);
#   (5) a 409 where the channel holds OUR bytes = success; a 409 where it
#       holds OTHER bytes = STOP (7);
#   (6) a definitive rejection (400) = FAILED (4); later members are not
#       attempted;
#   (7) a member that reads back with other bytes at step 3 = 10;
#   (8) in 4, 7, 9 and 10 the recorded requests hold NO metapackage upload;
#   (9) `ApprovedNames` built from the listing plus claims refuses a name in
#       neither with ZERO requests.
#
# The design's "--concurrency 1 and 4 give the same final state" row is not
# here: uploads are sequential and there is no --concurrency (run.mojo).
#
# Hermetic: ScriptedChannel; RecordingSleeper (no wait); no network.
# =============================================================================

from std.ffi import external_call
from std.os import getenv, makedirs
from std.testing import assert_equal, assert_false, assert_true

from kci_pkg_upload import SURFACE_PREFIX_DEV, RegistrySet, ScriptedCredential
from kci_publish import (
    EXIT_FAILED,
    EXIT_PARTIAL,
    EXIT_PUBLISHED,
    EXIT_READ_BACK_MISMATCH,
    EXIT_STOP_DIFFERENT_BYTES,
    PublishCredential,
    PublishReport,
    PublishTarget,
    RunOptions,
    ScriptedChannel,
    approved_names_for,
    read_channel,
    run_publish,
)
from kci_publish.release_fixture import EXAMPLE_HOST, ExampleRelease, example_targets
from kci_publish.scripted_channel import (
    UPLOAD_ANSWER_400,
    UPLOAD_LOSE_NOT_STORED,
    UPLOAD_STORE_ANSWER_409,
    UPLOAD_STORE_LOSE_ANSWER,
    UPLOAD_STORE_OTHER_BYTES,
)
from kci_publish.upload import package_file_of
from komira_retry import RecordingSleeper


def _root(tag: String) raises -> String:
    var base = getenv("TEST_TMPDIR")
    if base.byte_length() == 0:
        base = getenv("TMPDIR")
    if base.byte_length() == 0:
        raise Error("neither TEST_TMPDIR nor TMPDIR is set")
    var d = base + String("/prn_") + tag + String("_") + String(Int(external_call["getpid", Int32]()))
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
    var ch = ScriptedChannel(String(EXAMPLE_HOST), String("example-stable"), String("linux-64"))
    ch.put(String("linux-64"), String("komira_alpha-0.9.0-h00000000_1.conda"), _bytes(String("old a")))
    ch.put(String("linux-64"), String("komira_beta-0.9.0-h00000000_1.conda"), _bytes(String("old b")))
    ch.put(String("linux-64"), String("komira-0.9.0-h00000000_1.conda"), _bytes(String("old m")))
    return ch^


def _registry(var ch: ScriptedChannel) -> RegistrySet[ScriptedChannel, PublishCredential]:
    var c = PublishCredential()
    c.configure(SURFACE_PREFIX_DEV, String(EXAMPLE_HOST), String(""))
    return RegistrySet[ScriptedChannel, PublishCredential](ch^, c^)


def _src() -> ScriptedCredential:
    var s = ScriptedCredential()
    s.serve(SURFACE_PREFIX_DEV, String("Bearer pfx-test-token"))
    return s^


def _run(
    targets: List[PublishTarget],
    mut reg: RegistrySet[ScriptedChannel, PublishCredential],
    mut src: ScriptedCredential,
    upload_attempts: Int = 2,
) -> PublishReport:
    var sl = RecordingSleeper()
    return run_publish(
        targets, List[String](), reg, src, False,
        RunOptions(2, 0, upload_attempts, 0, 0, 1, 0), sl, PublishReport(),
    )


def _no_meta_upload(reg: RegistrySet[ScriptedChannel, PublishCredential], meta: String) raises:
    assert_equal(reg.transport().upload_count(meta), 0, String("the metapackage was uploaded"))


def test_a_clean_publish() raises:
    var t = _targets(String("clean"))
    var reg = _registry(_channel())
    var src = _src()
    var rep = _run(t, reg, src)
    assert_equal(rep.exit_code, EXIT_PUBLISHED, String("\n").join(rep.lines))
    ref ch = reg.transport()
    for i in range(len(t)):
        assert_equal(ch.upload_count(t[i].coordinate.file_name), 1, t[i].coordinate.file_name)
        assert_true(ch.holds(String("linux-64"), t[i].coordinate.file_name))
    var meta_at = ch.first_upload_call(t[2].coordinate.file_name)
    assert_true(meta_at > ch.last_fetch_call(String("linux-64"), t[0].coordinate.file_name))
    assert_true(meta_at > ch.last_upload_call(t[1].coordinate.file_name))
    # step 3 read every member back before the metapackage went
    var reads_before = 0
    for i in range(meta_at):
        if ch.call(i).path.endswith(t[1].coordinate.file_name) and len(ch.call(i).body) == 0:
            reads_before += 1
    assert_true(reads_before >= 3, String("beta read at step 1, settle and step 3"))
    assert_equal(src.asked_count(), 1)
    assert_equal(ch.call(meta_at).header_value(String("Authorization")), String("Bearer pfx-test-token"))
    print("  test_a_clean_publish: PASS")


def test_a_present_member_is_read_back_not_uploaded() raises:
    var t = _targets(String("present"))
    var ch = _channel()
    ch.put(String("linux-64"), t[0].coordinate.file_name, _bytes(String("alpha conda bytes")))
    var reg = _registry(ch^)
    var src = _src()
    var rep = _run(t, reg, src)
    assert_equal(rep.exit_code, EXIT_PUBLISHED, String("\n").join(rep.lines))
    assert_equal(reg.transport().upload_count(t[0].coordinate.file_name), 0)
    var meta_at = reg.transport().first_upload_call(t[2].coordinate.file_name)
    var alpha_reads = 0
    for i in range(meta_at):
        if reg.transport().call(i).path.endswith(t[0].coordinate.file_name):
            alpha_reads += 1
    assert_equal(alpha_reads, 2, String("step 1 and step 3"))
    print("  test_a_present_member_is_read_back_not_uploaded: PASS")


def test_a_lost_answer_settles_by_download() raises:
    var t = _targets(String("lost"))
    var ch = _channel()
    ch.plan_upload(t[0].coordinate.file_name, UPLOAD_STORE_LOSE_ANSWER)
    var reg = _registry(ch^)
    var src = _src()
    var rep = _run(t, reg, src)
    assert_equal(rep.exit_code, EXIT_PUBLISHED, String("\n").join(rep.lines))
    assert_equal(reg.transport().upload_count(t[0].coordinate.file_name), 1)
    print("  test_a_lost_answer_settles_by_download: PASS")


def test_absent_after_bounded_retries_is_partial() raises:
    var t = _targets(String("partial"))
    var ch = _channel()
    for _ in range(5):
        ch.plan_upload(t[1].coordinate.file_name, UPLOAD_LOSE_NOT_STORED)
    var reg = _registry(ch^)
    var src = _src()
    var rep = _run(t, reg, src, 3)
    assert_equal(rep.exit_code, EXIT_PARTIAL, String("\n").join(rep.lines))
    assert_equal(reg.transport().upload_count(t[1].coordinate.file_name), 3)
    assert_true(rep.has_line_containing(String("MISSING linux-64/") + t[1].coordinate.file_name))
    _no_meta_upload(reg, t[2].coordinate.file_name)
    print("  test_absent_after_bounded_retries_is_partial: PASS")


def test_a_409_is_settled_by_what_the_channel_holds() raises:
    var t = _targets(String("dup"))
    var ch = _channel()
    ch.plan_upload(t[0].coordinate.file_name, UPLOAD_STORE_ANSWER_409)
    var reg = _registry(ch^)
    var src = _src()
    var rep = _run(t, reg, src)
    assert_equal(rep.exit_code, EXIT_PUBLISHED, String("\n").join(rep.lines))
    assert_equal(reg.transport().upload_count(t[0].coordinate.file_name), 1)

    var ch2 = _channel()
    ch2.plan_upload(t[0].coordinate.file_name, UPLOAD_STORE_OTHER_BYTES)
    var reg2 = _registry(ch2^)
    var rep2 = _run(t, reg2, src)
    assert_equal(rep2.exit_code, EXIT_STOP_DIFFERENT_BYTES, String("\n").join(rep2.lines))
    assert_equal(reg2.transport().upload_count(t[0].coordinate.file_name), 1)
    _no_meta_upload(reg2, t[2].coordinate.file_name)
    assert_equal(reg2.transport().upload_count(t[1].coordinate.file_name), 0)
    print("  test_a_409_is_settled_by_what_the_channel_holds: PASS")


def test_a_rejection_fails_and_stops() raises:
    var t = _targets(String("reject"))
    var ch = _channel()
    ch.plan_upload(t[0].coordinate.file_name, UPLOAD_ANSWER_400)
    var reg = _registry(ch^)
    var src = _src()
    var rep = _run(t, reg, src)
    assert_equal(rep.exit_code, EXIT_FAILED, String("\n").join(rep.lines))
    assert_equal(reg.transport().upload_count(t[0].coordinate.file_name), 1)
    assert_equal(reg.transport().upload_count(t[1].coordinate.file_name), 0)
    assert_true(rep.has_line_containing(String("NOT-ATTEMPTED linux-64/") + t[1].coordinate.file_name))
    _no_meta_upload(reg, t[2].coordinate.file_name)
    print("  test_a_rejection_fails_and_stops: PASS")


def test_a_read_back_mismatch_withholds_the_metapackage() raises:
    var t = _targets(String("mismatch"))
    var ch = _channel()
    # alpha: GET 1 at step 1 (404), GET 2 settles, GET 3 is step 3
    ch.other_bytes_on_fetch(String("linux-64"), t[0].coordinate.file_name, 3)
    var reg = _registry(ch^)
    var src = _src()
    var rep = _run(t, reg, src)
    assert_equal(rep.exit_code, EXIT_READ_BACK_MISMATCH, String("\n").join(rep.lines))
    assert_true(rep.has_line_containing(String("READ-BACK linux-64/") + t[0].coordinate.file_name))
    _no_meta_upload(reg, t[2].coordinate.file_name)
    print("  test_a_read_back_mismatch_withholds_the_metapackage: PASS")


def test_the_uploader_gate_is_built_from_listing_and_claims() raises:
    var t = _targets(String("gate"))
    var ch = ScriptedChannel(String(EXAMPLE_HOST), String("example-stable"), String("linux-64"))
    ch.put(String("linux-64"), String("komira_alpha-0.9.0-h00000000_1.conda"), _bytes(String("old a")))
    var reg = _registry(ch^)
    var channel_read = read_channel(reg, t)
    var claims = List[String]()
    claims.append(String("komira"))
    var names = approved_names_for(t, channel_read, claims)
    var before = reg.transport().call_count()
    reg.credential().arm(String("Bearer pfx-test-token"))
    var raised = False
    try:
        _ = reg.upload(package_file_of(t[1]), names)
    except e:
        raised = True
        assert_true(String(e).find(String("'komira_beta' is not in the approved-names list")) >= 0, String(e))
    assert_true(raised, String("komira_beta was neither held nor claimed"))
    assert_equal(reg.transport().call_count(), before)
    print("  test_the_uploader_gate_is_built_from_listing_and_claims: PASS")


def main() raises:
    test_a_clean_publish()
    test_a_present_member_is_read_back_not_uploaded()
    test_a_lost_answer_settles_by_download()
    test_absent_after_bounded_retries_is_partial()
    test_a_409_is_settled_by_what_the_channel_holds()
    test_a_rejection_fails_and_stops()
    test_a_read_back_mismatch_withholds_the_metapackage()
    test_the_uploader_gate_is_built_from_listing_and_claims()
    print("test_publish_run: ALL PASS")
