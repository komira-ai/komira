"""The worker's Arrow IPC codec (pyworker/kudf_ipc.py) against pyarrow.

What it proves, and the defect each part catches:
  - read_schema maps every type the engine's writer can name (int and uint
    of 8 to 64 bits, half, single and double floats, null, binary, utf8,
    bool) to its C Data format, with the field's name and nullability, from
    schemas pyarrow wrote (its flatbuffers are laid out back to front, with
    shared vtables and defaults left out, unlike ours), and a type outside
    that set to "?<type id>"; the size it reports is the message's (a wrong
    entry in the type tables, a field read at the wrong id);
  - read_batch reads batches pyarrow wrote, one and two columns, with and
    without nulls, sliced, 0 to 1000 rows: every value and every validity
    bit at the positions it returns (an offset taken from the wrong buffer,
    a validity bitmap given where there are no nulls);
  - every check of read_batch and of the message frame refuses a copy of a
    good message with exactly that defect, with its reason, and the reason
    is the expected one (a check deleted or loosened: the worker reads an
    engine message past its end). The flatbuffer is patched by this file's
    own reader, not by the code under test;
  - BatchWriter's messages, written at offset 0 and inside a buffer, are
    read back by pyarrow with every value and null (a field patched at the
    wrong place, a layout that pyarrow rejects), and a one-column batch
    with nulls is byte for byte the engine-side writer's;
  - tests/ipc_golden.txt, the engine-side writer's bytes (native/ipc_codec.c,
    pinned by native/probe_codec.c): pyarrow reads every schema with its
    type, name and nullability, and every batch with its values and nulls
    (the golden bytes are a correct encoding, so a writer change that
    breaks them is caught on the engine side).

Mutants planted (the sweep in the pull request ran every operator mutant
of kudf_ipc.py against this file): read_batch without the compressed check,
and BatchWriter.write writing the validity length when there are no nulls:
each red here.
"""

import os
import struct
import sys

import numpy as np
import pyarrow as pa

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "pyworker"))
import kudf_ipc  # noqa: E402

FAILURES = []


def check(cond, what):
    if not cond:
        FAILURES.append(what)


# ---- an independent flatbuffer reader, for finding what to patch -------------


def u16(b, at):
    return struct.unpack_from("<H", b, at)[0]


def u32(b, at):
    return struct.unpack_from("<I", b, at)[0]


def i32(b, at):
    return struct.unpack_from("<i", b, at)[0]


def root(b):
    return 8 + u32(b, 8)


def vtable(b, t):
    return t - i32(b, t)


def slot(b, t, fid):
    """The vtable entry's position for field `fid` of the table at `t`, or
    None when the vtable is too short."""
    v = vtable(b, t)
    s = v + 4 + 2 * fid
    return s if 4 + 2 * fid + 2 <= u16(b, v) else None


def pos(b, t, fid):
    s = slot(b, t, fid)
    if s is None or u16(b, s) == 0:
        return None
    return t + u16(b, s)


def deref(b, at):
    return at + u32(b, at)


def header(b):
    return deref(b, pos(b, root(b), 2))


def vector(b, t, fid):
    v = deref(b, pos(b, t, fid))
    return v, u32(b, v)


def patched(b, at, fmt, value):
    c = bytearray(b)
    struct.pack_into(fmt, c, at, value)
    return c


def refused(name, fn, want):
    try:
        fn()
    except kudf_ipc.IpcError as exc:
        check(want in str(exc), "{}: refused with '{}', not '{}'".format(name, exc, want))
        return
    except Exception as exc:  # noqa: BLE001
        FAILURES.append("{}: {} instead of IpcError '{}'".format(name, type(exc).__name__, want))
        return
    FAILURES.append("{}: read, not refused ('{}')".format(name, want))


# ---- schemas -------------------------------------------------------------------

