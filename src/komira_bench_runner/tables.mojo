# From a dataset manifest to what both engines register: one named table per
# Parquet file, and the scale the result states.

from komira_bench_data import DatasetManifest


struct TableBinding(Copyable, Movable):
    """One table: the name the queries use, the file it reads, and the row
    count the manifest records (-1 when it does not)."""

    var name: String
    var path: String
    var rows: Int

    def __init__(out self, var name: String, var path: String, rows: Int):
        self.name = name^
        self.path = path^
        self.rows = rows


struct Scale(Copyable, Movable):
    """The scale of a result: `kind` is `sf` or `rows`."""

    var kind: String
    var value: Int64

    def __init__(out self, var kind: String, value: Int64):
        self.kind = kind^
        self.value = value


def _stem(rel_path: String) raises -> String:
    var slash = rel_path.rfind("/")
    var base = String(rel_path[byte = slash + 1 : rel_path.byte_length()])
    if not base.endswith(".parquet"):
        raise Error("not a parquet file: " + rel_path)
    return String(base[byte=0 : base.byte_length() - 8])


def table_name_of(dataset: String, rel_path: String) raises -> String:
    """The name the corpus queries use for the file at `rel_path` of
    `dataset`: the file name for TPC-H (`lineitem`) and ClickBench (`hits`),
    `x` for the h2o group-by file, and the table suffix of an h2o join file
    (`join_<scale>_big` is `big`)."""
    var stem = _stem(rel_path)
    if dataset == String("tpch") or dataset == String("clickbench"):
        return stem^
    if dataset == String("h2o_groupby"):
        return String("x")
    if dataset == String("h2o_join"):
        var us = stem.rfind("_")
        if us < 0:
            raise Error("not an h2o join file: " + rel_path)
        return String(stem[byte = us + 1 : stem.byte_length()])
    raise Error("no table naming for dataset " + dataset)


def tables_of(manifest: DatasetManifest, cache_dir: String) raises -> List[TableBinding]:
    """One binding per file of `manifest`, the path being `cache_dir` and the
    file's path in the manifest."""
    if cache_dir.byte_length() == 0:
        raise Error("the cache directory is empty")
    var dir = cache_dir.copy()
    if cache_dir.as_bytes()[cache_dir.byte_length() - 1] != 0x2F:
        dir += "/"
    var out = List[TableBinding]()
    for i in range(len(manifest.files)):
        ref f = manifest.files[i]
        var name = table_name_of(manifest.name, f.path)
        for j in range(len(out)):
            if out[j].name == name:
                raise Error("two files of the dataset are the table " + name)
        out.append(TableBinding(name^, dir + f.path, f.expected_rows))
    return out^


def scale_of(manifest: DatasetManifest) raises -> Scale:
    """The scale a result states for `manifest`: the scale factor for TPC-H,
    otherwise the most rows any file of the dataset holds (ClickBench's hits,
    an h2o table's N), which the manifest must record."""
    if manifest.name == String("tpch"):
        if not manifest.scale.startswith("sf"):
            raise Error("tpch scale '" + manifest.scale + "' is not sf<N>")
        var digits = String(manifest.scale[byte=2 : manifest.scale.byte_length()])
        return Scale(String("sf"), Int64(atol(digits)))
    var most = -1
    for i in range(len(manifest.files)):
        if manifest.files[i].expected_rows > most:
            most = manifest.files[i].expected_rows
    if most < 1:
        raise Error("the manifest of " + manifest.name + " records no row count to state a scale from")
    return Scale(String("rows"), Int64(most))
