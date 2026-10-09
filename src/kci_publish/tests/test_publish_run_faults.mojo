# =============================================================================
# src/kci_publish/tests/test_publish_run_faults.mojo -- steps 2 to 4 when a
#   read, a local file, the retry policy, a sleeper or a worker fails.
# =============================================================================
#
# ROWS
#   (1) the metapackage already present-same while the members are absent:
#       the members are uploaded, the metapackage is read again at step 4
#       and SKIPPED, never uploaded; SUCCEEDED;
#   (2) the same, but step 4's read of the metapackage serves other bytes:
#       READ_BACK_MISMATCH naming it present-different, no upload;
#   (2b) the metapackage's own upload is rejected at step 4: FAILED, naming
#       the channel's answer, after both members were uploaded;
#   (3) step 3 reads one member ABSENT and another CANNOT TELL: PARTIAL
#       (a missing member outranks an unreadable one), each named in a
#       READ-BACK line with its state, the metapackage not attempted;
#   (4) the settle read after an upload cannot tell, on every poll: that
#       member is CANNOT TELL ("unconfirmed"), the step INDETERMINATE at
#       step 2 (nothing is read back), the metapackage not attempted;
#   (5) a member's file changed after step 0 verified it: that member is
#       FAILED naming the new sha256 and is never sent; the other member is
#       still uploaded;
#   (6) a retry policy the backoff refuses (a negative initial wait): every
#       member FAILED naming it, nothing sent;
#   (7) a sleeper that cannot wait between upload attempts: FAILED naming
#       it, after exactly one upload;
#   (8) a worker transport that cannot be made: FAILED, nothing sent.
#
# Hermetic: TEST_TMPDIR, ScriptedChannel behind `_Faulty` (which answers a
# chosen status to a file's n-th and later downloads); no network.
# =============================================================================

from std.ffi import external_call
from std.os import makedirs

from komira_libc.posix import _read_env
from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_http_core.codec.types import HTTP_METHOD_GET

from kci_api import ERROR_PUBLISH_UPLOAD
from kci_pkg_upload import SURFACE_PREFIX_DEV, PkgRequest, PkgResponse, RegistrySet, ScriptedCredential
from kci_publish import (
    NoWaitSleeper,
    REASON_CANNOT_TELL,
    REASON_FAILED,
    REASON_PARTIAL,
    REASON_PUBLISHED,
    REASON_READ_BACK_MISMATCH,
    STATE_ABSENT,
    STATE_CANNOT_TELL,
    PublishCredential,
    PublishReport,
    PublishTarget,
    RunOptions,
    ScriptedChannel,
    run_publish,
)
from kci_publish.release_fixture import (
    EXAMPLE_HOST,
    ExampleRelease,
    example_channel_path,
    example_targets,
    write_text_file,
)
from kci_publish.scripted_channel import UPLOAD_ANSWER_400, UPLOAD_LOSE_NOT_STORED
from kci_publish.workers import ChannelTransport, WorkerSleeper


def _root(tag: String) raises -> String:
    var base = _read_env("TEST_TMPDIR")
    if base.byte_length() == 0:
        base = _read_env("TMPDIR")
    if base.byte_length() == 0:
        raise Error("neither TEST_TMPDIR nor TMPDIR is set")
    var d = base + String("/prf_") + tag + String("_") + String(Int(external_call["getpid", Int32]()))
    makedirs(d, exist_ok=True)
    return d^