TYPES = [
    (pa.int8(), "c"),
    (pa.uint8(), "C"),
    (pa.int16(), "s"),
    (pa.uint16(), "S"),
    (pa.int32(), "i"),
    (pa.uint32(), "I"),
    (pa.int64(), "l"),
    (pa.uint64(), "L"),
    (pa.float16(), "e"),
    (pa.float32(), "f"),
    (pa.float64(), "g"),
    (pa.null(), "n"),
    (pa.binary(), "z"),
    (pa.string(), "u"),
    (pa.bool_(), "b"),
]


def schema_cases():
    for i, (t, fmt) in enumerate(TYPES):
        for nullable in (True, False) if t != pa.null() else (True,):
            name = "f{}_{}".format(i, "n" if nullable else "r")
            msg = pa.schema([pa.field(name, t, nullable)]).serialize().to_pybytes()
            buf = b"\0" * 24 + msg + b"\0" * 16  # not at offset 0, not alone
            fields, used = kudf_ipc.read_schema(buf, 24, len(msg))
            check(fields == [(name, fmt, nullable)],
                  "schema {}: {} read as {}".format(t, fmt, fields))
            check(used == len(msg), "schema {}: {} bytes used of {}".format(t, used, len(msg)))
    # several fields, in order
    s = pa.schema([("a", pa.int64()), ("bb", pa.float64(), False), ("", pa.int32())])
    msg = s.serialize().to_pybytes()
    fields, _ = kudf_ipc.read_schema(msg, 0, len(msg))
    check(fields == [("a", "l", True), ("bb", "g", False), ("", "i", True)], "three fields: {}".format(fields))
    # types outside the set: "?<Type union id>"
    for t, tid in ((pa.date32(), 8), (pa.timestamp("us"), 10), (pa.list_(pa.int64()), 12), (pa.decimal128(5, 2), 7)):
        msg = pa.schema([("x", t)]).serialize().to_pybytes()
        fields, _ = kudf_ipc.read_schema(msg, 0, len(msg))
        check(fields == [("x", "?{}".format(tid), True)], "type {}: {}".format(t, fields))
    # a record batch is not a schema
    rb = pa.record_batch([pa.array([1, 2], pa.int64())], names=["x"]).serialize().to_pybytes()
    refused("schema_of_batch", lambda: kudf_ipc.read_schema(rb, 0, len(rb)), "the message is not a schema")
    # a field name past the metadata
    msg = pa.schema([("name", pa.int64())]).serialize().to_pybytes()
    fv, n = vector(msg, header(msg), 1)
    field = deref(msg, fv + 4)
    name = deref(msg, pos(msg, field, 0))
    refused("name_past_end", lambda: kudf_ipc.read_schema(patched(msg, name, "<I", 1 << 20), 0, len(msg)),
            "runs past the metadata")


# ---- batches -------------------------------------------------------------------


def column(buf, length, col, dtype):
    voff, valid_at, nulls = col
    vals = np.frombuffer(buf, dtype=dtype, count=length, offset=voff) if length else np.zeros(0, dtype)
    if valid_at is None:
        return list(vals), None
    bits = [(buf[valid_at + (i >> 3)] >> (i & 7)) & 1 for i in range(length)]
    return list(vals), bits


