# komira_fs_registry

The live file systems a plan's file-system descriptors stand for, as one
closed type. A plan names a source's file system by descriptor
(`komira_plan_expr`'s `FsDescriptorPod`: a scheme code, a bucket and a node
id); `FsHandle` holds the concrete file system behind it, with exactly one arm
set:

| tag | scheme code | arm |
|---|---|---|
| `FsHandle.FS_LOCAL` (0) | `FS_SCHEME_FILE` | `LocalArm`, `komira_fs`'s `LocalFs` |
| `FsHandle.FS_S3` (1) | `FS_SCHEME_S3` | `S3Arm`, `komira_objectstore_s3`'s `S3Fs` |
| `FsHandle.FS_AZURE` (3) | `FS_SCHEME_AZURE` | `AzureArm`, `komira_azure_blob`'s `AzureFs` |

The GCS code (2) is reserved: this build has no arm for it, and
`fs_arm_tag_for_scheme` / `fs_arm_tag_for_descriptor` refuse it with an error
that names the missing arm. `fs_handle_from_typed_fs` moves a concrete file
system into a handle when its type is exactly an arm's, and returns `None`
otherwise.

The package also picks each cloud arm's connector from its endpoint
(`s3_endpoint_is_plaintext`, `azure_endpoint_is_plaintext`: plaintext only for
an `http://` endpoint, TLS for `https://` or the provider's own endpoint),
parses Azure URLs (`parse_azure_url`: `az://`, `abfs[s]://`, the Blob
service's `https://` URI and an emulator's path-style `http://` URL) and
merges a URL with the configured account and endpoint
(`azure_arm_config_for_url`, which refuses a URL naming a different account
or endpoint, so a URL cannot send the configured credential elsewhere).

It does not resolve a plan's descriptors or dispatch a plan over handles: the
engine's registry does that and imports this package. Nothing here reads the
environment.

## Examples

Resolve descriptors to arm tags, and see the reserved GCS code refused:

<!-- mojo-hidden from std.testing import assert_equal, assert_raises -->
```mojo
from komira_fs_registry import FsHandle, fs_arm_tag_for_descriptor
from komira_plan_expr.fs_descriptor_pod import FS_SCHEME_GCS, FS_SCHEME_S3, FsDescriptorPod

assert_equal(fs_arm_tag_for_descriptor(FsDescriptorPod.local()), FsHandle.FS_LOCAL)
assert_equal(
    fs_arm_tag_for_descriptor(FsDescriptorPod.cloud(FS_SCHEME_S3, "lake", 7)),
    FsHandle.FS_S3,
)
with assert_raises(contains="no GCS arm in this build"):
    _ = fs_arm_tag_for_descriptor(FsDescriptorPod.cloud(FS_SCHEME_GCS, "gbucket", 2))
```

Parse Azure URLs; a path in the Blob service's URI is percent-decoded once,
and a URL carrying a query (where a SAS token would sit) is refused:

<!-- mojo-hidden from std.testing import assert_equal, assert_false, assert_raises, assert_true -->
```mojo
from komira_fs_registry import AzureArmConfig, azure_arm_config_for_url, parse_azure_url

var u = parse_azure_url("abfss://lake@myacct.dfs.core.windows.net/x/y.parquet")
assert_equal(u.account, "myacct")
assert_equal(u.container, "lake")
assert_equal(u.path, "x/y.parquet")
assert_true(u.names_endpoint)

var h = parse_azure_url("https://myacct.blob.core.windows.net/lake/year%3D2026/a.parquet")
assert_equal(h.path, "year=2026/a.parquet")

var bare = parse_azure_url("az://lake/data/a.parquet")  # no account in the URL
assert_equal(bare.account, "")
var cfg = azure_arm_config_for_url(bare, AzureArmConfig.azure("myacct"))
assert_equal(cfg.account, "myacct")  # taken from the configuration
assert_false(cfg.path_style)

with assert_raises(contains="must not carry a query or fragment"):
    _ = parse_azure_url("az://lake/a.parquet?sig=x")
```

The endpoint's scheme picks plaintext or TLS:

<!-- mojo-hidden from std.testing import assert_false, assert_raises, assert_true -->
```mojo
from komira_fs_registry import azure_endpoint_is_plaintext, s3_endpoint_is_plaintext

assert_false(s3_endpoint_is_plaintext(""))  # the provider's own endpoint: TLS
assert_false(s3_endpoint_is_plaintext("https://objects.example.com"))
assert_true(s3_endpoint_is_plaintext("HTTP://objects.example.com:9000"))
assert_true(azure_endpoint_is_plaintext("http://emulator.example.com:10000"))
with assert_raises(contains="must start with http:// or https://"):
    _ = s3_endpoint_is_plaintext("ftp://objects.example.com")
```

The local arm reads a real file, here one the example writes into its own
temporary directory:

<!-- mojo-hidden from std.testing import assert_equal, assert_true -->
```mojo
from std.tempfile import TemporaryDirectory
from komira_async.ops.waker_sink import NoopSink
from komira_fs.local_fs import LocalFs
from komira_fs_registry import FsHandle, fs_handle_from_typed_fs

with TemporaryDirectory() as root:
    var path = root + "/data.bin"
    var payload = List[UInt8]()
    for i in range(64):
        payload.append(UInt8(i))
    with open(path, "w") as fh:
        fh.write_bytes(payload)

    var maybe = fs_handle_from_typed_fs(LocalFs[NoopSink].from_root(root))
    var handle = maybe.take()
    assert_true(handle.is_local())
    assert_equal(handle.tag(), FsHandle.FS_LOCAL)

    ref fs = handle.local_ref().value()
    assert_equal(fs.file_size(path), 64)
    var file = fs.open(path)
    var buf = fs.read_at(file, Int64(10), Int64(4))
    var got = buf.view_range_ro(0, 4).into_span()
    assert_equal(got[0], 10)
    assert_equal(got[3], 13)
```
