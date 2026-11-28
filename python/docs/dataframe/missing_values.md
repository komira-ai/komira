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

`df.replace(["N/A", "n/a", "-"], None)` turns each listed value into a NULL of
the column's own type, in every column whose type can hold it;
`df.replace({"city": "N/A", "score": -1}, None)` names the values of each
column, `df.replace({"N/A": None})` and `df.replace({"city": {"N/A": None}})`
map old to new, and `s.replace("N/A", None)` does one Series. A value can
also become another value of the column's type, as `df.replace(-1, 0)`. The
arguments are pandas 3's, read as pandas reads them, and so is what matches:
exact values, an int meeting an int or float column, a str only a string
column, NaN looked for meeting NULL (and NaN in a float column), a value given
twice taking its last replacement. Where pandas would change a column's type
(a str into an int column, a float that is not whole into an int column) the
call is refused by name, as is a bool, decimal, date or timestamp column a
value could be in; cast the column first, or pass a dict that leaves it out.
`regex=True` and `inplace=True` are refused by name.

```python
df = komira.read_csv("contacts.csv")
clean = df.replace(["N/A", "n/a", "-"], None).replace({"score": -1}, None)
clean[["score"]].mean()     # the mean skips the cells replace made NULL
```

The aggregates still read a NaN as a value ([group-by](groupby.md)).

Back to [the DataFrame overview](overview.md).
