# An AzureFs built by azure_fs_for reads over a scripted connector: no
# socket. Every dial answers the 206 for `bytes=0-3` of a 10-byte blob, with
# a body naming the connector's side ("plai" plaintext, "tlsx" TLS), and the
# connector keeps every byte written to it, so a test reads the request back
# from the connector the file system's client holds.
#
# Rows:
#  * the AzureFs azure_fs_for builds advertises FS_SCHEME_AZURE, names its
#    container, and has no client until its first verb.
#  * credential wiring, each read through the AzureFs: a SAS token
#    rides in the request line's query and no Authorization is sent; a
#    Shared Key signs (`Authorization: SharedKey <account>:`) and no query
#    is added; anonymous sends neither.
#  * a clone of the file system builds its own client from the same spec: one
#    request on its own connector, carrying the same SAS token.
#  * the endpoint's scheme picks the connector: http:// reads over the
#    plaintext side, https:// (and HTTPS://) over the TLS side; each read
#    passes komira_http_client's scheme check, so a side picked the wrong way
#    round is refused there.
#  * the production file system: azure_prod_fs's connector is TLS for
#    Azure's own endpoint and for https://, plaintext for http:// (asked
#    through AzureFs.spec().new_connector(), nothing dialed, no client
#    built); an ftp:// endpoint, a bad container name and a Shared Key for
#    another account are refused by exact message.
#  * the production type constructs and clones without dialing: an AzureFs
#    over KernelSchemeConnector whose factory raises if called keeps its
#    container through a clone and a move, and neither it nor its clone
#    builds a client.
from std.memory import ArcPointer
from std.testing import assert_equal, assert_false, assert_raises, assert_true

from komira_async.reactor.reactor import Reactor
from komira_async.runtime.runtime_trait import Runtime
from komira_azure_blob import (
    AzureClientSpec,
    AzureConfig,
    AzureCredential,
    AzureFs,
    AzureFsConfig,
    azure_fs_for,
    azure_prod_fs,
)
from komira_azure_core import AzureSas, AzureSharedKey
from komira_http_client import KernelSchemeConnector
from komira_http_core.transport.io_stream import Connector, TRANSPORT_KIND_KERNEL_TCP
from komira_http_core.transport.scripted import ScriptedStream
from komira_plan_expr.fs_descriptor_pod import FS_SCHEME_AZURE


comptime ACCOUNT = "devstoreaccount1"
comptime FAKE_KEY = "VGhpcyBpcyBhIGZha2Uga2V5IGZvciB0ZXN0aW5nIDEyMzQ1Njc4OTAxMjMK"
comptime TOKEN = "sv=2021-08-06&sp=r&sig=abc%2Bdef%3D"
comptime EMULATOR = "http://127.0.0.1:10000"
comptime EMULATOR_TLS = "https://127.0.0.1:10443"


def _text(bytes: List[UInt8]) -> String:
    return String(unsafe_from_utf8=Span(bytes))


struct _Wire(Connector, Movable, Deinitable):
    """Answers every dial with a 4-byte range whose body is `body`; keeps
    every byte written to it."""

    comptime Stream = ScriptedStream

    var _body: String
    var _tls: Bool
    var _capture: ArcPointer[List[UInt8]]

    def __init__(out self, var body: String, tls: Bool):
        self._body = body^
        self._tls = tls
        self._capture = ArcPointer[List[UInt8]](List[UInt8]())

    def connect[RT: Runtime](
        mut self, mut reactor: Reactor[RT.Sink], ip_be: UInt32, port: UInt16
    ) raises -> ScriptedStream:
        var answer = String(
            "HTTP/1.1 206 Partial Content\r\nContent-Length: 4\r\nConnection: close\r\n"
            "Content-Range: bytes 0-3/10\r\n\r\n"
        ) + self._body
        var bytes = List[UInt8]()
        bytes.extend(Span(answer.as_bytes()))
        return ScriptedStream.from_read_script_with_capture(bytes^, self._capture)

    def transport_kind(self) -> UInt8:
        return TRANSPORT_KIND_KERNEL_TCP

    def is_tls(self) -> Bool:
        return self._tls

    def set_dial_host(mut self, var host: String):
        _ = host^

    def wire(self) -> String:
        return _text(self._capture[])


def _mk_plain() raises -> _Wire:
    return _Wire(String("plai"), False)


def _mk_tls() raises -> _Wire:
    return _Wire(String("tlsx"), True)


comptime _Fs = AzureFs[_Wire]


def _emulator(endpoint: String) -> AzureFsConfig:
    return AzureFsConfig(account=String(ACCOUNT), endpoint=endpoint, path_style=True)


def _fs(endpoint: String, credential: AzureCredential) raises -> _Fs:
    return azure_fs_for[_Wire]("lake", _emulator(endpoint), credential, _mk_plain, _mk_tls)


def _read(fs: _Fs) raises -> String:
    """Reads bytes 0-3 of data/a.parquet through the AzureFs."""
    var file = fs.open("data/a.parquet")
    var buf = fs.read_at(file, 0, 4)
    var view = buf.view_range_ro(0, buf.len())
    return String(unsafe_from_utf8=view.into_span())


def _wire(fs: _Fs) raises -> String:
    """What the file system's client wrote to the connector it dials per
    call."""
    return fs._client.get_mut_interior(0).value()._inner_connector.value().wire()


