# =============================================================================
# src/kci_publish/tests/test_publish_result.mojo -- contract step 6: the
#   PUBLISH step's part of the run's one result document (kci_api's
#   `kci.result`), no secret in it, and one outcome per reason.
# =============================================================================
#
# ROWS
#   (1) the whole step over a channel holding older releases of every
#       name: SUCCEEDED, exit 0; the RUNNING record was written once, before
#       the first request, naming the revision and the run; the result holds
#       one PUBLISH step row, the channel, the recomputed set hash, who
#       produced the release (release.json's `produced_by`), and one
#       artifact row per file in upload order (alpha, beta, the metapackage
#       last) with effect UPLOADED, the revision, the platform, the subdir,
#       state_before absent, state_after present-same, indexed true; the API
#       token resolved by secret NAME from the store; the rendered document
#       parses back to the same value;
#   (2) the token string appears in no line and nowhere in the document, on
#       a publish and on a STOP;
#   (3) a STOP (other bytes under the metapackage's name, nothing uploaded):
#       REFUSED, exit 3, error KCI-E-PUBLISH-DIFFERENT-BYTES whose message
#       names the file; the metapackage row NOT_REACHED and
#       present-different, the members NOT_REACHED and absent;
#   (4) the whole step run AGAIN over the channel the first run filled:
#       NOOP, exit 0 (not a separate "already published" number), every row
#       ALREADY_PRESENT, no upload;
#   (5) every reason has one outcome, by the table in report.mojo, with and
#       without an upload landed;
#   (6) NEW NAMES in the result: a name the channel holds no file of is one
#       `new_names[]` row {stage, step, channel, name}; a name it holds is
#       none; the document holds no `expect_set_hash` key; a dry run over an
#       API-token channel records the credential probe NOT_OIDC, a real run
#       records none.
#
# Hermetic: TEST_TMPDIR, ScriptedChannel, StaticSecretStore; no network.
# =============================================================================

from std.ffi import external_call
from std.os import getenv, makedirs
from std.testing import assert_equal, assert_false, assert_true

from komira_secret_store import StaticSecretStore

from kci_api import (
    STEP_KIND_PUBLISH,
    ARTIFACT_ALREADY_PRESENT,
    ARTIFACT_NOT_REACHED,
    ARTIFACT_UPLOADED,
    ERROR_PUBLISH_DIFFERENT_BYTES,
    EXIT_CANNOT_TELL,
    EXIT_FAILED,
    EXIT_OK,
    EXIT_PARTIAL,
    EXIT_REFUSED,
    OUTCOME_NOOP,
    OUTCOME_SUCCEEDED,
    STATUS_RUNNING,
    MemoryRecorder,
    parse_result,
    render_result,
)
from kci_api import RunResult as KciRunResult
from kci_pkg_upload import RegistrySet, ScriptedPkgTransport
from kci_publish import (
    ActionsOidcEnv,
    REASON_ALREADY_PUBLISHED,
    REASON_CANNOT_TELL,
    REASON_FAILED,
    REASON_PARTIAL,
    REASON_PUBLISHED,
    REASON_READ_BACK_MISMATCH,
    REASON_REFUSED,
    REASON_STOP_DIFFERENT_BYTES,
    FileRow,
    NoWaitSleeper,
    PublishCredential,
    PublishReport,
    PublishRequest,
    RunOptions,
    ScriptedChannel,
    publish_flow,
)
from kci_publish.release_fixture import (
    example_channel_path,
    EXAMPLE_HOST,
    EXAMPLE_STAGE,
    EXAMPLE_TOKEN_SECRET,
    ExampleRelease,
    example_targets,
    write_example_inputs,
)


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


def _channel() raises -> ScriptedChannel:
    var ch = ScriptedChannel(String(EXAMPLE_HOST), example_channel_path(String("example-stable")), String("linux-64"))
    ch.put(String("linux-64"), String("komira_alpha-0.9.0-h00000000_1.conda"), _bytes(String("old a")))
    ch.put(String("linux-64"), String("komira_beta-0.9.0-h00000000_1.conda"), _bytes(String("old b")))
    ch.put(String("linux-64"), String("komira-0.9.0-h00000000_1.conda"), _bytes(String("old m")))
    return ch^


