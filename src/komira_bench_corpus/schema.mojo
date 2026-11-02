# The tables a query reads: the dataset a suite expects.

from .sha256 import sha256_hex


struct Column(Copyable, Movable):
    """A column: its name and its SQL type as written in `Dataset.ddl()`."""

    var name: String
    var sql_type: String

    def __init__(out self, var name: String, var sql_type: String):
        self.name = name^
        self.sql_type = sql_type^


struct Table(Copyable, Movable):
    """A table and its columns, in order."""

    var name: String
    var columns: List[Column]

    def __init__(out self, var name: String, var columns: List[Column]):
        self.name = name^
        self.columns = columns^

    def ddl(self) -> String:
        """`CREATE TABLE name (` with one column per line and `);`."""
        var out = "CREATE TABLE " + self.name + " (\n"
        for i in range(len(self.columns)):
            out += "  " + self.columns[i].name + " " + self.columns[i].sql_type
            if i + 1 < len(self.columns):
                out += ","
            out += "\n"
        out += ");\n"
        return out


struct Dataset(Copyable, Movable):
    """The tables a suite's queries expect, with the logical column types.

    It describes the data the queries are written against, not a file
    layout: how a table is stored (Parquet, CSV, a view over a file whose
    dates are integers) is the loader's business, and the loader must present
    these names and types to the engine."""

    var name: String
    var tables: List[Table]

    def __init__(out self, var name: String, var tables: List[Table]):
        self.name = name^
        self.tables = tables^

    def table(self, table_name: String) raises -> Table:
        """The table with that name; raises when there is none."""
        for i in range(len(self.tables)):
            if self.tables[i].name == table_name:
                return self.tables[i].copy()
        raise Error(
            "komira_bench_corpus: dataset "
            + self.name
            + " has no table "
            + table_name
        )

    def ddl(self) -> String:
        """The `CREATE TABLE` statements of every table, in order."""
        var out = String("")
        for i in range(len(self.tables)):
            if i > 0:
                out += "\n"
            out += self.tables[i].ddl()
        return out

    def sha256(self) -> String:
        """The SHA-256 of `ddl()`."""
        return sha256_hex(self.ddl())


def columns_of(spec: String) -> List[Column]:
    """Columns from `name type` pairs separated by `;`. The type is what
    follows the first space, so `l_extendedprice DECIMAL(15,2)` is one pair."""
    var out = List[Column]()
    var parts = spec.split(String(";"))
    for i in range(len(parts)):
        var item = String(String(parts[i]).strip())
        if item.byte_length() == 0:
            continue
        var at = item.find(String(" "))
        out.append(
            Column(String(item[byte=:at]), String(item[byte = at + 1 :]))
        )
    return out^