def batch_cases():
    rng = np.random.default_rng(7)
    for n in (0, 1, 7, 8, 9, 100, 1000):
        for with_nulls in (False, True):
            xs = rng.integers(-(1 << 40), 1 << 40, n)
            ys = rng.random(n)
            mask = rng.random(n) < 0.3 if with_nulls else None
            a = pa.array(xs, pa.int64(), mask=mask)
            b = pa.array(ys, pa.float64(), mask=None if mask is None else ~mask)
            for name, batch in (("whole", pa.record_batch([a, b], names=["x", "y"])),
                                ("sliced", pa.record_batch([a, b], names=["x", "y"]).slice(min(n, 3)))):
                msg = batch.serialize().to_pybytes()
                buf = b"\0" * 40 + msg
                length, cols = kudf_ipc.read_batch(buf, 40, len(msg), [8, 8])
                what = "batch n={} nulls={} {}".format(n, with_nulls, name)
                check(length == batch.num_rows, what + ": length {}".format(length))
                for k, (col, dtype) in enumerate(((cols[0], np.int64), (cols[1], np.float64))):
                    arr = batch.column(k)
                    vals, bits = column(buf, length, col, dtype)
                    check(col[2] == arr.null_count, what + ": col {} null count {}".format(k, col[2]))
                    check((bits is None) == (arr.null_count == 0), what + ": col {} validity given".format(k))
                    for i in range(length):
                        valid = arr[i].is_valid
                        if bits is not None:
                            check(bits[i] == valid, what + ": col {} row {} validity".format(k, i))
                        if valid:
                            check(vals[i] == arr[i].as_py(), what + ": col {} row {} value".format(k, i))


def good_batch():
    a = pa.array([10, None, 30, 40, 50, 60, 70, 80, 90, 100], pa.int64())
    return pa.record_batch([a], names=["x"]).serialize().to_pybytes()


