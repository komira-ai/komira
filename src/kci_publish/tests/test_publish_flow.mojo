# =============================================================================
# src/kci_publish/tests/test_publish_flow.mojo -- the whole verb, from flags
#   to report, over scripted transports.
# =============================================================================
#
# ROWS
#   (1) --dry-run through the whole verb: the plan is read anonymously, the
#       write and OIDC transports receive ZERO requests, and the named secret
#       is NEVER resolved (the store's resolve count stays 0);
#   (2) a real run with `token-secret:<name>`: the presence read is
#       anonymous, the upload carries the resolved token as a Bearer, the
#       read-back confirms it, exit 0;
#   (3) refusals before any request, each exit 3 with every transport
#       silent: an unapproved name (named), a manifest whose sha256 is not
#       the file's, an unknown channel, a dry run of a PRIVATE channel, an
#       unresolvable secret name, OIDC outside a GitHub Actions job (the
#       handshake variables named);
#   (4) the standalone store refuses `token-secret:` by naming the forms
#       that work.
#
# Hermetic: scripted transports and an in-memory secret store over staged
# fixture files; no network. Row (3)'s OIDC case reads two environment
# variables that a test action does not set.
# =============================================================================

from std.memory import ArcPointer
from std.testing import assert_equal, assert_true

from komira_http.codec.types import HTTP_METHOD_GET, HTTP_METHOD_POST
from komira_secret_store import StaticSecretStore

from kci_pkg_upload import PkgRequest, PkgResponse, PkgTransport, ScriptedPkgTransport
from kci_pkg_upload.wire import bytes_of

from komira_retry import RecordingSleeper

from kci_publish import (
    EXIT_OK,
    EXIT_REFUSED,
    NoSecretStore,
    PublishReport,
    RunOptions,
    parse_publish_flags,
    publish_flow,
)


comptime _FX: String = "src/kci_publish/tests/fixtures/"
comptime _FILE: String = "example-pkg-1.2.3-h0_0.conda"
comptime _LINUX_SHA: String = "d92ee691780d0dbc4dd45de1287d8980462041de9bd2fe3d7f8b89044a18cf52"
comptime _SECRET_NAME: String = "EXAMPLE_PUBLISH_TOKEN"
comptime _TOKEN: String = "example-token-not-a-credential"


struct _Shared(PkgTransport, Deinitable):
    """A scripted transport the test keeps a second handle on, so it can
    read the conversation after the verb consumed the first."""

    var _p: ArcPointer[ScriptedPkgTransport]

    def __init__(out self):
        self._p = ArcPointer[ScriptedPkgTransport](ScriptedPkgTransport())

    def __init__(out self, *, var _share: ArcPointer[ScriptedPkgTransport]):
        self._p = _share^

    def share(self) -> _Shared:
        # SAFETY: ArcPointer shared ownership; one thread.
        return _Shared(_share=ArcPointer[ScriptedPkgTransport](copy=self._p))

    def queue(mut self, var r: PkgResponse):
        self._p[].queue(r^)

    def call_count(self) -> Int:
        return self._p[].call_count()

    def call(self, i: Int) -> PkgRequest:
        return self._p[].call(i)

    def exchange(mut self, req: PkgRequest) raises -> PkgResponse:
        return self._p[].exchange(req)


def _args(s: String) -> List[String]:
    var out = List[String]()
    var parts = s.split(String(" "))
    for i in range(len(parts)):
        if String(parts[i]).byte_length() > 0:
            out.append(String(parts[i]))
    return out^


def _flags(
    channel: String = String("example-stable"),
    manifest: String = String("linux-64.json"),
    credential: String = String("token-secret:") + String(_SECRET_NAME),
    extra: String = String(""),
) -> String:
    return (
        String("--channels ")
        + String(_FX)
        + String("channels.textproto --channel ")
        + channel
        + String(" --artifacts ")
        + String(_FX)
        + manifest
        + String(" --approved-names ")
        + String(_FX)
        + String("approved.txt --credential ")
        + credential
        + String(" ")
        + extra
    )


def _repodata(sha: String) -> PkgResponse:
    var r = PkgResponse(200)
    var listed = String("")
    if sha.byte_length() > 0:
        listed = String('"') + String(_FILE) + String('": {"sha256": "') + sha + String('"}')
    r.with_body(
        bytes_of(
            String('{"info": {"subdir": "linux-64"}, "packages": {}, "packages.conda": {')
            + listed
            + String("}}")
        )
    )
    return r^


def _store() -> StaticSecretStore:
    var s = StaticSecretStore()
    s.put(String(_SECRET_NAME), String(_TOKEN))
    return s^


def _dump(r: PublishReport) -> String:
    return String("exit=") + String(r.exit_code) + String("\n") + String("\n").join(r.lines)


def _quick() -> RunOptions:
    return RunOptions(3, 250)


