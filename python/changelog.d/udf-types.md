- **UDF types.** A function captured for `komira/python` takes and returns `bool`, `int8` to `int64`, `float32`,
  `float64`, `string`, `binary`, `date32`, `timestamp` (with or without a time zone), `decimal128`, `list` and
  `struct`, with any number of arguments (it carried only `int32`, `int64` and `float64`). `decimal.Decimal` takes
  `return_dtype=`; a list item or struct field is not a list, struct, decimal or zoned timestamp; a `timestamp[ns]`
  argument is refused for a `VALUES` function. A dtype is the `str()` of the pyarrow type, except that the
  floats are `float32` and `float64` (pyarrow's `float` and `double` are accepted and kept as those). A
  `TypedDict` return hint with an optional key is refused: a struct's fields are all required.