struct _Ran(Movable):
    var rep: PublishReport
    var result: KciRunResult
    var rec: MemoryRecorder

    def __init__(out self, var rep: PublishReport, var result: KciRunResult, var rec: MemoryRecorder):
        self.rep = rep^
        self.result = result^
        self.rec = rec^


def _registry(var ch: ScriptedChannel) -> RegistrySet[ScriptedChannel, PublishCredential]:
    return RegistrySet[ScriptedChannel, PublishCredential](ch^, PublishCredential())


def _flow(req: PublishRequest, mut reg: RegistrySet[ScriptedChannel, PublishCredential]) raises -> _Ran:
    var store = StaticSecretStore()
    store.put(String(EXAMPLE_TOKEN_SECRET), String(_TOKEN))
    var sl = NoWaitSleeper()
    var result = KciRunResult(String("run"), String("publish"))
    var rec = MemoryRecorder()
    var rep = publish_flow(
        req, result, rec, reg, ScriptedPkgTransport(), ActionsOidcEnv.absent(), store, RunOptions(2, 0, 2, 0, 0, 2, 0), sl
    )
    return _Ran(rep^, result^, rec^)


def _finished(r: KciRunResult, rep: PublishReport) raises -> String:
    """The FINISHED record the caller would write, rendered."""
    return render_result(r.finish_record(rep.outcome(), 1, rep.retry()))


def _no_token(rep: PublishReport, text: String) raises:
    assert_false(rep.has_line_containing(String(_TOKEN)))
    assert_false(rep.has_line_containing(String(String(_TOKEN)[byte=0:16])))
    assert_true(text.find(String(String(_TOKEN)[byte=0:16])) < 0, text)


def test_the_result_of_a_publish() raises:
    var r = ExampleRelease()
    var req = write_example_inputs(r, _root(String("ok")), String("example-stable"))
    var reg = _registry(_channel())
    var ran = _flow(req, reg)
    assert_equal(ran.rep.outcome(), String(OUTCOME_SUCCEEDED), String("\n").join(ran.rep.lines))
    assert_equal(ran.rep.exit_code(), EXIT_OK)
    # RUNNING once, before any request: it names the revision and the run
    assert_equal(len(ran.rec.statuses), 1)
    assert_equal(ran.rec.statuses[0], String(STATUS_RUNNING))
    assert_true(ran.rec.records[0].find(String('"revision":"') + r.revision + String('"')) >= 0)
    assert_true(ran.rec.records[0].find(String('"run_id":"gh-2"')) >= 0)
    ref res = ran.result
    assert_equal(len(res.steps), 1)
    assert_equal(res.steps[0].kind, String(STEP_KIND_PUBLISH))
    assert_equal(res.steps[0].name, String("publish"))
    assert_true(res.steps[0].selected)
    assert_equal(res.steps[0].platform, String("linux-x86_64"))
    assert_equal(res.steps[0].outcome, String(OUTCOME_SUCCEEDED))
    assert_equal(res.channel, String("example-stable"))
    assert_equal(res.set_hash, r.set_hash(req.platform_dir()))
    # the channel held older files of every name: nothing is new
    assert_equal(len(res.new_names), 0)
    assert_equal(res.steps[0].credential_probe, String(""))
    assert_false(res.plan)
    assert_false(res.has_error)
    assert_true(res.has_release_produced_by)
    assert_equal(res.release_produced_by_run_id, String("gh-1"))
    assert_equal(res.release_produced_by_attempt, 1)
    assert_equal(len(res.artifacts), 3)
    var order = List[String]()
    order.append(String("komira_alpha"))
    order.append(String("komira_beta"))
    order.append(String("komira"))
    for i in range(3):
        ref a = res.artifacts[i]
        assert_equal(a.name, order[i])
        assert_equal(a.effect, String(ARTIFACT_UPLOADED))
        assert_equal(a.file, r.file_name(order[i]))
        assert_equal(a.subdir, String("linux-64"))
        assert_equal(a.platform, String("linux-x86_64"))
        assert_equal(a.revision, r.revision)
        assert_equal(a.version, r.version)
        assert_equal(a.sha256, r.sha256_of(order[i]))
        assert_equal(a.state_before, String("absent"))
        assert_equal(a.state_after, String("present-same"))
        assert_true(a.indexed)
    var text = _finished(res, ran.rep)
    var back = parse_result(text, String("<test>"))
    assert_equal(render_result(back), text)
    assert_equal(back.exit_code, EXIT_OK)
    _no_token(ran.rep, text)
    assert_true(text.find(String("expect_set_hash")) < 0, text)
    # (4) the same step again over the channel it filled: NOOP, exit 0
    var writes = reg.transport().write_count()
    var again = _flow(req, reg)
    assert_equal(again.rep.outcome(), String(OUTCOME_NOOP), String("\n").join(again.rep.lines))
    assert_equal(again.rep.exit_code(), EXIT_OK)
    assert_equal(reg.transport().write_count(), writes)
    for i in range(len(again.result.artifacts)):
        assert_equal(again.result.artifacts[i].effect, String(ARTIFACT_ALREADY_PRESENT))
    var again_text = _finished(again.result, again.rep)
    assert_true(again_text.find(String('"exit_code":0,')) >= 0, again_text)
    assert_true(again_text.find(String('"outcome":"NOOP"')) >= 0, again_text)
    print("  test_the_result_of_a_publish: PASS")


