# komira_snapshotter

The provider-agnostic change-data-capture (CDC) seam. It defines what a change
stream yields and the traits a provider's listener implements, so the code that
applies changes to a table is written once for every source:

- `ChangeRecord`: one normalized change, an op (`CDC_OP_INSERT`,
  `CDC_OP_MODIFY`, `CDC_OP_REMOVE`), the primary-key cells, the row after
  (`new_image`) and before (`old_image`) the change as `List[RowCell]` from
  `komira_rowcell`, and the source's opaque `sequence_number`, carried verbatim.
  The constructors `make_insert_record`, `make_modify_record` and
  `make_remove_record` give each op its image shape; `validate()` refuses a
  record whose images do not match its op, or that has no key.
- `ChangeBatch`: the records of one poll plus the cursor for the next one. An
  empty batch with a live cursor means "nothing new yet, keep polling";
  `end_of_segment()` (`is_exhausted()`) means the segment has closed.
- `ChangeStreamListener` (`open()` returns the first cursor, `poll(cursor)`
  returns a batch) and `MultiShardChangeStreamListener` (adds
  `list_shard_ids()` and `open_shard(id, after_sequence_number)`).

It contains no provider client, no table writer and no checkpoint logic: the
provider packages implement the traits, and the consumer decides how records are
applied and when a cursor is committed. It depends only on `komira_rowcell`.
Everything is imported from `komira_snapshotter.change_stream_trait`.

## Examples

Each constructor gives its op the matching images, and `validate()` refuses a
record that breaks the shape:

<!-- mojo-hidden from std.testing import assert_equal, assert_true, assert_false -->
```mojo
from komira_rowcell import RowCell, make_long_cell, make_string_cell
from komira_snapshotter.change_stream_trait import CDC_OP_INSERT, ChangeRecord
from komira_snapshotter.change_stream_trait import make_insert_record, make_modify_record, make_remove_record

var key: List[RowCell] = [make_long_cell(7)]
var before: List[RowCell] = [make_long_cell(7), make_string_cell("bob")]
var after: List[RowCell] = [make_long_cell(7), make_string_cell("bobby")]

var ins = make_insert_record(key.copy(), after.copy(), "seq-100")
assert_true(ins.is_insert())
assert_equal(len(ins.old_image), 0)  # an insert has no row before
ins.validate()

var upd = make_modify_record(key.copy(), before.copy(), after.copy(), "seq-101")
assert_equal(upd.op_name(), "MODIFY")
assert_equal(upd.old_image[1].as_string(), "bob")
assert_equal(upd.new_image[1].as_string(), "bobby")
assert_equal(upd.sequence_number, "seq-101")  # carried, not interpreted
upd.validate()

var rem = make_remove_record(key.copy(), before.copy(), "seq-102")
assert_equal(len(rem.new_image), 0)  # a remove has no row after
rem.validate()

# Built by hand, an INSERT that also carries a before-image is refused.
var bad = ChangeRecord(CDC_OP_INSERT, key.copy(), after.copy(), before.copy(), "seq-1")
var refused = False
try:
    bad.validate()
except e:
    refused = String(e).find("INSERT with non-empty old_image") >= 0
assert_true(refused)
```

A listener is any struct that implements the trait. This one replays two
canned polls from memory; the loop below is the shape a consumer runs against
any provider: thread the cursor, keep polling through empty batches, stop at
the end of the segment.

<!-- mojo-hidden from std.testing import assert_equal -->
```mojo module
from komira_rowcell import RowCell, make_long_cell
from komira_snapshotter.change_stream_trait import ChangeBatch, ChangeRecord, ChangeStreamListener
from komira_snapshotter.change_stream_trait import make_insert_record, make_remove_record


struct ReplayListener(ChangeStreamListener, Movable, Deinitable):
    var polls: Int

    def __init__(out self):
        self.polls = 0

    def open(mut self) raises -> String:
        return "c0"

    def poll(mut self, cursor: String) raises -> ChangeBatch:
        self.polls += 1
        if cursor == "c0":
            var recs = List[ChangeRecord]()
            var row: List[RowCell] = [make_long_cell(1)]
            recs.append(make_insert_record(row.copy(), row.copy(), "s1"))
            return ChangeBatch(recs^, "c1", False)
        if cursor == "c1":
            return ChangeBatch.empty_live("c2")  # nothing new yet
        if cursor == "c2":
            var recs = List[ChangeRecord]()
            var row: List[RowCell] = [make_long_cell(1)]
            recs.append(make_remove_record(row.copy(), row.copy(), "s2"))
            return ChangeBatch(recs^, "c3", False)
        return ChangeBatch.end_of_segment()


def drain[L: ChangeStreamListener](mut listener: L) raises -> List[String]:
    var seen = List[String]()
    var cursor = listener.open()
    while True:
        var batch = listener.poll(cursor)
        for i in range(len(batch.records)):
            seen.append(batch.records[i].op_name() + "@" + batch.records[i].sequence_number)
        if batch.is_exhausted():
            break
        cursor = batch.next_cursor.copy()
    return seen^


def main() raises:
    var listener = ReplayListener()
    var seen = drain(listener)
    assert_equal(len(seen), 2)
    assert_equal(seen[0], "INSERT@s1")
    assert_equal(seen[1], "REMOVE@s2")
    assert_equal(listener.polls, 4)  # the empty live poll did not end the loop
```

## Build files

This package is built with buildrules' `mojo_package` and packaged for mopm as `komira_snapshotter`, version 0.1.0
(`mopm.toml`). The library is `src/komira_snapshotter/`, its tests are `tests/`. It depends on one package,
`komira_rowcell`, a sibling directory (`[dependencies]` of `mopm.toml`: `{ path = "../komira_rowcell",
version = "0.1" }`), so the `.conda` of this package records `mojo-komira_rowcell >=0.1,<0.2` as a dependency
and holds none of that package's files. The files that are not sources:

| file | what |
|---|---|
| `mopm.toml` | the mopm manifest: name, version, the Mojo version, the dependency and where the library and its tests are |
| `mopm.lock` | the toolchain pins and the path dependency, as `mopm lock` writes them (no registry is reached: the only dependency is a sibling) |
| `mopm-toolchain.toml` | the exact mopm and Mojo versions the build uses (written by hand) |
| `coverage_floor.txt` | `lines NN.NN` and `branches NN.NN`: the least line and branch coverage `:coverage` may measure; `:coverage_floor` fails when either falls below |
| `buildrules.mojo.lock.bzl`, `buildrules.mojo.bzl` | written by `buildrules mojo sync` from the files above and from the manifest of the sibling; `buildrules mojo check` fails when they are stale |

`:lib` is the library file, built from the `:lib` of `komira_rowcell`, and exists only once the tests have passed.
After any change to a source, a test, or a manifest of this package or of the sibling, run `buildrules mojo sync`
with both packages staged, commit what it writes, and build `komira//src/komira_snapshotter:lib` on the farm.

`:conda` is buildrules' `mojo_conda` over `:lib`: the `.conda` of the mopm package
(`mojo-komira_snapshotter-0.1.0-mojo1.0.0_0.conda`), packed with the sibling's manifest beside its own (`members`).
Publishing it (`mopm publish`) uploads, so it is a step of a CI job that takes that file, not a build action.

`:komira_snapshotter` is `:lib` as komira's Mojo rules take it (`mojo_adopted_library`): its `deps` are the adopted
target of each package in `[dependencies]`, and the rule refuses a list that is not the closure `:lib` was built
from. It also compiles and runs the README's examples above (`[tests][readme]`) against `:lib`; the tests are not
run again.
