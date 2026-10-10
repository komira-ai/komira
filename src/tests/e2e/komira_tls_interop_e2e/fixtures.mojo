# =============================================================================
# komira_tls_interop_e2e/fixtures.mojo -- the certificates, komira's TLS
# configurations, and the flags a test is given
# =============================================================================
#
# The certificates are komira_http_core's throwaway test fixtures, staged into
# each test's working directory at their source paths by `data` (see BUCK),
# so komira and bssl open them by the same relative path. The leaf names
# `localhost` and `127.0.0.1` and is signed by `root_ca.pem`;
# `smoke_cert.pem` is an unrelated self-signed certificate, the trust anchor
# of a client that must NOT accept the leaf.
#
# komira's server is configured as an HTTPS server with HTTP/2 deploys: the
# leaf, the "default_tls13" policy (TLS 1.3 and 1.2), ALPN `h2` then
# `http/1.1`. komira's client is the production one,
# `komira_http_client.default_client_tls_config` (the same policy, ALPN
# `http/1.1` preceded by `h2` when asked, verification on), with its trust
# store narrowed to one anchor.
# =============================================================================

from std.pathlib import Path
from std.sys import argv

from komira_http_client.tls_connector import default_client_tls_config
from komira_http_core.tls import TlsConfig
from komira_runtime_paths import test_tmpdir


comptime LEAF_CERT_PATH = "src/komira_http_core/tests/fixtures/tls/leaf_cert.pem"
comptime LEAF_KEY_PATH = "src/komira_http_core/tests/fixtures/tls/leaf_key.pem"
comptime ROOT_CA_PATH = "src/komira_http_core/tests/fixtures/tls/root_ca.pem"
comptime OTHER_CA_PATH = "src/komira_http_core/tests/fixtures/smoke_cert.pem"

# The name the leaf certifies, sent as SNI and verified by both clients.
comptime SERVER_NAME = "localhost"


def read_fixture(path: StaticString) raises -> String:
    """The text of a staged fixture file, read from the test's working
    directory."""
    return Path(String(path)).read_text()


def flag(name: String) raises -> String:
    """The value of `--<name>=<value>` among the test's arguments (BUCK
    passes them); raises when it is absent or empty."""
    var want = "--" + name + "="
    var args = argv()
    for i in range(1, len(args)):
        var a = String(args[i])
        if a.startswith(want):
            var v = String(a[byte = want.byte_length() :])
            if v.byte_length() > 0:
                return v^
    raise Error("missing flag " + want + "<value> (the mojo_test's args in BUCK give it)")


def scratch_file(name: String, text: String) raises -> String:
    """Write `text` to `name` in the test's own scratch directory
    (TEST_TMPDIR, made by the test runner for this run); returns its path."""
    var path = test_tmpdir() + "/" + name
    with open(path, "w") as f:
        f.write(text)
    return path^


def server_tls_config() raises -> TlsConfig:
    """komira's server: the fixture leaf and its key, "default_tls13", ALPN
    `h2` then `http/1.1`."""
    var config = TlsConfig()
    config.set_cipher_preferences(String("default_tls13"))
    config.load_cert(read_fixture(LEAF_CERT_PATH), read_fixture(LEAF_KEY_PATH))
    var alpn = List[String]()
    alpn.append(String("h2"))
    alpn.append(String("http/1.1"))
    config.set_alpn_protocols(alpn)
    return config^


def client_tls_config(trust_anchor_path: StaticString, offer_h2: Bool) raises -> TlsConfig:
    """komira's production client configuration, trusting ONLY the
    certificate at `trust_anchor_path`."""
    var config = default_client_tls_config(offer_h2)
    config.wipe_trust()
    config.add_trust_pem(read_fixture(trust_anchor_path))
    return config^
