# kci_release_channel

Release channels for kci. A release channel is a publish destination and
nothing else: a name, a visibility (`PUBLIC` adds anonymous read, `PRIVATE`
adds none) and one repository per artifact type (`OCI`, `PYTHON`, `NPM`,
`CONDA`), each with the location a push lands at, the one identity that may
push to it, and its credential (`API_TOKEN` with a secret *name*, never secret
material, or `OIDC_TRUSTED_PUBLISHING`). `parse_channels_file` reads a
textproto channels file, checks its `schema_version` first, and runs
`validate_channels` on the result, so a parsed list is always a valid one:
it refuses an unknown field, a duplicate channel name, an unknown visibility
or artifact type, an empty location or push identity, an invalid credential,
and a location shared by two repositories. `find_channel` and
`Channel.repository_for` read channels back and raise rather than fall back
when a name or artifact type is not declared.

## Examples

Parse a channels file and read a repository back:

<!-- mojo-hidden from std.testing import assert_equal, assert_false, assert_true -->
```mojo
from kci_release_channel import find_channel, parse_channels_file

var channels = parse_channels_file("""
schema_version: 1
channel {
  name: "beta"
  visibility: PRIVATE
  repository {
    artifact_type: OCI
    location: "registry.example.invalid/beta"
    push_identity: "publisher@example.invalid"
    credential { kind: API_TOKEN secret_name: "BETA_REGISTRY_TOKEN" }
  }
}
""")
assert_equal(len(channels), 1)
var beta = find_channel(channels, "beta")
assert_false(beta.is_public())
var repo = beta.repository_for("OCI")
assert_equal(repo.location, "registry.example.invalid/beta")
assert_equal(repo.push_identity, "publisher@example.invalid")
var credential = repo.declared_credential()
assert_true(credential.is_api_token())
assert_equal(credential.secret_name, "BETA_REGISTRY_TOKEN")
```

A lookup never falls back: an unknown channel is refused, naming the declared
ones:

<!-- mojo-hidden from std.testing import assert_equal -->
```mojo
from kci_release_channel import Channel, ChannelRepository, find_channel

var only = List[Channel]()
only.append(Channel("stable", "PUBLIC", List[ChannelRepository]()))
var message = String()
try:
    _ = find_channel(only, "nightly")
except e:
    message = String(e)
assert_equal(message, "unknown release channel 'nightly' (declared: stable)")
```

Two channels may not share a location; the parser refuses the file:

<!-- mojo-hidden from std.testing import assert_true -->
```mojo
from kci_release_channel import parse_channels_file

var text = String("schema_version: 1\n")
for name in ["beta", "stable"]:
    text += String("channel { name: \"") + name + String("\" visibility: PUBLIC ")
    text += "repository { artifact_type: OCI location: \"registry.example.invalid/shared\" "
    text += "push_identity: \"publisher@example.invalid\" "
    text += "credential { kind: API_TOKEN secret_name: \"REGISTRY_TOKEN\" } } }\n"
var refusal = String()
try:
    _ = parse_channels_file(text)
except e:
    refusal = String(e)
assert_true(
    "location 'registry.example.invalid/shared' is declared by both"
    " channel 'beta' and channel 'stable'" in refusal
)
```

Channel names are lowercase letters, digits and `-`, starting with a letter:

<!-- mojo-hidden from std.testing import assert_false, assert_true -->
```mojo
from kci_release_channel import is_valid_channel_name

assert_true(is_valid_channel_name("stable-2"))
assert_false(is_valid_channel_name("Stable"))
assert_false(is_valid_channel_name("2stable"))
assert_false(is_valid_channel_name("stable-"))
```

## Build files

This package is built with buildrules' `mojo_package` and packaged for mopm as `kci_release_channel`, version 0.1.0 (`mopm.toml`). The library is `src/kci_release_channel/`, its tests are `tests/`. It depends on kci_api and komira_textproto, sibling directories (`[dependencies]` of `mopm.toml`), so the `.conda` of this package records `mojo-kci_api >=0.1,<0.2` and `mojo-komira_textproto >=0.1,<0.2` as dependencies and holds none of those packages' files: installing `kci_release_channel` installs them with it. The files that are not sources:

| file | what |
|---|---|
| `mopm.toml` | the mopm manifest: name, version, the Mojo version, the dependencies and where the library and its tests are |
| `mopm.lock` | the toolchain pins and the path dependencies (no registry is reached: every dependency is a sibling) |
| `mopm-toolchain.toml` | the exact mopm and Mojo versions the build uses |
| `coverage_floor.txt` | `lines NN.NN` and `branches NN.NN`: the least line and branch coverage `:coverage` may measure; `:coverage_floor` fails when either falls below, and above it passes and prints a hint to raise the figure |
| `buildrules.mojo.lock.bzl`, `buildrules.mojo.bzl` | written by `buildrules mojo sync` from the files above and from the manifests of the dependencies; `buildrules mojo check` fails when they are stale |

`:lib` is the library file and exists only once every test of `tests/` has passed. After any change to a source, a test, or a manifest of this package or of a dependency, run `buildrules mojo sync`, commit what it writes, and build `komira//src/kci_release_channel:lib` on the farm. A test file that the sync has not listed is not run: run the sync after adding one.

`:conda` is buildrules' `mojo_conda` over `:lib`: the `.conda` of the mopm package (`mojo-kci_release_channel-0.1.0-mojo1.0.0_0.conda`), which therefore exists only once the tests have passed. Publishing it (`mopm publish`) uploads, so it is a step of a CI job that takes that file, not a build action.

`:kci_release_channel` is `:lib` as komira's Mojo rules take it (`mojo_adopted_library`). Its `deps` are the adopted target of each package in `[dependencies]`, and the rule refuses a list that is not the closure `:lib` was built from. It also compiles and runs the README's examples above (`[tests][readme]`) against `:lib`; the tests are not run again.
