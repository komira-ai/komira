# =============================================================================
# komira_test_s3_adapter/tests/test_minio_object_store.mojo
#   `MinioObjectStore`'s verbs over two connectors with no socket:
#   komira_http_core's `ScriptedConnector`, which replays one scripted
#   answer, and `RecordingConnector` (below), which also appends every byte
#   the store writes to a log in TEST_TMPDIR, so a test reads back the
#   request as it reached the wire. No object service; the credentials file
#   lives in TEST_TMPDIR.
# =============================================================================
#
# What each arm would catch:
#   * ARM 1 (credentials): a reader that takes the key, the secret or the
#     session token from the wrong entry or another profile, or that quotes
#     the path in an error.
#   * ARM 2 (CreateBucket answers): a store that treats someone else's
#     bucket (409 BucketAlreadyExists) or a refusal as created, or refuses
#     its own run's bucket on a second call (409 BucketAlreadyOwnedByYou);
#     a body that is not UTF-8; a transport failure that escapes without
#     the operation's name or with the bucket.
#   * ARM 3 (binding): a verb that runs unbound, or a second bind.
#   * ARM 4 (verbs): GetObject / ListObjectsV2 / DeleteObject results lost,
#     a failed delete not reported in `failed`, a failed PutObject that does
#     not raise, or an error that carries the bucket or the endpoint.
#   * ARM 5 (the wire): a verb sent with the wrong method, to the wrong
#     bucket or key, path-style lost, the list prefix lost, the body lost,
#     or a request signed without SigV4, for another region or service, or
#     with any key but the file's default (the [other] profile's key must
#     never appear).
#
# EVERY ARM HAS A CONTROL.
# =============================================================================

from std.testing import assert_equal, assert_false, assert_true

from komira_async.reactor.reactor import Reactor
from komira_async.runtime.runtime_trait import Runtime
from komira_libc.posix import _read_env
from komira_http_core.transport.io_stream import (
    Connector,
    IoStream,
    NEGOTIATED_HTTP_1_1,
    StreamIo,
    TRANSPORT_KIND_KERNEL_TCP,
)
from komira_http_core.transport.scripted import ScriptedConnector, ScriptedStream
from komira_test_bucket import StoreTarget

from komira_test_s3_adapter import (
    MinioObjectStore,
    create_bucket_status_ok,
    read_credential_file,
)


comptime _ENDPOINT = "http://127.0.0.1:9000"
comptime _BUCKET = "kt-adapter-bucket-7f3a"
comptime Scripted = MinioObjectStore[ScriptedConnector]


