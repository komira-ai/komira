# =============================================================================
# test_adc.mojo — Application Default Credentials, every branch.
# =============================================================================
#
# `resolve_adc` runs over a `MapEnv` (which records every variable read), a
# `MapFiles` and a scripted probe transport, so every step of Google's order
# is driven without a filesystem, an environment or a network:
#
#   1. GOOGLE_APPLICATION_CREDENTIALS: each credential type (service_account
#      as a JWT grant, as a self-signed JWT for an audience and with
#      always_use_jwt_access; authorized_user), and each refusal: a missing
#      file (which does NOT fall through), external_account (named: it is
#      komira_gcp_wif's), the other Google types, an unknown type, a key
#      with neither scopes nor an audience; an empty value is unset;
#   2. the gcloud well-known file under CLOUDSDK_CONFIG, HOME and, on
#      Windows, APPDATA;
#   3. the metadata server: GCE_METADATA_HOST (no probe), the probe answered
#      `Metadata-Flavor: Google`, the probe failed but the DMI product name
#      says Google, and neither;
#   4. nothing found: Google's own text.
#
# After every case the variables read are checked against the five Google's
# libraries read, and across the cases every one of the five is read.
#
# `application_default_token_source_with` is then run end to end through
# komira_http_client over ScriptedConnectors: the metadata token over the
# plain transport and a key file's grant over the TLS one. The production
# entry `application_default_token_source` is compiled here, not run: it
# reads this process's environment.
# =============================================================================

from std.memory import ArcPointer
from std.sys import argv
from std.testing import assert_equal, assert_false, assert_true

from komira_gcp_core import (
    ADC_KIND_AUTHORIZED_USER,
    ADC_KIND_METADATA_SERVER,
    ADC_KIND_SELF_SIGNED_JWT,
    ADC_KIND_SERVICE_ACCOUNT,
    ADC_NOT_FOUND,
    ADC_SOURCE_ENV_FILE,
    ADC_SOURCE_GCLOUD_FILE,
    ADC_SOURCE_METADATA,
    PROBE_TIMEOUT_US,
    AdcCredentials,
    AdcOptions,
    FixedWallClock,
    GcpConnectorTransport,
    GcpHttpTransport,
    MapEnv,
    MapFiles,
    TokenHttpRequest,
    TokenHttpResponse,
    adc_env_names,
    adc_probe_config,
    application_default_token_source,
    application_default_token_source_with,
    gcloud_adc_path,
    resolve_adc,
)
from komira_encoding import base64_url_decode_nopad
from komira_http_client.client import HttpClientConfig
from komira_http_core.transport.scripted import ScriptedConnector, ScriptedStream
from komira_retry import ManualClock


comptime _ACCOUNT = "conformance/storage/v1/test_service_account.not-a-test.json"
comptime _CLOUD = "https://www.googleapis.com/auth/cloud-platform"
comptime _GAC = "GOOGLE_APPLICATION_CREDENTIALS"
comptime _KEY_PATH = "/secrets/sa.json"
comptime _HOME = "/h/u"
comptime _WELL_KNOWN = "/h/u/.config/gcloud/application_default_credentials.json"
comptime _DMI = "/sys/class/dmi/id/product_name"
comptime _T0: Int64 = 1_790_000_000

comptime _USER = (
    '{"type":"authorized_user","client_id":"cid","client_secret":"s",'
    '"refresh_token":"r"}'
)


# =============================================================================
# Doubles and helpers
# =============================================================================

comptime _PROBE_RAISES = 0
comptime _PROBE_GOOGLE = 1
comptime _PROBE_OTHER = 2


struct ScriptedProbe(GcpHttpTransport, Movable, Deinitable):
    """The metadata probe's transport: answers as a metadata server, as
    something else, or not at all; keeps every request."""

    var mode: Int
    var sent: List[TokenHttpRequest]

    def __init__(out self, mode: Int):
        self.mode = mode
        self.sent = List[TokenHttpRequest]()

    def send(mut self, req: TokenHttpRequest) raises -> TokenHttpResponse:
        self.sent.append(req.copy())
        if self.mode == _PROBE_RAISES:
            raise Error("HttpError[CONNECT_FAILED]: no route")
        var res = TokenHttpResponse(200, List[UInt8]())
        if self.mode == _PROBE_GOOGLE:
            res.add_header(String("Metadata-Flavor"), String("Google"))
        return res^


