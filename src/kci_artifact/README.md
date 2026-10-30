# kci_artifact

Reads, validates and renders kci's artifacts file: the one reviewed list of
what kci builds and publishes, written as textproto in the
`kci.release.v1.Artifacts` schema (generated into `kci_artifact_proto`).

A file declares build systems (a name, a program and the args it always
gets; kci names no build tool) and artifacts (a name, the build system that
builds it and the args appended for it), plus optional checks.
`parse_artifacts` and `read_artifacts` parse a file and validate it before
returning, raising on the first refusal with the file name and the rule
broken. `render_build_argv` turns one artifact into the argv that builds it
into `<release_dir>/<artifact>`, substituting the seven placeholders
(`{out_dir}`, `{release_dir}`, `{platform}` and the stamp `{revision_id}`,
`{source_commit}`, `{build_number}`, `{timestamp_ms}`) in one pass.
`require_one_manifest` and `require_manifest_name` are the two refusals over
what a build left: exactly one `manifest.json` at the top of the output
directory, whose `name` is the artifact's, byte for byte. The package also
renders the argvs of a per-change check (`render_affected_argv`,
`render_targets_argv`, `render_derive_argv`) and parses their answers.

It is pure: it runs no process and lists no directory (the BUILD step of
`kci` does both); `read_artifacts` is the one function that reads a file.

## Examples

Parse an artifacts file and render the argv that builds one artifact. The
stamp is the git-derived identity of the release; every placeholder is
substituted once:

<!-- mojo-hidden from std.testing import assert_equal -->
```mojo
from kci_artifact import ReleaseStamp, parse_artifacts, render_build_argv

var text = String(
    "schema_version: 1\n"
    "build_systems {\n"
    "  name: \"buck2\"\n"
    "  executable: \"buck2\"\n"
    "  args: \"build\"\n"
    "  args: \"-c\"\n"
    "  args: \"komira.package_stamp={build_number}\"\n"
    "}\n"
    "artifacts {\n"
    "  name: \"komira_hash\"\n"
    "  build_system: \"buck2\"\n"
    "  args: \"//src/komira_hash:komira_hash_conda[release]\"\n"
    "  args: \"--out\"\n"
    "  args: \"{out_dir}\"\n"
    "}\n"
)
var arts = parse_artifacts(text, "artifacts.textproto")
assert_equal(len(arts.artifacts), 1)
assert_equal(arts.artifacts[0].build_system, "buck2")

var stamp = ReleaseStamp(
    "a1b2c3d4e5f60718293a4b5c6d7e8f9012345678",  # revision id: a full commit id
    "f0e1d2c3b4a5968778695a4b3c2d1e0f12345678",  # source commit
    154,  # build number
    1790994309000,  # timestamp, ms
)
var argv = render_build_argv(arts, "komira_hash", "/work/rel", "linux-x86_64", stamp)
assert_equal(len(argv), 7)
assert_equal(argv[0], "buck2")
assert_equal(argv[3], "komira.package_stamp=154")
assert_equal(argv[4], "//src/komira_hash:komira_hash_conda[release]")
assert_equal(argv[6], "/work/rel/komira_hash")
```

A file that breaks a rule is refused on the first problem, naming the file,
the entry and the rule. Here the artifact's args never say where the build
puts its output:

<!-- mojo-hidden from std.testing import assert_equal -->
```mojo
from kci_artifact import is_valid_artifact_name, parse_artifacts

var bad = String(
    "schema_version: 1\n"
    "build_systems { name: \"tool\" executable: \"tool\" args: \"build\" }\n"
    "artifacts { name: \"a\" build_system: \"tool\" args: \"//pkg:a\" }\n"
)
var message = String()
try:
    _ = parse_artifacts(bad, "artifacts.textproto")
except e:
    message = String(e)
assert_equal(
    message,
    "artifacts.textproto: artifact 'a' has no '{out_dir}' in its args or in"
    " the args of build system 'tool': kci could not find what the build made",
)
assert_equal(is_valid_artifact_name("komira_json"), True)
assert_equal(is_valid_artifact_name("komira-json"), False)
```

After a build, its output directory must hold exactly one `manifest.json`,
and that manifest must name the artifact exactly:

<!-- mojo-hidden from std.testing import assert_equal -->
```mojo
from kci_artifact import require_manifest_name, require_one_manifest

var top: List[String] = ["manifest.json", "komira_hash-1.0.0-h0_154.conda"]
require_one_manifest("komira_hash", top)  # accepted: returns
require_manifest_name("komira_hash", "komira_hash")

var empty = List[String]()
var refused = String()
try:
    require_one_manifest("komira_hash", empty)
except e:
    refused = String(e)
assert_equal(
    refused,
    "artifact 'komira_hash': the build left no manifest.json at the top of its output directory",
)
try:
    require_manifest_name("komira_hash", "Komira_hash")
except e:
    refused = String(e)
assert_equal(
    refused,
    "artifact 'komira_hash': the built manifest's name 'Komira_hash' is not"
    " the artifact's name (compared exactly)",
)
```

## Build files

This package is built with buildrules' `mojo_package` and packaged for mopm as `kci_artifact`, version 0.1.0 (`mopm.toml`). The library is `src/kci_artifact/`, its tests are `tests/`. It depends on kci_api, kci_artifact_proto and komira_textproto, sibling directories (`[dependencies]` of `mopm.toml`), so the `.conda` of this package records `mojo-kci_api >=0.1,<0.2`, `mojo-kci_artifact_proto >=0.1,<0.2` and `mojo-komira_textproto >=0.1,<0.2` as dependencies and holds none of those packages' files: installing `kci_artifact` installs them with it. The files that are not sources:

| file | what |
|---|---|
| `mopm.toml` | the mopm manifest: name, version, the Mojo version, the dependencies and where the library and its tests are |
| `mopm.lock` | the toolchain pins and the path dependencies (no registry is reached: every dependency is a sibling) |
| `mopm-toolchain.toml` | the exact mopm and Mojo versions the build uses |
| `coverage_floor.txt` | `lines NN.NN` and `branches NN.NN`: the least line and branch coverage `:coverage` may measure; `:coverage_floor` fails when either falls below, and above it passes and prints a hint to raise the figure |
| `buildrules.mojo.lock.bzl`, `buildrules.mojo.bzl` | written by `buildrules mojo sync` from the files above and from the manifests of the dependencies; `buildrules mojo check` fails when they are stale |

`:lib` is the library file and exists only once every test of `tests/` has passed. After any change to a source, a test, or a manifest of this package or of a dependency, run `buildrules mojo sync`, commit what it writes, and build `komira//src/kci_artifact:lib` on the farm. A test file that the sync has not listed is not run: run the sync after adding one.

`:conda` is buildrules' `mojo_conda` over `:lib`: the `.conda` of the mopm package (`mojo-kci_artifact-0.1.0-mojo1.0.0_0.conda`), which therefore exists only once the tests have passed. Publishing it (`mopm publish`) uploads, so it is a step of a CI job that takes that file, not a build action.

`:kci_artifact` is `:lib` as komira's Mojo rules take it (`mojo_adopted_library`). Its `deps` are the adopted target of each package in `[dependencies]`, and the rule refuses a list that is not the closure `:lib` was built from. It also compiles and runs the README's examples above (`[tests][readme]`) against `:lib`; the tests are not run again.
