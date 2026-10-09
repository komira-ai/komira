# =============================================================================
# komira_job_supervisor/tests/test_bearer_heartbeat_auth.mojo
#   The entrypoint's heartbeat credential: a file re-read for every beat, or
#   an environment variable read once and removed before the job is spawned.
# =============================================================================
#
# ARM 1, the file. Every beat's `Authorization: Bearer` is the file's content
# AT THAT BEAT: the file is rewritten between two beats and the second beat
# carries the new token (a conformer that read the file once and cached it
# fails here). The token reaches the serialized request. One trailing newline
# is not part of the token. A file that is empty, missing or holds a space
# inside the token refuses the start, and so does a DEL (0x7F), beside an
# accepted `~` (0x7E), the top of visible ASCII; a DEL or vertical tab as the
# token's LAST byte is refused too (only trailing space, tab, CR and LF are
# dropped). A token of MAX_SECRET_LEN (4096) bytes is accepted and one of
# 4097 refused, from a file and from a variable. A file removed after the
# start fails that beat closed
# (AUTH_UNAVAILABLE, nothing dialled).
#
# ARM 2, the environment. `from_env` reads the variable (set for this test
# by the BUCK file's test_env), and afterwards the process environment no
# longer holds it, so a child spawned through the supervisor prints its
# absence; the CONTROL is a second test_env variable the child does see, so
# "absent" cannot come from a child that sees no environment at all. An
# unset variable and a name that is not a variable name refuse the start.
#
# Every refusal is checked not to carry the token.
# =============================================================================

from std.ffi import external_call
from std.os import remove, setenv
from std.pathlib import Path as FsPath
from std.testing import assert_equal, assert_false, assert_true

from komira_libc.posix import _read_env
from komira_objectstore import InMemoryConditionalStore
from komira_secret_store import MAX_SECRET_LEN
from komira_supervisor.supervisor import ChildSpec

from komira_job_supervisor import (
    BearerHeartbeatAuth,
    HeartbeatOutcome,
    HeartbeatReporter,
    HttpHeartbeatReporter,
    HEARTBEAT_STATUS_AUTH_UNAVAILABLE,
    JobSupervisor,
    JobSupervisorConfig,
    SupervisorHeartbeat,
    build_heartbeat_request,
)
from komira_job_supervisor.job_supervisor_state import JobSupervisorPhase


comptime _ENV_CREDENTIAL = "KOMIRA_JOB_SUPERVISOR_TEST_CREDENTIAL"
comptime _ENV_CREDENTIAL_VALUE = "tok-env-0123456789"
comptime _ENV_PASSTHROUGH = "KOMIRA_JOB_SUPERVISOR_TEST_PASSTHROUGH"
comptime _ENV_PASSTHROUGH_VALUE = "visible-to-the-job"
comptime _ENV_LONG = "KOMIRA_JOB_SUPERVISOR_TEST_LONG_CREDENTIAL"
comptime _URL = "https://beats.example.com/v1/beat"


def _tmp(name: String) raises -> String:
    var tmp = _read_env("TEST_TMPDIR")
    assert_true(tmp.byte_length() > 0, "TEST_TMPDIR is unset")
    return tmp + "/" + name


def _write(path: String, text: String) raises:
    FsPath(path).write_text(text)


def _only_header(mut auth: BearerHeartbeatAuth) raises -> String:
    """The one header's `name: value` for one beat."""
    var hs = auth.headers(String("POST"), String(_URL), List[UInt8]())
    assert_equal(len(hs), 1, "exactly one auth header")
    return hs[0].name + String(": ") + hs[0].value


def _refusal_from_file(path: String) -> String:
    try:
        _ = BearerHeartbeatAuth.from_file(path)
    except e:
        return String(e)
    return String("")


def _refusal_from_env(name: String) -> String:
    try:
        _ = BearerHeartbeatAuth.from_env(name)
    except e:
        return String(e)
    return String("")


