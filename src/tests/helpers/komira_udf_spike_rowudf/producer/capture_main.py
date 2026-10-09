"""The producer step of the row-UDF spike: the read set of each row function
the runtime tests and the bench load, determined as the SDK would when the
plan is built (komira_udf_readset.read_set), written as one table the Mojo
side reads into its UDF references (UdfSpec.arg_names: the ROW UdfRef's
arg_types, one named field each).

Run by the python_oracle rule: argv is [script, output directory, data
directory]. Writes read_sets.tsv, one line per case, tab-separated:

    case  entry  input columns  source  read set  recorded  note

with comma-separated column lists. `source` is columns, static or
every_column; `recorded` is what the sample run read (the cross-check),
empty without a sample.
"""

import os
import sys

# The oracle's interpreter puts no script directory on sys.path (-P).
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(os.path.dirname(HERE), "pyrt"))

import komira_udf_readset as rs  # noqa: E402
import udf_rows  # noqa: E402

# The bench's input widths, of which price_qty reads 2.
WIDTHS = (4, 16, 64)


def bench_columns(width):
    """`width` columns: c<j>, with c1 named price and the last named qty."""
    names = ["c{}".format(j) for j in range(width)]
    names[1] = "price"
    names[width - 1] = "qty"
    return names


def cases():
    """(case, function, input columns, columns override, sample) each."""
    out = []
    for w in WIDTHS:
        cols = bench_columns(w)
        sample = [{c: float(j + 1) for j, c in enumerate(cols)}]
        out.append(("price_qty@{}".format(w), "price_qty", cols, None, sample))
    out.append(("price_qty_keys", "price_qty_keys", bench_columns(4), None, None))
    # The local run sees only rows with a > 0, so it records {a, b}; the
    # scan finds c on the other branch.
    abc = ["a", "b", "c"]
    out.append(("branchy", "branchy", abc, None, [{"a": 1.0, "b": 2.0, "c": 3.0}, {"a": 5.0, "b": 6.0, "c": 7.0}]))
    out.append(("branchy_declared_ab", "branchy", abc, ["a", "b"], None))
    out.append(("pick", "pick", ["flag", "a", "b"], None, [{"flag": 1, "a": 10, "b": 100}]))
    out.append(("via_helper", "via_helper", bench_columns(4), None, None))
    return out


def main():
    out_dir = sys.argv[1]
    lines = []
    for case, name, cols, columns, sample in cases():
        r = rs.read_set(getattr(udf_rows, name), cols, columns=columns, sample=sample)
        lines.append(
            "\t".join(
                [case, "udf_rows:" + name, ",".join(cols), r.source, ",".join(r.names), ",".join(r.recorded), r.note]
            )
        )
    with open(os.path.join(out_dir, "read_sets.tsv"), "w") as f:
        f.write("\n".join(lines) + "\n")
    print("\n".join(lines))


main()
