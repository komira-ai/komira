# komira_column_format

`ColumnFormatStorage`: column-major storage of slots (rows) for the grouping,
join and sort kernels of an engine whose column types are known only at run
time. A layout is a list of `ColDescriptor`, one per column, each naming its
storage kind (`COL_FIXED`, `COL_VAR_STRING`, `COL_VAR_BINARY`,
`COL_DECIMAL128`), its data type (a `DT_*` tag), its role (a `ROLE_*` tag)
and whether it tracks validity. `ColumnFormatStorage.alloc(layout, capacity)`
then gives each column:

- a contiguous fixed-width buffer of `capacity` cells, read and written by
  `(column, slot)` with typed accessors (`write_slot_i64` / `read_slot_i64`,
  `_f64`, `_i32`, `_f32`, `_u8` ... `_u64`, `_decimal128`);
- for a string or binary column, an 8-byte `(offset, length)` cell per slot
  and a payload heap that grows as payloads are appended (`write_slot_str`,
  `read_slot_str_bytes`, `read_slot_str_len`);
- for a validity-tracked column, a bitmap packed least significant bit first,
  as Arrow does (`set_slot_valid`, `is_slot_valid`, `any_slot_invalid`). A
  fresh slot reads valid, and a column that tracks no validity always reads
  valid.

`grow_to` enlarges every column and keeps the live slots. The caller owns the
slot count (`set_n_slots`) and must keep it at most `capacity`: the storage does not
insert, hash, compare keys or know about batches on its own. Import from
`komira_column_format.column_format_storage`; there is no facade module.

## Examples

A two-column layout, a 64-bit key and a string payload, written by slot and
read back:

<!-- mojo-hidden from std.testing import assert_equal -->
```mojo
from komira_column_format.column_format_storage import COL_FIXED, COL_VAR_STRING, ColDescriptor
from komira_column_format.column_format_storage import ColumnFormatStorage
from komira_column_format.column_format_storage import DT_I64, DT_STRING, ROLE_KEY, ROLE_PAYLOAD

var layout = List[ColDescriptor]()
layout.append(ColDescriptor(name_id=0, kind=COL_FIXED, dtype_tag=DT_I64, role=ROLE_KEY,
    col_idx_in_batch=0, col_idx_in_storage=0, validity_tracked=False))
layout.append(ColDescriptor(name_id=1, kind=COL_VAR_STRING, dtype_tag=DT_STRING, role=ROLE_PAYLOAD,
    col_idx_in_batch=1, col_idx_in_storage=1, validity_tracked=False))
var storage = ColumnFormatStorage.alloc(layout^, 4)
assert_equal(storage.n_cols(), 2)

var names: List[String] = ["pen", "ink", "eraser"]
for slot in range(3):
    storage.write_slot_i64(0, slot, Int64(100 + slot))
    storage.write_slot_str(1, slot, List[UInt8](names[slot].as_bytes()))
storage.set_n_slots(3)

assert_equal(storage.read_slot_i64(0, 2), 102)
assert_equal(storage.read_slot_str_len(1, 1), 3)
assert_equal(String(unsafe_from_utf8=storage.read_slot_str_bytes(1, 2)), "eraser")
```

A validity-tracked column, and growing past the first capacity without losing
what was written:

<!-- mojo-hidden from std.testing import assert_equal, assert_true -->
```mojo
from komira_column_format.column_format_storage import COL_FIXED, ColDescriptor, ColumnFormatStorage
from komira_column_format.column_format_storage import DT_F64, ROLE_AGG_INPUT

var one: List[ColDescriptor] = [ColDescriptor(name_id=0, kind=COL_FIXED, dtype_tag=DT_F64,
    role=ROLE_AGG_INPUT, col_idx_in_batch=0, col_idx_in_storage=0, validity_tracked=True)]
var sums = ColumnFormatStorage.alloc(one^, 8)
for slot in range(8):
    sums.write_slot_f64(0, slot, Float64(slot) * 0.5)
sums.set_n_slots(8)
assert_true(not sums.any_slot_invalid(0, 8))  # fresh slots read valid

sums.set_slot_valid(0, 3, False)
assert_true(not sums.is_slot_valid(0, 3))
assert_true(sums.any_slot_invalid(0, 8))

sums.grow_to(32)
assert_equal(sums.capacity, 32)
assert_equal(sums.read_slot_f64(0, 7), 3.5)
assert_true(not sums.is_slot_valid(0, 3))
sums.write_slot_f64(0, 31, 1.25)
assert_equal(sums.read_slot_f64(0, 31), 1.25)
```