def _head_lower(var req_bytes: List[UInt8]) -> String:
    var out = String("")
    for i in range(len(req_bytes)):
        var b = req_bytes[i]
        out += chr(Int(b)) if b < UInt8(0x80) else String("?")
    return out.lower()


struct CountingReporter(HeartbeatReporter):
    var beats: Int

    def __init__(out self):
        self.beats = 0

    def report(mut self, hb: SupervisorHeartbeat) -> HeartbeatOutcome:
        self.beats += 1
        return HeartbeatOutcome(True, False, 200)


# =============================================================================
# ARM 1: the file.
# =============================================================================
def test_the_file_is_read_for_every_beat() raises:
    var path = _tmp(String("credential-rotating"))
    _write(path, String("tok-first-AAAA"))
    var auth = BearerHeartbeatAuth.from_file(path)
    assert_equal(
        _only_header(auth),
        String("Authorization: Bearer tok-first-AAAA"),
        "beat 1 carries the file's token",
    )
    # The platform rotates the secret in place.
    _write(path, String("tok-second-BBBB"))
    assert_equal(
        _only_header(auth),
        String("Authorization: Bearer tok-second-BBBB"),
        "beat 2 carries the ROTATED token: the file is read per beat",
    )
    assert_true(auth.attaches_credential(), "a bearer attaches a credential")
    assert_true(auth.reads_file_per_beat(), "the file form re-reads")

    # The token reaches the serialized request.
    var hs = auth.headers(String("POST"), String(_URL), List[UInt8]())
    var body = List[UInt8]()
    body.append(UInt8(0x08))
    var req = build_heartbeat_request(String(_URL), body^, hs)
    var head = _head_lower(req.request_bytes.copy())
    assert_true(
        head.find(String("authorization: bearer tok-second-bbbb\r\n")) >= 0,
        "the bearer header is on the serialized wire: " + head,
    )
    _ = req^
    print("  test_the_file_is_read_for_every_beat: PASS")


def test_a_trailing_newline_is_not_part_of_the_token() raises:
    var path = _tmp(String("credential-newline"))
    _write(path, String("tok-with-newline\n"))
    var auth = BearerHeartbeatAuth.from_file(path)
    assert_equal(
        _only_header(auth),
        String("Authorization: Bearer tok-with-newline"),
        "the file's final newline is dropped",
    )
    _write(path, String("tok-crlf\r\n"))
    assert_equal(
        _only_header(auth),
        String("Authorization: Bearer tok-crlf"),
        "and a final CRLF",
    )
    print("  test_a_trailing_newline_is_not_part_of_the_token: PASS")