def _bytes(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    var b = s.as_bytes()
    for i in range(len(b)):
        out.append(b[i])
    return out^


def _targets(tag: String) raises -> List[PublishTarget]:
    """komira_alpha, komira_beta, then the metapackage komira."""
    var r = ExampleRelease()
    var d = _root(tag)
    r.write(d)
    return example_targets(r, d)


def _channel() raises -> ScriptedChannel:
    return ScriptedChannel(String(EXAMPLE_HOST), example_channel_path(String("example-stable")), String("linux-64"))


def _path(t: PublishTarget) -> String:
    """The download path of `t` on the example-stable channel."""
    return String("/example/stable/linux-64/") + t.coordinate.file_name


struct _Faulty(ChannelTransport, Movable):
    """A ScriptedChannel whose answer to the n-th and every later download
    of a chosen path is a chosen status (the request still reaches the
    channel, so it is counted); `refuse_workers` makes `for_worker` raise.
    Every handle shares the channel's request log, so the count is the
    channel's, whichever worker sent it."""

    var inner: ScriptedChannel
    var paths: List[String]
    var from_nth: List[Int]
    var status: List[Int]
    var refuse_workers: Bool

    def __init__(out self, var inner: ScriptedChannel):
        self.inner = inner^
        self.paths = List[String]()
        self.from_nth = List[Int]()
        self.status = List[Int]()
        self.refuse_workers = False

    def answer_from(mut self, path: String, nth: Int, status: Int):
        self.paths.append(path.copy())
        self.from_nth.append(nth)
        self.status.append(status)

    def for_worker(mut self) raises -> Self:
        if self.refuse_workers:
            raise Error("_Faulty: no transport for another worker")
        var w = _Faulty(self.inner.for_worker())
        w.paths = self.paths.copy()
        w.from_nth = self.from_nth.copy()
        w.status = self.status.copy()
        return w^

    def _gets(self, path: String) -> Int:
        var n = 0
        for i in range(self.inner.call_count()):
            var c = self.inner.call(i)
            if c.method == HTTP_METHOD_GET and c.path == path:
                n += 1
        return n

    def exchange(mut self, req: PkgRequest) raises -> PkgResponse:
        var nth = 0
        if req.method == HTTP_METHOD_GET:
            nth = self._gets(req.path) + 1
        var r = self.inner.exchange(req)
        for k in range(len(self.paths)):
            if nth > 0 and req.path == self.paths[k] and nth >= self.from_nth[k]:
                return PkgResponse(self.status[k])
        return r^


struct _NoSleep(WorkerSleeper, Movable, Deinitable):
    """A sleeper that refuses every wait."""

    def __init__(out self):
        pass

    def for_worker(self) -> Self:
        return Self()

    def sleep_ms(mut self, ms: Int64) raises:
        raise Error("_NoSleep: this sleeper cannot wait")


def _cred() -> PublishCredential:
    var c = PublishCredential()
    c.configure(SURFACE_PREFIX_DEV, String(EXAMPLE_HOST), String(""))
    return c^


def _src() -> ScriptedCredential:
    var s = ScriptedCredential()
    s.serve(SURFACE_PREFIX_DEV, String("Bearer pfx-test-token"))
    return s^


def _opts(read_back_attempts: Int, upload_attempts: Int, retry_initial_ms: Int64 = 0) -> RunOptions:
    return RunOptions(read_back_attempts, 0, upload_attempts, retry_initial_ms, 0, 1, 0, concurrency=1)


def _lines(r: PublishReport) -> String:
    return String("\n").join(r.lines)


def test_a_present_metapackage_is_read_again_and_skipped() raises:
    var t = _targets(String("meta_same"))
    var ch = _channel()
    ch.put(String("linux-64"), t[2].coordinate.file_name, _bytes(String("meta conda bytes")))
    var reg = RegistrySet[ScriptedChannel, PublishCredential](ch^, _cred())
    var src = _src()
    var sl = NoWaitSleeper()
    var rep = run_publish(t, reg, src, False, _opts(2, 2), sl, PublishReport())
    assert_equal(rep.reason, String(REASON_PUBLISHED), _lines(rep))
    assert_equal(reg.transport().upload_count(t[2].coordinate.file_name), 0)
    assert_equal(reg.transport().upload_count(t[0].coordinate.file_name), 1)
    assert_equal(reg.transport().upload_count(t[1].coordinate.file_name), 1)
    assert_equal(rep.files[2].effect, String("skipped"))
    assert_true(
        rep.has_line_containing(String("SKIPPED linux-64/") + t[2].coordinate.file_name + String(" -- already present, identical")),
        _lines(rep),
    )
    # step 1 and step 4 read it; step 3 reads members only
    var reads = 0
    for i in range(reg.transport().call_count()):
        if reg.transport().call(i).path == _path(t[2]):
            reads += 1
    assert_equal(reads, 2)


def test_a_present_metapackage_that_changes_before_step_4_is_a_read_back_mismatch() raises:
    var t = _targets(String("meta_changed"))
    var ch = _channel()
    ch.put(String("linux-64"), t[2].coordinate.file_name, _bytes(String("meta conda bytes")))
    ch.other_bytes_on_fetch(String("linux-64"), t[2].coordinate.file_name, 2)
    var reg = RegistrySet[ScriptedChannel, PublishCredential](ch^, _cred())
    var src = _src()
    var sl = NoWaitSleeper()
    var rep = run_publish(t, reg, src, False, _opts(2, 2), sl, PublishReport())
    assert_equal(rep.reason, String(REASON_READ_BACK_MISMATCH), _lines(rep))
    assert_true(
        rep.has_line_containing(String("READ-BACK linux-64/") + t[2].coordinate.file_name + String(": present-different")),
        _lines(rep),
    )
    assert_equal(reg.transport().upload_count(t[2].coordinate.file_name), 0)


def test_a_rejected_metapackage_upload_fails_the_step() raises:
    var t = _targets(String("meta_400"))
    var ch = _channel()
    ch.plan_upload(t[2].coordinate.file_name, UPLOAD_ANSWER_400)
    var reg = RegistrySet[ScriptedChannel, PublishCredential](ch^, _cred())
    var src = _src()
    var sl = NoWaitSleeper()
    var rep = run_publish(t, reg, src, False, _opts(1, 1), sl, PublishReport())
    assert_equal(rep.reason, String(REASON_FAILED), _lines(rep))
    assert_equal(rep.outcome(), String("PARTIAL"), String("both members landed"))
    assert_true(
        rep.has_line_containing(String("FAILED linux-64/") + t[2].coordinate.file_name + String(" -- the channel answered ")),
        _lines(rep),
    )
    assert_equal(rep.files[2].effect, String("failed"))
    assert_false(rep.has_line_containing(String("RESULT outcome=SUCCEEDED")), _lines(rep))
    assert_equal(reg.transport().upload_count(t[2].coordinate.file_name), 1)


def test_step_3_absent_outranks_cannot_tell() raises:
    var t = _targets(String("rb_absent"))
    var f = _Faulty(_channel())
    # downloads: 1 = step 1 (absent), 2 = the settle read, 3 = step 3
    f.answer_from(_path(t[0]), 3, 404)
    f.answer_from(_path(t[1]), 3, 503)
    var reg = RegistrySet[_Faulty, PublishCredential](f^, _cred())
    var src = _src()
    var sl = NoWaitSleeper()
    var rep = run_publish(t, reg, src, False, _opts(1, 1), sl, PublishReport())
    assert_equal(rep.reason, String(REASON_PARTIAL), _lines(rep))
    assert_equal(rep.error_id, String(ERROR_PUBLISH_UPLOAD))
    assert_true(rep.has_line_containing(String("READ-BACK linux-64/") + t[0].coordinate.file_name + String(": absent")), _lines(rep))
    assert_true(
        rep.has_line_containing(String("READ-BACK linux-64/") + t[1].coordinate.file_name + String(": cannot-tell")), _lines(rep)
    )
    assert_equal(rep.files[0].state_after, STATE_ABSENT)
    assert_equal(rep.files[1].state_after, STATE_CANNOT_TELL)
    assert_equal(rep.files[2].effect, String("not-attempted"))
    assert_equal(reg.transport().inner.upload_count(t[2].coordinate.file_name), 0)


def test_a_settle_read_that_cannot_tell_is_unconfirmed() raises:
    var t = _targets(String("settle_ct"))
    var f = _Faulty(_channel())
    f.answer_from(_path(t[0]), 2, 503)
    var reg = RegistrySet[_Faulty, PublishCredential](f^, _cred())
    var src = _src()
    var sl = NoWaitSleeper()
    var rep = run_publish(t, reg, src, False, _opts(1, 1), sl, PublishReport())
    assert_equal(rep.reason, String(REASON_CANNOT_TELL), _lines(rep))
    assert_equal(rep.outcome(), String("INDETERMINATE"))
    assert_equal(rep.files[0].effect, String("unconfirmed"))
    assert_equal(rep.files[0].state_after, STATE_CANNOT_TELL)
    assert_true(rep.has_line_containing(String("CANNOT TELL linux-64/") + t[0].coordinate.file_name + String(" -- ")), _lines(rep))
    assert_equal(rep.files[1].effect, String("uploaded"))
    assert_equal(rep.files[2].effect, String("not-attempted"))
    # the step stopped at step 2: step 3 never read anything back
    assert_false(rep.has_line_containing(String("READ-BACK ")), _lines(rep))


def test_a_file_changed_after_step_0_is_never_sent() raises:
    var t = _targets(String("changed"))
    write_text_file(t[0].file_path, String("bytes written after the check"))
    var reg = RegistrySet[ScriptedChannel, PublishCredential](_channel(), _cred())
    var src = _src()
    var sl = NoWaitSleeper()
    var rep = run_publish(t, reg, src, False, _opts(1, 1), sl, PublishReport())
    assert_equal(rep.reason, String(REASON_FAILED), _lines(rep))
    assert_true(
        rep.has_line_containing(String("FAILED linux-64/") + t[0].coordinate.file_name + String(" -- '") + t[0].file_path
        + String("' changed after it was verified (sha256 now ")),
        _lines(rep),
    )
    assert_equal(reg.transport().upload_count(t[0].coordinate.file_name), 0)
    assert_equal(reg.transport().upload_count(t[1].coordinate.file_name), 1)
    assert_equal(rep.outcome(), String("PARTIAL"), String("the other member landed"))


def test_a_refused_retry_policy_sends_nothing() raises:
    var t = _targets(String("backoff"))
    var reg = RegistrySet[ScriptedChannel, PublishCredential](_channel(), _cred())
    var src = _src()
    var sl = NoWaitSleeper()
    var rep = run_publish(t, reg, src, False, _opts(1, 2, -1), sl, PublishReport())
    assert_equal(rep.reason, String(REASON_FAILED), _lines(rep))
    assert_equal(rep.outcome(), String("FAILED"))
    for i in range(2):
        assert_true(
            rep.has_line_containing(String("FAILED linux-64/") + t[i].coordinate.file_name + String(" -- Backoff: need 0 <= initial_ms")),
            _lines(rep),
        )
        assert_equal(rep.files[i].effect, String("failed"))
    assert_equal(reg.transport().write_count(), 0)


def test_a_sleeper_that_cannot_wait_fails_the_retry() raises:
    var t = _targets(String("nosleep"))
    var ch = _channel()
    ch.plan_upload(t[0].coordinate.file_name, UPLOAD_LOSE_NOT_STORED)
    var reg = RegistrySet[ScriptedChannel, PublishCredential](ch^, _cred())
    var src = _src()
    var sl = _NoSleep()
    var rep = run_publish(t, reg, src, False, _opts(1, 2), sl, PublishReport())
    assert_equal(rep.reason, String(REASON_FAILED), _lines(rep))
    assert_true(
        rep.has_line_containing(String("FAILED linux-64/") + t[0].coordinate.file_name + String(" -- _NoSleep: this sleeper cannot wait")),
        _lines(rep),
    )
    assert_equal(reg.transport().upload_count(t[0].coordinate.file_name), 1)
    assert_equal(rep.files[0].state_after, STATE_ABSENT)


def test_a_worker_that_cannot_be_made_sends_nothing() raises:
    var t = _targets(String("noworker"))
    var f = _Faulty(_channel())
    f.refuse_workers = True
    var reg = RegistrySet[_Faulty, PublishCredential](f^, _cred())
    var src = _src()
    var sl = NoWaitSleeper()
    var rep = run_publish(t, reg, src, False, _opts(1, 1), sl, PublishReport())
    assert_equal(rep.reason, String(REASON_FAILED), _lines(rep))
    assert_true(rep.has_line_containing(String("FAILED -- _Faulty: no transport for another worker")), _lines(rep))
    assert_equal(reg.transport().inner.write_count(), 0)
    assert_false(rep.landed())


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