def _sas() raises -> AzureCredential:
    return AzureCredential.sas(AzureSas("?" + TOKEN))


def test_the_fs_advertises_the_azure_scheme() raises:
    assert_equal(_Fs.SCHEME, FS_SCHEME_AZURE)
    var h = _fs(EMULATOR, _sas())
    assert_equal(h.container(), "lake")
    assert_false(h.client_built())


def test_a_sas_token_rides_in_the_query() raises:
    var h = _fs(EMULATOR, _sas())
    assert_equal(_read(h), "plai")
    var wire = _wire(h)
    assert_true(
        wire.startswith("GET /devstoreaccount1/lake/data/a.parquet?" + TOKEN + " HTTP/1.1\r\n"),
        wire,
    )
    assert_false(wire.lower().find("authorization") >= 0, wire)


def test_a_shared_key_signs() raises:
    var h = _fs(
        EMULATOR, AzureCredential.shared_key(AzureSharedKey(String(ACCOUNT), String(FAKE_KEY)))
    )
    assert_equal(_read(h), "plai")
    var wire = _wire(h)
    assert_true(wire.startswith("GET /devstoreaccount1/lake/data/a.parquet HTTP/1.1\r\n"), wire)
    assert_true(wire.lower().find("authorization: sharedkey devstoreaccount1:") >= 0, wire)
    assert_false(wire.find("sig=") >= 0, wire)


def test_anonymous_sends_neither() raises:
    var h = _fs(EMULATOR, AzureCredential.anonymous())
    assert_equal(_read(h), "plai")
    var wire = _wire(h)
    assert_true(wire.startswith("GET /devstoreaccount1/lake/data/a.parquet HTTP/1.1\r\n"), wire)
    assert_false(wire.lower().find("authorization") >= 0, wire)


def test_a_clone_reads_with_the_same_credential() raises:
    var h = _fs(EMULATOR, _sas())
    assert_equal(_read(h), "plai")
    var c = h.clone()
    assert_false(c.client_built())
    assert_equal(_read(c), "plai")
    var wire = _wire(c)
    assert_true(
        wire.startswith("GET /devstoreaccount1/lake/data/a.parquet?" + TOKEN + " HTTP/1.1\r\n"),
        wire,
    )
    assert_equal(wire.find("GET ", 1), -1)


def test_the_endpoint_scheme_picks_the_connector() raises:
    assert_equal(_read(_fs(EMULATOR, _sas())), "plai")
    assert_equal(_read(_fs("HTTP://127.0.0.1:10000", _sas())), "plai")
    assert_equal(_read(_fs(EMULATOR_TLS, _sas())), "tlsx")
    assert_equal(_read(_fs("HTTPS://127.0.0.1:10443", _sas())), "tlsx")


def _prod_is_tls(config: AzureFsConfig) raises -> Bool:
    var fs = azure_prod_fs("lake", config, AzureCredential.anonymous())
    assert_equal(fs.container(), "lake")
    var is_tls = fs.spec().new_connector().is_tls()
    assert_false(fs.client_built())
    assert_equal(AzureFs[KernelSchemeConnector].SCHEME, FS_SCHEME_AZURE)
    return is_tls


def test_the_production_fs() raises:
    assert_true(_prod_is_tls(AzureFsConfig.azure("myacct")), "Azure's own endpoint dials plaintext")
    assert_true(
        _prod_is_tls(AzureFsConfig(account=String("myacct"), endpoint=String("https://blob.example.test"), path_style=False)),
        "an https:// endpoint dials plaintext",
    )
    assert_false(_prod_is_tls(_emulator(EMULATOR)), "an http:// endpoint dials TLS")
    with assert_raises(
        contains="azure_url: an Azure endpoint must start with http:// or https://, got 'ftp://x.test'"
    ):
        _ = _prod_is_tls(_emulator("ftp://x.test"))
    with assert_raises(contains="azure_url: 'Lake' is not an Azure container name"):
        _ = azure_prod_fs("Lake", AzureFsConfig.azure("myacct"), AzureCredential.anonymous())
    with assert_raises(
        contains="azure_client_spec: the shared key is for account 'otheracct' and the endpoint is account 'myacct'"
    ):
        _ = azure_prod_fs(
            "lake",
            AzureFsConfig.azure("myacct"),
            AzureCredential.shared_key(AzureSharedKey(String("otheracct"), String(FAKE_KEY))),
        )


def _never_dial() raises -> KernelSchemeConnector:
    raise Error("test: the AzureFs made a connector")


def test_the_production_type_clones_without_dialing() raises:
    var fs = AzureFs[KernelSchemeConnector](
        container=String("box"),
        spec=AzureClientSpec[KernelSchemeConnector](
            AzureConfig.azure("myacct"), AzureCredential.anonymous(), _never_dial
        ),
    )
    assert_equal(fs.container(), "box")
    assert_false(fs.client_built())
    var c = fs.clone()
    assert_equal(c.container(), "box")
    assert_false(c.client_built())
    var moved = c^
    assert_equal(moved.container(), "box")
    assert_false(fs.client_built())


def main() raises:
    test_the_fs_advertises_the_azure_scheme()
    test_a_sas_token_rides_in_the_query()
    test_a_shared_key_signs()
    test_anonymous_sends_neither()
    test_a_clone_reads_with_the_same_credential()
    test_the_endpoint_scheme_picks_the_connector()
    test_the_production_fs()
    test_the_production_type_clones_without_dialing()
    print("OK")
