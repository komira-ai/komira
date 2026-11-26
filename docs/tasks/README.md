# Common tasks

The data-analysis tasks people do most often, ranked, with what komira can do for each today and,
where it can, a complete example that runs.

- [catalogue.json](catalogue.json) lists the top 100. Each entry has its `rank`, a `slug`, a
  `category`, the `question` ("How do I ...?") and a `status`: `works` (komira does the task),
  `partial` (komira does part of it, or one form of it, and the page says which), or `gap` (komira
  cannot do it yet). A `gap` entry names in `issues` the komira issue or issues that block it; a
  `partial` entry may too.
- A task with an example has a directory `<rank>-<slug>/` holding three files:
  - `example.py`: a complete program. It makes its own small input files in the directory it runs
    in and uses no network.
  - `expected_output.txt`: exactly what `example.py` prints.
  - `page.md`: the page of the task: a one-line answer, the program, its output, notes, and the
    related tasks by rank.
- A `gap` task has no directory: it is listed in the catalogue, not shown.

The ranking, and the evidence of how often each task is asked, come from public sources: call
counts of pandas functions in Kaggle notebooks, the canonical Stack Overflow questions, and the
guides of DuckDB and Polars. Ranks above about 50 are less certain than those below.
