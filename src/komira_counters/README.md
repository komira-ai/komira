# komira_counters

Process-global census and falsifier counters plus the build-gated runtime introspection probe.

A counter is named, not constructed: `GlobalCounter["name"]` is a type whose
static methods add to, read and reset one 64-bit cell, and every use of the
same name, in any module of the process, reaches the same cell. The cell is
created, zeroed, the first time a name is used. Adds are relaxed atomic
operations, so threads may count at once; read a total after they have
joined. `GlobalCounterTable["name", n]` is the same with `n` slots.

The `try_` forms (`try_add`, `try_incr`) do not raise, for an instrument in a
function that cannot: a counter must never change the control flow of the
code it observes.

Every example below runs as a test when the package is built, so it cannot
go stale.

## A counter

```mojo
from komira_counters.global_counter import GlobalCounter
from std.testing import assert_equal

comptime Requests = GlobalCounter["readme_example_requests"]


def handle_request() raises:
    Requests.incr()


def requests_seen() raises -> Int:
    # The name spelled again: the same counter.
    comptime Seen = GlobalCounter["readme_example_requests"]
    return Seen.read()


Requests.reset()
handle_request()
handle_request()
Requests.add(5)
Requests.try_add(-1)
assert_equal(requests_seen(), 6)
Requests.reset()
assert_equal(requests_seen(), 0)
```

## A table of counters

A slot outside the table is refused rather than written.

```mojo
from komira_counters.global_counter import GlobalCounterTable
from std.testing import assert_equal, assert_raises

comptime ByWidth = GlobalCounterTable["readme_example_by_width", 4]

ByWidth.reset()
ByWidth.incr(1)
ByWidth.add(3, 40)
assert_equal(ByWidth.read(0), 0)
assert_equal(ByWidth.read(1), 1)
assert_equal(ByWidth.read(3), 40)
with assert_raises(contains="slot out of range"):
    ByWidth.incr(4)
```

## The counters in this package

`global_counter` is the one primitive under every counter here: a process-global, name-keyed table of relaxed atomic counters (`GlobalCounter`, `GlobalCounterTable`) whose API exposes no pointer. Each counter module declares its names and keeps only its own meaning.
