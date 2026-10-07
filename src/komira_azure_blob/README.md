# komira_azure_blob

Azure Blob Storage, hand-written:

- **Shared Key signing**: `azure_shared_key_sign` builds the 13-field
  string-to-sign (canonicalized `x-ms-*` headers and resource, query
  parameters included) and signs it with the account key (HMAC-SHA256);
  `SharedKeySigningLayer` is an `HttpService` layer that stamps `x-ms-date`
  and adds `Authorization: SharedKey <account>:<signature>` to each request.
- **The store**: `AzureStore` does HEAD, range GET, List Blobs (one page
  per call; the caller passes the marker) and Put Blob (a block
  blob in one request) over any komira_http_client `HttpService`, addressing
  real Azure (virtual-hosted, `<account>.blob.core.windows.net`) or the
  Azurite emulator (path-style); `parse_azure_list_blobs_result` and
  `parse_azure_error` read the XML bodies.
- **The client**: `AzureClient` bundles an HTTP client, the signing layer,
  a `SasQueryLayer` (a SAS token appended to every request), the store, a
  connector and a reactor; `AzureClientSpec` holds the endpoint, the
  `AzureCredential` (a Shared Key, a SAS token, or anonymous; a key and a
  token together are refused) and the connector factory a client is built
  from.
- **`AzureFs`**: komira_fs's `FileSystem` over one container, read-only;
  its `list` follows `NextMarker` for at most `AZURE_LIST_MAX_PAGES` pages.
- **`AzureSasSigner`**: komira_objectstore's `ObjectUrlSigner`, minting
  blob service SAS URLs signed at the instant its `AzureSasClock` reports.

The account key comes from komira_azure_core's `AzureSharedKey`. Nothing here
reads the environment. It does not create or delete containers, and holds
no Entra token flow (komira_azure_core has those).

## Examples

None of these sends a request: they build URLs, sign, and read canned
response bodies.

Where a blob lives. Real Azure puts the account in the host; Azurite puts it
first in the path. A blob key keeps its `/` and has every other reserved
byte percent-encoded:

<!-- mojo-hidden from std.testing import assert_equal, assert_true -->
```mojo
from komira_azure_blob import AzureConfig, build_azure_blob_url

var real = build_azure_blob_url(
    AzureConfig.azure(String("mystoraccount")), String("my-container"), String("a b/c?d")
)
assert_equal(String(real.scheme), "https")
assert_equal(String(real.host), "mystoraccount.blob.core.windows.net")
assert_equal(String(real.path), "/my-container/a%20b/c%3Fd")

var emulator = build_azure_blob_url(
    AzureConfig.azurite(String("devstoreaccount1")), String("c"), String("k.bin")
)
assert_equal(String(emulator.scheme), "http")
assert_equal(emulator.port, UInt16(10000))
assert_equal(String(emulator.path), "/devstoreaccount1/c/k.bin")
```

A Shared Key signature for `GET /container/blob.txt`, with the string that
was signed (the empty fields are the Content-*, Date, If-* and Range slots
this request leaves unset):

```mojo
from komira_azure_core import AzureSharedKey
from komira_azure_blob import AzureSharedKeySigningContext, azure_shared_key_sign
from komira_azure_blob.azure_signing import Header

var x_ms = List[Header]()
x_ms.append(Header(String("x-ms-date"), String("Thu, 01 Oct 2026 12:00:00 GMT")))
x_ms.append(Header(String("x-ms-version"), String("2015-02-21")))
var signed = azure_shared_key_sign(
    AzureSharedKeySigningContext.for_get(
        AzureSharedKey(
            String("mystoraccount"),
            String("VGhpcyBpcyBhIGZha2Uga2V5IGZvciB0ZXN0aW5nIDEyMzQ1Njc4OTAxMjMK"),
        ),
        String("/container/blob.txt"),
        x_ms^,
    )
)
assert_equal(
    signed.string_to_sign,
    String("GET\n\n\n\n\n\n\n\n\n\n\n\n")
    + "x-ms-date:Thu, 01 Oct 2026 12:00:00 GMT\n"
    + "x-ms-version:2015-02-21\n"
    + "/mystoraccount/container/blob.txt",
)
assert_equal(
    signed.authorization,
    "SharedKey mystoraccount:qzu2SLO4TnzbYyPx9EJ4tE9ipoaAOZqKOq9WNrjdsdw=",
)
```

A List Blobs page and an error body, read:

```mojo
from komira_azure_blob import parse_azure_error, parse_azure_list_blobs_result

var page = parse_azure_list_blobs_result(
    String('<?xml version="1.0" encoding="utf-8"?>')
    + '<EnumerationResults ServiceEndpoint="https://x.blob.core.windows.net/"'
    + ' ContainerName="c"><Blobs><Blob><Name>logs/part-0001.parquet</Name>'
    + "<Properties><Content-Length>7</Content-Length><Etag>0x8D123</Etag>"
    + "<Last-Modified>Thu, 01 Oct 2026 12:00:00 GMT</Last-Modified>"
    + "<BlobType>BlockBlob</BlobType></Properties></Blob></Blobs>"
    + "<NextMarker>page-2</NextMarker></EnumerationResults>"
)
assert_equal(page.container, "c")
assert_equal(len(page.blobs), 1)
assert_equal(page.blobs[0].name, "logs/part-0001.parquet")
assert_equal(page.blobs[0].size, Int64(7))
assert_equal(page.blobs[0].blob_type, "BlockBlob")
assert_equal(page.next_marker, "page-2")

var error = parse_azure_error(
    String('<?xml version="1.0" encoding="utf-8"?>')
    + "<Error><Code>BlobNotFound</Code><Message>The specified blob does not exist.</Message></Error>"
)
assert_equal(error.code, "BlobNotFound")
```

A presigned download and upload, signed at a fixed instant
(2026-10-01T12:00:00Z) for five minutes. The upload URL comes with the one
header Put Blob requires of a block-blob write:

```mojo
from komira_azure_blob import AzureSasSigner, FixedAzureSasClock

var signer = AzureSasSigner[FixedAzureSasClock](
    String("myaccount"),
    String("repo-container"),
    String("YXp1cmUtc2FzLXRlc3Qta2V5LW5vdC1hLXJlYWwtYWNjb3VudC1rZXkh"),
    FixedAzureSasClock(1790856000),
)
var download = signer.presign_download(String("lake/events/part-0001.parquet"), 300)
assert_equal(download.method, "GET")
assert_equal(
    download.url,
    String("https://myaccount.blob.core.windows.net/repo-container/lake/events/part-0001.parquet")
    + "?sp=r&st=2026-10-01T12%3A00%3A00Z&se=2026-10-01T12%3A05%3A00Z&spr=https"
    + "&sv=2020-12-06&sr=b&sig=xvFLpnr8zb%2Bg9fCQsN0TM7jdDRj%2Bl4QJkkpR38L%2FLqo%3D",
)
assert_equal(download.expires_unix_seconds, Int64(1790856000 + 300))

var upload = signer.presign_upload(String("lake/events/part-0001.parquet"), 300)
assert_equal(upload.method, "PUT")
assert_true("?sp=cw&" in upload.url)
assert_equal(upload.required_headers[0].name, "x-ms-blob-type")
assert_equal(upload.required_headers[0].value, "BlockBlob")
```