def test_a_stop_records_its_error() raises:
    var r = ExampleRelease()
    var req = write_example_inputs(r, _root(String("stop")), String("example-stable"))
    var ch = _channel()
    ch.put(String("linux-64"), r.file_name(String("komira")), _bytes(String("not our metapackage")))
    var reg = _registry(ch^)
    var ran = _flow(req, reg)
    assert_equal(ran.rep.exit_code(), EXIT_REFUSED, String("\n").join(ran.rep.lines))
    ref res = ran.result
    assert_true(res.has_error)
    assert_equal(res.error.id, String(ERROR_PUBLISH_DIFFERENT_BYTES))
    assert_true(res.error.message.find(String("linux-64/") + r.file_name(String("komira"))) >= 0, res.error.message)
    ref meta = res.artifacts[2]
    assert_equal(meta.name, String("komira"))
    assert_equal(meta.state_before, String("present-different"))
    assert_equal(meta.effect, String(ARTIFACT_NOT_REACHED))
    assert_equal(res.artifacts[0].effect, String(ARTIFACT_NOT_REACHED))
    assert_equal(res.artifacts[0].state_before, String("absent"))
    var text = _finished(res, ran.rep)
    assert_true(text.find(String('"exit_code":3,')) >= 0, text)
    _no_token(ran.rep, text)
    print("  test_a_stop_records_its_error: PASS")


def _report(reason: String, landed: Bool) raises -> PublishReport:
    var r = ExampleRelease()
    var d = _root(String("reasons"))
    r.write(d)
    var t = example_targets(r, d)
    var rep = PublishReport()
    rep.files.append(FileRow(t[0]))
    if landed:
        rep.files[0].effect = String("uploaded")
    if reason == REASON_REFUSED:
        rep.stop(reason.copy(), String("KCI-E-MEMBER"), String("refused"))
    else:
        rep.end(reason.copy())
    return rep^


def _is(reason: String, landed: Bool, outcome: String, exit_code: Int) raises:
    var rep = _report(reason, landed)
    var why = reason + String(" landed=") + String(landed)
    assert_equal(rep.outcome(), outcome, why)
    assert_equal(rep.exit_code(), exit_code, why)