def _key_text() raises -> String:
    with open(String(_ACCOUNT), "r") as f:
        return f.read()


def _scopes() -> List[String]:
    var s = List[String]()
    s.append(String(_CLOUD))
    return s^


def _official() -> List[String]:
    return [
        String("GOOGLE_APPLICATION_CREDENTIALS"),
        String("CLOUDSDK_CONFIG"),
        String("HOME"),
        String("APPDATA"),
        String("GCE_METADATA_HOST"),
    ]


def _contains(names: List[String], s: String) -> Bool:
    for i in range(len(names)):
        if names[i] == s:
            return True
    return False


struct Seen(Movable):
    """Every variable read across the cases."""

    var names: List[String]

    def __init__(out self):
        self.names = List[String]()

    def check(mut self, env: MapEnv) raises:
        """Every name `env` was asked for is one of Google's."""
        var official = _official()
        for i in range(len(env.reads)):
            assert_true(
                _contains(official, env.reads[i]),
                "the chain read " + env.reads[i] + ", not a Google variable",
            )
            if not _contains(self.names, env.reads[i]):
                self.names.append(env.reads[i])


def _resolve(
    mut seen: Seen,
    mut env: MapEnv,
    mut files: MapFiles,
    mut probe: ScriptedProbe,
    options: AdcOptions,
    windows: Bool = False,
) raises -> AdcCredentials:
    var out = resolve_adc(env, files, probe, options, windows)
    seen.check(env)
    return out^


def _refusal(
    mut seen: Seen,
    mut env: MapEnv,
    mut files: MapFiles,
    mut probe: ScriptedProbe,
    options: AdcOptions,
    windows: Bool = False,
) raises -> String:
    var msg = String("<no error>")
    try:
        _ = resolve_adc(env, files, probe, options, windows)
    except e:
        msg = String(e)
    seen.check(env)
    return msg


# =============================================================================
# Step 1: GOOGLE_APPLICATION_CREDENTIALS
# =============================================================================


def test_env_file_service_account(mut seen: Seen) raises:
    var env = MapEnv()
    env.set(String(_GAC), String(_KEY_PATH))
    var files = MapFiles()
    files.put(String(_KEY_PATH), _key_text())
    # The well-known file exists too: step 1 wins.
    env.set(String("HOME"), String(_HOME))
    files.put(String(_WELL_KNOWN), String(_USER))
    var probe = ScriptedProbe(_PROBE_GOOGLE)
    var c = _resolve(seen, env, files, probe, AdcOptions(_scopes()))
    assert_equal(c.source, ADC_SOURCE_ENV_FILE)
    assert_equal(c.kind, ADC_KIND_SERVICE_ACCOUNT)
    assert_equal(c.origin, _KEY_PATH)
    assert_true(Bool(c.key))
    assert_equal(len(probe.sent), 0)
    assert_false(env.was_read(String("HOME")))
    assert_equal(len(env.reads), 1)


def test_env_file_kinds(mut seen: Seen) raises:
    # No scopes, an audience: a self-signed JWT.
    var env = MapEnv()
    env.set(String(_GAC), String(_KEY_PATH))
    var files = MapFiles()
    files.put(String(_KEY_PATH), _key_text())
    var probe = ScriptedProbe(_PROBE_RAISES)
    var c = _resolve(
        seen, env, files, probe,
        AdcOptions(List[String](), String("https://logging.googleapis.com/")),
    )
    assert_equal(c.kind, ADC_KIND_SELF_SIGNED_JWT)
    # Scopes AND always_use_jwt_access: a self-signed JWT too.
    var env2 = MapEnv()
    env2.set(String(_GAC), String(_KEY_PATH))
    var c2 = _resolve(
        seen, env2, files, probe, AdcOptions(_scopes(), String(""), True)
    )
    assert_equal(c2.kind, ADC_KIND_SELF_SIGNED_JWT)
    # An authorized_user file.
    var env3 = MapEnv()
    env3.set(String(_GAC), String(_KEY_PATH))
    var files3 = MapFiles()
    files3.put(String(_KEY_PATH), String(_USER))
    var c3 = _resolve(seen, env3, files3, probe, AdcOptions())
    assert_equal(c3.kind, ADC_KIND_AUTHORIZED_USER)
    assert_equal(c3.source, ADC_SOURCE_ENV_FILE)
    assert_true(Bool(c3.user))
    assert_equal(len(probe.sent), 0)


