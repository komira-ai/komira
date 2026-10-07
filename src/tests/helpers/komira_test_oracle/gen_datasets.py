"""The oracle's datasets, written in every format the suite scans.

    gen_datasets.py <output directory> <data directory>

A `python_oracle` script (tools/build/python/README.md, Oracles): it reads
nothing (the data directory is empty), builds each table of datasets.py from
its fixed seed, and writes under the output directory, per dataset:

- `<dataset>.schema`: the schema line of the canonical result text
  (schema_text.py);
- `<dataset>.<suffix>`: the table in each format of formats.SUFFIX, holding
  the columns that format carries (datasets.Dataset.carried);

and `index.tsv`: one line per data file, `file`, `dataset`, `format`, `rows`
and the comma-separated columns it holds, sorted by file, under a header line.
"""

import os
import sys

import datasets
import formats
import schema_text


def main(out):
    index = []
    for name in datasets.NAMES:
        ds = datasets.build(name)
        with open(os.path.join(out, name + ".schema"), "w", encoding="utf-8", newline="\n") as f:
            f.write(schema_text.schema_line(ds.schema))
        for fmt in datasets.FORMATS:
            columns = ds.carried(fmt)
            file = name + "." + formats.SUFFIX[fmt]
            formats.write(fmt, ds.table.select(columns), os.path.join(out, file))
            index.append((file, name, fmt, str(ds.rows), ",".join(columns)))
    with open(os.path.join(out, "index.tsv"), "w", encoding="utf-8", newline="\n") as f:
        f.write("file\tdataset\tformat\trows\tcolumns\n")
        for row in sorted(index):
            f.write("\t".join(row) + "\n")


main(sys.argv[1])
