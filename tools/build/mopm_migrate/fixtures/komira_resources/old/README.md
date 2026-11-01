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
