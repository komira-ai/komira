"""`DataFrame.explode` (komira) and `LazyFrame.explode` (komira.pl) as plans,
with no library: both skins are built over one stand-in `Session` whose file
schema, written here as the engine's `WireSchema` bytes, holds an int64 id, a
list<string> column `tags` (a nullable element), a list<int64> column `nums`
(a non-null element), a string column and a float64 column. Checked:

- the plan each skin builds is the `Unnest` node over the scan with
  keep_empty true, the same tree and the same plan bytes in both skins;
- the wire plan: the `unnest` arm names the column and keeps empty lists, and
  the output schema has the child's fields with the list field replaced in
  place by its element type, nullable because the node keeps empty and NULL
  lists as a NULL row;
- the order rules: a sorted frame stays sorted unless it is sorted by the
  exploded column;
- every refusal by class and full message: a column that is not a list, an
  unknown column, several columns, a list of columns, a non-bool
  ignore_index.

    explode_skins_test
"""

import os
import tempfile

import komira
import komira.pl as kpl
from komira import Session, _ops
from komira._errors import UnsupportedOperation
from komira._ops import SortKey, Unnest
from komira._plan import encode_plan
from komira._plan._wire import arrow_id, field, pb

PATH = os.path.join(tempfile.gettempdir(), "explode_skins.parquet")
TYPES = (
    ("id", "int64"),
    ("tags", "list<string>"),
    ("nums", "list<int64>"),
    ("name", "string"),
    ("score", "float64"),
)


def _wire_field(name, kind):
    if not kind.startswith("list<"):
        return field(name, arrow_id(kind), True)
    element = kind[5:-1]
    f = field(name, arrow_id("list"), True)
    f.child_names.append("item")
    f.child_type_ids.append(arrow_id(element))
    f.child_nullables.append(element == "string")
    return f


class StandIn(Session):
    def __init__(self):
        self.ran = []

    def _parquet_schema(self, path):
        return pb.WireSchema(fields=[_wire_field(n, t) for n, t in TYPES]).SerializeToString()

    def _plan_stream(self, plan):
        self.ran.append(plan)
        return "result"

    def close(self):
        pass


SESSION = StandIn()
# The scan the readers build, whatever type tokens they give the list columns.
SCAN = komira.read_parquet(PATH, session=SESSION)._plan


def pandas_frame():
    return komira.read_parquet(PATH, session=SESSION)


def polars_frame():
    return kpl.scan_parquet(PATH, session=SESSION)


def raised(call):
    try:
        call()
    except BaseException as e:  # each caller checks the exact type
        return e
    raise AssertionError("the call raised nothing")


def refuses(call, cls, message):
    e = raised(call)
    assert type(e) is cls and e.args[0] == message, repr(e)


def schema_of(frame):
    return list(frame._fields if isinstance(frame, komira.DataFrame) else frame._wire_fields())


def test_both_skins_build_the_unnest_node_with_keep_empty():
    expected = Unnest(SCAN, "tags", True)
    p = pandas_frame().explode("tags")
    q = polars_frame().explode("tags")
    assert p._plan == expected and q._plan == expected
    assert p.columns == q.columns == ["id", "tags", "nums", "name", "score"]
    assert p._plan_bytes() == q._encode()


def test_the_wire_plan_names_the_column_and_replaces_the_list_field_by_its_element():
    plan = encode_plan(Unnest(SCAN, "tags", True), {PATH: SESSION_SOURCE()}).plan
    assert plan.WhichOneof("node") == "unnest"
    assert plan.unnest.column == "tags" and plan.unnest.keep_empty is True
    assert [f.name for f in plan.output_schema.fields] == ["id", "tags", "nums", "name", "score"]
    tags = plan.output_schema.fields[1]
    assert (tags.arrow_type_id, tags.nullable, len(tags.child_type_ids)) == (arrow_id("string"), True, 0)
    assert plan.output_schema.fields[2].arrow_type_id == arrow_id("list")
    assert plan.output_schema.fields[0] == plan.unnest.child.output_schema.fields[0]


