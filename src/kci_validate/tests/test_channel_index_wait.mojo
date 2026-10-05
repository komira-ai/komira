# =============================================================================
# src/kci_validate/tests/test_channel_index_wait.mojo
#   Check 1 ("channel") on its own, over a prefix.dev-shaped location: the
#   URL kci reads for a declared channel location (golden), the wait (404 for
#   N polls then listed passes and says how long it waited and how many
#   polls; 404 past the budget fails naming the URL), a 303 to another host
#   followed anonymously, and the poll log: one line per read, naming the
#   channel's index URL and nothing the registry redirected to.
#
# Hermetic: kci_pkg_upload's ScriptedPkgTransport is the channel,
# kci_publish's NoWaitSleeper the clock. No network.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from kci_api import ResultValidationCheck
from kci_pkg_upload import PkgResponse, ScriptedPkgTransport, content_identity_of
from kci_publish import NoWaitSleeper
from kci_validate import InstallPin, RecordingIndexPollLog, check_channel

comptime LOCATION: String = "https://prefix.dev/komira-ai/gamma"
comptime INDEX_URL: String = "https://prefix.dev/komira-ai/gamma/linux-64/repodata.json"
comptime CONTENT: String = "the bytes of one conda file"


def _bytes(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    var b = s.as_bytes()
    for i in range(len(b)):
        out.append(b[i])
    return out^


def _resp(status: Int, body: String = String("")) -> PkgResponse:
    var r = PkgResponse(status)
    r.with_body(_bytes(body))
    return r^


def _redirect(location: String) -> PkgResponse:
    var r = PkgResponse(303)
    r.with_header(String("location"), location.copy())
    return r^


def _pin() -> InstallPin:
    var p = InstallPin(String("komira_encoding"))
    p.version = String("1.0.0")
    p.build = String("h6e843fe6_277")
    p.subdir = String("linux-64")
    p.sha256 = content_identity_of(String(CONTENT).as_bytes()).sha256_hex
    return p^


def _pins() -> List[InstallPin]:
    var out = List[InstallPin]()
    out.append(_pin())
    return out^


def _index() -> String:
    var p = _pin()
    return (
        String('{"info":{"subdir":"linux-64"},"packages":{},"packages.conda":{"') + p.file_name()
        + String('":{"sha256":"') + p.sha256 + String('","size":1}}}')
    )


def _failed(checks: List[ResultValidationCheck]) -> String:
    var s = String("")
    for i in range(len(checks)):
        if not checks[i].ok:
            if s.byte_length() > 0:
                s += String("|")
            s += checks[i].got
    return s^


def test_reads_the_declared_location_golden() raises:
    # The index URL is `<location>/<subdir>/repodata.json`, the location as
    # the channels file declares it: prefix.dev answers it (303 to its
    # package host once the subdir is indexed, 404 before) exactly as it
    # answers the same path on repo.prefix.dev.
    var t = ScriptedPkgTransport()
    t.queue(_resp(200, _index()))
    t.queue(_resp(200, String(CONTENT)))
    var sl = NoWaitSleeper()
    var log = RecordingIndexPollLog()
    var checks = List[ResultValidationCheck]()
    assert_true(check_channel(t, sl, log, String(LOCATION), _pins(), 1800, checks), _failed(checks))
    assert_equal(t.call_count(), 2)
    assert_equal(t.call(0).host, String("prefix.dev"))
    assert_equal(t.call(0).path, String("/komira-ai/gamma/linux-64/repodata.json"))
    assert_equal(t.call(1).host, String("prefix.dev"))
    assert_equal(t.call(1).path, String("/komira-ai/gamma/linux-64/") + _pin().file_name())
    for i in range(t.call_count()):
        assert_equal(t.call(i).header_value(String("Authorization")), String(""))
    assert_equal(checks[0].expected, String("GET ") + String(INDEX_URL) + String(" answers 200 (read anonymously; waited 0 of 1800 s over 1 poll)"))
    assert_equal(checks[0].got, String("channel: ") + String(INDEX_URL) + String(" answered 200; waited 0 of 1800 s over 1 poll"))
    assert_true(checks[0].ok)
    assert_equal(sl.waits, 0)
    assert_equal(len(log.lines), 1)
    assert_equal(
        log.lines[0],
        String("kci: channel index poll 1: ") + String(INDEX_URL) + String(" answered 200, lists 1 of 1 pinned files; waited 0 of 1800 s"),
    )


def test_404_then_listed_after_n_polls_passes_and_says_how_long() raises:
    var t = ScriptedPkgTransport()
    for _ in range(4):
        t.queue(_resp(404))
    t.queue(_resp(200, _index()))
    t.queue(_resp(200, String(CONTENT)))
    var sl = NoWaitSleeper()
    var log = RecordingIndexPollLog()
    var checks = List[ResultValidationCheck]()
    assert_true(check_channel(t, sl, log, String(LOCATION), _pins(), 1800, checks), _failed(checks))
    assert_equal(sl.waits, 4)
    assert_equal(t.unconsumed(), 0)
    assert_equal(checks[0].got, String("channel: ") + String(INDEX_URL) + String(" answered 200; waited 60 of 1800 s over 5 polls"))
    assert_true(checks[1].expected.find(String("waited 60 of 1800 s over 5 polls")) >= 0, checks[1].expected)
    assert_equal(len(log.lines), 5)
    for n in range(4):
        assert_equal(
            log.lines[n],
            String("kci: channel index poll ") + String(n + 1) + String(": ") + String(INDEX_URL)
            + String(" answered 404; waited ") + String(n * 15) + String(" of 1800 s"),
        )
    assert_equal(
        log.lines[4],
        String("kci: channel index poll 5: ") + String(INDEX_URL) + String(" answered 200, lists 1 of 1 pinned files; waited 60 of 1800 s"),
    )


def test_404_past_the_budget_fails_naming_the_index_url() raises:
    var t = ScriptedPkgTransport()
    for _ in range(4):
        t.queue(_resp(404))
    var sl = NoWaitSleeper()
    var log = RecordingIndexPollLog()
    var checks = List[ResultValidationCheck]()
    assert_false(check_channel(t, sl, log, String(LOCATION), _pins(), 45, checks))
    # read at 0, 15, 30 and 45 s
    assert_equal(t.call_count(), 4)
    assert_equal(sl.waits, 3)
    assert_equal(len(checks), 1)
    assert_equal(
        checks[0].got,
        String("channel: ") + String(INDEX_URL)
        + String(" answered 404 at poll 4, after waiting 45 of 45 s: no such channel, nothing published to it,")
        + String(" or the registry has not indexed it yet"),
    )
    assert_equal(len(log.lines), 4)
    assert_equal(log.lines[3], String("kci: channel index poll 4: ") + String(INDEX_URL) + String(" answered 404; waited 45 of 45 s"))


def test_a_303_to_the_package_host_is_followed_and_not_logged() raises:
    var signed = String("https://packages.example.invalid/channels/0000/linux-64/repodata.json?verify=1-sig")
    var t = ScriptedPkgTransport()
    t.queue(_redirect(signed))
    t.queue(_resp(200, _index()))
    t.queue(_resp(200, String(CONTENT)))
    var sl = NoWaitSleeper()
    var log = RecordingIndexPollLog()
    var checks = List[ResultValidationCheck]()
    assert_true(check_channel(t, sl, log, String(LOCATION), _pins(), 1800, checks), _failed(checks))
    assert_equal(t.call(0).host, String("prefix.dev"))
    assert_equal(t.call(1).host, String("packages.example.invalid"))
    assert_equal(t.call(1).path, String("/channels/0000/linux-64/repodata.json?verify=1-sig"))
    for i in range(t.call_count()):
        assert_equal(t.call(i).header_value(String("Authorization")), String(""))
    assert_equal(
        checks[0].got,
        String("channel: ") + String(INDEX_URL) + String(" answered 200 after a redirect; waited 0 of 1800 s over 1 poll"),
    )
    assert_equal(
        log.lines[0],
        String("kci: channel index poll 1: ") + String(INDEX_URL)
        + String(" answered 200 after a redirect, lists 1 of 1 pinned files; waited 0 of 1800 s"),
    )
    for i in range(len(checks)):
        assert_equal(checks[i].got.find(String("packages.example.invalid")), -1, checks[i].got)
    assert_equal(log.lines[0].find(String("verify=")), -1)


def test_a_poll_that_cannot_read_logs_no_address() raises:
    var t = ScriptedPkgTransport()
    t.queue_fault(String("connection to 192.0.2.7:443 refused"))
    var sl = NoWaitSleeper()
    var log = RecordingIndexPollLog()
    var checks = List[ResultValidationCheck]()
    assert_false(check_channel(t, sl, log, String(LOCATION), _pins(), 0, checks))
    assert_equal(len(log.lines), 1)
    assert_equal(
        log.lines[0], String("kci: channel index poll 1: ") + String(INDEX_URL) + String(" could not be read; waited 0 of 0 s")
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
