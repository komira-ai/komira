# komira_scan_source

What a scan is: SourceLike, ScanBinding identity, scan params, per-format source descriptors, pushdown gate, Sink trait, in-memory registry.

## Examples

Every `ScanRegistry` takes a process-unique, nonzero epoch from a counter in
this package's C (`native/komira_scan_source_inmem_id.c`), so a handle minted
by one registry is never valid in another; the unbound registry has none:

<!-- mojo-hidden from std.testing import assert_true, assert_false -->
```mojo
from komira_scan_source.scan_binding import SCAN_EPOCH_NONE
from komira_scan_source.scan_registry import ScanRegistry

var first = ScanRegistry()
var second = ScanRegistry()
assert_true(first.epoch() != SCAN_EPOCH_NONE)
assert_true(second.epoch() > first.epoch())  # strictly increasing
assert_false(first.is_bound(0, 0))  # a live registry that holds nothing yet
assert_true(ScanRegistry(unbound=True).epoch() == SCAN_EPOCH_NONE)
```
