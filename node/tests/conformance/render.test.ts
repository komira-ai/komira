// render.ts: apache-arrow Tables written as the SQL conformance corpus writes
// DuckDB's answers. Each expected spelling here is the pinned DuckDB's own
// (its CSV writer, TAB between cells), so the renderer and the corpus agree
// on every type a corpus answer holds.

import assert from "node:assert/strict";
import { test } from "node:test";

import {
  Binary,
  Bool,
  type Data,
  DateDay,
  DateMillisecond,
  Decimal,
  Dictionary,
  Field,
  Float16,
  Float32,
  Float64,
  Int32,
  Int64,
  Int8,
  Interval,
  IntervalUnit,
  LargeBinary,
  LargeUtf8,
  List,
  Struct,
  Table,
  Time,
  TimeUnit,
  Timestamp,
  Uint64,
  Utf8,
  type Vector,
  makeData,
  makeVector,
  vectorFromArray,
} from "apache-arrow";

import {
  UnrenderedType,
  answerText,
  blobText,
  compareRows,
  csvCell,
  dateText,
  decimalText,
  floatText,
  headerNames,
  listElement,
  rowsOf,
  timeText,
  timestampText,
} from "./render.ts";

/** A one-column table. */
function column(name: string, v: Vector): Table {
  return new Table({ [name]: v });
}

/** The cells of the one column of `t`. */
function cells(t: Table): (string | null)[] {
  return rowsOf(t).map((r) => r[0] ?? null);
}

/** A validity bitmap of `valid`, one bit per slot, least significant first. */
function bitmap(valid: readonly boolean[]): Uint8Array {
  const out = new Uint8Array(Math.ceil(valid.length / 8));
  valid.forEach((v, i) => {
    if (v) {
      out[i >> 3] = (out[i >> 3] ?? 0) | (1 << (i & 7));
    }
  });
  return out;
}

/** The DOUBLE whose bits are `bits`. */
function double(bits: bigint): number {
  const v = new DataView(new ArrayBuffer(8));
  v.setBigUint64(0, bits, true);
  return v.getFloat64(0, true);
}

test("a DOUBLE is its shortest round-trip decimal, positional from 1e-4 to below 1e16", () => {
  const cases: [number, string][] = [
    [0.1, "0.1"],
    [1, "1.0"],
    [-2.25, "-2.25"],
    [123.456, "123.456"],
    [0.0001, "0.0001"],
    [0.00001, "1e-05"],
    [1.5e-7, "1.5e-07"],
    [1e15, "1000000000000000.0"],
    [1e16, "1e+16"],
    [1.2345e16, "1.2345e+16"],
    [1e300, "1e+300"],
    [5e-324, "5e-324"],
    [Number.MAX_VALUE, "1.7976931348623157e+308"],
    [0.5623790762907029, "0.5623790762907029"],
  ];
  for (const [v, want] of cases) {
    assert.equal(floatText(v, v < 0, false), want, String(v));
  }
});

test("a FLOAT is the shortest decimal of its 32-bit value, or the widened DOUBLE's where that search is unsure", () => {
  const cases: [number, string][] = [
    [0.1, "0.1"],
    [0.3, "0.3"],
    [3.4028235e38, "3.4028235e+38"],
    // The least subnormal FLOAT, and the least normal one (an end of its interval is half as far below).
    [1.4e-45, "1e-45"],
    [1.17549435e-38, "1.1754944e-38"],
    [16777216, "16777216.0"],
    [1e10, "10000000000.0"],
    [2 ** 100, "1.2676506e+30"],
    // Rounded up into one digit more: 9.99999968e-22 is 1e-21.
    [9.99999968266e-22, "1e-21"],
    // A tie of 1378041.7 and 1378041.8, and 155616600 on an end of the interval: the DOUBLE's digits.
    [1378041.75, "1378041.75"],
    [155616608, "155616608.0"],
  ];
  for (const [v, want] of cases) {
    assert.equal(floatText(Math.fround(v), false, true), want, String(v));
  }
});

