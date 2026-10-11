# The producer's read sets (producer/capture_main.py's table, committed as
# golden/read_sets.tsv and checked against the capture by the py_test
# read_sets_golden_test) read back into UDF references: a ROW UdfSpec whose
# argument struct is the read set, one named field per entry, in the read
# set's order (sorted by UTF-8 bytes: arg_types must match it). A PRESENT
# read set gives its columns (EMPTY: none); an ABSENT one gives every input
# column, which is what the planner passes a UDF with no read set. The tests and the bench take their
# read sets from here, so what the runtime is given is what the producer
# determined.

from komira_udf_spike_abi.contract import SHAPE_ROW
from komira_udf_spike_abi.runtime import UdfSpec
from komira_udf_spike_abi.values import ColumnType

comptime READ_SETS = "read_sets.tsv"
"""Where each test and the bench find golden/read_sets.tsv (staged here)."""


@fieldwise_init
struct ReadSetRow(Copyable, Movable):
    """One line of read_sets.tsv: a case's name, the function's entry, the input's
    columns, where the read set came from (columns, static, absent), whether
    a read set is present, the read set (every input column when absent:
    the UDF reads them all), what the sample run read, and the producer's
    note."""

    var name: String
    var entry: String
    var input: List[String]
    var source: String
    var present: Bool
    var read_set: List[String]
    var recorded: List[String]
    var note: String


def _names(csv: String) -> List[String]:
    var out = List[String]()
    if csv == "":
        return out^
    for part in csv.split(","):
        out.append(String(part))
    return out^


def load_read_sets(path: String = READ_SETS) raises -> List[ReadSetRow]:
    var text = String("")
    with open(path, "r") as f:
        text = f.read()
    var out = List[ReadSetRow]()
    for line in text.split("\n"):
        if String(line) == "":
            continue
        var f = line.split("\t")
        if len(f) != 7:
            raise Error("UDF_READ_SETS_MALFORMED: " + String(len(f)) + " fields in '" + String(line) + "'")
        var input = _names(String(f[2]))
        var read = String(f[4])
        var present = read != "absent"
        var names = input.copy()
        if present:
            if read.byte_length() < 2 or not read.startswith("[") or not read.endswith("]"):
                raise Error(
                    "UDF_READ_SETS_MALFORMED: read set '" + read + "' of " + String(f[0]) + " is neither absent nor [...]"
                )
            # The brackets are one byte each: a slice inside them is whole code points.
            names = _names(String(read[byte = 1 : read.byte_length() - 1]))
        out.append(
            ReadSetRow(
                String(f[0]), String(f[1]), input^, String(f[3]), present, names^, _names(String(f[5])), String(f[6]),
            )
        )
    return out^


def read_set_of(rows: List[ReadSetRow], name: String) raises -> ReadSetRow:
    """The line whose case is `name`."""
    for r in rows:
        if r.name == name:
            return r.copy()
    raise Error("UDF_READ_SET_MISSING: no case '" + name + "' in " + READ_SETS)


def row_spec(entry: String, read_set: List[String], arg_type: Int, result_type: Int) -> UdfSpec:
    """A ROW UdfSpec: one field of `arg_type` per read-set name, in order,
    and a nullable result of `result_type`."""
    var args = List[ColumnType]()
    for _ in range(len(read_set)):
        args.append(ColumnType(arg_type, True))
    var s = UdfSpec(SHAPE_ROW, entry, args^, [ColumnType(result_type, True)])
    s.arg_names = read_set.copy()
    return s^
