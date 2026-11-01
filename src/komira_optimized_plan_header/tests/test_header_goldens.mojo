# =============================================================================
# test_header_goldens.mojo
# =============================================================================
#
# komira_plan_proto's protoc goldens through the header codec (BUCK
# `test_data`, exported by komira_plan_proto):
#
#   optimized_plan.canonical.hex   protoc's encoding of the full golden
#   optimized_plan.hex             komira_plan_proto's generated encoding of it
#   optimized_plan_undeclared_write_format.canonical.hex
#                                  protoc's bytes of a header whose
#                                  write_target.format is 9
#
# What each test proves, and the defect it catches:
#   test_golden_decodes_and_reencodes: the header codec reads protoc's bytes
#     with every header field at protoc's number and value, keeps the body as
#     the exact bytes protoc wrote, and writes the committed `.hex`; decoding
#     the `.hex` and writing it again changes nothing. Catches a walk that
#     refuses a field version 1 includes (a dropped `_rule` row), a body that
#     is parsed or altered, and an encoder that moves a field.
#   test_golden_admitted: the golden passes steps 1-3 and step 4 with an empty
#     revocation set. Catches a check that refuses a valid header.
#   test_undeclared_write_format_refused: protoc's hostile fixture is refused
#     as an understated version, by name. Catches a walk that does not bound
#     enum values (proto3 enums are open, so the generated decoder keeps 9).
# =============================================================================

from std.pathlib import Path
from std.testing import assert_equal, assert_true

from komira_optimized_plan_header import (
    OPTIMIZED_PLAN_VERSION_UNSUPPORTED,
    admit_optimized_plan_header,
    check_optimized_plan_contract,
    decode_optimized_plan_header,
    encode_optimized_plan_header,
)

comptime _DIR = "fixtures/"
comptime _ENGINE = "4f6fc603903c936efd5359e7a42e103bca318df0614edf6b1f2c42136e453bc4"
comptime _CONFIG = "855aecc8f75deb62975c54b0f6a2d45a69ffdc2b61a1ac8c87d93aaf68dba733"
comptime _PLAN_DIGEST = "fb1a3aa0dec14c3496723edfebcada34a04f48742bd0de5e689a144598708521"
comptime _RECURRING = "ecd896d689e243225a2fd149fe8707cba3c43c9a64793b88d9102e8cde115aa5"
# The golden's body, an OptimizedPlanBody, as protoc wrote it.
comptime _BODY = "0a05920102084d120a084d12068a01030a0176"


def _nibble(c: Int) raises -> Int:
    if c >= 48 and c <= 57:
        return c - 48
    if c >= 97 and c <= 102:
        return c - 87
    raise Error("not a lower-case hex digit: " + chr(c))


def _read(path: String) raises -> List[UInt8]:
    """The fixture hex format: two digits a byte, whitespace ignored."""
    var out = List[UInt8]()
    var high = -1
    for b in Path(path).read_text().as_bytes():
        var c = Int(b)
        if c == 32 or c == 10 or c == 13 or c == 9:
            continue
        if high < 0:
            high = _nibble(c)
        else:
            out.append(UInt8(high * 16 + _nibble(c)))
            high = -1
    return out^


def _hex(b: List[UInt8]) -> String:
    comptime digits = "0123456789abcdef"
    var out = String("")
    for i in range(len(b)):
        var v = Int(b[i])
        out += String(digits[byte = v >> 4]) + String(digits[byte = v & 15])
    return out


def test_golden_decodes_and_reencodes() raises:
    var h = decode_optimized_plan_header(_read(_DIR + "optimized_plan.canonical.hex"))
    assert_equal(h.format_version, UInt32(1), "format_version")
    ref p = h.producer.value()
    assert_equal(_hex(p.engine_build), _ENGINE, "producer.engine_build")
    assert_equal(p.optimizer_contract_version, UInt32(1), "producer.optimizer_contract_version")
    assert_equal(_hex(p.optimizer_config_digest), _CONFIG, "producer.optimizer_config_digest")
    assert_equal(p.kind, "komira/python-sdk", "producer.kind")
    assert_equal(_hex(h.plan_digest), _PLAN_DIGEST, "plan_digest")
    assert_equal(_hex(h.recurring_signature), _RECURRING, "recurring_signature")
    ref n = h.needs.value()
    assert_equal(len(n.data_scopes), 2, "needs.data_scopes: count")
    assert_equal(n.data_scopes[0], "orders", "needs.data_scopes[0]")
    assert_equal(n.data_scopes[1], "customers", "needs.data_scopes[1]")
    assert_true(n.unbounded, "needs.unbounded")
    assert_equal(len(n.runtimes), 2, "needs.runtimes: count")
    assert_equal(n.runtimes[0].runtime, "komira/node", "needs.runtimes[0].runtime")
    assert_equal(n.runtimes[0].runtime_abi, "node22", "needs.runtimes[0].runtime_abi")
    assert_equal(n.runtimes[1].runtime, "komira/python", "needs.runtimes[1].runtime")
    assert_equal(n.runtimes[1].runtime_abi, "cp312", "needs.runtimes[1].runtime_abi")
    ref w = h.write_target.value()
    assert_equal(w.path, "out/orders/", "write_target.path")
    assert_equal(w.format.number(), 1, "write_target.format (WFMT_PARQUET)")
    assert_equal(w.codec.number(), 3, "write_target.codec (WCOMP_ZSTD)")
    ref a = h.advice.value()
    assert_equal(len(a.stats_basis), 2, "advice.stats_basis: count")
    assert_equal(a.stats_basis[0].pin_index, UInt32(0), "advice.stats_basis[0].pin_index")
    assert_equal(a.stats_basis[0].row_count, UInt64(150000), "advice.stats_basis[0].row_count")
    assert_equal(a.stats_basis[1].pin_index, UInt32(1), "advice.stats_basis[1].pin_index")
    assert_equal(a.stats_basis[1].row_count, UInt64(6001215), "advice.stats_basis[1].row_count")
    assert_equal(_hex(h.body), _BODY, "body: the bytes protoc wrote, unparsed")

    var committed = _read(_DIR + "optimized_plan.hex")
    assert_equal(_hex(encode_optimized_plan_header(h)), _hex(committed), "encode: the committed .hex")
    var again = encode_optimized_plan_header(decode_optimized_plan_header(committed.copy()))
    assert_equal(_hex(again), _hex(committed), "decoding and re-encoding the committed .hex changes it")


def test_golden_admitted() raises:
    var h = admit_optimized_plan_header(_read(_DIR + "optimized_plan.canonical.hex"), List[List[UInt8]]())
    check_optimized_plan_contract(h)
    assert_equal(_hex(h.body), _BODY, "the admitted header's body")


def test_undeclared_write_format_refused() raises:
    var refused = False
    try:
        _ = decode_optimized_plan_header(_read(_DIR + "optimized_plan_undeclared_write_format.canonical.hex"))
    except e:
        refused = True
        var text = String(e)
        assert_true(text.startswith(OPTIMIZED_PLAN_VERSION_UNSUPPORTED + ":"), text)
        assert_true("the format value 9" in text, text)
    assert_true(refused, "a header with write_target.format 9 decoded")


def main() raises:
    test_golden_decodes_and_reencodes()
    test_golden_admitted()
    test_undeclared_write_format_refused()
    print("the optimized_plan goldens read, written and admitted through the header codec")
