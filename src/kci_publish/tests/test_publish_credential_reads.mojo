# =============================================================================
# src/kci_publish/tests/test_publish_credential_reads.mojo -- the write
#   credential that cannot be had, the run's own credential refusing what it
#   was not bound to, step 1's reads when nothing can be read, the index
#   check's polls, and the reasons no caller asks for.
# =============================================================================
#
# ROWS
#   (1) the write value cannot be had (the source is not configured, or
#       resolves to nothing): FAILED, KCI-E-CREDENTIAL, naming why, ZERO
#       writes;
#   (2) `PublishCredential` refuses a surface it was not configured for;
#   (3) step 1 through an unconfigured credential: every file CANNOT TELL
#       and no listing read, each naming why and which subdir; an empty set
#       reads nothing and sends nothing;
#   (4) an index that lags: step 5 polls `index_polls` times with a wait
#       between polls and none before the first, reports `indexed: false`,
#       and the step still SUCCEEDS;
#   (5) the index check never raises: a read that raises is "not indexed";
#   (6) the reason and rank tables: a PROCEED verdict and a done file are
#       PUBLISHED, an unconfirmed file CANNOT TELL, and step 3 ranks a
#       mismatch over a missing member over an unreadable one.
#
# Hermetic: TEST_TMPDIR, ScriptedChannel; no network.
# =============================================================================

from std.ffi import external_call
from std.os import makedirs

from komira_libc.posix import _read_env
from std.testing import TestSuite, assert_equal, assert_false, assert_true

from kci_api import ERROR_CREDENTIAL
from kci_pkg_upload import SURFACE_PREFIX_DEV, RegistrySet, ScriptedCredential
from kci_pkg_upload.credential import SURFACE_PYPI_UPLOAD
from kci_publish import (
    NoWaitSleeper,
    REASON_CANNOT_TELL,
    REASON_FAILED,
    REASON_PARTIAL,
    REASON_PUBLISHED,
    REASON_READ_BACK_MISMATCH,
    STATE_CANNOT_TELL,
    PublishCredential,
    PublishReport,
    PublishTarget,
    RunOptions,
    ScriptedChannel,
    read_channel,
    run_publish,
)
from kci_publish.index import is_indexed
from kci_publish.plan import VERDICT_PROCEED
from kci_publish.release_fixture import EXAMPLE_HOST, ExampleRelease, example_channel_path, example_targets
from kci_publish.run import _read_back_rank, _reason_of_file, _reason_of_verdict
from kci_publish.upload import FILE_CANNOT_TELL, FILE_DONE


def _root(tag: String) raises -> String:
    var base = _read_env("TEST_TMPDIR")
    if base.byte_length() == 0:
        base = _read_env("TMPDIR")
    if base.byte_length() == 0:
        raise Error("neither TEST_TMPDIR nor TMPDIR is set")
    var d = base + String("/pcr_") + tag + String("_") + String(Int(external_call["getpid", Int32]()))
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


def _channel() raises -> ScriptedChannel:
    return ScriptedChannel(String(EXAMPLE_HOST), example_channel_path(String("example-stable")), String("linux-64"))


def _cred() -> PublishCredential:
    var c = PublishCredential()
    c.configure(SURFACE_PREFIX_DEV, String(EXAMPLE_HOST), String(""))
    return c^


def _lines(r: PublishReport) -> String:
    return String("\n").join(r.lines)


def test_a_write_value_that_cannot_be_had_sends_nothing() raises:
    var t = _targets(String("nowrite"))
    # the source is not configured: it refuses before any request
    var reg = RegistrySet[ScriptedChannel, PublishCredential](_channel(), _cred())
    var unconfigured = PublishCredential()
    var sl = NoWaitSleeper()
    var rep = run_publish(t, reg, unconfigured, False, RunOptions(1, 0, 1, 0, 0, 1, 0), sl, PublishReport())
    assert_equal(rep.reason, String(REASON_FAILED), _lines(rep))
    assert_equal(rep.error_id, String(ERROR_CREDENTIAL))
    assert_true(
        rep.has_line_containing(
            String("FAILED -- the channel's credential: PUBLISH step: the channel credential is not configured; the request was not sent")
        ),
        _lines(rep),
    )
    assert_equal(reg.transport().write_count(), 0)
    # the source resolves to nothing: an upload needs a credential
    var reg2 = RegistrySet[ScriptedChannel, PublishCredential](_channel(), _cred())
    var empty = _cred()
    var rep2 = run_publish(t, reg2, empty, False, RunOptions(1, 0, 1, 0, 0, 1, 0), sl, PublishReport())
    assert_equal(rep2.reason, String(REASON_FAILED), _lines(rep2))
    assert_equal(rep2.error_id, String(ERROR_CREDENTIAL))
    assert_true(rep2.has_line_containing(String("the channel's credential resolved to nothing; an upload needs one")), _lines(rep2))
    assert_equal(reg2.transport().write_count(), 0)


