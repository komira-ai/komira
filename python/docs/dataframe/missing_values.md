# Missing values

> **Newer than 0.1.1623.** komira 0.1.1623 and older releases do not have what this page describes. [The changelog](../../CHANGELOG.md) lists what each release added.

`df.fillna(value)` or `df.fillna({"col": value})` fills the missing values of
int32, int64, float32, float64, bool and string columns with a value of the
column's type; `df.dropna(how="any", subset=None)` (or `how="all"`) keeps the
rows with no missing value (or not every one missing). In both, as in pandas, a
NaN in a float column is missing as NULL is.

`df.isna()` gives a frame of the same columns, each True where the value is
missing and False elsewhere, so `df.isna().sum()` counts the missing values of
each column; `df.notna()` is its negation, column by column. On a Series,
`s.isna()` and `s.notna()` give a boolean Series, used as a filter
(`df[df["score"].isna()]`) or as a column (`df.assign(m=df["score"].notna())`).
A NaN in a float column is missing here too, and the answer is never NULL.
`isnull` and `notnull` are the same methods. `isna` and `notna` replace every
column, so a sorted frame's `isna()` is unordered; a filter by a Series'
`isna()` keeps the order. The four methods are newer than the release above.

The aggregates still read a NaN as a value ([group-by](groupby.md)).

Back to [the DataFrame overview](overview.md).
