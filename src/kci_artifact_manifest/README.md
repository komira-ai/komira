# kci_artifact_manifest

The artifact manifest: one JSON object per package file, saying what the file
is (artifact type `CONDA`, `PYTHON` or `OCI`, name, version, platform, and for a
CONDA artifact its conda subdir), where it is (`file`, `metadata`) and its
sha256. An `OCI` artifact is an image: its `file` is an OCI image layout
directory, its `sha256` is the hex of the image manifest digest, and it has no
`metadata` and no `subdir`. `OCI` is the one word for an image; `OCI_IMAGE` and
`oci-image` are refused.
`parse_artifact_manifest` reads `format` and `schema_version` first and refuses
another format or a major this kci does not read; inside a known major an
unknown key is ignored and listed in `ignored_keys`. A missing required key, a
key given twice, a key that does not belong to the artifact type, a non-string
or empty value, a platform that is not released, a CONDA subdir that is not its
platform's conda subdir and a sha256 that is not 64 lowercase hex characters
are each refused with an error naming the manifest. Relative `file` and
`metadata` paths resolve against the manifest's directory.
`render_artifact_manifest` writes the same format back in a fixed key order and
checks its own output with the parser. `read_artifact_manifest` reads a file and
parses it. Everything else is pure computation on in-memory strings.

Every example below runs as a test when the package is built, so it cannot go
stale.

## Parsing a manifest

```mojo
from kci_artifact_manifest import parse_artifact_manifest
from std.testing import assert_equal

var hash = String("0123456789abcdef") * 4
var text = (
    String('{"format":"kci.artifact_manifest","schema_version":1,')
    + String('"artifact_type":"CONDA","name":"example-pkg","version":"1.2.3",')
    + String('"platform":"linux-x86_64","subdir":"linux-64",')
    + String('"file":"linux-64/example-pkg-1.2.3-h0_0.conda",')
    + String('"sha256":"') + hash + String('","metadata":"metadata.json"}')
)
var m = parse_artifact_manifest(text, String("out/m.json"))
assert_equal(m.artifact_type, String("CONDA"))
assert_equal(m.subdir, String("linux-64"))
# relative paths resolve against the manifest's directory
assert_equal(m.file_path, String("out/linux-64/example-pkg-1.2.3-h0_0.conda"))
assert_equal(m.metadata_path, String("out/metadata.json"))
assert_equal(m.file_name(), String("example-pkg-1.2.3-h0_0.conda"))
```

## Rendering round-trips

The renderer writes compact JSON with the keys in a fixed order, so what one
step writes is exactly what the next one reads.

```mojo
from kci_artifact_manifest import parse_artifact_manifest, render_artifact_manifest
from std.testing import assert_equal

var py_hash = String("fedcba9876543210") * 4
var py_text = (
    String('{"format":"kci.artifact_manifest","schema_version":1,')
    + String('"artifact_type":"PYTHON","name":"example_pkg","version":"1.2.3",')
    + String('"platform":"noarch","file":"example_pkg-1.2.3-py3-none-any.whl",')
    + String('"sha256":"') + py_hash + String('","metadata":"METADATA"}')
)
var py = parse_artifact_manifest(py_text, String("/abs/dir/m.json"))
assert_equal(py.file_path, String("/abs/dir/example_pkg-1.2.3-py3-none-any.whl"))
assert_equal(render_artifact_manifest(py), py_text + String("\n"))
```

## An image

```mojo
from kci_artifact_manifest import parse_artifact_manifest, render_artifact_manifest
from std.testing import assert_equal

var digest_hex = String("89abcdef01234567") * 4
var oci_text = (
    String('{"format":"kci.artifact_manifest","schema_version":1,')
    + String('"artifact_type":"OCI","name":"hello","version":"0.1.0",')
    + String('"platform":"linux-x86_64","file":"hello_image.oci",')
    + String('"sha256":"') + digest_hex + String('"}')
)
var image = parse_artifact_manifest(oci_text, String("out/m.json"))
assert_equal(image.artifact_type, String("OCI"))
# `file` is the layout directory, resolved like any other path
assert_equal(image.file_path, String("out/hello_image.oci"))
assert_equal(image.metadata, String(""))
# no `metadata` key is written back
assert_equal(render_artifact_manifest(image), oci_text + String("\n"))
```

## Refusals name the manifest

```mojo
from kci_artifact_manifest import is_sha256_hex, parse_artifact_manifest
from std.testing import assert_equal, assert_false, assert_true

var refusal = String("")
try:
    _ = parse_artifact_manifest(
        String('{"format":"kci.artifact_manifest","schema_version":1,"name":"x"}'),
        String("out/bad.json"),
    )
except e:
    refusal = String(e)
assert_equal(refusal, String("artifact manifest 'out/bad.json': missing 'artifact_type'"))

assert_true(is_sha256_hex(String("0123456789abcdef") * 4))
assert_false(is_sha256_hex(String("0123456789ABCDEF") * 4))  # uppercase is refused
```
