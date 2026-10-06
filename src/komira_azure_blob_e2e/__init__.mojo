"""`komira_azure_blob_e2e` -- test-only: komira_azure_blob's `AzureFs` and
`AzureClient` over a real `KernelTcpConnector`, against a fake Blob service
on 127.0.0.1:0 that checks every request's Shared Key signature with its own
canonicalizer.

  * `shared_key_oracle` -- the fake's string-to-sign and Authorization,
    written from the Shared Key document, independent of the signer.
  * `fake_blob_service` -- `FakeBlobService`, a `komira_http_server`
    `RequestDispatcher`: Get Blob (200 / 206 / 416), Get Blob Properties,
    List Blobs with prefix, delimiter and NextMarker pages, the documented
    error codes, and a request log.
  * `duet` -- `serve_while`: the server stepped on one thread while the
    client leg runs on another.
"""

from .shared_key_oracle import (
    AZURITE_ACCOUNT,
    AZURITE_KEY_B64,
    QueryParam,
    parse_query,
    percent_decode,
    query_value,
    shared_key_authorization,
    shared_key_string_to_sign,
)
from .fake_blob_service import FakeBlob, FakeBlobService, RequestRecord
from .duet import BlobServeLoop, ClientLeg, SERVE_POLL_TIMEOUT_US, serve_while
