# kci_publish_oci

The OCI image arm of a kci PUBLISH step. `publish_layout` pushes one built
OCI image layout to `registry/repository`, tagged with the full revision id,
through a `komira_oci` `LayoutPusher` over any `OciTransport`. Before any
registry request it checks that the revision is a full commit id, that the
platform is one kci releases, that the layout on disk reads and verifies, and
that the layout's own `os/arch` is the step's platform in OCI spelling; any
failure is `REFUSED` with nothing sent. With `plan` set it stops after these
checks and sends nothing.

The push's end state maps onto `kci_api`'s outcome words, error ids and exit
numbers: uploaded or tag added is `SUCCEEDED`; a tag that already names the
same bytes is `NOOP` (exit 0); refused, failed, indeterminate and partial
are exits 3, 4, 5 and 6 with error `KCI-E-IMAGE-PUSH`. `record_image_publish`
adds the step row, the image's artifact row and the first error to a run's
result document. The arm never raises, and an error message carries the
pusher's detail, which holds no credential.

The push protocol itself (blobs, manifest by digest, tag, read back,
retries) is `komira_oci`'s. This package is not wired into `kci run`.

## Examples

The examples push to `komira_oci`'s in-process fake registry, so nothing
leaves the process. A layout is written into a temporary directory; a second
push of the same bytes is a no-op:

<!-- mojo-hidden from std.testing import assert_equal, assert_true -->
```mojo
from std.tempfile import mkdtemp
from komira_oci.oci_auth import OciAuth
from komira_oci.oci_fake_registry import FakeOciRegistry
from komira_oci.oci_layout_fixture import write_test_layout
from komira_oci.oci_push import LayoutPusher
from kci_publish_oci import ARTIFACT_TYPE_OCI_IMAGE, publish_layout

def bytes_of(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    var src = s.as_bytes()
    for i in range(len(src)):
        out.append(src[i])
    return out^

var dir = mkdtemp() + "/image"
var layers = List[List[UInt8]]()
layers.append(bytes_of("layer one"))
var digest = write_test_layout(dir, layers, "linux", "amd64")

var rev = "3f2a9c1d8b7e6f5a4c3b2a1908f7e6d5c4b3a291"
var pusher = LayoutPusher[FakeOciRegistry](
    FakeOciRegistry("registry.example.test"), OciAuth.basic("publisher", "not-a-real-secret"), False, 0
)
var first = publish_layout(pusher, dir, "registry.example.test", "team/app", rev, "linux-x86_64", False)
assert_equal(first.outcome, "SUCCEEDED")
assert_equal(first.exit_code(), 0)
assert_equal(first.artifact.artifact_type, ARTIFACT_TYPE_OCI_IMAGE)
assert_equal(first.artifact.file, "registry.example.test/team/app@" + digest)
assert_equal(pusher.transport().tag_digest("team/app", rev), digest)

var again = publish_layout(pusher, dir, "registry.example.test", "team/app", rev, "linux-x86_64", False)
assert_equal(again.outcome, "NOOP")
assert_equal(again.exit_code(), 0)
assert_true(again.ok())
```

An abbreviated revision, a platform kci does not release, or a layout built
for another CPU is refused before any request; `plan` checks the layout and
sends nothing:

<!-- mojo-hidden
from std.testing import assert_equal, assert_true

def bytes_of(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    var src = s.as_bytes()
    for i in range(len(src)):
        out.append(src[i])
    return out^
-->
```mojo
from std.tempfile import mkdtemp
from komira_oci.oci_auth import OciAuth
from komira_oci.oci_fake_registry import FakeOciRegistry
from komira_oci.oci_layout_fixture import write_test_layout
from komira_oci.oci_push import LayoutPusher
from kci_publish_oci import publish_layout

var root = mkdtemp()
var layers = List[List[UInt8]]()
layers.append(bytes_of("one layer"))
_ = write_test_layout(root + "/amd64", layers, "linux", "amd64")
_ = write_test_layout(root + "/arm64", layers, "linux", "arm64")

var rev = "3f2a9c1d8b7e6f5a4c3b2a1908f7e6d5c4b3a291"
var pusher = LayoutPusher[FakeOciRegistry](FakeOciRegistry("registry.example.test"), OciAuth.none(), False, 0)

var short = publish_layout(pusher, root + "/amd64", "registry.example.test", "team/app", "3f2a9c1", "linux-x86_64", False)
assert_equal(short.outcome, "REFUSED")
assert_equal(short.exit_code(), 3)
assert_equal(short.error_id, "KCI-E-REVISION")

var reserved = publish_layout(pusher, root + "/amd64", "registry.example.test", "team/app", rev, "darwin-arm64", False)
assert_equal(reserved.error_id, "KCI-E-PLATFORM")

var wrong_cpu = publish_layout(pusher, root + "/arm64", "registry.example.test", "team/app", rev, "linux-x86_64", False)
assert_equal(wrong_cpu.error_id, "KCI-E-IMAGE-PLATFORM")
assert_true("is for linux/arm64; this step publishes linux-x86_64 (linux/amd64)" in wrong_cpu.message)

var plan = publish_layout(pusher, root + "/amd64", "registry.example.test", "team/app", rev, "linux-x86_64", True)
assert_equal(plan.outcome, "SUCCEEDED")
assert_equal(plan.artifact.effect, "WOULD_UPLOAD")
assert_equal(pusher.transport().call_count(), 0)  # nothing was sent
```