def _env_file_refusal(mut seen: Seen, contents: String, options: AdcOptions) raises -> String:
    var env = MapEnv()
    env.set(String(_GAC), String(_KEY_PATH))
    var files = MapFiles()
    files.put(String(_KEY_PATH), contents)
    var probe = ScriptedProbe(_PROBE_GOOGLE)
    var msg = _refusal(seen, env, files, probe, options)
    assert_equal(len(probe.sent), 0)
    return msg


def test_env_file_refusals(mut seen: Seen) raises:
    # A missing file is an error, not a reason to look further.
    var env = MapEnv()
    env.set(String(_GAC), String("/nowhere.json"))
    env.set(String("HOME"), String(_HOME))
    var files = MapFiles()
    files.put(String(_WELL_KNOWN), String(_USER))
    var probe = ScriptedProbe(_PROBE_GOOGLE)
    assert_equal(
        _refusal(seen, env, files, probe, AdcOptions()),
        "ADC: GOOGLE_APPLICATION_CREDENTIALS names the file /nowhere.json,"
        " which does not exist",
    )
    assert_equal(len(probe.sent), 0)
    assert_false(env.was_read(String("HOME")))

    assert_equal(
        _env_file_refusal(
            seen,
            String('{"type":"external_account","audience":"//iam.googleapis.com/x"}'),
            AdcOptions(_scopes()),
        ),
        "ADC: the credentials file /secrets/sa.json is an external_account"
        " (workload identity federation) file. komira_gcp_core does not read"
        " one: workload identity federation belongs to komira_gcp_wif, which"
        " is not on main yet",
    )
    assert_equal(
        _env_file_refusal(
            seen,
            String('{"type":"impersonated_service_account"}'),
            AdcOptions(_scopes()),
        ),
        "ADC: the credentials file /secrets/sa.json is of type"
        " impersonated_service_account, which komira_gcp_core does not support",
    )
    assert_equal(
        _env_file_refusal(
            seen,
            String('{"type":"external_account_authorized_user"}'),
            AdcOptions(_scopes()),
        ),
        "ADC: the credentials file /secrets/sa.json is of type"
        " external_account_authorized_user, which komira_gcp_core does not"
        " support",
    )
    # An unknown type is not repeated.
    var unknown = _env_file_refusal(
        seen, String('{"type":"SOMETHING-ELSE"}'), AdcOptions(_scopes())
    )
    assert_equal(
        unknown,
        "ADC: the credentials file /secrets/sa.json is of an unknown type;"
        " expected service_account or authorized_user",
    )
    assert_equal(
        _env_file_refusal(seen, String("not json"), AdcOptions(_scopes())),
        "the credentials file /secrets/sa.json is not JSON",
    )
    assert_equal(
        _env_file_refusal(seen, _key_text(), AdcOptions()),
        "ADC: the service-account key /secrets/sa.json needs scopes (for the"
        " JWT bearer grant) or a self-signed JWT audience",
    )
    assert_equal(
        _env_file_refusal(seen, _key_text(), AdcOptions(List[String](), String(""), True)),
        "ADC: the service-account key /secrets/sa.json is set to always"
        " self-sign, and that needs scopes or an audience",
    )


def test_empty_env_value_is_unset(mut seen: Seen) raises:
    var env = MapEnv()
    env.set(String(_GAC), String(""))
    env.set(String("HOME"), String(_HOME))
    var files = MapFiles()
    files.put(String(_WELL_KNOWN), String(_USER))
    var probe = ScriptedProbe(_PROBE_RAISES)
    var c = _resolve(seen, env, files, probe, AdcOptions())
    assert_equal(c.source, ADC_SOURCE_GCLOUD_FILE)


# =============================================================================
# Step 2: the gcloud well-known file
# =============================================================================


