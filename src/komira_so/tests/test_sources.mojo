# The source and render operations behind the C surface, on values.
#
# Rows: register_parquet adds a table (found by name without regard to case)
# whose schema is the footer's, and a missing file or a file that is not
# Parquet is refused with nothing registered; parquet_schema_bytes carries the
# footer's column names; csv_binding_bytes names the path and the CSV kind, and
# changes with each of delimiter, header and all_varchar; json_binding_bytes
# names the path and the JSON kind; a missing file is refused by both; a plan
# is rendered as the text of its scan (the binding's name, kind and path), and bytes that are not a plan are
# refused.
from std.testing import assert_equal, assert_false, assert_true

from komira_runtime_paths import test_tmpdir

from komira_so import (
    Session,
    csv_binding_bytes,
    json_binding_bytes,
    parquet_schema_bytes,
    plan_render_text,
    register_parquet,
)

comptime PARQUET = "src/komira_so/tests/fixtures/two_columns.parquet"
# A serialized plan: one scan of "/data/orders.orc" (the plan wire's frozen
# scan example).
comptime SCAN_PLAN_HEX = "080412a903124c0a200a0161100518052000280030003a00400450005a04756e6974620563656e74730a130a0162100518052001280030003a00400450000a130a0173100d18002001280030003a004004500022d8020af90112f60108c0c2d2f703120a6b6f6d6972612e6f72631a066f7264657273221b0a0a6861735f666f6f74657210051a00200129000000000000000022250a047061746810011a102f646174612f6f72646572732e6f72632000290000000000000000221d0a0c7374726970655f636f756e7410021a0020072900000000000000002a4c0a200a0161100518052000280030003a00400450005a04756e6974620563656e74730a130a0162100518052001280030003a00400450000a130a0173100d18002001280030003a004004500030effdb6f50d38cef5b7f70f420a0803103f180120012801500258d285d8cc04600180010068007008780010011a4c0a200a0161100518052000280030003a00400450005a04756e6974620563656e74730a130a0162100518052001280030003a00400450000a130a0173100d18002001280030003a0040045000200030004000480050015800"


def _contains(haystack: List[UInt8], needle: String) -> Bool:
    var nb = needle.as_bytes()
    var n = len(nb)
    if n == 0:
        return True
    if len(haystack) < n:
        return False
    for i in range(len(haystack) - n + 1):
        var ok = True
        for j in range(n):
            if haystack[i + j] != nb[j]:
                ok = False
                break
        if ok:
            return True
    return False


def _hex_value(c: UInt8) -> Int:
    if c >= UInt8(ord("0")) and c <= UInt8(ord("9")):
        return Int(c) - ord("0")
    return Int(c) - ord("a") + 10


def _from_hex(hex: String) -> List[UInt8]:
    var b = hex.as_bytes()
    var out = List[UInt8]()
    var i = 0
    while i + 1 < len(b):
        out.append(UInt8(_hex_value(b[i]) * 16 + _hex_value(b[i + 1])))
        i += 2
    return out^


def _write(name: String, text: String) raises -> String:
    var path = test_tmpdir() + "/" + name
    with open(path, "w") as f:
        f.write(text)
    return path^


def test_register_parquet() raises:
    var s = Session()
    assert_false(s.catalog.has("t"))
    register_parquet(s, String("Two"), String(PARQUET))
    assert_true(s.catalog.has("two"))
    assert_true(s.catalog.has("TWO"))
    assert_false(s.catalog.has("other"))
    var schema = s.catalog.schema_of("two")
    assert_equal(schema.num_columns(), 2)
    assert_equal(schema.field_at_unchecked(0).name, String("i64"))
    assert_equal(schema.field_at_unchecked(1).name, String("s"))


def test_register_parquet_refusals() raises:
    var s = Session()
    var raised = False
    try:
        register_parquet(s, String("gone"), String("/no/such/file.parquet"))
    except:
        raised = True
    assert_true(raised)
    assert_false(s.catalog.has("gone"))
    var notpq = _write(String("not_parquet.parquet"), String("this is text"))
    raised = False
    try:
        register_parquet(s, String("text"), notpq)
    except:
        raised = True
    assert_true(raised)
    assert_false(s.catalog.has("text"))


def test_parquet_schema_bytes() raises:
    var bytes = parquet_schema_bytes(String(PARQUET))
    assert_true(len(bytes) > 0)
    assert_true(_contains(bytes, String("i64")))
    var raised = False
    try:
        _ = parquet_schema_bytes(String("/no/such/file.parquet"))
    except:
        raised = True
    assert_true(raised)


def test_csv_binding() raises:
    var path = _write(String("t.csv"), String("a,b\n1,x\n2,y\n"))
    var base = csv_binding_bytes(path, UInt8(ord(",")), True, False)
    assert_true(len(base) > 0)
    assert_true(_contains(base, path))
    assert_true(_contains(base, String("komira.csv")))
    var again = csv_binding_bytes(path, UInt8(ord(",")), True, False)
    assert_true(again == base)
    # Each option changes what the cells mean, so each changes the bytes.
    assert_false(csv_binding_bytes(path, UInt8(ord(";")), True, False) == base)
    assert_false(csv_binding_bytes(path, UInt8(ord(",")), False, False) == base)
    assert_false(csv_binding_bytes(path, UInt8(ord(",")), True, True) == base)


def test_csv_binding_missing_file() raises:
    var raised = False
    try:
        _ = csv_binding_bytes(
            String("/no/such/file.csv"), UInt8(ord(",")), True, False
        )
    except:
        raised = True
    assert_true(raised)


def test_json_binding() raises:
    var path = _write(
        String("t.jsonl"), String('{"a":1,"b":"x"}\n{"a":2,"b":"y"}\n')
    )
    var bytes = json_binding_bytes(path)
    assert_true(len(bytes) > 0)
    assert_true(_contains(bytes, path))
    assert_true(_contains(bytes, String("komira.json")))
    var raised = False
    try:
        _ = json_binding_bytes(String("/no/such/file.jsonl"))
    except:
        raised = True
    assert_true(raised)


def test_plan_render() raises:
    var text = plan_render_text(_from_hex(String(SCAN_PLAN_HEX)))
    assert_true(text.startswith('Scan(path="orders"'))
    assert_true("komira.orc(orders" in text)
    assert_true("path=/data/orders.orc" in text)


def test_plan_render_refuses_garbage() raises:
    var raised = False
    var garbage = List[UInt8]()
    garbage.append(UInt8(0xFF))
    garbage.append(UInt8(0xFF))
    garbage.append(UInt8(0xFF))
    try:
        _ = plan_render_text(garbage^)
    except:
        raised = True
    assert_true(raised)


def main() raises:
    test_register_parquet()
    test_register_parquet_refusals()
    test_parquet_schema_bytes()
    test_csv_binding()
    test_csv_binding_missing_file()
    test_json_binding()
    test_plan_render()
    test_plan_render_refuses_garbage()
    print("OK")
