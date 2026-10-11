# kci_cell

Cells for kci. A cell is one closed world a DEPLOY step deploys into: one
cloud, one place, owned by one machine. Every cell is declared once, in one
cells file (format `kci.cells`, a textproto). A DEPLOY step, or a PUBLISH step
into a cell, names the file and picks one cell from it, the way a PUBLISH step
names a channels file and picks one channel (`kci_release_machine` parses those
steps; `kci run` does not run them yet). A cell has a `name` (the step-name grammar: `[a-z][a-z0-9-]*`, at
most 63 bytes, not ending in `-`), a `cloud` (a cloud id; the parser refuses
only an empty or whitespace-only one and does not check the word's form, which
is checked, with whether this kci was built with that cloud, where the step
runs), `setting`s (case-sensitive keys and values
kci does not interpret: the cloud's adapter reads them) and a
`bootstrap_level`, which today must be `1`.

`parse_cells_file` reads a cells file, checks its `schema_version` first, and
checks every rule on the line it names, so a parsed list is always a valid one.
Every refusal starts `cells file: line N:`. It refuses an unknown field, a
scalar set twice, a duplicate cell name or setting key, a setting with no key,
an empty cloud, a name outside the grammar, a `bootstrap_level` other than 1,
a block never closed, a file with no cell, and a `schema_version` that is
missing or of another major. The package depends on the textproto lexer and
`kci_api` only.

## Examples

Parse a cells file and read a cell back:

<!-- mojo-hidden from std.testing import assert_equal, assert_false, assert_true -->
```mojo
from kci_cell import BOOTSTRAP_LEVEL_V1, cell_names, find_cell, parse_cells_file

var cells = parse_cells_file("""
schema_version: 1
cell {
  name: "staging"
  cloud: "gcp"
  setting { key: "project" value: "example-staging" }
  setting { key: "region" value: "europe-west1" }
  bootstrap_level: 1
}
""")
assert_equal(cell_names(cells)[0], "staging")
var staging = find_cell(cells, "staging")
assert_equal(staging.cloud, "gcp")
assert_equal(staging.bootstrap_level, BOOTSTRAP_LEVEL_V1)
assert_true(staging.has_setting("region"))
assert_false(staging.has_setting("zone"))
assert_equal(staging.setting("project"), "example-staging")
```

A lookup never falls back: an unknown cell is refused, naming the declared
ones:

<!-- mojo-hidden from std.testing import assert_equal -->
```mojo
from kci_cell import Cell, CellSetting, find_cell

var only = List[Cell]()
only.append(Cell("staging", "fake", List[CellSetting](), 1))
var message = String()
try:
    _ = find_cell(only, "prod")
except e:
    message = String(e)
assert_equal(message, "unknown cell 'prod' (declared: staging)")
```

Two cells may not share a name; the parser refuses the file, naming both
lines:

<!-- mojo-hidden from std.testing import assert_equal -->
```mojo
from kci_cell import parse_cells_file

var text = String("schema_version: 1\n")
for _ in range(2):
    text += "cell {\n  name: \"staging\"\n  cloud: \"fake\"\n  bootstrap_level: 1\n}\n"
var refusal = String()
try:
    _ = parse_cells_file(text)
except e:
    refusal = String(e)
assert_equal(refusal, "cells file: line 8: cell 'staging' is declared twice (first on line 3)")
```
