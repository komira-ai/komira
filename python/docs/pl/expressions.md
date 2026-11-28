# komira.pl: expressions

`Expr` has the operators, `alias`, `cast`, the null tests, `fill_null`,
`is_in`, `is_between`, `abs`, the aggregates, the [windows](windows.md)
(newer than 0.1.1623) and `.str`. Expressions are built with `col`, `lit` and
`when` (see [lazy frames](frames.md)).

**Count types.** polars answers a count as UInt32, and `komira.pl` answers
it as Int64: `len()`, `count()`, `n_unique()`, `str.len_chars()`, and
`sum()` of a boolean or a UInt32 column. The values are polars'; only the
type differs, in `schema` and in the collected frame. The engine casts to no
UInt32 yet. A program that needs polars' types casts the count's column
after collecting, with polars itself:

```python
import polars as pl

counts = lf.select(kpl.len()).collect().to_polars()
counts = counts.with_columns(pl.col("len").cast(pl.UInt32))
```

**Strings.** `.str` has `to_lowercase`, `to_uppercase`, `len_chars`,
`starts_with`, `ends_with`, `contains(p, literal=True)`, `strip_chars`,
`strip_chars_start`, `strip_chars_end`, `replace` and `replace_all`.
`strip_chars()` with no argument removes the Unicode whitespace, as polars
does: a space, a tab, a newline, a non-breaking space among it, and not
U+001C to U+001F, which Python's `str.strip()` removes. `strip_chars("xy")`
removes any of the characters `x` and `y`: a set, not a prefix. `replace`
changes the first match of the pattern and `replace_all` every match. The
pattern is a regular expression in the engine's dialect, which pandas'
`str.replace(regex=True)` takes too: RE2's syntax without backreferences or
lookaround, matched over bytes. `literal=True` takes the pattern and the
value as text. In the value, `$1` and `${1}` are group 1, `$0` the whole match
and `$$` a `$`. A named group, `n=` other than 1 and an empty pattern raise
`UnsupportedOperation`. A regular expression over a computed expression
(`col("s").str.to_lowercase().str.replace(p, v)`) is refused at `collect()`
today: add the computed column with `with_columns` first.
