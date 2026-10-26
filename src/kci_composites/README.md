# kci_composites

The composite definitions kci ships, `kci.job` and `kci.app`, as data: each
is one `kci.resource.v1.CompositeDefinition` in proto3 JSON under
`src/kci_composites/definitions/`. Nothing in kci_cloud branches on them;
they are loaded the way any author's definition is loaded.

| name | what it is |
|---|---|
| `KCI_DEFINITIONS_DIR` | where the files are, as resource names (their repository paths) |
| `kci_definition_files()` | every definition file kci ships, as a resource name, `kci.job` first |
| `read_kci_definitions()` | each file read through `komira_resources` and decoded strictly with `komira_proto_codec`'s `decode_json`, which refuses an unknown field or enum name |

The files are resources of the program that reads them
([komira_resources](https://github.com/komira-ai/komira/blob/main/src/komira_resources/README.md)):
a test names them in its `test_data`, and a shipped program puts each one in
its bundle's `data` under the path it has here. Each file is pinned by name,
version and digest in kci_cloud's `shipped_definitions`, so an edited file
needs a new version and a new row there (the `kci` namespace rule).

## Examples

Every example below runs as a test when the package is built, so it cannot
go stale.

### The files, and their rows in kci_cloud

Each file kci ships is named after its definition, and kci_cloud pins every
one of them by name.

```mojo
from kci_cloud import shipped_definitions
from kci_composites import KCI_DEFINITIONS_DIR, kci_definition_files
from std.testing import assert_equal, assert_true

var files = kci_definition_files()
var rows = shipped_definitions()
assert_equal(files[0], "src/kci_composites/definitions/kci.job.json")
assert_equal(len(files), len(rows))  # one row per file, and no row without one
for i in range(len(files)):
    assert_true(files[i].startswith(String(KCI_DEFINITIONS_DIR) + "/"), files[i])
    var found = False
    for k in range(len(rows)):
        if files[i] == String(KCI_DEFINITIONS_DIR) + "/" + rows[k].name + ".json":
            found = True
    assert_true(found, files[i] + " has a row in shipped_definitions")
```

### A program that does not declare them

The program this example builds into declares no data, so reading the
definitions is refused, naming the first file and saying where to declare
it. There is no fallback to a path in the source tree.

```mojo
from kci_composites import read_kci_definitions
from std.testing import assert_true

var message = String()
try:
    _ = read_kci_definitions()
except e:
    message = String(e)
assert_true(message.startswith("kci_composites: src/kci_composites/definitions/kci.job.json: "), message)
assert_true("is not a resource of this program" in message, message)
assert_true("mojo_bundle lists it in data as 'share/src/kci_composites/definitions/kci.job.json'" in message, message)
```
