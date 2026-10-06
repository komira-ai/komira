# komira_name_registry

Interned names: a compile-time id for a string literal, and a fixed-size
table that turns an id back into its name.

- `name_id[name]()` is the FNV-1a 32-bit hash of a `StringLiteral`, computed
  at compile time, so the id is a constant at the call site.
  `name_id_of(s)` computes the same id at run time from a `String`.
- `NameRegistry` records each registered name under its id, so code that
  carries only ids (a counter, a trace span) can print names later.
  It holds at most `MAX_REGISTERED_NAMES` (256) names of at most
  `MAX_NAME_BYTES` (64) bytes each; a longer name is stored cut at the last
  whole UTF-8 character that fits. Registration fails (returns `False`) when
  the table is full. Id 0 marks an empty slot, so a name whose id is 0 cannot
  be registered.

Concurrency: register from one thread at a time (or under your own lock).
Once registration is done, any number of threads may call `lookup`,
`contains` and `count`. The full contract is in the header of
`registry.mojo`.

The package depends only on `komira_hash`.

Every example below runs as a test when the package is built, so it cannot
go stale.

## Ids

```mojo
from komira_name_registry import name_id, name_id_of
from std.testing import assert_equal, assert_true

assert_equal(name_id["a"](), UInt32(0xE40C292C))  # the FNV-1a 32-bit test vector
assert_equal(name_id["foobar"](), UInt32(0xBF9CF968))
assert_equal(name_id["scan.rows"](), name_id_of(String("scan.rows")))
assert_true(name_id["scan.rows"]() != name_id["scan.bytes"]())
```

## Registering and looking up

`try_register` returns `True` the first time a name is registered and
`False` after that, so registering a name twice is harmless. `lookup`
returns the name for an id, or `None` for an id nobody registered;
`contains` answers the same question without allocating a `String`.

```mojo
from komira_name_registry import NameRegistry, name_id, name_id_of
from std.testing import assert_equal, assert_false, assert_true

var reg = NameRegistry()
assert_true(reg.try_register["scan.rows"]())
assert_false(reg.try_register["scan.rows"]())  # already there: a no-op
assert_true(reg.try_register["scan.bytes"]())
assert_equal(reg.count(), 2)

assert_equal(reg.lookup(name_id["scan.rows"]()).value(), "scan.rows")
assert_true(reg.contains(name_id_of(String("scan.bytes"))))
assert_false(reg.contains(name_id["never.registered"]()))
assert_false(Bool(reg.lookup(name_id["never.registered"]())))
assert_false(Bool(reg.lookup(UInt32(0))))  # 0 is the empty-slot marker
```
