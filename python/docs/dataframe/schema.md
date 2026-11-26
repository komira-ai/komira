# Schema without a query

`columns` (a list of names), `dtypes` (each column's Arrow type name,
`int64`, `float64`, `string`, `bool`, ...) and `repr` run nothing. An unknown
column raises `KeyError` at the verb that names it, with the closest name and
the frame's columns.

Back to [the DataFrame overview](overview.md).
