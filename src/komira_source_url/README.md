# komira_source_url

A logical plan names the exact source each scan reads: its scan node carries
`komira_plan_expr`'s `FsDescriptorPod`, whose scheme code says which file
system serves it. A surface (SQL, a DataFrame API) takes a URL from its user
and has to pick that code before it builds the plan. This package is the one
mapping every surface calls for it, so two surfaces never disagree about what
a prefix means, and a compiled physical plan is built over exactly the one
file system its plan names.

| prefix | source | scheme code |
|---|---|---|
| a bare path, `file://` | `komira_fs`'s `LocalFs` | `FS_SCHEME_FILE` (0) |
| `s3://`, `s3a://` | `komira_objectstore_s3`'s `S3Fs` | `FS_SCHEME_S3` (1) |
| `gs://`, `gcs://` | `komira_objectstore_gcs`'s `GcsFs` | `FS_SCHEME_GCS` (2) |
| `az://`, `abfs://`, `abfss://`, `https://<account>.blob.core.windows.net` | `komira_azure_blob`'s `AzureFs` | `FS_SCHEME_AZURE` (3) |

The scheme is compared without regard to letter case. The text before the
first `://` is a scheme only when it is scheme-shaped (a letter, then
letters, digits, `+`, `-` or `.`); otherwise the whole string is a bare
path, so `/data/x://y` is a local file. The `https://` row is the Blob
service's URL as `komira_azure_blob`'s `parse_azure_url` reads it: the host
alone, with no user information or port. A `.dfs.` host is named through
`abfs://` or `abfss://`, which `parse_azure_url` reads on either host.

Every other prefix is refused, as is an `https://` URL on any other host
(a `.dfs.` one included) and every `http://` URL: a
plaintext endpoint (an S3 or Azure emulator) is not something a prefix can
name, so the surface that holds that endpoint in its configuration picks the
source for it. Only the prefix is read here; what follows it is parsed by the
package that owns the source (`komira_azure_blob`'s `parse_azure_url` for the
Azure forms).

A physical-plan package does not depend on this package: by the time a plan
is compiled, its source is named. Nothing here reads the environment.

Every example below runs as a test when the package is built.

## Mapping a URL

```mojo
from komira_plan_expr.fs_descriptor_pod import FS_SCHEME_AZURE, FS_SCHEME_FILE, FS_SCHEME_S3
from komira_source_url import source_scheme_for_url
from std.testing import assert_equal, assert_raises

assert_equal(source_scheme_for_url("data/trips.parquet"), FS_SCHEME_FILE)
assert_equal(source_scheme_for_url("S3://lake/trips.parquet"), FS_SCHEME_S3)
assert_equal(
    source_scheme_for_url("abfss://lake@myacct.dfs.core.windows.net/trips.parquet"),
    FS_SCHEME_AZURE,
)
with assert_raises(contains="no source serves 'ftp://' URLs"):
    _ = source_scheme_for_url("ftp://files.example/trips.parquet")
```

A refusal names the scheme, or for `https://` the host, and never the rest of
the URL, so a token pasted into a query string is not repeated in an error.

## Checking a code a plan carries

A scheme code that arrives in a plan (from a descriptor, or off the wire) is
held to the same four codes.

```mojo
from komira_plan_expr.fs_descriptor_pod import FS_SCHEME_GCS, FsDescriptorPod
from komira_source_url import check_source_descriptor, check_source_scheme
from std.testing import assert_equal, assert_raises

var desc = FsDescriptorPod.cloud(FS_SCHEME_GCS, "lake", 7)
assert_equal(check_source_descriptor(desc), FS_SCHEME_GCS)
with assert_raises(contains="unknown file system scheme 9 (bucket 'lake', node 7)"):
    _ = check_source_scheme(UInt8(9), "lake", 7)
```