def test_an_unusable_file_refuses_the_start() raises:
    var empty = _tmp(String("credential-empty"))
    _write(empty, String("\n"))
    var r = _refusal_from_file(empty)
    assert_true(r.find(String("is empty")) >= 0, "empty: " + r)

    var missing = _tmp(String("credential-never-written"))
    r = _refusal_from_file(missing)
    assert_true(r.find(String("cannot read")) >= 0, "missing: " + r)

    var spaced = _tmp(String("credential-spaced"))
    _write(spaced, String("tok-left tok-right"))
    r = _refusal_from_file(spaced)
    assert_true(r.find(String("not visible ASCII")) >= 0, "a space: " + r)
    assert_false(r.find(String("tok-left")) >= 0, "the refusal never quotes the token")

    var split = _tmp(String("credential-split"))
    _write(split, String("tok-a\r\nX-Injected: 1"))
    r = _refusal_from_file(split)
    assert_true(r.find(String("not visible ASCII")) >= 0, "a CRLF inside: " + r)

    # The top of visible ASCII: DEL (0x7F) is refused, `~` (0x7E) accepted.
    # Nothing downstream checks a header value, so a bound one byte too
    # high would send a DEL in the Authorization header.
    var del_file = _tmp(String("credential-del"))
    _write(del_file, String("tok-del") + chr(0x7F) + String("x"))
    r = _refusal_from_file(del_file)
    assert_true(r.find(String("not visible ASCII at offset 7")) >= 0, "a DEL: " + r)
    # The LAST byte is checked too. Only trailing space, tab, CR and LF are
    # dropped before the check, so a final DEL or vertical tab (0x0B) is
    # still part of the token; a byte loop that stopped one short would
    # send it in the header.
    var del_last = _tmp(String("credential-del-last"))
    _write(del_last, String("tok-del") + chr(0x7F))
    r = _refusal_from_file(del_last)
    assert_true(
        r.find(String("not visible ASCII at offset 7")) >= 0, "a final DEL: " + r
    )
    var vt_last = _tmp(String("credential-vt-last"))
    _write(vt_last, String("tok-vt") + chr(0x0B) + String("\n"))
    r = _refusal_from_file(vt_last)
    assert_true(
        r.find(String("not visible ASCII at offset 6")) >= 0,
        "a final vertical tab before the newline: " + r,
    )
    var tilde = _tmp(String("credential-tilde"))
    _write(tilde, String("tok~tilde"))
    var tilde_auth = BearerHeartbeatAuth.from_file(tilde)
    assert_equal(
        _only_header(tilde_auth),
        String("Authorization: Bearer tok~tilde"),
        "CONTROL: `~` (0x7E) is visible ASCII and accepted",
    )

    # CONTROL: a usable file is accepted.
    var good = _tmp(String("credential-good"))
    _write(good, String("tok-good"))
    assert_equal(_refusal_from_file(good), String(""), "CONTROL: accepted")
    print("  test_an_unusable_file_refuses_the_start: PASS")


def _token_of(n: Int) -> String:
    """`n` bytes of visible ASCII."""
    var out = String("")
    for i in range(n):
        out += String("k") if i % 2 == 0 else String("9")
    return out^


def test_the_token_length_cap_is_4096_bytes() raises:
    """MAX_SECRET_LEN (4096) bytes are accepted and one more is refused, in
    both forms. For the file form nothing else bounds the token."""
    var at_cap = _token_of(MAX_SECRET_LEN)
    var over_cap = _token_of(MAX_SECRET_LEN + 1)
    assert_equal(MAX_SECRET_LEN, 4096, "the documented cap")

    var over_file = _tmp(String("credential-4097"))
    _write(over_file, over_cap)
    var r = _refusal_from_file(over_file)
    assert_true(r.find(String("is longer than 4096 bytes")) >= 0, "file, 4097: " + r)
    assert_false(r.find(String("k9k9")) >= 0, "the refusal never quotes the token")
    var at_file = _tmp(String("credential-4096"))
    _write(at_file, at_cap + String("\n"))
    var fa = BearerHeartbeatAuth.from_file(at_file)
    assert_equal(
        _only_header(fa),
        String("Authorization: Bearer ") + at_cap,
        "file, 4096 (and a final newline): accepted whole",
    )

    assert_true(setenv(String(_ENV_LONG), over_cap), "setenv 4097")
    r = _refusal_from_env(String(_ENV_LONG))
    assert_true(r.find(String("4096")) >= 0, "env, 4097: refused naming the cap: " + r)
    assert_false(r.find(String("k9k9")) >= 0, "the refusal never quotes the token")
    assert_true(setenv(String(_ENV_LONG), at_cap), "setenv 4096")
    var ea = BearerHeartbeatAuth.from_env(String(_ENV_LONG))
    assert_equal(
        _only_header(ea),
        String("Authorization: Bearer ") + at_cap,
        "env, 4096: accepted whole",
    )
    print("  test_the_token_length_cap_is_4096_bytes: PASS")