def batch_refusals():
    msg = good_batch()
    L = len(msg)
    meta = i32(msg, 4)
    rd = lambda m, lim=None, w=(8,): kudf_ipc.read_batch(m, 0, L if lim is None else lim, list(w))  # noqa: E731
    length, cols = rd(msg)
    check(length == 10 and cols[0][2] == 1, "the good batch reads: {} {}".format(length, cols))
    m = root(msg)
    h = header(msg)
    nodes, _ = vector(msg, h, 1)
    bufs, nb = vector(msg, h, 2)
    # the frame
    refused("short_prefix", lambda: rd(msg, 7), "shorter than its prefix")
    refused("continuation", lambda: rd(patched(msg, 0, "<I", 0xFFFFFFFE)), "continuation marker")
    refused("meta_zero", lambda: rd(patched(msg, 4, "<i", 0)), "metadata length outside")
    refused("meta_negative", lambda: rd(patched(msg, 4, "<i", -8)), "metadata length outside")
    refused("meta_unaligned", lambda: rd(patched(msg, 4, "<i", meta - 4)), "metadata length outside")
    refused("meta_past", lambda: rd(msg, 8 + meta - 8), "metadata length outside")
    check(rd(msg, 8 + meta + (L - 8 - meta))[0] == 10, "the exact limit reads")
    refused("version_v4", lambda: rd(patched(msg, pos(msg, m, 0), "<h", 3)), "not metadata version V5")
    refused("version_absent", lambda: rd(patched(msg, slot(msg, m, 0), "<H", 0)), "not metadata version V5")
    refused("header_type_schema", lambda: rd(patched(msg, pos(msg, m, 1), "<B", 1)), "not a record batch")
    refused("header_type_absent", lambda: rd(patched(msg, slot(msg, m, 1), "<H", 0)), "not a record batch")
    refused("header_absent", lambda: rd(patched(msg, slot(msg, m, 2), "<H", 0)), "a message without a header")
    refused("body_past", lambda: rd(msg, L - 1), "the body runs past the message")
    refused("body_negative", lambda: rd(patched(msg, pos(msg, m, 3), "<q", -64)), "the body runs past the message")
    refused("root_past", lambda: rd(patched(msg, 8, "<I", meta + 4)), "runs past the metadata")
    vt = vtable(msg, m)
    refused("field_past_table", lambda: rd(patched(msg, slot(msg, m, 3), "<H", u16(msg, vt + 2))),
            "a field offset past its table")
    refused("nodes_past", lambda: rd(patched(msg, nodes, "<I", 1 << 20)), "runs past the metadata")
    # the record batch
    refused("columns", lambda: rd(msg, None, (8, 8)), "1 columns and 2 buffers; the schema has 2 columns")
    refused("buffers", lambda: rd(patched(msg, bufs, "<I", 1)), "1 columns and 1 buffers")
    lp = pos(msg, h, 0)
    refused("negative_length", lambda: rd(patched(msg, lp, "<q", -1)), "a negative batch length")
    refused("node_length", lambda: rd(patched(msg, nodes + 4, "<q", 9)), "column 0 has 9 rows, the batch 10")
    refused("nulls_negative", lambda: rd(patched(msg, nodes + 12, "<q", -1)), "null count outside")
    refused("nulls_over", lambda: rd(patched(msg, nodes + 12, "<q", 11)), "null count outside")
    check(rd(patched(msg, nodes + 12, "<q", 10))[1][0][2] == 10, "a null count equal to the length reads")
    b0 = bufs + 4  # validity {offset, length}, then values
    body = L - 8 - meta
    refused("validity_offset_negative", lambda: rd(patched(msg, b0, "<q", -1)), "a buffer runs past the body")
    refused("validity_length_negative", lambda: rd(patched(msg, b0 + 8, "<q", -1)), "a buffer runs past the body")
    refused("values_offset_negative", lambda: rd(patched(msg, b0 + 16, "<q", -1)), "a buffer runs past the body")
    refused("values_length_negative", lambda: rd(patched(msg, b0 + 24, "<q", -1)), "a buffer runs past the body")
    vo = struct.unpack_from("<q", msg, b0 + 16)[0]
    refused("values_past_body", lambda: rd(patched(msg, b0 + 24, "<q", body - vo + 1)), "a buffer runs past the body")
    check(rd(patched(msg, b0 + 24, "<q", body - vo))[0] == 10, "a values buffer to the body's end reads")
    refused("values_short", lambda: rd(patched(msg, b0 + 24, "<q", 79)), "values buffer is shorter than its rows")
    check(rd(patched(msg, b0 + 24, "<q", 80))[0] == 10, "a values buffer of exactly the rows reads")
    refused("validity_short", lambda: rd(patched(msg, b0 + 8, "<q", 1)), "validity bitmap is shorter than its rows")
    check(rd(patched(msg, b0 + 8, "<q", 2))[0] == 10, "a validity bitmap of exactly the rows reads")
    nn = patched(patched(msg, nodes + 12, "<q", 0), b0 + 8, "<q", 0)
    check(rd(nn)[1][0][1] is None, "no nulls: no validity, whatever its length")
    # compression, as pyarrow writes it in a stream
    for codec in ("lz4", "zstd"):
        rb = pa.record_batch([pa.array(list(range(100)), pa.int64())], names=["x"])
        try:
            sink = pa.BufferOutputStream()
            with pa.ipc.new_stream(sink, rb.schema, options=pa.ipc.IpcWriteOptions(compression=codec)) as w:
                w.write_batch(rb)
        except Exception:  # noqa: BLE001 (this pyarrow build lacks the codec)
            continue
        s = sink.getvalue().to_pybytes()
        at = 8 + i32(s, 4)  # past the schema message (it has no body)
        refused("compressed_" + codec, lambda: kudf_ipc.read_batch(s, at, len(s) - at - 8, [8]),
                "a compressed record batch")
        break
    else:
        FAILURES.append("no compression codec in pyarrow")


# ---- the writer -----------------------------------------------------------------