test("NaN, the infinities and zero keep the sign their bits hold", () => {
  const bits = [0x7ff8000000000000n, 0xfff8000000000000n, 0x7ff0000000000000n, 0xfff0000000000000n, 0n, 0x8000000000000000n];
  const values = new Float64Array(bits.map(double));
  assert.deepEqual(cells(column("d", makeVector(values))), ["nan", "-nan", "inf", "-inf", "0.0", "-0.0"]);
  const singles = new Float32Array([NaN, -Infinity, -0, 0.1]);
  new DataView(singles.buffer).setUint32(0, 0xffc00000, true);
  assert.deepEqual(cells(column("f", makeVector(singles))), ["-nan", "-inf", "-0.0", "0.1"]);
});

test("integers of every width are their digits, NULL an empty cell", () => {
  const t = new Table({
    i8: vectorFromArray([-128, null], new Int8()),
    i64: vectorFromArray([-9223372036854775808n, 1n], new Int64()),
    u64: vectorFromArray([18446744073709551615n, 0n], new Uint64()),
  });
  assert.deepEqual(rowsOf(t), [
    ["-128", "-9223372036854775808", "18446744073709551615"],
    [null, "1", "0"],
  ]);
});

test("a decimal has exactly its scale's digits, at 128 and at 256 bits", () => {
  assert.equal(decimalText(1250n, 2), "12.50");
  assert.equal(decimalText(-5n, 2), "-0.05");
  assert.equal(decimalText(5n, 0), "5");
  assert.equal(decimalText(-7n, -2), "-700");
  const d128 = makeData({ type: new Decimal(2, 12, 128), length: 2, data: new Uint32Array([1250, 0, 0, 0, 0xfffffffb, 0xffffffff, 0xffffffff, 0xffffffff]) });
  assert.deepEqual(cells(column("d", makeVector(d128))), ["12.50", "-0.05"]);
  const words = new Uint32Array(8);
  words[4] = 1; // 2^128
  const d256 = makeData({ type: new Decimal(3, 76, 256), length: 1, data: words });
  assert.deepEqual(cells(column("d", makeVector(d256))), ["340282366920938463463374607431768211.456"]);
});

test("a date is YYYY-MM-DD, with (BC) after a year before 1, and five digits past 9999", () => {
  assert.equal(dateText(0n), "1970-01-01");
  assert.equal(dateText(-1n), "1969-12-31");
  assert.equal(dateText(19782n), "2024-02-29");
  // -0044-03-15, the year 45 BC; 0000-12-31 is 1 BC.
  assert.equal(dateText(-735525n), "0045-03-15 (BC)");
  assert.equal(dateText(-719163n), "0001-12-31 (BC)");
  assert.equal(dateText(3789391n), "12345-01-01");
  const days = makeData({ type: new DateDay(), length: 2, nullCount: 1, nullBitmap: bitmap([true, false]), data: new Int32Array([19782, 0]) });
  const ms = makeData({ type: new DateMillisecond(), length: 1, data: new BigInt64Array([-86400000n]) });
  assert.deepEqual(cells(column("d", makeVector(days))), ["2024-02-29", null]);
  assert.deepEqual(cells(column("d", makeVector(ms))), ["1969-12-31"]);
});

test("a timestamp is its date and clock, the fraction without trailing zeros, +00 for a zone", () => {
  assert.equal(timestampText(1704164645n, TimeUnit.SECOND, false), "2024-01-02 03:04:05");
  assert.equal(timestampText(1704164645120n, TimeUnit.MILLISECOND, false), "2024-01-02 03:04:05.12");
  assert.equal(timestampText(1704072615123456n, TimeUnit.MICROSECOND, true), "2024-01-01 01:30:15.123456+00");
  assert.equal(timestampText(1704164645000000100n, TimeUnit.NANOSECOND, false), "2024-01-02 03:04:05.0000001");
  // Before the epoch the day is floored: -1 microsecond is the last of 1969-12-31.
  assert.equal(timestampText(-1n, TimeUnit.MICROSECOND, false), "1969-12-31 23:59:59.999999");
  assert.equal(timestampText(-63549316800n, TimeUnit.SECOND, false), "0045-03-15 (BC) 12:00:00");
  assert.equal(timestampText(-63549316800n, TimeUnit.SECOND, true), "0045-03-15 (BC) 12:00:00+00");
  const us = makeData({ type: new Timestamp(TimeUnit.MICROSECOND, "UTC"), length: 1, data: new BigInt64Array([0n]) });
  assert.deepEqual(cells(column("t", makeVector(us))), ["1970-01-01 00:00:00+00"]);
});

