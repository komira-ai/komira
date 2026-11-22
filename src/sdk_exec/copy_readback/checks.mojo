# =============================================================================
# copy_readback/checks.mojo -- read what the read-back build actions wrote
# =============================================================================
#
#   case_names(cases_sql)  the case of each `COPY (` line of cases.sql: its
#                          destination file name without `.parquet`
#   tsv_row(tsv)           the first data row of a TSV with a header row, by
#                          column name
#   tsv_pairs(tsv)         every data row of a two-column TSV with a header
#                          row, first column to second
#
# The test asserts on what these return; a line or row of another shape gives
# a name or cell the assertions do not expect, never a raise here.


def case_names(cases_sql: String) -> List[String]:
    """The case names of the `COPY (` lines of `cases_sql`, in order."""
    var out = List[String]()
    for raw in cases_sql.split("\n"):
        var line = String(raw)
        if line.startswith("COPY ("):
            var start = line.rfind(") TO '") + 6
            out.append(String(line[byte = start : line.rfind(".parquet'")]))
    return out^


def tsv_row(tsv: String) -> Dict[String, String]:
    """The first data row of `tsv` (after its header row) by column name; a
    column with no cell in the row is absent."""
    var row = Dict[String, String]()
    var lines = tsv.split("\n")
    if len(lines) < 2:
        return row^
    var names = String(lines[0]).split("\t")
    var values = String(lines[1]).split("\t")
    for i in range(min(len(names), len(values))):
        row[String(names[i])] = String(values[i])
    return row^


def tsv_pairs(tsv: String) -> Dict[String, String]:
    """Every data row of the two-column `tsv` (after its header row): the
    first cell to the second. A row without both cells is skipped."""
    var out = Dict[String, String]()
    var lines = tsv.split("\n")
    for i in range(1, len(lines)):
        var cells = String(lines[i]).split("\t")
        if len(cells) == 2:
            out[String(cells[0])] = String(cells[1])
    return out^