def writer_cases():
    w = kudf_ipc.BatchWriter()
    rng = np.random.default_rng(11)
    for n in (0, 1, 7, 8, 9, 63, 64, 65, 1000):
        for nulls_on in (False, True):
            _, voff, body = kudf_ipc.BatchWriter.layout(n, 8)
            check(voff % 64 == 0 and voff >= (n + 7) // 8, "layout {}: values at {}".format(n, voff))
            check(body % 64 == 0 and body >= voff + 8 * n, "layout {}: body {}".format(n, body))
            for at in (0, 64):
                vals = rng.integers(-(1 << 50), 1 << 50, n)
                valid = rng.random(n) >= 0.25 if nulls_on else np.ones(n, bool)
                nulls = int((~valid).sum())
                dst = bytearray(at + w.head + body)
                bits = np.packbits(valid, bitorder="little").tobytes()
                dst[at + w.head : at + w.head + len(bits)] = bits
                dst[at + w.head + voff : at + w.head + voff + 8 * n] = vals.astype("<i8").tobytes()
                size = w.write(dst, at, n, 8, nulls)
                what = "writer n={} nulls={} at={}".format(n, nulls, at)
                check(size == w.head + body, what + ": size {}".format(size))
                check(bytes(dst[:at]) == bytes(at), what + ": wrote before its offset")
                msg = pa.ipc.read_message(pa.py_buffer(bytes(dst[at : at + size])))
                got = pa.ipc.read_record_batch(msg, pa.schema([("result", pa.int64())]))
                col = got.column(0)
                check(got.num_rows == n and col.null_count == nulls, what + ": {} rows {} nulls".format(
                    got.num_rows, col.null_count))
                for i in range(min(n, got.num_rows)):
                    check(col[i].is_valid == bool(valid[i]), what + ": row {} validity".format(i))
                    if valid[i] and col[i].is_valid:
                        check(col[i].as_py() == int(vals[i]), what + ": row {} value".format(i))
                bl = struct.unpack_from("<q", dst, at + w.at_body_len)[0]
                check(bl == body, what + ": bodyLength {}".format(bl))


# ---- the engine-side writer's messages (tests/ipc_golden.txt) --------------

FMT_TYPES = {
    "c": pa.int8(), "C": pa.uint8(), "s": pa.int16(), "S": pa.uint16(), "i": pa.int32(), "I": pa.uint32(),
    "l": pa.int64(), "L": pa.uint64(), "e": pa.float16(), "f": pa.float32(), "g": pa.float64(),
    "n": pa.null(), "b": pa.bool_(), "u": pa.string(), "z": pa.binary(),
}


def golden():
    out = {}
    with open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "ipc_golden.txt")) as f:
        for line in f:
            if line.startswith("#") or not line.strip():
                continue
            name, hexs = line.split()
            out[name] = bytes.fromhex(hexs)
    return out


def fixture_value(fmt, p):
    """native/probe_codec.c, fill_values."""
    if fmt == "c":
        return ((3 * p - 20 + 128) % 256) - 128
    if fmt == "s":
        return ((301 * p - 1000 + 32768) % 65536) - 32768
    if fmt == "i":
        return 70001 * p - 50
    if fmt == "l":
        return 1000 + 7 * p
    return p * 0.5 - 1.25


def fixture_valid(p):
    return (p * 5) % 7 != 3


def check_batch(name, msg, n, cols):
    """cols: [(fmt, offset, mode)], mode as probe_codec.c's colfx."""
    schema = pa.schema([("c{}".format(k), FMT_TYPES[f]) for k, (f, _, _) in enumerate(cols)])
    try:
        got = pa.ipc.read_record_batch(pa.ipc.read_message(pa.py_buffer(msg)), schema)
    except Exception as exc:  # noqa: BLE001
        FAILURES.append("{}: pyarrow refused it: {}".format(name, exc))
        return
    check(got.num_rows == n, "{}: {} rows".format(name, got.num_rows))
    for k, (fmt, off, mode) in enumerate(cols):
        col = got.column(k)
        nulls = 0
        for i in range(min(n, got.num_rows)):
            p = off + i
            valid = mode in (0, 3) or fixture_valid(p)
            nulls += not valid
            check(col[i].is_valid == valid, "{}: col {} row {} validity".format(name, k, i))
            if valid and col[i].is_valid:
                check(col[i].as_py() == fixture_value(fmt, p), "{}: col {} row {} value {}".format(
                    name, k, i, col[i].as_py()))
        check(col.null_count == nulls, "{}: col {} null count {}".format(name, k, col.null_count))
        # no bitmap when there are no nulls (the writer leaves it out)
        check((col.buffers()[0] is None) == (nulls == 0), "{}: col {} bitmap given".format(name, k))