test("a time of day is HH:MM:SS with its fraction, at 32 and at 64 bits", () => {
  assert.equal(timeText(45296n, TimeUnit.SECOND), "12:34:56");
  assert.equal(timeText(45296500n, TimeUnit.MILLISECOND), "12:34:56.5");
  assert.equal(timeText(0n, TimeUnit.NANOSECOND), "00:00:00");
  const s = makeData({ type: new Time(TimeUnit.SECOND, 32), length: 1, data: new Int32Array([45296]) });
  const ns = makeData({ type: new Time(TimeUnit.NANOSECOND, 64), length: 1, data: new BigInt64Array([45296000000001n]) });
  assert.deepEqual(cells(column("t", makeVector(s))), ["12:34:56"]);
  assert.deepEqual(cells(column("t", makeVector(ns))), ["12:34:56.000000001"]);
});

test("a BLOB is printable ASCII as is and every other byte, \\, ' and \" as \\xHH", () => {
  const bytes = new Uint8Array([0x00, 0x41, 0x5c, 0x27, 0x22, 0x7e, 0x7f, 0xff, 0x20]);
  assert.equal(blobText(bytes), "\\x00A\\x5C\\x27\\x22~\\x7F\\xFF ");
  const t = new Table({
    b: vectorFromArray([bytes, null], new Binary()),
    lb: vectorFromArray([new Uint8Array([0x0a]), new Uint8Array([])], new LargeBinary()),
  });
  assert.deepEqual(rowsOf(t), [
    ["\\x00A\\x5C\\x27\\x22~\\x7F\\xFF ", "\\x0A"],
    [null, ""],
  ]);
});

test("a text cell is quoted, its \" doubled, when empty or holding a TAB, LF, CR or \"", () => {
  assert.equal(csvCell(null), "");
  assert.equal(csvCell(""), '""');
  assert.equal(csvCell("plain text, with comma"), "plain text, with comma");
  assert.equal(csvCell("a\tb"), '"a\tb"');
  assert.equal(csvCell("a\nb"), '"a\nb"');
  assert.equal(csvCell("a\rb"), '"a\rb"');
  assert.equal(csvCell('q"x'), '"q""x"');
  const t = new Table({
    s: vectorFromArray(["Ünïcodé", "", null], new Utf8()),
    l: vectorFromArray(["a\tb", "x", "y"], new LargeUtf8()),
  });
  assert.equal(answerText(t, "query"), 's\tl\nÜnïcodé\t"a\tb"\n""\tx\n\ty\n');
});

test("a list is [a, b], a text element quoted with ' where DuckDB quotes it and NULL as NULL", () => {
  const strings = ["a", "", " x", "x ", "NULL", "null", "a,b", "it's", "b\\c", "[x]", "{y}", "k:v", '"q"', "a,\\b", null];
  const t = new Table({
    l: vectorFromArray([strings, [], null], new List(new Field("item", new Utf8(), true))),
    n: vectorFromArray([[1, null, 3], [], [2]], new List(new Field("item", new Int32(), true))),
  });
  assert.deepEqual(rowsOf(t), [
    ["[a, '', ' x', 'x ', 'NULL', 'null', 'a,b', 'it\\'s', b\\c, '[x]', '{y}', 'k:v', '\"q\"', 'a,\\\\b', NULL]", "[1, NULL, 3]"],
    ["[]", "[]"],
    [null, "[2]"],
  ]);
  assert.equal(listElement("", new Utf8()), "''");
  assert.equal(listElement("12", new Int32()), "12");
});

test("a dictionary is spelled by its values, and a bool read at its slot past the array's offset", () => {
  const t = new Table({
    d: vectorFromArray(["x", "y", null, "x"], new Dictionary(new Utf8(), new Int32())),
    b: vectorFromArray([true, false, null, true], new Bool()),
  });
  assert.deepEqual(rowsOf(t.slice(1)), [
    ["y", "false"],
    [null, null],
    ["x", "true"],
  ]);
});

