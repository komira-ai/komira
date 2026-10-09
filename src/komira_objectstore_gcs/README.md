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
* `build_gcs_tls_connector_trusting(root_pem, server_name)` is for a peer
  signed by a private CA (a storage emulator behind TLS, an in-process fake):
  the public roots are wiped, `root_pem` is the only trust anchor, SNI is
  pinned to `server_name`, and verification stays on, so the handshake still
  checks the chain against `root_pem` and the certificate's name against
  `server_name`. It takes the root rather than a `TlsConfig`, so verification
  cannot be turned off through it.

There is no plaintext (h2c) route: komira_grpc carries only unary calls over
h2c, so WriteObject and ReadObject could not use one.

Nothing in this package reads the environment. The trusting connector trusts
only the root its caller passes. The default connector keeps libcrypto's
default CA paths, which the `SSL_CERT_FILE` and `SSL_CERT_DIR` environment
variables can redirect, so the process environment decides what the default
connector trusts.

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

A connector trusting one private root, here for an endpoint that presents
the name `localhost`. A trust root that is not a PEM certificate, and an empty
server name, are refused when the connector is built, before anything is
dialed:

```mojo
from komira_objectstore_gcs import build_gcs_tls_connector_trusting

var refused = String("")
try:
    _ = build_gcs_tls_connector_trusting(String("not a certificate"), String("localhost"))
except e:
    refused = String(e)
assert_equal(refused.startswith(String("TlsConfig.add_trust_pem: ")), True)
```

With the emulator's CA certificate in hand (`root_pem`), a backend that
reaches it at `127.0.0.1:<port>`, verifying the name `localhost`:

```text
var connector = build_gcs_tls_connector_trusting(root_pem, String("localhost"))
var backend = StorageGrpcBackend[GcsTlsConnector, T, K](
    connector^, token_source^, clock^, HttpClientConfig.defaults(),
    host=String("127.0.0.1"), port=port,
)
```

`tests/test_gcs_grpc_trust.mojo` runs exactly that against an in-process TLS
gRPC server holding a certificate signed by a test CA, and checks that the
default connector refuses the same server and that the trusting connector
refuses it under a name its certificate does not carry.
