- **Notebook display.** In Jupyter and IPython a `komira.DataFrame` shows as a table of its column
  names over their types, and runs nothing; a `Result` shows its first ten rows at most, with a line
  giving the row and column counts or saying there are more. The result is still unread after it is
  shown: `to_arrow()`, `to_pandas()` and the other terminals read every row, once.