test("a dictionary's values may be in chunks, and an index past them is refused", () => {
  const values = makeVector([makeData({ type: new Int32(), length: 2, data: new Int32Array([10, 20]) }), makeData({ type: new Int32(), length: 1, data: new Int32Array([30]) })]);
  const type = new Dictionary(new Int32(), new Int32());
  const ok = makeData({ type, length: 3, data: new Int32Array([2, 0, 1]), dictionary: values });
  assert.deepEqual(cells(column("d", makeVector(ok))), ["30", "10", "20"]);
  const past = makeData({ type, length: 1, data: new Int32Array([3]), dictionary: values });
  assert.throws(() => rowsOf(column("d", makeVector(past))), { name: "RangeError", message: "row 3 is past the end of a 3-row column" });
});

test("a column of a type the corpus never answers with is refused by name", () => {
  const half = makeData({ type: new Float16(), length: 1, data: new Uint16Array([0x3c00]) });
  const interval = makeData({ type: new Interval(IntervalUnit.YEAR_MONTH), length: 1, data: new Int32Array([1]) });
  const struct = vectorFromArray([{ a: 1 }], new Struct([new Field("a", new Int32(), true)]));
  for (const [v, type] of [
    [makeVector(half), "Float16"],
    [makeVector(interval), "Interval<YEAR_MONTH>"],
    [struct, "Struct<{a:Int32}>"],
  ] as const) {
    assert.throws(() => answerText(column("c", v), "query"), (e: unknown) => {
      assert.ok(e instanceof UnrenderedType);
      assert.equal(e.message, `column "c": no spelling for the Arrow type ${type}`);
      return true;
    });
  }
});

test("a repeated column name gets _<n>, compared without case, the first n that makes it new", () => {
  assert.deepEqual(headerNames(["k", "a", "k", "b"]), ["k", "a", "k_1", "b"]);
  assert.deepEqual(headerNames(["k", "K", "k"]), ["k", "K_1", "k_2"]);
  assert.deepEqual(headerNames(["k", "k_1", "k"]), ["k", "k_1", "k_2"]);
});

test("order: rows sorts by each column's text in turn, NULL first, text by its UTF-8 bytes", () => {
  assert.equal(compareRows([null, "b"], ["a", "a"]), -1);
  assert.equal(compareRows(["a", "b"], [null, "a"]), 1);
  assert.equal(compareRows(["a", "b"], ["a", "c"]) < 0, true);
  assert.equal(compareRows(["B"], ["a"]) < 0, true);
  assert.equal(compareRows(["z"], ["é"]) < 0, true);
  // 10 sorts before 9 as text, as DuckDB's VARCHAR order does.
  assert.equal(compareRows(["10"], ["9"]) < 0, true);
  assert.equal(compareRows([null, "x"], [null, "x"]), 0);
  // Two lone surrogates are the same UTF-8 bytes (U+FFFD each): the next column decides.
  assert.equal(compareRows(["\uD800", "b"], ["\uD801", "a"]), 1);
});

test("an answer is the header line then a line per row, every line ending in LF, over every batch", () => {
  const first = new Table({ k: vectorFromArray([3, 1], new Int32()), s: vectorFromArray(["c", null], new Utf8()) });
  const second = new Table({ k: vectorFromArray([2], new Int32()), s: vectorFromArray([""], new Utf8()) });
  const t = first.concat(second);
  assert.equal(t.batches.length, 2);
  assert.equal(answerText(t, "query"), 'k\ts\n3\tc\n1\t\n2\t""\n');
  assert.equal(answerText(t, "rows"), 'k\ts\n1\t\n2\t""\n3\tc\n');
  const empty = new Table({ k: vectorFromArray([], new Int32()) });
  assert.equal(answerText(empty, "rows"), "k\n");
});

test("the Data a batch holds is read at its own slots, not its buffer's", () => {
  const t = new Table({ f: makeVector(new Float64Array([1.5, -0.0, 2.5])) }).slice(1);
  const data = t.batches[0]?.data.children[0] as Data;
  assert.equal(data.length, 2);
  assert.deepEqual(cells(t), ["-0.0", "2.5"]);
});