def golden_cases():
    g = golden()
    check(len(g) == 52, "golden messages: {}".format(len(g)))
    for fmt, typ in FMT_TYPES.items():
        for nl in (0, 1):
            name = "S_{}_{}".format(fmt, nl)
            m = g.get(name, b"")
            fields, used = kudf_ipc.read_schema(m, 0, len(m))
            check(fields == [("f", fmt, bool(nl))] and used == len(m), "{}: kudf_ipc read {}".format(name, fields))
            s = pa.ipc.read_schema(pa.ipc.read_message(pa.py_buffer(m)))
            check(len(s) == 1 and s[0].name == "f" and s[0].type == typ, "{}: pyarrow read {}".format(name, s))
            if fmt != "n":  # pyarrow takes every null-type field as nullable
                check(s[0].nullable == bool(nl), "{}: pyarrow nullability".format(name))
    three = g.get("S_three", b"")
    s = pa.ipc.read_schema(pa.ipc.read_message(pa.py_buffer(three)))
    check([(f.name, f.type, f.nullable) for f in s] == [("a", pa.int64(), True), ("bb", pa.float64(), False),
                                                       ("", pa.int32(), True)], "S_three: {}".format(s))
    both = g.get("S_three_then_result", b"")
    check(both.startswith(three), "S_three_then_result: the second schema is appended")
    rest = both[len(three):]
    s = pa.ipc.read_schema(pa.ipc.read_message(pa.py_buffer(rest)))
    check([(f.name, f.type, f.nullable) for f in s] == [("result", pa.float64(), True)], "the second schema: {}".format(s))
    w = kudf_ipc.BatchWriter()
    for n in (0, 1, 9, 64):
        for mode, label in enumerate(("none", "given", "counted", "allvalid")):
            name = "B1_{}_{}".format(n, label)
            msg = g.get(name, b"")
            check_batch(name, msg, n, [("l", 0, mode)])
            nulls = sum(1 for p in range(n) if not fixture_valid(p)) if mode in (1, 2) else 0
            if nulls:
                # the worker's writer lays out a one-column batch with nulls
                # exactly as the engine's does
                _, voff, body = kudf_ipc.BatchWriter.layout(n, 8)
                dst = bytearray(w.head + body)
                bits = np.packbits([fixture_valid(p) for p in range(n)], bitorder="little").tobytes()
                dst[w.head : w.head + len(bits)] = bits
                vals = np.array([fixture_value("l", p) for p in range(n)], dtype="<i8").tobytes()
                dst[w.head + voff : w.head + voff + 8 * n] = vals
                size = w.write(dst, 0, n, 8, nulls)
                check(bytes(dst[:size]) == msg, "{}: BatchWriter's bytes differ from the engine's".format(name))
    check_batch("B1_21_sliced13", g.get("B1_21_sliced13", b""), 21, [("l", 13, 2)])
    check_batch("B4_13_mixed", g.get("B4_13_mixed", b""), 13, [("c", 3, 0), ("s", 5, 1), ("i", 0, 2), ("g", 1, 1)])
    check_batch("B3_13_wide", g.get("B3_13_wide", b""), 13, [("l", 0, 0), ("l", 2, 1), ("c", 0, 2)])
    check_batch("B64_3_columns", g.get("B64_3_columns", b""), 3, [("c", k % 5, k % 3) for k in range(64)])


def run_all():
    golden_cases()
    schema_cases()
    batch_cases()
    batch_refusals()
    writer_cases()
    return FAILURES


if __name__ == "__main__":
    failures = run_all()
    for f in failures[:40]:
        print("FAIL", f)
    if failures:
        raise SystemExit("test_kudf_ipc: {} failures".format(len(failures)))
    print("test_kudf_ipc: ok")
