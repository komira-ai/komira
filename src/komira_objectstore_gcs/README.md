# komira_objectstore_gcs

Google Cloud Storage over the komira_objectstore traits. The object verbs sit
behind one narrow seam, `GcsStorageBackend`; `GcsConditionalStore` and `GcsFs`
are generic over it. `FakeGcsStorageBackend` is an in-memory conformer for
hermetic tests, and `StorageGrpcBackend` is the production one:
google.storage.v2 over gRPC, HTTP/2 over TLS, through the generated
komira_gcp_storage client. `GcsV4Signer` signs V4 URLs. The package-level
docstring in `__init__.mojo` lists every public name.

## Choosing the transport trust

`StorageGrpcBackend` always dials `https://<host>:<port>` over the connector it
is given; which server certificates that connector accepts is its `TlsConfig`'s.

* `build_gcs_tls_connector(host)` is the default, and the one the production
  endpoint needs: the system's public CA roots, verification on, SNI `host`,
  ALPN `h2`. A peer whose certificate chains to no public root fails the
  handshake.
* `build_gcs_tls_connector_with_config(config, server_name)` takes a
  `TlsConfig` the caller built (its trust store, its verification), sets its
  ALPN to `h2`, `http/1.1` and pins SNI to `server_name`.
  `gcs_tls_config_trusting_only(root_pem)` builds that config for a peer
  signed by a private CA (a storage emulator behind TLS, an in-process fake):
  the public roots are wiped, `root_pem` is the only trust anchor, and
  verification stays on.

There is no plaintext (h2c) route: komira_grpc carries only unary calls over
h2c, so WriteObject and ReadObject could not use one. Nothing here reads the
environment; the trust is whatever the caller's code passes.

The default connector, and a backend over it (built, not called: nothing is
dialed until a verb runs):

<!-- mojo-hidden from std.testing import assert_equal, assert_true -->
```mojo
from komira_gcp_core import StaticTokenSource
from komira_http_client.client import HttpClientConfig
from komira_retry import SystemClock
from komira_objectstore_gcs import GcsTlsConnector, StorageGrpcBackend
from komira_objectstore_gcs import build_gcs_tls_connector

var connector = build_gcs_tls_connector()
assert_true(connector.is_tls())
var backend = StorageGrpcBackend[GcsTlsConnector, StaticTokenSource, SystemClock](
    connector^,
    StaticTokenSource(String("a-token")),
    SystemClock(),
    HttpClientConfig.defaults(),
)
assert_equal(backend.request_timeout_us(), HttpClientConfig.defaults().request_timeout_us)
```

A connector over a caller's `TlsConfig`, here for an endpoint that presents
the name `localhost`. A trust root that is not a PEM certificate is refused
when the config is built, before anything is dialed:

<!-- mojo-hidden from std.testing import assert_true -->
```mojo
from komira_http_core.tls import TlsConfig
from komira_objectstore_gcs import build_gcs_tls_connector_with_config
from komira_objectstore_gcs import gcs_tls_config_trusting_only

var own = build_gcs_tls_connector_with_config(TlsConfig(), String("localhost"))
assert_true(own.is_tls())

var refused = False
try:
    _ = gcs_tls_config_trusting_only(String("not a certificate"))
except:
    refused = True
assert_true(refused)
```

With the emulator's CA certificate in hand (`root_pem`), a backend that
reaches it at `127.0.0.1:<port>`, verifying the name `localhost`:

```text
var config = gcs_tls_config_trusting_only(root_pem)
var connector = build_gcs_tls_connector_with_config(config^, String("localhost"))
var backend = StorageGrpcBackend[GcsTlsConnector, T, K](
    connector^, token_source^, clock^, HttpClientConfig.defaults(),
    host=String("127.0.0.1"), port=port,
)
```

`tests/test_gcs_grpc_trust.mojo` runs exactly that against an in-process TLS
gRPC server holding a certificate signed by a test CA, and checks that the
default connector refuses the same server.