def test_well_known_file(mut seen: Seen) raises:
    var env = MapEnv()
    env.set(String("HOME"), String(_HOME))
    var files = MapFiles()
    files.put(String(_WELL_KNOWN), String(_USER))
    var probe = ScriptedProbe(_PROBE_GOOGLE)
    var c = _resolve(seen, env, files, probe, AdcOptions())
    assert_equal(c.source, ADC_SOURCE_GCLOUD_FILE)
    assert_equal(c.kind, ADC_KIND_AUTHORIZED_USER)
    assert_equal(c.origin, _WELL_KNOWN)
    assert_equal(len(probe.sent), 0)
    # Its order of reads: the file variable, then gcloud's directory.
    assert_equal(env.reads[0], _GAC)
    assert_equal(env.reads[1], "CLOUDSDK_CONFIG")
    assert_equal(env.reads[2], "HOME")


def test_well_known_paths(mut seen: Seen) raises:
    var env = MapEnv()
    env.set(String("HOME"), String(_HOME))
    env.set(String("CLOUDSDK_CONFIG"), String("/cfg"))
    assert_equal(gcloud_adc_path(env, False), "/cfg/application_default_credentials.json")
    var files = MapFiles()
    files.put(String("/cfg/application_default_credentials.json"), _key_text())
    var probe = ScriptedProbe(_PROBE_RAISES)
    var c = _resolve(seen, env, files, probe, AdcOptions(_scopes()))
    assert_equal(c.source, ADC_SOURCE_GCLOUD_FILE)
    assert_equal(c.kind, ADC_KIND_SERVICE_ACCOUNT)
    assert_false(env.was_read(String("HOME")))

    var win = MapEnv()
    win.set(String("APPDATA"), String("C:\\Users\\u\\AppData\\Roaming"))
    win.set(String("HOME"), String(_HOME))
    assert_equal(
        gcloud_adc_path(win, True),
        "C:\\Users\\u\\AppData\\Roaming\\gcloud\\application_default_credentials.json",
    )
    seen.check(win)
    var win_cfg = MapEnv()
    win_cfg.set(String("CLOUDSDK_CONFIG"), String("D:\\g"))
    assert_equal(gcloud_adc_path(win_cfg, True), "D:\\g\\application_default_credentials.json")
    var none = MapEnv()
    assert_equal(gcloud_adc_path(none, False), "")
    assert_equal(gcloud_adc_path(none, True), "")
    seen.check(none)

    # On Windows the well-known file is found under APPDATA, and the Linux
    # DMI check is not made.
    var wenv = MapEnv()
    wenv.set(String("APPDATA"), String("C:\\A"))
    var wfiles = MapFiles()
    wfiles.put(String("C:\\A\\gcloud\\application_default_credentials.json"), String(_USER))
    var c2 = _resolve(seen, wenv, wfiles, probe, AdcOptions(), True)
    assert_equal(c2.source, ADC_SOURCE_GCLOUD_FILE)
    var wenv2 = MapEnv()
    var wfiles2 = MapFiles()
    wfiles2.put(String(_DMI), String("Google Compute Engine\n"))
    assert_equal(
        _refusal(seen, wenv2, wfiles2, probe, AdcOptions(), True),
        String(ADC_NOT_FOUND),
    )
    assert_false(_contains(wfiles2.probes, String(_DMI)))


# =============================================================================
# Step 3: the metadata server
# =============================================================================


def test_metadata_host_env(mut seen: Seen) raises:
    var env = MapEnv()
    env.set(String("GCE_METADATA_HOST"), String("127.0.0.1:8080"))
    var files = MapFiles()
    var probe = ScriptedProbe(_PROBE_RAISES)
    var c = _resolve(seen, env, files, probe, AdcOptions())
    assert_equal(c.source, ADC_SOURCE_METADATA)
    assert_equal(c.kind, ADC_KIND_METADATA_SERVER)
    assert_equal(
        c.origin,
        "http://127.0.0.1:8080/computeMetadata/v1/instance/service-accounts/default/token",
    )
    # The variable is taken as being on Google Cloud: no probe.
    assert_equal(len(probe.sent), 0)


