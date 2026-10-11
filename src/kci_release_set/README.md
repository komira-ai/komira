# kci_release_set

What the kci BUILD step and PUBLISH step both know about a release set, kept
in one package so the two steps cannot disagree:

- the **set hash**: the sha256 of a header line (format major, full revision,
  platform) and one tab-separated line per artifact, sorted bytewise. The
  order the artifacts arrive in does not change it; any field of any line,
  the revision or the platform does. Who built the set is not part of it.
- **`release.json`** (format `kci.release_set`, major 2): `render_release_manifest`
  writes sorted compact JSON, and `parse_release_manifest` reads it and
  refuses anything malformed, including a `set_hash` that is not the hash of
  its own revision, platform and members.
- the conda **`metadata.json`** reader (`parse_conda_metadata`,
  `read_conda_metadata`) for the file `komira_pack` writes next to a package.
- `verify_member`, the checks over one artifact's directory (one manifest,
  bare file names, nothing else in the directory, the sha256, the conda
  metadata agreeing), and `undeclared_requirements`, which lists library
  requirements that name no other library of the set, except one byte-equal
  to a conda-forge requirement of `system_libs()` (the system libraries a
  library may open, a compiled copy of
  [`system_libs.bzl`](../../tools/build/package/system_libs.bzl) that a welded
  test holds equal to it).

It runs no process and opens no socket; only `verify_member` and the
`read_*` functions read files.

## Examples

The set hash does not depend on the order of the artifacts:

<!-- mojo-hidden from std.testing import assert_equal -->
```mojo
from kci_release_set import SetHashLine, set_hash_of_lines

def line(name: String, sha: String) -> SetHashLine:
    return SetHashLine(name.copy(), "linux-x86_64", "1.0.0", "h01234567_7", "linux-64", "CONDA", sha.copy())

var rev = "0123456789abcdef0123456789abcdef01234567"
var a = line("komira_hash", "a" * 64)
var b = line("komira_name_registry", "b" * 64)
var c = line("komira", "c" * 64)
var one: List[SetHashLine] = [a.copy(), b.copy(), c.copy()]
var other: List[SetHashLine] = [c.copy(), a.copy(), b.copy()]
var golden = "7a85e80aabbb553803809d3c2b516b8eaaeae467668051498fbeb82790682efe"
assert_equal(set_hash_of_lines(rev, "linux-x86_64", one), golden)
assert_equal(set_hash_of_lines(rev, "linux-x86_64", other), golden)
```

`release.json` renders sorted and parses back to the same value; a set hash
that does not match the members is refused:

<!-- mojo-hidden from std.testing import assert_equal, assert_true -->
```mojo
from kci_release_set import ReleaseEntry, ReleaseIdentity, ReleaseManifest, entries_set_hash, parse_release_manifest
from kci_release_set import render_release_manifest

def entry(name: String, kind: String, sha: String) -> ReleaseEntry:
    var e = ReleaseEntry()
    e.artifact_type = "CONDA"
    e.build = "0"
    e.dir = name.copy()
    e.kind = kind.copy()
    e.name = name.copy()
    e.platform = "linux-x86_64"
    e.sha256_hex = sha.copy()
    e.subdir = "linux-64"
    e.version = "0.1.7"
    return e^

var r = ReleaseManifest()
r.set_identity(ReleaseIdentity("0123456789abcdef0123456789abcdef01234567", "linux-x86_64", "gh-1", 1))
r.entries.append(entry("komira_hash", "library", "a" * 64))
r.entries.append(entry("komira", "metapackage", "c" * 64))
r.set_hash = entries_set_hash(r.revision, r.platform, r.entries)
assert_equal(r.set_hash, "c5e97905a05bcab80064d0b583b4f963ea55cdc03ebc73959a623dc0dfbf941c")

var text = render_release_manifest(r)
var back = parse_release_manifest(text, "release.json")
assert_equal(back.entries[0].name, "komira")  # members sorted by name
assert_equal(back.set_hash, r.set_hash)
assert_equal(back.produced_by_attempt, 1)

var tampered = text.replace("0.1.7", "0.1.8")
var message = String()
try:
    _ = parse_release_manifest(tampered, "release.json")
except e:
    message = String(e)
assert_true(message.startswith(
    "release manifest 'release.json': 'set_hash' " + r.set_hash
    + " is not the hash of its revision, platform and members ("
), message)
```

A package's `metadata.json` is read and checked, and its requirements name
other packages:

<!-- mojo-hidden from std.testing import assert_equal, assert_false, assert_true -->
```mojo
from kci_release_set import KIND_LIBRARY, parse_conda_metadata, requirement_name

var text = (
    '{"build":"0","build_number":0,"depends":["__linux","mojo-compiler ==1.0.0","komira_hash ==0.1.7"],'
    + '"file_name":"komira_name_registry-0.1.7-0.conda","format":"kci.conda_metadata",'
    + '"import_name":"komira_name_registry","kind":"library",'
    + '"label":"komira//src/komira_name_registry:komira_name_registry_conda","mojo_pin":"1.0.0",'
    + '"name":"komira_name_registry","payload_path":"lib/mojo/komira_name_registry.mojoc",'
    + '"payload_sha256":"' + "a" * 64 + '","schema_version":1,"size":62966,'
    + '"source_commit":"0123456789abcdef0123456789abcdef01234567","stamped":true,'
    + '"subdir":"linux-64","timestamp_ms":86400000,"version":"0.1.7"}'
)
var md = parse_conda_metadata(text, "metadata.json")
assert_equal(md.kind, KIND_LIBRARY)
assert_equal(md.name, "komira_name_registry")
assert_equal(md.payload_path, "lib/mojo/komira_name_registry.mojoc")
assert_false(md.has_doc_files)
assert_true(md.stamped)
assert_equal(requirement_name(md.depends[2]), "komira_hash")

var message = String()
try:
    _ = parse_conda_metadata(text.replace('"kind":"library"', '"kind":"binary"'), "metadata.json")
except e:
    message = String(e)
assert_equal(message, "conda metadata 'metadata.json': kind 'binary' is neither 'library' nor 'metapackage'")
```
