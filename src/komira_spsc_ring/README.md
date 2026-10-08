# komira_spsc_ring

`SpscRing[T]`, one bounded single-producer / single-consumer ring of plain
data. Exactly one thread calls `try_push` and exactly one calls `try_pop` (they
may be the same thread); each cursor has one writer, published with a release
store and read with an acquire load (the full ordering argument is in the
header of `spsc_ring.mojo`). The capacity is rounded up to a power of two.

What a push onto a full ring does is chosen at construction: under
`OVERFLOW_BLOCK` (the default) it spins until the consumer frees a slot, so
`try_push` never returns `False`; under `OVERFLOW_DROP` it returns `False`
and counts the drop. Both are counted (`overflow_dropped_count`,
`overflow_blocked_count`). By default the ring is lazy: no slot memory exists
until the first push. `T` must be trivially copyable and trivially
destructible (checked at compile time): the ring holds no `String` or `List`.
It does not grow, does not support more than one producer or consumer, and
offers no blocking pop: `try_pop` on an empty ring returns `None`.

The ring lives in the `komira_spsc_ring.spsc_ring` module.

## Examples

Records come out in push order; the capacity is a power of two:

<!-- mojo-hidden from std.testing import assert_equal, assert_true, assert_false -->
```mojo
from komira_spsc_ring.spsc_ring import SpscRing

var ring = SpscRing[Int64](capacity=6)
assert_equal(ring.capacity(), 8)
assert_false(ring.slots_allocated())  # lazy: nothing allocated yet
assert_true(ring.try_pop() is None)

for i in range(3):
    _ = ring.try_push(Int64(i * 10))
assert_true(ring.slots_allocated())
assert_equal(ring.approximate_size(), 3)
assert_equal(ring.try_pop().value(), 0)
assert_equal(ring.try_pop().value(), 10)
assert_equal(ring.try_pop().value(), 20)
assert_true(ring.is_empty())
```

Under `OVERFLOW_DROP`, a push onto a full ring is refused and counted, and the
stored records are untouched:

<!-- mojo-hidden from std.testing import assert_equal, assert_true, assert_false -->
```mojo
from komira_spsc_ring.spsc_ring import OVERFLOW_DROP, SpscRing

var ring = SpscRing[Int64](capacity=2, overflow_policy=OVERFLOW_DROP)
assert_true(ring.try_push(1))
assert_true(ring.try_push(2))
assert_false(ring.try_push(3))  # full
assert_equal(ring.overflow_dropped_count(), 1)
assert_equal(ring.try_pop().value(), 1)
assert_true(ring.try_push(4))   # a slot is free again
assert_equal(ring.try_pop().value(), 2)
assert_equal(ring.try_pop().value(), 4)
```

A capacity of zero or less is refused:

<!-- mojo-hidden from std.testing import assert_equal -->
```mojo
from komira_spsc_ring.spsc_ring import SpscRing

var message = String()
try:
    _ = SpscRing[Int64](capacity=0)
except e:
    message = String(e)
assert_equal(message, "SpscRing: capacity must be > 0")
```