def test_metadata_probe(mut seen: Seen) raises:
    var env = MapEnv()
    var files = MapFiles()
    var probe = ScriptedProbe(_PROBE_GOOGLE)
    var c = _resolve(seen, env, files, probe, AdcOptions())
    assert_equal(c.source, ADC_SOURCE_METADATA)
    assert_equal(
        c.origin,
        "http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/token",
    )
    assert_equal(len(probe.sent), 1)
    assert_equal(
        probe.sent[0].to_wire(),
        "GET / HTTP/1.1\r\nHost: 169.254.169.254\r\nMetadata-Flavor: Google\r\n\r\n",
    )
    assert_equal(probe.sent[0].port, 80)


def test_metadata_dmi_fallback(mut seen: Seen) raises:
    var env = MapEnv()
    var files = MapFiles()
    files.put(String(_DMI), String("Google Compute Engine\n"))
    var probe = ScriptedProbe(_PROBE_RAISES)
    var c = _resolve(seen, env, files, probe, AdcOptions())
    assert_equal(c.source, ADC_SOURCE_METADATA)
    assert_equal(len(probe.sent), 1)


def test_nothing_found(mut seen: Seen) raises:
    var env = MapEnv()
    env.set(String("HOME"), String(_HOME))
    var files = MapFiles()
    files.put(String(_DMI), String("Standard PC\n"))
    var probe = ScriptedProbe(_PROBE_OTHER)
    assert_equal(_refusal(seen, env, files, probe, AdcOptions()), String(ADC_NOT_FOUND))
    assert_equal(
        String(ADC_NOT_FOUND),
        "Your default credentials were not found. To set up Application"
        " Default Credentials, see"
        " https://cloud.google.com/docs/authentication/external/set-up-adc"
        " for more information.",
    )
    assert_equal(len(probe.sent), 1)
    var bare_env = MapEnv()
    var bare = MapFiles()
    var down = ScriptedProbe(_PROBE_RAISES)
    assert_equal(_refusal(seen, bare_env, bare, down, AdcOptions()), String(ADC_NOT_FOUND))


def test_every_google_variable_and_no_other(seen: Seen) raises:
    var official = _official()
    var names = adc_env_names()
    assert_equal(len(names), len(official))
    for i in range(len(official)):
        assert_true(_contains(names, official[i]), official[i])
        assert_true(
            _contains(seen.names, official[i]),
            official[i] + " is never read by any case",
        )


# =============================================================================
# End to end over komira_http_client
# =============================================================================

comptime Transport = GcpConnectorTransport[ScriptedConnector]

comptime _OK_BODY = '{"access_token":"ya29.ADC","expires_in":3599}'


def _answer(body: String) -> List[UInt8]:
    var out = List[UInt8]()
    out.extend(
        Span(
            (
                String("HTTP/1.1 200 OK\r\nContent-Length: ")
                + String(body.byte_length())
                + "\r\nConnection: close\r\n\r\n"
                + body
            ).as_bytes()
        )
    )
    return out^


def _unused() raises -> Transport:
    """A transport whose dial is refused: a step that must not send."""
    var c = ScriptedConnector()
    c.arm_connect_error(111)
    return Transport(HttpClientConfig.defaults(), c^)


def test_end_to_end_metadata(mut seen: Seen) raises:
    var env = MapEnv()
    env.set(String("GCE_METADATA_HOST"), String("127.0.0.1:8080"))
    var files = MapFiles()
    var capture = ArcPointer(List[UInt8]())
    var plain = ScriptedConnector()
    plain.arm(ScriptedStream.from_read_script_with_capture(_answer(_OK_BODY), capture))
    var src = application_default_token_source_with(
        env,
        files,
        _unused(),
        Transport(HttpClientConfig.defaults(), plain^),
        _unused(),
        FixedWallClock(_T0),
        ManualClock(0),
        AdcOptions(),
    )
    seen.check(env)
    assert_equal(src.access_token(), "ya29.ADC")
    var wire = String(unsafe_from_utf8=Span(capture[]))
    assert_true(
        wire.startswith(
            "GET /computeMetadata/v1/instance/service-accounts/default/token HTTP/1.1\r\n"
        ),
        wire,
    )
    assert_true("host: 127.0.0.1:8080\r\n" in wire, wire)
    assert_true("metadata-flavor: Google\r\n" in wire, wire)