def test_one_outcome_per_reason() raises:
    _is(String(REASON_PUBLISHED), True, String("SUCCEEDED"), EXIT_OK)
    _is(String(REASON_ALREADY_PUBLISHED), False, String("NOOP"), EXIT_OK)
    _is(String(REASON_REFUSED), False, String("REFUSED"), EXIT_REFUSED)
    _is(String(REASON_STOP_DIFFERENT_BYTES), False, String("REFUSED"), EXIT_REFUSED)
    _is(String(REASON_STOP_DIFFERENT_BYTES), True, String("PARTIAL"), EXIT_PARTIAL)
    _is(String(REASON_FAILED), False, String("FAILED"), EXIT_FAILED)
    _is(String(REASON_FAILED), True, String("PARTIAL"), EXIT_PARTIAL)
    _is(String(REASON_CANNOT_TELL), False, String("INDETERMINATE"), EXIT_CANNOT_TELL)
    _is(String(REASON_CANNOT_TELL), True, String("INDETERMINATE"), EXIT_CANNOT_TELL)
    _is(String(REASON_PARTIAL), True, String("PARTIAL"), EXIT_PARTIAL)
    _is(String(REASON_READ_BACK_MISMATCH), True, String("PARTIAL"), EXIT_PARTIAL)
    assert_equal(_report(String(REASON_READ_BACK_MISMATCH), True).retry(), String("NEEDS_HUMAN"))
    assert_equal(_report(String(REASON_FAILED), False).retry(), String(""))
    print("  test_one_outcome_per_reason: PASS")


def test_new_names_in_the_result() raises:
    var r = ExampleRelease()
    var req = write_example_inputs(r, _root(String("names")), String("example-stable"))
    # older files of both libraries, none of the metapackage
    var ch = ScriptedChannel(String(EXAMPLE_HOST), example_channel_path(String("example-stable")), String("linux-64"))
    ch.put(String("linux-64"), String("komira_alpha-0.9.0-h00000000_1.conda"), _bytes(String("old a")))
    ch.put(String("linux-64"), String("komira_beta-0.9.0-h00000000_1.conda"), _bytes(String("old b")))
    var reg = _registry(ch^)
    var ran = _flow(req, reg)
    assert_equal(ran.rep.exit_code(), EXIT_OK, String("\n").join(ran.rep.lines))
    ref res = ran.result
    assert_equal(len(res.new_names), 1)
    assert_equal(res.new_names[0].stage, String(EXAMPLE_STAGE))
    assert_equal(res.new_names[0].step, String("publish"))
    assert_equal(res.new_names[0].channel, String("example-stable"))
    assert_equal(res.new_names[0].name, String("komira"))
    var text = _finished(res, ran.rep)
    assert_true(
        text.find(String('"new_names":[{"channel":"example-stable","name":"komira","stage":"publish-prod","step":"publish"}]')) >= 0,
        text,
    )
    # a dry run: the same names, and the probe of a token channel is NOT_OIDC
    var plan = write_example_inputs(r, _root(String("names_plan")), String("example-stable"), True)
    var ch2 = ScriptedChannel(String(EXAMPLE_HOST), example_channel_path(String("example-stable")), String("linux-64"))
    ch2.put(String("linux-64"), String("komira_alpha-0.9.0-h00000000_1.conda"), _bytes(String("old a")))
    ch2.put(String("linux-64"), String("komira_beta-0.9.0-h00000000_1.conda"), _bytes(String("old b")))
    var reg2 = _registry(ch2^)
    var ran2 = _flow(plan, reg2)
    assert_equal(ran2.rep.exit_code(), EXIT_OK, String("\n").join(ran2.rep.lines))
    assert_equal(len(ran2.result.new_names), 1)
    assert_equal(ran2.result.steps[0].credential_probe, String("NOT_OIDC"))
    assert_equal(reg2.transport().write_count(), 0)
    var text2 = _finished(ran2.result, ran2.rep)
    assert_true(text2.find(String('"credential_probe":"NOT_OIDC"')) >= 0, text2)
    print("  test_new_names_in_the_result: PASS")


def main() raises:
    test_the_result_of_a_publish()
    test_new_names_in_the_result()
    test_a_stop_records_its_error()
    test_one_outcome_per_reason()
    print("test_publish_result: ALL PASS")
