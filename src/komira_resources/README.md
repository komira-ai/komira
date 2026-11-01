# komira_resources

The files a program reads at run time, found under its own `share/`
directory.

```text
<root>/bin/<program>
<root>/share/<name>
```

A resource is named by its path under `share/`. A test and a shipped program
both have that layout, so the same call works in each and the caller never
says which it is in:

- a test (a `test_srcs` entry of a `mojo_library`, or a `mojo_test`) runs from
  a tree staged for it alone. A list entry of its `test_data` / `data` is
  staged at its path in the repository, so
  `read_resource("<repository path>")` opens it; a dict entry
  `{"<name>": <source>}` is staged at `<name>`;
- a shipped program is a `mojo_bundle`, and `data = {"share/<name>": <source>}`
  puts the file at `<name>`. Ship it under its repository path and the test
  and the program use the same name.

| function | returns |
|---|---|
| `resource_path(name)` | the absolute path of resource `name`, a file or a directory |
| `read_resource(name)` | the text of resource file `name` |

The lookup goes through the executable's own path (see
`komira_runtime_paths`), so it does not depend on the current directory or on
any environment variable, and there is no fallback. A name that was not
declared is absent, and asking for it raises an error that names it and says
where to declare it. There is deliberately no "does it exist" query: a test
that skips when its data is missing passes without testing anything.

A name is a relative path with no empty, `.` or `..` segment. A directory
name holds exactly the files declared under it.

Every example below runs as a test when the package is built, so it cannot
go stale.

## An undeclared resource

The program these examples build into declares no data, so every name is
undeclared, and the error says how to declare it.

```mojo
from komira_resources import read_resource, resource_path
from std.testing import assert_true

var message = String()
try:
    _ = read_resource("komira_resources_example/settings.textproto")
except e:
    message = String(e)
assert_true(message.startswith("komira_resources: 'komira_resources_example/settings.textproto' is not a resource of this program"))
assert_true("mojo_bundle lists it in data as 'share/komira_resources_example/settings.textproto'" in message)

var refused = False
try:
    _ = resource_path("komira_resources_example")  # a directory name is looked up the same way
except e:
    refused = String(e).startswith("komira_resources: ")
assert_true(refused)
```

## A name outside `share/`

```mojo
from komira_resources import resource_path
from std.testing import assert_true

var message = String()
try:
    _ = resource_path("../bin/program")
except e:
    message = String(e)
assert_true("must not hold an empty, '.' or '..' segment" in message)
```

## Build files

This package is built with buildrules' `mojo_package` and packaged for mopm as `komira_resources`, version 0.1.0
(`mopm.toml`). The library is `src/komira_resources/`, its test is `tests/`. It depends on one package,
`komira_runtime_paths`, a sibling directory (`[dependencies]` of `mopm.toml`: `{ path = "../komira_runtime_paths",
version = "0.1" }`), so the `.conda` of this package records `mojo-komira_runtime_paths >=0.1,<0.2` as a dependency
and holds none of that package's files: installing `komira_resources` installs `komira_runtime_paths` with it. The
files that are not sources:

| file | what |
|---|---|
| `mopm.toml` | the mopm manifest: name, version, the Mojo version, the dependency and where the library and its test are |
| `mopm.lock` | the toolchain pins and the path dependency, as `mopm lock` writes them (no registry is reached: the only dependency is a sibling) |
| `mopm-toolchain.toml` | the exact mopm and Mojo versions the build uses (written by hand) |
| `coverage_floor.txt` | `lines NN.NN` and `branches NN.NN`: the least line and branch coverage `:coverage` may measure; `:coverage_floor` fails when either falls below, and above it passes and prints a hint to raise the figure |
| `buildrules.mojo.lock.bzl`, `buildrules.mojo.bzl` | written by `buildrules mojo sync` from the files above and from the manifest of the sibling; `buildrules mojo check` fails when they are stale |

The test runs with `test_layout = "installed"` (the test binary is `<root>/bin/<exe>`, the declared files are under
`<root>/share`), the layout this library reads. `:lib` is the library file, built from the `:lib` of
`komira_runtime_paths`, and exists only once the test has passed. After any change to a source, the test, a
manifest of this package or of the sibling, run `buildrules mojo sync` with both packages staged, commit what it
writes, and build `komira//src/komira_resources:lib` on the farm.

`:conda` is buildrules' `mojo_conda` over `:lib`: the `.conda` of the mopm package
(`mojo-komira_resources-0.1.0-mojo1.0.0_0.conda`), packed with the sibling's manifest beside its own (`members`),
which therefore exists only once the test has passed. Publishing it (`mopm publish`) uploads, so it is a step of a
CI job that takes that file, not a build action.

`:komira_resources` is `:lib` as komira's Mojo rules take it (`mojo_adopted_library`): its `deps` are the adopted
target of each package in `[dependencies]`, and the rule refuses a list that is not the closure `:lib` was built
from. It also compiles and runs the README's examples above (`[tests][readme]`) against `:lib`; the test is not
run again.