def test_end_to_end_key_file(mut seen: Seen) raises:
    var env = MapEnv()
    env.set(String(_GAC), String(_KEY_PATH))
    var files = MapFiles()
    files.put(
        String(_KEY_PATH),
        _key_text().replace(
            "https://oauth2.googleapis.com/token", "https://127.0.0.1:8443/token"
        ),
    )
    var capture = ArcPointer(List[UInt8]())
    var tls = ScriptedConnector.with_stream_tls(
        ScriptedStream.from_read_script_with_capture(_answer(_OK_BODY), capture)
    )
    var src = application_default_token_source_with(
        env,
        files,
        _unused(),
        _unused(),
        Transport(HttpClientConfig.defaults(), tls^),
        FixedWallClock(_T0),
        ManualClock(0),
        AdcOptions(_scopes()),
    )
    seen.check(env)
    assert_equal(src.access_token(), "ya29.ADC")
    var wire = String(unsafe_from_utf8=Span(capture[]))
    assert_true(wire.startswith("POST /token HTTP/1.1\r\n"), wire)
    assert_true(
        "grant_type=urn%3Aietf%3Aparams%3Aoauth%3Agrant-type%3Ajwt-bearer&assertion=eyJ"
        in wire,
        wire,
    )


def test_end_to_end_always_self_signed(mut seen: Seen) raises:
    var env = MapEnv()
    env.set(String(_GAC), String(_KEY_PATH))
    var files = MapFiles()
    files.put(String(_KEY_PATH), _key_text())
    var src = application_default_token_source_with(
        env,
        files,
        _unused(),
        _unused(),
        _unused(),
        FixedWallClock(_T0),
        ManualClock(0),
        AdcOptions(_scopes(), String("https://logging.googleapis.com/"), True),
    )
    seen.check(env)
    var jwt = src.access_token()
    var parts = jwt.split(".")
    assert_equal(len(parts), 3)
    var claims = String(unsafe_from_utf8=Span(base64_url_decode_nopad(String(parts[1]))))
    # google-auth: with always_use_jwt_access and scopes, a `scope` claim
    # and no audience.
    assert_true(claims.endswith(',"scope":"' + String(_CLOUD) + '"}'), claims)
    assert_false('"aud"' in claims, claims)


def test_probe_config() raises:
    var d = adc_probe_config(HttpClientConfig.defaults())
    assert_equal(d.request_timeout_us, PROBE_TIMEOUT_US)
    var short = HttpClientConfig.defaults()
    short.request_timeout_us = 1_000_000
    assert_equal(adc_probe_config(short).request_timeout_us, 1_000_000)
    var long = HttpClientConfig.defaults()
    long.request_timeout_us = 30_000_000
    assert_equal(adc_probe_config(long).request_timeout_us, PROBE_TIMEOUT_US)
    assert_equal(PROBE_TIMEOUT_US, 3_000_000)


def _mk() raises -> ScriptedConnector:
    return ScriptedConnector()


def test_production_entry_compiles() raises:
    # Never true: the production entry reads this process's environment and
    # may probe the network. Calling it here makes the compiler build it.
    if len(argv()) > 1_000_000:
        var src = application_default_token_source[ScriptedConnector, ScriptedConnector](
            HttpClientConfig.defaults(), _mk, _mk, AdcOptions(_scopes())
        )
        _ = src.access_token()


def main() raises:
    var seen = Seen()
    test_env_file_service_account(seen)
    test_env_file_kinds(seen)
    test_env_file_refusals(seen)
    test_empty_env_value_is_unset(seen)
    test_well_known_file(seen)
    test_well_known_paths(seen)
    test_metadata_host_env(seen)
    test_metadata_probe(seen)
    test_metadata_dmi_fallback(seen)
    test_nothing_found(seen)
    test_end_to_end_metadata(seen)
    test_end_to_end_key_file(seen)
    test_end_to_end_always_self_signed(seen)
    test_every_google_variable_and_no_other(seen)
    test_probe_config()
    test_production_entry_compiles()
    print("OK")