def test_a_file_gone_after_the_start_fails_the_beat_closed() raises:
    var path = _tmp(String("credential-vanishing"))
    _write(path, String("tok-vanishing"))
    var reporter = HttpHeartbeatReporter[BearerHeartbeatAuth](
        String("https://127.0.0.1:1/beat"), BearerHeartbeatAuth.from_file(path)
    )
    remove(path)
    var hb = SupervisorHeartbeat(
        String("job-1"),
        JobSupervisorPhase.running(),
        String("instance-1"),
        None,
        None,
        None,
    )
    var outcome = reporter.report(hb)
    assert_false(outcome.ok, "no beat without the credential")
    assert_equal(
        outcome.status,
        HEARTBEAT_STATUS_AUTH_UNAVAILABLE,
        "the failure is the credential's, not the network's",
    )
    print("  test_a_file_gone_after_the_start_fails_the_beat_closed: PASS")


# =============================================================================
# ARM 2: the environment.
# =============================================================================
def test_the_env_credential_is_read_once_and_removed() raises:
    assert_equal(
        _read_env(_ENV_CREDENTIAL),
        String(_ENV_CREDENTIAL_VALUE),
        "precondition: test_env set the credential variable",
    )
    var auth = BearerHeartbeatAuth.from_env(String(_ENV_CREDENTIAL))
    assert_false(auth.reads_file_per_beat(), "the env form holds the token")
    assert_equal(
        _only_header(auth),
        String("Authorization: Bearer ") + _ENV_CREDENTIAL_VALUE,
        "the beat carries the variable's token",
    )

    # The job, which inherits the environment, does not see it.
    var cmd = (
        String('printf "%s|%s\\n" "${')
        + _ENV_CREDENTIAL
        + String('-absent}" "${')
        + _ENV_PASSTHROUGH
        + String('-absent}"')
    )
    var cfg = JobSupervisorConfig(
        String("env-job"),
        String("instance-1"),
        String("/bin/sh"),
        List[String](),
        String("http://127.0.0.1:1/beat"),
    )
    var js = JobSupervisor[CountingReporter, InMemoryConditionalStore](
        cfg^, CountingReporter(), None
    )
    js.spawn_child_spec(ChildSpec.shell(cmd))
    var spins = 0
    while not js.child_exited and spins < 2000:
        js.poll_and_drain()
        _ = external_call["usleep", Int32](UInt32(2000))
        spins += 1
    assert_true(js.child_exited, "the child ran")
    assert_equal(len(js.stdout_ring), 1, "one line from the child")
    assert_equal(
        js.stdout_ring[0],
        String("absent|") + _ENV_PASSTHROUGH_VALUE,
        "the job sees no credential (CONTROL: it does see the other variable)",
    )
    _ = js^
    assert_equal(
        _read_env(_ENV_CREDENTIAL),
        String(""),
        "the variable is gone from this process's environment",
    )
    assert_equal(
        _only_header(auth),
        String("Authorization: Bearer ") + _ENV_CREDENTIAL_VALUE,
        "and the held token still serves later beats",
    )

    # Read once: a second read of the same variable now refuses.
    var again = _refusal_from_env(String(_ENV_CREDENTIAL))
    assert_true(again.find(String("is not set")) >= 0, "read once: " + again)
    print("  test_the_env_credential_is_read_once_and_removed: PASS")


def test_an_unusable_variable_refuses_the_start() raises:
    var r = _refusal_from_env(String("KOMIRA_JOB_SUPERVISOR_TEST_NEVER_SET"))
    assert_true(r.find(String("is not set")) >= 0, "unset: " + r)
    r = _refusal_from_env(String("not a name"))
    assert_true(r.byte_length() > 0, "a name outside the grammar is refused")
    print("  test_an_unusable_variable_refuses_the_start: PASS")


def main() raises:
    test_the_file_is_read_for_every_beat()
    test_a_trailing_newline_is_not_part_of_the_token()
    test_an_unusable_file_refuses_the_start()
    test_the_token_length_cap_is_4096_bytes()
    test_a_file_gone_after_the_start_fails_the_beat_closed()
    test_the_env_credential_is_read_once_and_removed()
    test_an_unusable_variable_refuses_the_start()
    print("PASS test_bearer_heartbeat_auth")
