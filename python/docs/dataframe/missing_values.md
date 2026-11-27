# Missing values

> **Newer than 0.1.1623.** komira 0.1.1623 and older releases do not have what this page describes. [The changelog](../../CHANGELOG.md) lists what each release added.

`df.fillna(value)` or `df.fillna({"col": value})` fills the missing values of
int32, int64, float32, float64, bool and string columns with a value of the
column's type; `df.dropna(how="any", subset=None)` (or `how="all"`) keeps the
rows with no missing value (or not every one missing). In both, as in pandas, a
NaN in a float column is missing as NULL is.

`isna` and `notna` are not built yet. The aggregates still read a NaN as a
value ([group-by](groupby.md)).

Back to [the DataFrame overview](overview.md).