def test_dry_run_through_the_verb() raises:
    var sl = RecordingSleeper()
    var read = _Shared()
    read.queue(_repodata(String("")))
    var write = _Shared()
    var oidc = _Shared()
    var store = _store()
    var flags = parse_publish_flags(_args(_flags(extra=String("--dry-run"))))
    var r = publish_flow(flags, read.share(), write.share(), oidc.share(), store, _quick(), sl)
    assert_equal(r.exit_code, EXIT_OK, _dump(r))
    assert_true(r.has_line_containing(String("UPLOAD https://conda.example.invalid/example-stable/linux-64/") + String(_FILE)), _dump(r))
    assert_true(r.has_line_containing(String("DRY RUN: nothing was uploaded")), _dump(r))
    assert_equal(read.call_count(), 1)
    assert_equal(read.call(0).method, HTTP_METHOD_GET)
    assert_equal(read.call(0).header_value(String("Authorization")), String(""))
    assert_equal(write.call_count(), 0)
    assert_equal(oidc.call_count(), 0)
    assert_equal(store.resolve_count(), 0)
    # the dry run of an oidc run never reaches the handshake either
    var read2 = _Shared()
    read2.queue(_repodata(String("")))
    var oidc2 = _Shared()
    var f2 = parse_publish_flags(
        _args(_flags(credential=String("oidc"), extra=String("--require-environment release --dry-run")))
    )
    var r2 = publish_flow(f2, read2.share(), _Shared(), oidc2.share(), store, _quick(), sl)
    assert_equal(r2.exit_code, EXIT_OK, _dump(r2))
    assert_equal(oidc2.call_count(), 0)


def test_a_real_run_with_a_named_secret() raises:
    var sl = RecordingSleeper()
    var read = _Shared()
    read.queue(_repodata(String("")))
    var write = _Shared()
    write.queue(PkgResponse(201))
    write.queue(_repodata(String(_LINUX_SHA)))
    var store = _store()
    var flags = parse_publish_flags(_args(_flags()))
    var r = publish_flow(flags, read.share(), write.share(), _Shared(), store, _quick(), sl)
    assert_equal(r.exit_code, EXIT_OK, _dump(r))
    assert_true(r.has_line_containing(String("UPLOADED https://conda.example.invalid/example-stable/linux-64/") + String(_FILE)), _dump(r))
    assert_equal(read.call_count(), 1)
    assert_equal(read.call(0).header_value(String("Authorization")), String(""))
    assert_equal(write.call_count(), 2)
    var post = write.call(0)
    assert_equal(post.method, HTTP_METHOD_POST)
    assert_equal(post.host, String("conda.example.invalid"))
    assert_equal(post.path, String("/api/v1/upload/example-stable"))
    assert_equal(post.header_value(String("Authorization")), String("Bearer ") + String(_TOKEN))
    assert_equal(store.resolve_count(), 1)
    for i in range(len(r.lines)):
        assert_true(r.lines[i].find(String(_TOKEN)) < 0, r.lines[i])


def _refused(flags: String, needle: String) raises:
    var read = _Shared()
    var write = _Shared()
    var oidc = _Shared()
    var store = _store()
    var sl = RecordingSleeper()
    var r = publish_flow(
        parse_publish_flags(_args(flags)), read.share(), write.share(), oidc.share(), store, _quick(), sl
    )
    assert_equal(r.exit_code, EXIT_REFUSED, _dump(r))
    assert_true(r.has_line_containing(needle), _dump(r))
    assert_equal(read.call_count() + write.call_count() + oidc.call_count(), 0)


def test_refusals_before_any_request() raises:
    var sl = RecordingSleeper()
    _refused(
        _flags(manifest=String("other.json")),
        String("not in the approved-names list (1 approved): other-pkg."),
    )
    _refused(_flags(manifest=String("bad_sha.json")), String("its manifest says"))
    _refused(_flags(channel=String("example-beta")), String("unknown release channel 'example-beta'"))
    _refused(
        _flags(channel=String("example-private"), extra=String("--dry-run")),
        String("channel 'example-private' is PRIVATE"),
    )
    _refused(_flags(credential=String("token-secret:NO_SUCH_SECRET")), String("NO_SUCH_SECRET"))
    _refused(_flags(credential=String("oidc")), String("ACTIONS_ID_TOKEN_REQUEST_URL"))


def test_the_standalone_store_names_the_working_forms() raises:
    var sl = RecordingSleeper()
    var s = NoSecretStore()
    var why = String("")
    try:
        _ = s.resolve(String("ANY"))
    except e:
        why = String(e)
    assert_true(why.find(String("--credential token-file:<path> or --credential oidc")) >= 0, why)


def main() raises:
    test_dry_run_through_the_verb()
    test_a_real_run_with_a_named_secret()
    test_refusals_before_any_request()
    test_the_standalone_store_names_the_working_forms()
    print("test_publish_flow: ALL PASS")
