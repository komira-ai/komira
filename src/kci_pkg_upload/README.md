# kci_pkg_upload

Package-registry clients for two registries: PyPI (the legacy upload form,
byte for byte what `uv publish` sends) and a prefix.dev conda channel. For one
package file they upload it, ask whether it is there and whether it holds our
bytes (`presence`), read back what the registry lists (`read_back`), fetch
it, and list the package names a conda subdir holds.

`RegistrySet` is the one entry point: it picks the registry by the
coordinate's substrate and refuses, before any request, to upload a
distribution name the caller has not approved (`ApprovedNames`): an uploaded
name is claimed for good. Every answer is a kind (`UPLOAD_CREATED`,
`UPLOAD_DUPLICATE_REFUSED`, `UPLOAD_UNKNOWN` for a request whose bytes may or
may not have landed, `PRESENCE_PRESENT_IDENTICAL`, `PRESENCE_PRESENT_DIFFERENT`,
...), never a guess. An upload is never sent with `force` and never follows a
redirect. A 404 on a read is `ABSENT`, not an error.

Requests go through the `PkgTransport` seam (`HttpPkgTransport` over HTTPS;
`ScriptedPkgTransport` replays scripted answers and records every request)
and credentials through `RegistryCredential` (an anonymous one, a static
token by file or secret name, or GitHub OIDC trusted publishing). The package
names no channel, account or organisation: locations, approved names and
credentials all come from the caller.

## Examples

The examples answer from `ScriptedPkgTransport`, so no request leaves the
process. An upload to a conda channel is one multipart POST carrying the
credential for that registry:

<!-- mojo-hidden from std.testing import assert_equal, assert_true -->
```mojo
from kci_pkg_upload import ApprovedNames, PackageCoordinate, PackageFile, PkgResponse, RegistrySet
from kci_pkg_upload import ScriptedCredential, ScriptedPkgTransport, SURFACE_PREFIX_DEV
from kci_pkg_upload import SUBSTRATE_PREFIX_DEV_CONDA, UPLOAD_CREATED

def probe_file(content: String) -> PackageFile:
    var c = PackageCoordinate(
        SUBSTRATE_PREFIX_DEV_CONDA, "prefix.dev/example-channel", "komira-probe", "1.2.3", "linux-64",
        "komira-probe-1.2.3-h0123abc_0.conda",
    )
    var bytes = List[UInt8]()
    var src = content.as_bytes()
    for i in range(len(src)):
        bytes.append(src[i])
    return PackageFile(c^, bytes^, "")

def probe_registry(var t: ScriptedPkgTransport) -> RegistrySet[ScriptedPkgTransport, ScriptedCredential]:
    var cred = ScriptedCredential()
    cred.serve(SURFACE_PREFIX_DEV, "Bearer example-token")
    return RegistrySet[ScriptedPkgTransport, ScriptedCredential](t^, cred^)

var names = ApprovedNames()
names.approve("komira-probe")

var t = ScriptedPkgTransport()
t.queue(PkgResponse(201))
var reg = probe_registry(t^)
var outcome = reg.upload(probe_file("conda-bytes-v1"), names)
assert_equal(outcome.kind, UPLOAD_CREATED)

var req = reg.transport().call(0)
assert_equal(req.host, "prefix.dev")
assert_equal(req.path, "/api/v1/upload/example-channel")
assert_equal(req.header_value("Authorization"), "Bearer example-token")
assert_true(req.path.find("force") < 0)
```

A name nobody approved is refused before any request is made:

<!-- mojo-hidden
from std.testing import assert_equal, assert_true
from kci_pkg_upload import PackageCoordinate, PackageFile, RegistrySet, SUBSTRATE_PREFIX_DEV_CONDA, SURFACE_PREFIX_DEV, ScriptedCredential, ScriptedPkgTransport

def probe_file(content: String) -> PackageFile:
    var c = PackageCoordinate(
        SUBSTRATE_PREFIX_DEV_CONDA, "prefix.dev/example-channel", "komira-probe", "1.2.3", "linux-64",
        "komira-probe-1.2.3-h0123abc_0.conda",
    )
    var bytes = List[UInt8]()
    var src = content.as_bytes()
    for i in range(len(src)):
        bytes.append(src[i])
    return PackageFile(c^, bytes^, "")

