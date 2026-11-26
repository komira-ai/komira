"""How a notebook shows a frame and a result: the HTML of IPython's
`_repr_html_` (docs/design/dataframe_surface.md, section 2).

- A `DataFrame` is a plan, and showing it runs nothing: its HTML is a table of
  its column names, each over its type, and a line saying that the frame has
  not run and that `.materialize()` runs it. No SQL text is shown or made.
- A `Result` shows its first `MAX_ROWS` rows under the same two header rows,
  its types as pyarrow names them (`double`, `timestamp[us]`), and a line
  giving the row and column counts, or saying that the result has more rows.
  The `Result` reads those rows from its stream (komira/_session.py) and
  hands them here; this module reads no stream and calls no library.
- A value's text is Arrow's cast of its column to `string`; a column the cast
  refuses (bytes that are not UTF-8, a nested type) is shown as Python's
  `str()` of each value. A null is shown as `null`, in italics, and a text
  longer than `MAX_CELL` characters is cut there and ends with `…`. Every
  name, type and value is HTML-escaped.

pyarrow is imported by `result_html`, which only a `Result`, already holding
a pyarrow reader, calls.
"""

from __future__ import annotations

import html
from collections.abc import Sequence
from typing import TYPE_CHECKING

if TYPE_CHECKING:
    import pyarrow

# The rows a result shows.
MAX_ROWS = 10

# The characters of a value's text a cell shows before it is cut.
MAX_CELL = 100


def _count(n: int, noun: str) -> str:
    return f"{n} {noun}" if n == 1 else f"{n} {noun}s"


def _table(names: Sequence[str], types: Sequence[str], rows: Sequence[Sequence[str | None]], note: str) -> str:
    head = "".join(f"<th>{html.escape(name)}</th>" for name in names)
    kinds = "".join(f"<th>{html.escape(kind)}</th>" for kind in types)
    body = "".join("<tr>" + "".join(_cell(text) for text in row) + "</tr>" for row in rows)
    return (
        '<div class="komira"><table class="dataframe">'
        f"<thead><tr>{head}</tr><tr>{kinds}</tr></thead><tbody>{body}</tbody>"
        f"</table><p>{html.escape(note)}</p></div>"
    )


def _cell(text: str | None) -> str:
    if text is None:
        return "<td><i>null</i></td>"
    if len(text) > MAX_CELL:
        text = text[:MAX_CELL] + "…"
    return f"<td>{html.escape(text)}</td>"


def frame_html(dtypes: dict[str, str]) -> str:
    """The HTML of a frame whose columns and their type names are `dtypes`."""
    note = (
        f"komira.DataFrame of {_count(len(dtypes), 'column')}: a plan that has not run; "
        ".materialize() runs it and returns its rows"
    )
    return _table(list(dtypes), list(dtypes.values()), (), note)


def _texts(column: pyarrow.ChunkedArray) -> list[str | None]:
    import pyarrow as pa
    import pyarrow.compute as pc

    try:
        return pc.cast(column, pa.string()).to_pylist()
    except (pa.ArrowInvalid, pa.ArrowNotImplementedError):
        return [None if value is None else str(value) for value in column.to_pylist()]


def result_html(schema: pyarrow.Schema, batches: list[pyarrow.RecordBatch], more: bool) -> str:
    """The HTML of a result of `schema` whose first batches are `batches`:
    their first `MAX_ROWS` rows, and `more` says whether the stream had more."""
    import pyarrow as pa

    table = pa.Table.from_batches(batches, schema=schema).slice(0, MAX_ROWS)
    columns = [_texts(column) for column in table.columns]
    rows = [[column[i] for column in columns] for i in range(table.num_rows)]
    shape = _count(len(schema), "column")
    if more:
        note = f"the first {_count(table.num_rows, 'row')} of more, {shape}"
    else:
        note = f"{_count(table.num_rows, 'row')}, {shape}"
    return _table(schema.names, [str(field.type) for field in schema], rows, note)
