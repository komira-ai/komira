# komira_oci

A native OCI distribution client over the shipped HTTP client, for release
tooling that must move images without an external binary:

- `OciCopier[T]` copies an image from one registry to another by digest:
  it walks the manifest tree (an image index included), mounts or uploads
  every blob, then puts the manifests leaves first. Every manifest and blob it
  moves is checked against the digest that named it; the copy either
  reproduces the source digest at the destination or raises.
- `read_oci_layout` reads and verifies a local OCI layout directory
  (`oci-layout`, `index.json`, `blobs/sha256/*`): exactly one image
  manifest, every blob's size and sha256, the platform from the config.
- `LayoutPusher[T]` pushes a verified layout and tags it: blobs the
  registry already has are skipped, missing ones are uploaded in one PUT each,
  then the manifest by digest, then the tag, and both are read back. The
  outcome is a `PushResult` (`PUSH_UPLOADED`, `PUSH_NOOP` for a re-run,
  `PUSH_TAG_ADDED`, `PUSH_REFUSED` when the tag already names another
  digest, `PUSH_INDETERMINATE`, `PUSH_PARTIAL`, `PUSH_FAILED`).
- Helpers: `parse_oci_ref` (`<registry>/<repository>@sha256:...` or
  `:<tag>`), `digest_of_bytes` / `verify_digest` / `validate_digest_format`,
  `validate_oci_tag`, `resolve_upload_location` (refuses an upload session
  on another host or over plain HTTP), `OciAuth` (none, bearer or basic),
  `layout_image_digest`.
- `OciTransport` is the one-method seam the client speaks through;
  `HttpOciTransport` is the real one, `ScriptedOciTransport` and
  `FakeOciRegistry` (an in-process registry) are test doubles, and
  `write_test_layout` writes a real layout directory for tests.

It does not do the `WWW-Authenticate` token exchange (the caller passes a
bearer or basic credential), chunked uploads (a blob above
`MAX_MONOLITHIC_BLOB_BYTES` is refused), multi-architecture layout pushes,
or tag deletion. `parse_oci_ref` never defaults the registry host or the
`latest` tag.

## Examples

References, digests and tags, all checked locally:

<!-- mojo-hidden from std.testing import assert_equal, assert_false, assert_raises, assert_true -->
```mojo
from komira_oci import digest_of_bytes, parse_oci_ref, validate_oci_tag, verify_digest

var by_tag = parse_oci_ref("registry.example.com/team/app:v1.2.0")
assert_equal(by_tag.registry, "registry.example.com")
assert_equal(by_tag.repository, "team/app")
assert_equal(by_tag.reference, "v1.2.0")
assert_false(by_tag.is_digest)

var nothing = List[UInt8]()
var empty_digest = digest_of_bytes(Span(nothing))
assert_equal(
    empty_digest,
    "sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
)
var by_digest = parse_oci_ref("registry.example.com:5000/team/app@" + empty_digest)
assert_equal(by_digest.registry, "registry.example.com:5000")
assert_true(by_digest.is_digest)
assert_equal(by_digest.render(), "registry.example.com:5000/team/app@" + empty_digest)

with assert_raises():
    _ = parse_oci_ref("team/app")  # no registry host
with assert_raises():
    _ = parse_oci_ref("registry.example.com/team/app")  # no tag or digest

verify_digest(Span(nothing), empty_digest, "empty blob")
with assert_raises():
    verify_digest("x".as_bytes(), empty_digest, "a changed blob")

validate_oci_tag("release-42")
with assert_raises():
    validate_oci_tag(".hidden")  # a tag cannot start with a dot
```

Write a two-layer layout into a temporary directory, verify it, and push it
to the in-process `FakeOciRegistry`; a second push of the same digest is a
no-op:

<!-- mojo-hidden from std.testing import assert_equal, assert_true -->
```mojo
from std.tempfile import TemporaryDirectory
from komira_oci import PUSH_NOOP, PUSH_UPLOADED, FakeOciRegistry, LayoutPusher, OciAuth
from komira_oci import push_outcome_name, read_oci_layout, write_test_layout

# TemporaryDirectory.__exit__ swallows an error raised in its block, so the
# checks run inside a try and any failure is re-asserted after the block.
var failure = String()
with TemporaryDirectory() as dir:
    try:
        var layers = List[List[UInt8]]()
        var layer_one: List[UInt8] = [1, 2, 3, 4]
        var layer_two: List[UInt8] = [5, 6, 7]
        layers.append(layer_one^)
        layers.append(layer_two^)
        var written = write_test_layout(dir, layers)
        var layout = read_oci_layout(dir)
        assert_equal(layout.manifest_digest, written)

        var host = String("registry.example.com")
        var pusher = LayoutPusher[FakeOciRegistry](
            FakeOciRegistry(host), OciAuth.basic("user", "token"), False, 0
        )
        var first = pusher.push(layout, host, "team/app", "build-1")
        assert_equal(push_outcome_name(first.outcome), push_outcome_name(PUSH_UPLOADED))
        assert_equal(first.blobs_uploaded, 3)  # two layers and the config
        assert_equal(first.platform, "linux/amd64")
        assert_equal(first.reference(), "registry.example.com/team/app@" + written)
        assert_equal(pusher.transport().tag_digest("team/app", "build-1"), written)

        var again = pusher.push(layout, host, "team/app", "build-1")
        assert_equal(push_outcome_name(again.outcome), push_outcome_name(PUSH_NOOP))
        assert_true(pusher.transport().has_manifest("team/app", written))
    except e:
        failure = String(e)
assert_equal(failure, "")
```