def probe_registry(var t: ScriptedPkgTransport) -> RegistrySet[ScriptedPkgTransport, ScriptedCredential]:
    var cred = ScriptedCredential()
    cred.serve(SURFACE_PREFIX_DEV, "Bearer example-token")
    return RegistrySet[ScriptedPkgTransport, ScriptedCredential](t^, cred^)
-->
```mojo
from kci_pkg_upload import ApprovedNames, PkgResponse, ScriptedPkgTransport

var t = ScriptedPkgTransport()
t.queue(PkgResponse(201))
var reg = probe_registry(t^)
var message = String()
try:
    _ = reg.upload(probe_file("conda-bytes-v1"), ApprovedNames())
except e:
    message = String(e)
assert_true("published name 'komira-probe' is not in the approved-names list" in message)
assert_equal(reg.transport().call_count(), 0)
```

A 409 says the file name is taken; reading the channel's listing back
settles whether it holds our bytes or someone else's:

<!-- mojo-hidden
from std.testing import assert_equal
from kci_pkg_upload import PackageCoordinate, PackageFile, RegistrySet, SUBSTRATE_PREFIX_DEV_CONDA, SURFACE_PREFIX_DEV, ScriptedCredential, ScriptedPkgTransport

def probe_file(content: String) -> PackageFile:
    var c = PackageCoordinate(
        SUBSTRATE_PREFIX_DEV_CONDA, "prefix.dev/example-channel", "komira-probe", "1.2.3", "linux-64",
        "komira-probe-1.2.3-h0123abc_0.conda",
    )
    var bytes = List[UInt8]()
    var src = content.as_bytes()
    for i in range(len(src)):
        bytes.append(src[i])
    return PackageFile(c^, bytes^, "")

def probe_registry(var t: ScriptedPkgTransport) -> RegistrySet[ScriptedPkgTransport, ScriptedCredential]:
    var cred = ScriptedCredential()
    cred.serve(SURFACE_PREFIX_DEV, "Bearer example-token")
    return RegistrySet[ScriptedPkgTransport, ScriptedCredential](t^, cred^)
-->
```mojo
from kci_pkg_upload import ApprovedNames, PkgResponse, ScriptedPkgTransport, PRESENCE_PRESENT_DIFFERENT
from kci_pkg_upload import PRESENCE_PRESENT_IDENTICAL, UPLOAD_DUPLICATE_REFUSED

def listing(sha256_hex: String) -> PkgResponse:
    var text = (
        '{"info": {"subdir": "linux-64"}, "packages": {}, "packages.conda": '
        + '{"komira-probe-1.2.3-h0123abc_0.conda": {"sha256": "' + sha256_hex + '", "size": 14}}}'
    )
    var body = List[UInt8]()
    var src = text.as_bytes()
    for i in range(len(src)):
        body.append(src[i])
    var r = PkgResponse(200)
    r.with_header("content-type", "application/json")
    r.with_body(body^)
    return r^

var ours = probe_file("conda-bytes-v1")
var theirs = probe_file("someone else's bytes")
var names = ApprovedNames()
names.approve("komira-probe")

var t = ScriptedPkgTransport()
t.queue(PkgResponse(409))
t.queue(listing(ours.identity.sha256_hex))
t.queue(listing(theirs.identity.sha256_hex))
var reg = probe_registry(t^)
assert_equal(reg.upload(ours, names).kind, UPLOAD_DUPLICATE_REFUSED)
assert_equal(reg.presence(ours.coordinate, ours.identity).kind, PRESENCE_PRESENT_IDENTICAL)
assert_equal(reg.presence(ours.coordinate, ours.identity).kind, PRESENCE_PRESENT_DIFFERENT)
```

Names are compared the way each index does:

<!-- mojo-hidden from std.testing import assert_equal -->
```mojo
from kci_pkg_upload import conda_package_name_of_file, normalize_distribution_name

assert_equal(normalize_distribution_name("Kci.Pkg__Upload"), "kci-pkg-upload")
assert_equal(conda_package_name_of_file("komira-probe-1.2.3-h0123abc_0.conda"), "komira-probe")
assert_equal(conda_package_name_of_file("README.md"), "")
```