# =============================================================================
# helpers
# =============================================================================
def _bytes(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    out.extend(s.as_bytes())
    return out^


def _text(b: List[UInt8]) -> String:
    return String(unsafe_from_utf8=Span(b))


def _tmp(name: String) raises -> String:
    var tmp = _read_env("TEST_TMPDIR")
    assert_true(tmp.byte_length() > 0, "TEST_TMPDIR is unset")
    return tmp + "/" + name


def _write(path: String, text: String) raises:
    with open(path, "w") as f:
        f.write(text)


comptime _KEY = "AKIAIOSFODNN7EXAMPLE"
comptime _SECRET = "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"


def _credentials_file() raises -> String:
    var path = _tmp(String("adapter-credentials"))
    _write(
        path,
        String("[other]\naws_access_key_id = OTHERKEY\naws_secret_access_key = othersecret\n")
        + "aws_session_token = othertoken\n"
        + "[default]\naws_access_key_id = "
        + _KEY
        + "\naws_secret_access_key = "
        + _SECRET
        + "\n",
    )
    return path^


def _target() raises -> StoreTarget:
    return StoreTarget(
        String(_ENDPOINT), String("us-east-1"), String(_BUCKET), _credentials_file()
    )


def _response(status_line: String, extra: String, body: String) -> List[UInt8]:
    var head = String("HTTP/1.1 ") + status_line + "\r\n" + extra
    head += "Content-Length: " + String(body.byte_length()) + "\r\n\r\n"
    return _bytes(head + body)


def _connector(var answer: List[UInt8]) -> ScriptedConnector:
    return ScriptedConnector.with_stream(ScriptedStream.from_read_script(answer^))


def _mk_ok_empty() raises -> ScriptedConnector:
    return _connector(_response(String("200 OK"), String(""), String("")))


def _mk_owned() raises -> ScriptedConnector:
    return _connector(
        _response(
            String("409 Conflict"),
            String("Content-Type: application/xml\r\n"),
            String("<Error><Code>BucketAlreadyOwnedByYou</Code></Error>"),
        )
    )


def _mk_exists() raises -> ScriptedConnector:
    return _connector(
        _response(
            String("409 Conflict"),
            String("Content-Type: application/xml\r\n"),
            String("<Error><Code>BucketAlreadyExists</Code></Error>"),
        )
    )


def _mk_get() raises -> ScriptedConnector:
    return _connector(_response(String("200 OK"), String('ETag: "e-1"\r\n'), String("BODY")))


def _mk_list() raises -> ScriptedConnector:
    var body = String('<ListBucketResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/"><Name>')
    body += String(_BUCKET) + "</Name><Prefix>run/</Prefix>"
    body += "<KeyCount>2</KeyCount><MaxKeys>1000</MaxKeys><IsTruncated>false</IsTruncated>"
    body += '<Contents><Key>run/a</Key><Size>1</Size><ETag>"x"</ETag></Contents>'
    body += '<Contents><Key>run/b/c</Key><Size>2</Size><ETag>"y"</ETag></Contents>'
    body += "</ListBucketResult>"
    return _connector(
        _response(String("200 OK"), String("Content-Type: application/xml\r\n"), body)
    )


def _mk_deleted() raises -> ScriptedConnector:
    return _connector(_response(String("204 No Content"), String(""), String("")))


def _mk_denied() raises -> ScriptedConnector:
    """A 403 whose message quotes the bucket and the endpoint, as a careless
    server might."""
    return _connector(
        _response(
            String("403 Forbidden"),
            String("Content-Type: application/xml\r\n"),
            String("<Error><Code>AccessDenied</Code><Message>no access to ")
            + _BUCKET
            + " at "
            + _ENDPOINT
            + "</Message></Error>",
        )
    )


def _bound(mk: def () raises thin -> ScriptedConnector) raises -> Scripted:
    var s = Scripted(mk)
    s.bind(_target())
    return s^


def _mk_unarmed() raises -> ScriptedConnector:
    """A connector whose every dial fails."""
    return ScriptedConnector()


def _mk_owned_not_utf8() raises -> ScriptedConnector:
    """A 409 whose body names BucketAlreadyOwnedByYou between bytes that are
    not UTF-8."""
    var body = List[UInt8]()
    body.append(UInt8(0xFF))
    body.append(UInt8(0xC3))
    body.extend(String("<Code>BucketAlreadyOwnedByYou</Code>").as_bytes())
    body.append(UInt8(0x80))
    var head = _bytes(
        String("HTTP/1.1 409 Conflict\r\nContent-Length: ") + String(len(body)) + "\r\n\r\n"
    )
    head.extend(Span(body))
    return _connector(head^)


# =============================================================================
# RecordingConnector: every dial is a stream that answers `answer` and
# appends what the store writes to the file at `log`. The connector factory
# is a `thin` function, so it cannot capture a buffer; the log file is how
# the bytes get back to the test.
# =============================================================================
struct RecordingStream(IoStream, Movable, Deinitable):
    var _log: String
    var _answer: ScriptedStream

    def __init__(out self, log: String, var answer: List[UInt8]):
        self._log = log
        self._answer = ScriptedStream.from_read_script(answer^)

    def try_read[
        RT: Runtime, o: Origin[mut=True],
    ](
        mut self,
        mut reactor: Reactor[RT.Sink],
        dst: Span[UInt8, o],
    ) raises -> StreamIo:
        return self._answer.try_read[RT, o](reactor, dst)

    def try_write[RT: Runtime](
        mut self,
        mut reactor: Reactor[RT.Sink],
        src: Span[UInt8, _],
    ) raises -> StreamIo:
        with open(self._log, "a") as f:
            f.write_bytes(src)
        return StreamIo.ready(Int64(len(src)))

    def unread(mut self, src: Span[UInt8, _]) raises:
        self._answer.unread(src)

    def close(var self):
        pass

    def negotiated_protocol(self) -> UInt8:
        return NEGOTIATED_HTTP_1_1

    def fd(self) -> Int32:
        return Int32(-1)


struct RecordingConnector(Connector, Movable, Deinitable):
    comptime Stream = RecordingStream

    var _log: String
    var _answer: List[UInt8]

    def __init__(out self, log: String, var answer: List[UInt8]):
        self._log = log
        self._answer = answer^

    def connect[RT: Runtime](
        mut self,
        mut reactor: Reactor[RT.Sink],
        ip_be: UInt32,
        port: UInt16,
    ) raises -> RecordingStream:
        _ = ip_be
        _ = port
        return RecordingStream(self._log, self._answer.copy())

    def transport_kind(self) -> UInt8:
        return TRANSPORT_KIND_KERNEL_TCP

    def is_tls(self) -> Bool:
        return False

    def set_dial_host(mut self, var host: String):
        _ = host^


comptime Recorded = MinioObjectStore[RecordingConnector]


def _log_path(name: String) raises -> String:
    return _tmp(String("wire-") + name)


def _fresh_log(name: String) raises -> String:
    var path = _log_path(name)
    _write(path, String(""))
    return path^


def _read_log(name: String) raises -> String:
    with open(_log_path(name), "r") as f:
        return f.read()


def _rec_create() raises -> RecordingConnector:
    return RecordingConnector(
        _log_path(String("create")), _response(String("200 OK"), String(""), String(""))
    )


def _rec_put() raises -> RecordingConnector:
    return RecordingConnector(
        _log_path(String("put")),
        _response(String("200 OK"), String('ETag: "e-1"\r\n'), String("")),
    )


def _rec_get() raises -> RecordingConnector:
    return RecordingConnector(
        _log_path(String("get")),
        _response(String("200 OK"), String('ETag: "e-1"\r\n'), String("BODY")),
    )


def _rec_list() raises -> RecordingConnector:
    var body = String('<ListBucketResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/"><Name>')
    body += String(_BUCKET) + "</Name><Prefix>run/</Prefix>"
    body += "<KeyCount>0</KeyCount><MaxKeys>1000</MaxKeys><IsTruncated>false</IsTruncated>"
    body += "</ListBucketResult>"
    return RecordingConnector(
        _log_path(String("list")),
        _response(String("200 OK"), String("Content-Type: application/xml\r\n"), body),
    )


def _rec_delete() raises -> RecordingConnector:
    return RecordingConnector(
        _log_path(String("delete")), _response(String("204 No Content"), String(""), String(""))
    )


def _request_line(wire: String) -> String:
    var end = wire.find("\r\n")
    if end < 0:
        return wire
    return String(wire[byte=0:end])


def _check_signed(wire: String, what: String) raises:
    """`wire` holds what every request of the store carries: the endpoint's
    Host, a SigV4 signature by the default profile's key scoped to us-east-1
    and s3, and the payload hash; never the [other] profile's key."""
    var w = wire.lower()
    var wants: List[String] = [
        String("\r\nhost: 127.0.0.1:9000\r\n"),
        String("\r\nauthorization: aws4-hmac-sha256 credential=")
        + String(_KEY).lower()
        + "/",
        String("/us-east-1/s3/aws4_request, signedheaders="),
        String("\r\nx-amz-content-sha256: "),
        String("\r\nx-amz-date: "),
    ]
    for i in range(len(wants)):
        assert_true(w.find(wants[i]) >= 0, what + ": " + wants[i] + " is not in " + wire)
    assert_true(w.find("otherkey") < 0, what + ": signed with the [other] key: " + wire)


# =============================================================================
# ARM 1: the credential comes from the file's default profile.
# =============================================================================
def test_credential_is_the_default_profile() raises:
    var cred = read_credential_file(_credentials_file())
    assert_equal(cred.access_key_id, String(_KEY))
    assert_equal(cred.secret_access_key, String(_SECRET))
    assert_equal(cred.session_token, String(""))

    # A default profile's session token is carried; the [other] one's never.
    var tok = _tmp(String("adapter-credentials-token"))
    _write(
        tok,
        String("[default]\naws_access_key_id = K\naws_secret_access_key = S\n")
        + "aws_session_token = T0K\n[other]\naws_session_token = othertoken\n",
    )
    var with_token = read_credential_file(tok)
    assert_equal(with_token.access_key_id, String("K"))
    assert_equal(with_token.secret_access_key, String("S"))
    assert_equal(with_token.session_token, String("T0K"))

    # CONTROL: a file whose default profile has no key pair, and a missing
    # file, are refused without quoting the path.
    var bad = _tmp(String("adapter-credentials-nodefault"))
    _write(bad, String("[other]\naws_access_key_id = K\naws_secret_access_key = S\n"))
    var raised = False
    try:
        _ = read_credential_file(bad)
    except e:
        raised = String(e).find("no default profile") >= 0 and String(e).find(bad) < 0
    assert_true(raised, "a file without a default profile must be refused, saying so")
    var half = _tmp(String("adapter-credentials-nosecret"))
    _write(half, String("[default]\naws_access_key_id = K\n"))
    raised = False
    try:
        _ = read_credential_file(half)
    except e:
        raised = (
            String(e).find("default profile has no key pair") >= 0
            and String(e).find(half) < 0
        )
    assert_true(raised, "a default profile without a secret must be refused")
    var missing = _tmp(String("adapter-credentials-missing"))
    raised = False
    try:
        _ = read_credential_file(missing)
    except e:
        raised = String(e).find("cannot read") >= 0 and String(e).find(missing) < 0
    assert_true(raised, "a missing file must be refused without its path")
    print("  test_credential_is_the_default_profile: PASS")


# =============================================================================
# ARM 2: what a CreateBucket answer means.
# =============================================================================
def test_create_bucket_answers() raises:
    var empty = List[UInt8]()
    assert_true(create_bucket_status_ok(200, Span(empty)), "200 is created")
    var owned = _bytes(String("<Error><Code>BucketAlreadyOwnedByYou</Code></Error>"))
    assert_true(create_bucket_status_ok(409, Span(owned)), "ours already")
    var exists = _bytes(String("<Error><Code>BucketAlreadyExists</Code></Error>"))
    assert_false(create_bucket_status_ok(409, Span(exists)), "someone else's bucket")
    assert_false(create_bucket_status_ok(403, Span(owned)), "a 403 is never created")
    var short = _bytes(String("Bucket"))
    assert_false(create_bucket_status_ok(409, Span(short)), "a body shorter than the code")
    assert_false(create_bucket_status_ok(409, Span(empty)), "an empty 409 body")

    # Over the wire: 200 and 409 owned return, 409 exists and 403 raise.
    var ca = Scripted(_mk_ok_empty)
    ca.bind(_target())
    ca.create_bucket_if_absent()
    var cb = Scripted(_mk_owned)
    cb.bind(_target())
    cb.create_bucket_if_absent()
    var cu = Scripted(_mk_owned_not_utf8)
    cu.bind(_target())
    cu.create_bucket_if_absent()

    # CONTROL: the refusals raise, with the status and without the bucket.
    var cc = Scripted(_mk_exists)
    cc.bind(_target())
    var raised = False
    try:
        cc.create_bucket_if_absent()
    except e:
        raised = String(e).find("status 409") >= 0 and String(e).find(_BUCKET) < 0
    assert_true(raised, "BucketAlreadyExists must raise")
    var cd = Scripted(_mk_denied)
    cd.bind(_target())
    raised = False
    try:
        cd.create_bucket_if_absent()
    except e:
        raised = String(e).find("status 403") >= 0 and String(e).find(_BUCKET) < 0
    assert_true(raised, "a 403 CreateBucket must raise")

    # A transport failure names the operation and not the bucket.
    var ce = Scripted(_mk_unarmed)
    ce.bind(_target())
    var msg = String("")
    try:
        ce.create_bucket_if_absent()
    except e:
        msg = String(e)
    assert_true(msg.find("CreateBucket: ") >= 0, "a failed dial must name CreateBucket: " + msg)
    assert_true(msg.find(_BUCKET) < 0, "the bucket leaked: " + msg)
    print("  test_create_bucket_answers: PASS")


# =============================================================================
# ARM 3: binding.
# =============================================================================
def test_binding_is_required_and_once() raises:
    var s = Scripted(_mk_get)
    var raised = False
    try:
        _ = s.get(String("k"))
    except e:
        raised = String(e).find("not bound") >= 0
    assert_true(raised, "an unbound get must raise")
    raised = False
    try:
        s.create_bucket_if_absent()
    except e:
        raised = String(e).find("not bound") >= 0
    assert_true(raised, "an unbound create must raise")

    # CONTROL: bound once works; a second bind raises.
    s.bind(_target())
    assert_equal(_text(s.get(String("run/a"))), String("BODY"))
    raised = False
    try:
        s.bind(_target())
    except e:
        raised = String(e).find("bind called twice") >= 0
    assert_true(raised, "a second bind must raise")
    print("  test_binding_is_required_and_once: PASS")


# =============================================================================
# ARM 4: the verbs.
# =============================================================================
def test_the_verbs() raises:
    var lister = _bound(_mk_list)
    var keys = List[String]()
    keys.append(String("already-there"))
    lister.list_keys(String("run/"), keys)
    assert_equal(len(keys), 3)
    assert_equal(keys[1], String("run/a"))
    assert_equal(keys[2], String("run/b/c"))

    var deleter = _bound(_mk_deleted)
    var gone = List[String]()
    gone.append(String("run/a"))
    var failed = List[String]()
    deleter.delete_keys(gone, failed)
    assert_equal(len(failed), 0)

    # CONTROL: a refused delete lands in `failed` and does not raise; a
    # refused put and list raise, naming the operation, with the bucket and
    # the endpoint the server quoted replaced.
    var refuser = _bound(_mk_denied)
    refuser.delete_keys(gone, failed)
    assert_equal(len(failed), 1)
    assert_equal(failed[0], String("run/a"))

    var putter = _bound(_mk_denied)
    var body = _bytes(String("x"))
    var msg = String("")
    try:
        putter.put(String("run/a"), Span(body))
    except e:
        msg = String(e)
    assert_true(msg.find("PutObject") >= 0, "a 403 PutObject must raise: " + msg)
    assert_true(msg.find(_BUCKET) < 0, "the bucket leaked: " + msg)
    assert_true(msg.find(_ENDPOINT) < 0, "the endpoint leaked: " + msg)

    var bad_list = _bound(_mk_denied)
    var none = List[String]()
    msg = String("")
    try:
        bad_list.list_keys(String("run/"), none)
    except e:
        msg = String(e)
    assert_true(msg.find("ListObjectsV2") >= 0, "a 403 list must raise: " + msg)
    assert_true(msg.find(_BUCKET) < 0, "the bucket leaked: " + msg)
    print("  test_the_verbs: PASS")


# =============================================================================
# ARM 5: each verb's request as it reached the wire.
# =============================================================================
def test_the_wire() raises:
    _ = _fresh_log(String("create"))
    var c = Recorded(_rec_create)
    c.bind(_target())
    c.create_bucket_if_absent()
    var w = _read_log(String("create"))
    assert_equal(_request_line(w), String("PUT /") + _BUCKET + " HTTP/1.1")
    _check_signed(w, String("CreateBucket"))

    _ = _fresh_log(String("put"))
    var p = Recorded(_rec_put)
    p.bind(_target())
    var body = _bytes(String("payload-7"))
    p.put(String("run/a"), Span(body))
    w = _read_log(String("put"))
    assert_equal(_request_line(w), String("PUT /") + _BUCKET + "/run/a HTTP/1.1")
    assert_true(w.endswith("\r\n\r\npayload-7"), "the body is lost: " + w)
    _check_signed(w, String("PutObject"))

    _ = _fresh_log(String("get"))
    var g = Recorded(_rec_get)
    g.bind(_target())
    assert_equal(_text(g.get(String("run/b/c"))), String("BODY"))
    w = _read_log(String("get"))
    assert_equal(_request_line(w), String("GET /") + _BUCKET + "/run/b/c HTTP/1.1")
    _check_signed(w, String("GetObject"))

    _ = _fresh_log(String("list"))
    var l = Recorded(_rec_list)
    l.bind(_target())
    var keys = List[String]()
    l.list_keys(String("run/"), keys)
    assert_equal(len(keys), 0)
    var line = _request_line(_read_log(String("list")))
    assert_true(line.startswith(String("GET /") + _BUCKET + "?"), "not a path-style list: " + line)
    assert_true(line.find("list-type=2") >= 0, "not ListObjectsV2: " + line)
    assert_true(line.lower().find("prefix=run%2f") >= 0, "the prefix is lost: " + line)
    _check_signed(_read_log(String("list")), String("ListObjectsV2"))

    _ = _fresh_log(String("delete"))
    var d = Recorded(_rec_delete)
    d.bind(_target())
    var gone: List[String] = [String("run/a")]
    var failed = List[String]()
    d.delete_keys(gone, failed)
    assert_equal(len(failed), 0)
    w = _read_log(String("delete"))
    assert_equal(_request_line(w), String("DELETE /") + _BUCKET + "/run/a HTTP/1.1")
    _check_signed(w, String("DeleteObject"))

    # CONTROL: a store that never sent leaves its log empty, so a log read
    # above is that verb's request and not a leftover.
    _ = _fresh_log(String("create"))
    var idle = Recorded(_rec_create)
    idle.bind(_target())
    assert_equal(_read_log(String("create")).byte_length(), 0)
    print("  test_the_wire: PASS")


def main() raises:
    print("test_minio_object_store:")
    test_credential_is_the_default_profile()
    test_create_bucket_answers()
    test_binding_is_required_and_once()
    test_the_verbs()
    test_the_wire()
    print("test_minio_object_store: ALL PASS")
