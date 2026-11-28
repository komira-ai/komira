# scan_source

What a scan is: SourceLike, ScanBinding identity, scan params, per-format source descriptors, pushdown gate, Sink trait, in-memory registry.

## Examples

Every `ScanRegistry` takes a process-unique, nonzero epoch from a counter in
this package's C (`native/komira_scan_source_inmem_id.c`), so a handle minted
by one registry is never valid in another; the unbound registry has none:

<!-- mojo-hidden from std.testing import assert_true, assert_false -->
```mojo
from scan_source.scan_binding import SCAN_EPOCH_NONE
from scan_source.scan_registry import ScanRegistry

var first = ScanRegistry()
var second = ScanRegistry()
assert_true(first.epoch() != SCAN_EPOCH_NONE)
assert_true(second.epoch() > first.epoch())  # strictly increasing
assert_false(first.is_bound(0, 0))  # a live registry that holds nothing yet
assert_true(ScanRegistry(unbound=True).epoch() == SCAN_EPOCH_NONE)
```

The rows of `generate_series` and `range` in FROM are a scan of the
`komira.generate_series` kind (`series_scan`): a `SeriesSpec` names the one
column, its bounds and its step, the binding carries it as parameters, and the
values are computed a window at a time, so a long series is never held whole:

<!-- mojo-hidden from std.testing import assert_equal, assert_true -->
```mojo
from scan_source.series_scan import (
    SeriesSpec, series_scan_binding, series_spec_of, series_values,
)

# range(1, 10, 3): the bound is exclusive, so 1, 4, 7.
var spec = SeriesSpec("range", False, 1, 10, 3, 0, False)
var rows = series_values(spec, 0, 100)
assert_equal(len(rows), 3)
assert_equal(rows[2], 7)
# The binding round-trips the spec; a window past the end is empty.
assert_equal(series_spec_of(series_scan_binding(spec, "range")).stop, 10)
assert_true(len(series_values(spec, 3, 100)) == 0)
```