def test_the_run_credential_serves_only_its_surface() raises:
    var c = _cred()
    assert_equal(c.authorization(SURFACE_PREFIX_DEV, String(EXAMPLE_HOST)), String(""))
    var text = String("")
    try:
        _ = c.authorization(SURFACE_PYPI_UPLOAD, String(EXAMPLE_HOST))
    except e:
        text = String(e)
    assert_true(text.startswith(String("the PUBLISH step's channel credential cannot serve the ")), text)


def test_step_1_through_an_unconfigured_credential_reads_nothing() raises:
    var t = _targets(String("unconf"))
    var reg = RegistrySet[ScriptedChannel, PublishCredential](_channel(), PublishCredential())
    var read = read_channel(reg, t)
    assert_equal(len(read.states), 3)
    for i in range(3):
        assert_equal(read.states[i].kind, STATE_CANNOT_TELL)
        assert_true(read.states[i].detail.find(String("the channel credential is not configured")) >= 0, read.states[i].detail)
    assert_false(read.names_read)
    assert_true(read.names_detail.startswith(String("linux-64: PUBLISH step: the channel credential is not configured")), read.names_detail)
    assert_true(read.names_detail.find(String("; noarch: PUBLISH step: ")) > 0, read.names_detail)
    assert_equal(reg.transport().call_count(), 0)
    # an empty set: nothing read, nothing sent, nothing unread
    var none = read_channel(reg, List[PublishTarget]())
    assert_equal(len(none.states), 0)
    assert_true(none.names_read)
    assert_equal(reg.transport().call_count(), 0)


def test_a_lagging_index_is_polled_and_reported_not_indexed() raises:
    var t = _targets(String("lag"))
    var ch = _channel()
    ch.lag_index()
    var reg = RegistrySet[ScriptedChannel, PublishCredential](ch^, _cred())
    var src = ScriptedCredential()
    src.serve(SURFACE_PREFIX_DEV, String("Bearer pfx-test-token"))
    var sl = NoWaitSleeper()
    var rep = run_publish(t, reg, src, False, RunOptions(2, 0, 2, 0, 0, 3, 0, concurrency=1), sl, PublishReport())
    assert_equal(rep.reason, String(REASON_PUBLISHED), _lines(rep))
    for i in range(3):
        assert_false(rep.files[i].indexed, t[i].coordinate.file_name)
    # three polls per file, a wait before the second and the third only
    assert_equal(sl.waits, 6)


def test_the_index_check_never_raises() raises:
    var t = _targets(String("idx"))
    var ch = _channel()
    ch.put(String("linux-64"), t[0].coordinate.file_name, _bytes(String("alpha conda bytes")))
    var listed = RegistrySet[ScriptedChannel, PublishCredential](ch.for_worker(), _cred())
    var sl = NoWaitSleeper()
    var opts = RunOptions(1, 0, 1, 0, 0, 2, 0)
    assert_true(is_indexed(listed, t[0], opts, sl), String("the channel lists it with our sha256"))
    assert_equal(sl.waits, 0)
    var unconfigured = RegistrySet[ScriptedChannel, PublishCredential](ch.for_worker(), PublishCredential())
    assert_false(is_indexed(unconfigured, t[0], opts, sl))
    assert_equal(sl.waits, 0, String("a read that raises ends the polls"))


def test_the_reasons_no_caller_asks_for() raises:
    assert_equal(_reason_of_verdict(VERDICT_PROCEED), String(REASON_PUBLISHED))
    assert_equal(_reason_of_file(FILE_DONE), String(REASON_PUBLISHED))
    assert_equal(_reason_of_file(FILE_CANNOT_TELL), String(REASON_CANNOT_TELL))
    assert_true(_read_back_rank(String(REASON_READ_BACK_MISMATCH)) > _read_back_rank(String(REASON_PARTIAL)))
    assert_true(_read_back_rank(String(REASON_PARTIAL)) > _read_back_rank(String(REASON_CANNOT_TELL)))
    assert_true(_read_back_rank(String(REASON_CANNOT_TELL)) > _read_back_rank(String(REASON_PUBLISHED)))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
