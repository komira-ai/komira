# komira_op_sort

The sort kernels of the engine. A sort here never moves data: it returns a
permutation, a `PrimitiveArray[DType.int32]` of row indices such that
`keys[result[i]]` is in order, and the caller gathers every column of its
batch by it.

- `sort`: `sort_indices_int64`, `_int32`, `_int128` (DECIMAL128 unscaled
  values) and `_float64`, a stable merge sort written once over the key
  DType; `gather_by_indices_int64` / `_float64`; and `sort_key_lt`, the key
  order every kernel uses.
- `sort_radix`: `radix_sort_int64` (signed) and `radix_sort_u64_keys`
  (unsigned magnitudes), a stable ascending LSD radix sort that skips a pass
  whose byte is the same for every key.
- `sort_topn`: `topn_indices_int64` / `_float64`, the first K rows in order
  by bounded-heap selection, O(N log K).
- `sort_string`: `sort_indices_string`, STRING/BINARY columns in byte-wise
  order (the shorter string first on a shared prefix), nulls first or last.
  By default a prefix-key radix sort; `prefix_key=False` runs the
  byte-compare merge sort, which gives the same permutation.
- `sort_nested`: `sort_indices_nested`, STRUCT / LIST / UNION keys
  (field by field, element by element, type id then value). MAP refuses.
- `sort_multi`: `sort_batch_by_keys`, a stable multi-key sort of a
  `RecordBatch` (one stable pass per key, last key first).
- `sort_lex`: `sort_batch_lex`, the single-pass multi-key sort that
  `sort_batch_by_keys` uses when every key is INT32 / INT64 / STRING: keys
  are encoded as Int64 ranks and, when the ranks fit in 62 bits, packed into
  one Int64 and radix-sorted.
- `sort_loser_tree`: `LoserTree`, a tournament tree for the k-way merge of
  sorted runs, driven by a caller's `LoserTreeComparator`.

Every sort is stable: rows with equal keys keep their input order, in both
directions. Float keys are totally ordered the way DuckDB orders them: NaN
sorts above +inf (last ascending, first descending), every NaN equals every
other NaN, and -0.0 equals +0.0. The numeric kernels read values only;
`sort_indices_string`, `sort_indices_nested` and the BOOL arm of
`sort_batch_by_keys` place nulls (first ascending, last descending, unless
told otherwise). Import from the sub-modules; there is no facade.

## Examples

A float column with a NaN and an infinity, ascending and descending:

<!-- mojo-hidden from std.testing import assert_equal -->
```mojo
from komira_arrow.primitive_array import PrimitiveArray
from komira_op_sort.sort import sort_indices_float64

var nan = Float64(0.0) / Float64(0.0)
var keys = PrimitiveArray[DType.float64].from_list([2.5, nan, -1.0, Float64.MAX])
var asc = sort_indices_float64(keys)
assert_equal(Int(asc.get(0)), 2)   # -1.0
assert_equal(Int(asc.get(3)), 1)   # NaN sorts last ascending
var desc = sort_indices_float64(keys, descending=True)
assert_equal(Int(desc.get(0)), 1)  # and first descending
```

Radix sort of signed keys, and the top two of a column:

<!-- mojo-hidden from std.testing import assert_equal -->
```mojo
from komira_arrow.primitive_array import PrimitiveArray
from komira_op_sort.sort_radix import radix_sort_int64
from komira_op_sort.sort_topn import topn_indices_int64

var keys = PrimitiveArray[DType.int64].from_list([Int64(7), -3, 7, 0])
var perm = radix_sort_int64(keys)
assert_equal(Int(perm.get(0)), 1)  # -3
assert_equal(Int(perm.get(2)), 0)  # the two 7s keep their input order
assert_equal(Int(perm.get(3)), 2)

var top = topn_indices_int64(keys, 2, descending=True)
assert_equal(top.length, 2)
assert_equal(Int(keys.get(Int(top.get(0)))), 7)
```

A string column ascending, and the two string algorithms agreeing:

<!-- mojo-hidden from std.testing import assert_equal -->
```mojo
from komira_arrow.column import Column
from komira_arrow.string_array import StringArray
from komira_op_sort.sort_string import sort_indices_string

var words: List[String] = ["pear", "apple", "pea", "apple"]
var col = Column.from_string(StringArray.from_strings(words))
var asc = sort_indices_string(col)
assert_equal(Int(asc.get(0)), 1)  # "apple" (row 1 before row 3: stable)
assert_equal(Int(asc.get(1)), 3)
assert_equal(Int(asc.get(2)), 2)  # "pea" before "pear": a prefix sorts first
var oracle = sort_indices_string(col, prefix_key=False)
for i in range(4):
    assert_equal(Int(asc.get(i)), Int(oracle.get(i)))
```