def test_the_element_is_nullable_when_empty_lists_are_kept_even_if_the_element_is_not():
    for frame in (pandas_frame().explode("nums"), polars_frame().explode("nums")):
        fields = schema_of(frame)
        nums = fields[2]
        assert (nums.name, nums.arrow_type_id, nums.nullable) == ("nums", arrow_id("int64"), True)
        assert fields[1].arrow_type_id == arrow_id("list")
    child = encode_plan(SCAN, {PATH: SESSION_SOURCE()}).plan
    assert child.output_schema.fields[2].child_nullables[0] is False
    dropped = encode_plan(Unnest(SCAN, "nums", False), {PATH: SESSION_SOURCE()}).plan
    assert dropped.output_schema.fields[2].nullable is False
    assert dropped.unnest.keep_empty is False
    kept = encode_plan(Unnest(SCAN, "tags", False), {PATH: SESSION_SOURCE()}).plan
    assert kept.output_schema.fields[1].nullable is True


def SESSION_SOURCE():
    return pandas_frame()._sources[PATH]


def test_a_frame_sorted_by_another_column_stays_sorted_and_by_the_column_does_not():
    keys = (SortKey("id"),)
    p = pandas_frame().sort_values("id").explode("tags")
    assert p._plan == _ops.Sort(Unnest(_ops.Sort(SCAN, keys), "tags", True), keys)
    q = polars_frame().sort("id").explode("tags")
    # polars sorts nulls first by default, so its key is not pandas' key.
    pl_keys = (SortKey("id", False, True),)
    assert q._order == pl_keys, q._order
    assert q._plan == _ops.Sort(Unnest(_ops.Sort(SCAN, pl_keys), "tags", True), pl_keys)
    by_list = pandas_frame().sort_values("tags").explode("tags")
    assert isinstance(by_list._plan, Unnest)
    by_list_pl = polars_frame().sort("tags").explode("tags")
    assert isinstance(by_list_pl._plan, Unnest) and by_list_pl._order is None


def test_ignore_index_is_accepted_and_changes_nothing():
    df = pandas_frame()
    assert df.explode("tags", ignore_index=True)._plan == df.explode("tags")._plan
    assert df.explode("tags", True)._plan == Unnest(SCAN, "tags", True)


def test_a_column_that_is_not_a_list_is_refused_by_its_dtype_in_both_skins():
    for build in (pandas_frame, polars_frame):
        refuses(
            lambda: build().explode("name"),
            UnsupportedOperation,
            "explode: column 'name' is string, not a list",
        )
        refuses(
            lambda: build().explode("id"),
            UnsupportedOperation,
            "explode: column 'id' is int64, not a list",
        )


def test_an_unknown_column_is_the_frames_unknown_column_error_in_both_skins():
    message = _ops.unknown_column("tag", tuple(n for n, _ in TYPES)).args[0]
    refuses(lambda: pandas_frame().explode("tag"), KeyError, message)
    refuses(lambda: polars_frame().explode("tag"), KeyError, message)


def test_more_than_one_column_is_refused_by_name():
    only_one = "explode: only one column, given by its name, is supported; explode the columns one after another"
    refuses(lambda: pandas_frame().explode(["tags", "nums"]), UnsupportedOperation, only_one)
    refuses(lambda: pandas_frame().explode(("tags",)), UnsupportedOperation, only_one)
    refuses(lambda: polars_frame().explode("tags", "nums"), UnsupportedOperation, only_one)
    refuses(lambda: polars_frame().explode(["tags"]), UnsupportedOperation, only_one)


def test_a_non_bool_ignore_index_is_a_type_error():
    refuses(
        lambda: pandas_frame().explode("tags", ignore_index=1),
        TypeError,
        "explode ignore_index must be a bool, not int",
    )


def main():
    tests = [
        value
        for name, value in list(globals().items())
        if name.startswith("test_") and callable(value) and value.__module__ == __name__
    ]
    for test in tests:
        test()
    print(f"test_explode_skins: {len(tests)} tests passed")


if __name__ == "__main__":
    main()
