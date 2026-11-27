// An apache-arrow Table written as the SQL conformance corpus writes its
// answers (src/tests/conformance/komira_sql_conformance/README.md, "The
// answers"): DuckDB's CSV writer with a TAB between cells and a header line.
//
// A cell is spelled as DuckDB spells the value: NULL as an empty unquoted
// cell, the empty string as `""`, a cell holding a TAB, LF, CR or `"` quoted
// with `"` doubled; integers as digits; a decimal with exactly its scale's
// digits; a float as its shortest round-trip decimal (`0.1`, `-0.0`, `1e+300`,
// `1.5e-07`), `nan`, `-nan`, `inf` or `-inf`; booleans `true`/`false`; dates
// and timestamps in ISO form with `(BC)` after the date of a year before 1;
// a list as `[a, b]`; a BLOB with every byte outside printable ASCII, and
// `\`, `'` and `"`, as `\xHH`. A float's spelling reads its bits, so a NaN
// keeps its sign.
//
// `order: rows` sorts the rows as the corpus's runner does, `ORDER BY
// COLUMNS(*)::VARCHAR ASC NULLS FIRST`: by the text of each column in turn,
// compared byte by byte as UTF-8, a NULL before any text.
//
// A column of a type the corpus never answers with (a struct, a map,
// an interval, a union) is refused by name: it is never written as some other
// text.

import {
  type Data,
  DataType,
  DateUnit,
  type Field,
  Precision,
  type RecordBatch,
  type Table,
  TimeUnit,
  type Vector,
} from "apache-arrow";

/** A column's type the renderer does not spell, by the column's name. */
export class UnrenderedType extends Error {
  constructor(column: string, type: DataType) {
    super(`column "${column}": no spelling for the Arrow type ${String(type)}`);
    this.name = "UnrenderedType";
  }
}

/** The order of an answer's rows: the query's own, or sorted as a multiset. */
export type RowOrder = "query" | "rows";

/** A cell: its text as DuckDB's VARCHAR cast writes it, or null for NULL. */
export type Cell = string | null;

// ---- numbers ------------------------------------------------------------------

/** The exponents of a float's first digit DuckDB writes positionally; the rest take `e`. */
const POSITIONAL_MIN = -4;
const POSITIONAL_MAX = 15;

/** Significant digits (no sign, no point) and the decimal exponent of the first. */
interface Digits {
  digits: string;
  exp: number;
}

/**
 * A finite non-zero DOUBLE's digits: JavaScript's shortest round-trip
 * spelling (`toExponential()` with no argument), which is DuckDB's.
 */
function doubleDigits(abs: number): Digits {
  const [mantissa = "", exponent = ""] = abs.toExponential().split("e");
  return { digits: mantissa.replace(".", ""), exp: Number(exponent) };
}

/**
 * A finite non-zero FLOAT's digits as DuckDB writes them: the shortest that
 * read back as the float, found as DuckDB's formatter finds them, which gives
 * up and writes the float widened to a DOUBLE where its answer is not sure.
 * The digits of the exact value are taken one at a time; at each count the
 * value cut there and the next decimal up are the candidates, and one is
 * taken when it lies strictly inside the interval of reals that round to the
 * float, the closer one when both do. A candidate on an end of the interval,
 * or two equally close, is where the search gives up: 1378041.75 (a tie of
 * 1378041.7 and 1378041.8) and 155616608.0 (155616600 is an end) are written
 * from the DOUBLE. DuckDB's formatter decides some ends from its own rounding
 * error (183701088 is written 183701090.0, though 183701080 is an end), so a
 * float that close to an end can be written otherwise than DuckDB writes it.
 */
export function floatDigits(abs: number): Digits {
  // abs = m * 2^e exactly, m a 24-bit integer (fewer bits below the normal range).
  const bits = new DataView(new Float32Array([abs]).buffer).getUint32(0, true);
  const biased = (bits >>> 23) & 0xff;
  const fraction = bits & 0x7fffff;
  const m = BigInt(biased === 0 ? fraction : fraction | 0x800000);
  const e = (biased === 0 ? 1 : biased) - 150;
  // The gap to the float below is half the gap above at a power of two, but the least normal one.
  const narrowBelow = fraction === 0 && biased > 1;
  // At the digit 10^q every quantity is scaled by 2^max(0, 2 - e) * 10^max(0, -q), so all are integers.
  const pow2 = (n: number) => 1n << BigInt(n);
  const pow10 = (n: number) => 10n ** BigInt(n);
  const at = (q: number) => {
    const tens = q < 0 ? pow10(-q) : 1n;
    const v = (e < 2 ? m * 4n : m * pow2(e)) * tens;
    const step = (q > 0 ? pow10(q) : 1n) * (e < 2 ? pow2(2 - e) : 1n);
    const above = (e < 2 ? 2n : pow2(e - 1)) * tens;
    return { v, step, above, below: narrowBelow ? above / 2n : above };
  };
  // The exponent of the first significant digit: the DOUBLE's spelling of a FLOAT has it, since no
  // FLOAT but a power of ten itself is near enough one for that spelling to round across it.
  let q = doubleDigits(abs).exp;
  for (;;) {
    const { v, step, above, below } = at(q);
    const head = v / step;
    const dLow = v - head * step;
    const dHigh = step - dLow;
    if (dLow !== 0n && (dLow === below || dHigh === above)) {
      // A candidate on an end of the interval: the shortest search gives up.
      return doubleDigits(abs);
    }
    const low = dLow < below;
    const high = dHigh < above;
    if (dLow === 0n || (low && !high) || (low && high && dLow < dHigh)) {
      return { digits: head.toString(), exp: q + head.toString().length - 1 };
    }
    if ((high && !low) || (low && high && dHigh < dLow)) {
      // A carry (9.99 up to 10.0) adds a digit in front.
      const digits = (head + 1n).toString();
      return { digits, exp: q + digits.length - 1 };
    }
    if (low && high) {
      // Two candidates equally close: the shortest search gives up.
      return doubleDigits(abs);
    }
    q -= 1;
  }
}

/**
 * The shortest round-trip spelling of a finite non-zero float, laid out as
 * DuckDB lays it out: positional when the exponent of its first digit is
 * from -4 to 15, with `.0` after a whole number; else one digit, the rest
 * after a point, and `e` with a sign and at least two digits.
 */
function layout(digits: string, exp: number): string {
  // Not zero, so its digits hold one that is not 0.
  const trimmed = digits.replace(/0+$/, "");
  if (exp < POSITIONAL_MIN || exp > POSITIONAL_MAX) {
    const rest = trimmed.slice(1);
    const sign = exp < 0 ? "-" : "+";
    const e = String(Math.abs(exp)).padStart(2, "0");
    return `${trimmed[0]!}${rest === "" ? "" : "." + rest}e${sign}${e}`;
  }
  if (exp < 0) {
    return "0." + "0".repeat(-exp - 1) + trimmed;
  }
  if (trimmed.length <= exp + 1) {
    return trimmed + "0".repeat(exp + 1 - trimmed.length) + ".0";
  }
  return trimmed.slice(0, exp + 1) + "." + trimmed.slice(exp + 1);
}

/** A float's spelling: `value` with `negative` its sign bit (which a NaN keeps). */
export function floatText(value: number, negative: boolean, single: boolean): string {
  const sign = negative ? "-" : "";
  if (Number.isNaN(value)) {
    return sign + "nan";
  }
  if (!Number.isFinite(value)) {
    return sign + "inf";
  }
  if (value === 0) {
    return sign + "0.0";
  }
  const abs = Math.abs(value);
  const { digits, exp } = single ? floatDigits(abs) : doubleDigits(abs);
  return sign + layout(digits, exp);
}

/** The sign bit of the float `i` of `values` (a Float32Array or a Float64Array). */
function signBit(values: Float32Array | Float64Array, i: number): boolean {
  const bytes = new Uint8Array(values.buffer, values.byteOffset + i * values.BYTES_PER_ELEMENT, values.BYTES_PER_ELEMENT);
  return (bytes[values.BYTES_PER_ELEMENT - 1]! & 0x80) !== 0;
}

/** The integer `unscaled` written with `scale` digits after the point. */
export function decimalText(unscaled: bigint, scale: number): string {
  const negative = unscaled < 0n;
  const digits = (negative ? -unscaled : unscaled).toString();
  if (scale <= 0) {
    return (negative ? "-" : "") + digits + "0".repeat(-scale);
  }
  const padded = digits.padStart(scale + 1, "0");
  const point = padded.length - scale;
  return (negative ? "-" : "") + padded.slice(0, point) + "." + padded.slice(point);
}

/** The two's complement integer of `words` 32-bit little-endian words. */
function wideInteger(words: Uint32Array, at: number, count: number): bigint {
  let n = 0n;
  for (let w = count - 1; w >= 0; w--) {
    n = (n << 32n) | BigInt(words[at + w]!);
  }
  const bits = BigInt(32 * count);
  return n >= 1n << (bits - 1n) ? n - (1n << bits) : n;
}

// ---- dates and times -------------------------------------------------------------

/** The proleptic Gregorian (year, month, day) of a count of days since 1970-01-01. */
function civil(days: bigint): [bigint, number, number] {
  // Howard Hinnant's days_from_civil inverse, over BigInt so no day overflows.
  const z = days + 719468n;
  const era = (z >= 0n ? z : z - 146096n) / 146097n;
  const doe = z - era * 146097n;
  const yoe = (doe - doe / 1460n + doe / 36524n - doe / 146096n) / 365n;
  const doy = doe - (365n * yoe + yoe / 4n - yoe / 100n);
  const mp = (5n * doy + 2n) / 153n;
  const day = Number(doy - (153n * mp + 2n) / 5n + 1n);
  const month = Number(mp < 10n ? mp + 3n : mp - 9n);
  const year = yoe + era * 400n + (month <= 2 ? 1n : 0n);
  return [year, month, day];
}

const pad2 = (n: number | bigint) => String(n).padStart(2, "0");

/** A date's text, `YYYY-MM-DD`, with ` (BC)` and the year counted back for a year before 1. */
function dateParts(days: bigint): { text: string; bc: boolean } {
  const [year, month, day] = civil(days);
  const bc = year <= 0n;
  const y = bc ? 1n - year : year;
  return { text: `${String(y).padStart(4, "0")}-${pad2(month)}-${pad2(day)}`, bc };
}

/** A count of days since the epoch as DuckDB writes a DATE. */
export function dateText(days: bigint): string {
  const { text, bc } = dateParts(days);
  return bc ? text + " (BC)" : text;
}

/** Ticks per second of each time unit. */
const PER_SECOND: Record<TimeUnit, bigint> = {
  [TimeUnit.SECOND]: 1n,
  [TimeUnit.MILLISECOND]: 1000n,
  [TimeUnit.MICROSECOND]: 1000000n,
  [TimeUnit.NANOSECOND]: 1000000000n,
};

/** A floor division of BigInts. */
function floorDiv(a: bigint, b: bigint): bigint {
  const q = a / b;
  return a % b !== 0n && a < 0n !== b < 0n ? q - 1n : q;
}

/** A time of day in `unit` ticks as `HH:MM:SS`, with its fraction's trailing zeros dropped. */
function clockText(ticks: bigint, unit: TimeUnit): string {
  const per = PER_SECOND[unit];
  const seconds = ticks / per;
  const fraction = ticks % per;
  const hms = `${pad2(seconds / 3600n)}:${pad2((seconds / 60n) % 60n)}:${pad2(seconds % 60n)}`;
  if (fraction === 0n) {
    return hms;
  }
  const width = String(per).length - 1;
  return hms + "." + String(fraction).padStart(width, "0").replace(/0+$/, "");
}

/** A count of `unit` ticks since the epoch as DuckDB writes a TIMESTAMP, `zone` naming a TIMESTAMPTZ's. */
export function timestampText(ticks: bigint, unit: TimeUnit, zoned: boolean): string {
  const perDay = PER_SECOND[unit] * 86400n;
  const days = floorDiv(ticks, perDay);
  const { text, bc } = dateParts(days);
  const clock = clockText(ticks - days * perDay, unit);
  return `${text}${bc ? " (BC)" : ""} ${clock}${zoned ? "+00" : ""}`;
}

/** A time of day in `unit` ticks as DuckDB writes a TIME. */
export function timeText(ticks: bigint, unit: TimeUnit): string {
  return clockText(ticks, unit);
}

// ---- text ---------------------------------------------------------------------------

/** A BLOB's bytes as DuckDB writes them: printable ASCII but `\`, `'` and `"` as is, the rest `\xHH`. */
export function blobText(bytes: Uint8Array): string {
  let out = "";
  for (const b of bytes) {
    const plain = b >= 0x20 && b <= 0x7e && b !== 0x5c && b !== 0x27 && b !== 0x22;
    out += plain ? String.fromCharCode(b) : "\\x" + b.toString(16).toUpperCase().padStart(2, "0");
  }
  return out;
}

/**
 * An element of a list as DuckDB writes it inside `[...]`: NULL as `NULL`;
 * a string quoted with `'` (a `'` or `\` in it escaped with `\`) when it
 * is empty, starts or ends with whitespace, spells NULL in any case, or holds
 * a character that delimits a list, a struct or a map (`[],{}:'"`; a `\`
 * alone quotes nothing); any other value as its cell text.
 */
export function listElement(cell: Cell, type: DataType): string {
  if (cell === null) {
    return "NULL";
  }
  const text = DataType.isUtf8(type) || DataType.isLargeUtf8(type);
  if (text && (cell === "" || /^\s|\s$/.test(cell) || cell.toLowerCase() === "null" || /[[\],{}:'"]/.test(cell))) {
    return `'${cell.replace(/['\\]/g, "\\$&")}'`;
  }
  return cell;
}

/** A cell as the CSV writer puts it in the file: NULL empty, `""` for the empty string, quoted when it must be. */
export function csvCell(cell: Cell): string {
  if (cell === null) {
    return "";
  }
  if (cell === "" || /[\t\n\r"]/.test(cell)) {
    return `"${cell.replaceAll('"', '""')}"`;
  }
  return cell;
}

/**
 * The column names as COPY writes them: a name the answer already holds,
 * compared without case, gets `_<n>` with the first n that makes it new.
 */
export function headerNames(names: readonly string[]): string[] {
  const seen = new Set<string>();
  const counts = new Map<string, number>();
  return names.map((name) => {
    const low = name.toLowerCase();
    let out = name;
    if (seen.has(low)) {
      let n = counts.get(low) ?? 0;
      do {
        n += 1;
        out = `${name}_${n}`;
      } while (seen.has(out.toLowerCase()));
      counts.set(low, n);
    }
    seen.add(out.toLowerCase());
    return out;
  });
}

// ---- columns ------------------------------------------------------------------------

/** The cell text of slot `i` of `data` (whose type is `type`), or null for NULL. */
function cellOf(column: string, type: DataType, data: Data, i: number): Cell {
  if (!data.getValid(i)) {
    return null;
  }
  if (DataType.isDictionary(type)) {
    const index = Number((data.values as ArrayLike<number | bigint>)[i]);
    const dict = data.dictionary as Vector;
    const [chunk, at] = locate(dict, index);
    return cellOf(column, type.dictionary, chunk, at);
  }
  if (DataType.isInt(type)) {
    return String((data.values as ArrayLike<number | bigint>)[i]);
  }
  if (DataType.isFloat(type)) {
    if (type.precision === Precision.HALF) {
      throw new UnrenderedType(column, type);
    }
    const values = data.values as Float32Array | Float64Array;
    return floatText(values[i]!, signBit(values, i), type.precision === Precision.SINGLE);
  }
  if (DataType.isBool(type)) {
    const byte = (data.values as Uint8Array)[(data.offset + i) >> 3]!;
    return (byte >> ((data.offset + i) & 7)) & 1 ? "true" : "false";
  }
  if (DataType.isDecimal(type)) {
    const words = type.bitWidth / 32;
    return decimalText(wideInteger(data.values as Uint32Array, i * words, words), type.scale);
  }
  if (DataType.isUtf8(type) || DataType.isLargeUtf8(type) || DataType.isBinary(type) || DataType.isLargeBinary(type)) {
    const offsets = data.valueOffsets as Int32Array | BigInt64Array;
    const bytes = (data.values as Uint8Array).subarray(Number(offsets[i]), Number(offsets[i + 1]));
    return DataType.isUtf8(type) || DataType.isLargeUtf8(type) ? new TextDecoder().decode(bytes) : blobText(bytes);
  }
  if (DataType.isDate(type)) {
    const v = (data.values as Int32Array | BigInt64Array)[i]!;
    return dateText(type.unit === DateUnit.DAY ? BigInt(v) : floorDiv(BigInt(v), 86400000n));
  }
  if (DataType.isTimestamp(type)) {
    // A zone left out is null or undefined, and the empty zone is none (the C Data Interface's `tsu:`).
    return timestampText((data.values as BigInt64Array)[i]!, type.unit, Boolean(type.timezone));
  }
  if (DataType.isTime(type)) {
    return timeText(BigInt((data.values as Int32Array | BigInt64Array)[i]!), type.unit);
  }
  if (DataType.isList(type)) {
    const offsets = data.valueOffsets as Int32Array;
    const child = data.children[0] as Data;
    const element = type.children[0] as Field;
    const items: string[] = [];
    for (let k = offsets[i]!; k < offsets[i + 1]!; k++) {
      items.push(listElement(cellOf(column, element.type, child, k), element.type));
    }
    return `[${items.join(", ")}]`;
  }
  throw new UnrenderedType(column, type);
}

/** The chunk of `vector` holding row `index`, and the row's slot in it. */
function locate(vector: Vector, index: number): [Data, number] {
  let at = index;
  for (const d of vector.data) {
    if (at < d.length) {
      return [d, at];
    }
    at -= d.length;
  }
  throw new RangeError(`row ${index} is past the end of a ${vector.length}-row column`);
}

/** Every row of `table` as its cells, in the table's order. */
export function rowsOf(table: Table): Cell[][] {
  const fields: Field[] = table.schema.fields;
  const rows: Cell[][] = [];
  for (const batch of table.batches as RecordBatch[]) {
    const columns = fields.map((_, c) => batch.data.children[c] as Data);
    for (let r = 0; r < batch.numRows; r++) {
      rows.push(fields.map((f, c) => cellOf(f.name, f.type, columns[c] as Data, r)));
    }
  }
  return rows;
}

/** Compares UTF-8 bytes of two strings, as DuckDB compares VARCHARs. */
function compareText(a: string, b: string): number {
  const x = Buffer.from(a, "utf8");
  const y = Buffer.from(b, "utf8");
  return Buffer.compare(x, y);
}

/** Orders two rows by each cell in turn, NULL first, text by its UTF-8 bytes. */
export function compareRows(a: readonly Cell[], b: readonly Cell[]): number {
  for (let c = 0; c < a.length; c++) {
    const x = a[c] as Cell;
    const y = b[c] as Cell;
    if (x === y) {
      continue;
    }
    if (x === null) {
      return -1;
    }
    if (y === null) {
      return 1;
    }
    const d = compareText(x, y);
    if (d !== 0) {
      return d;
    }
  }
  return 0;
}

/** `table` as the corpus's TSV text: the header line, then a line per row, each ending in LF. */
export function answerText(table: Table, order: RowOrder): string {
  const rows = rowsOf(table);
  if (order === "rows") {
    rows.sort(compareRows);
  }
  const lines = [headerNames(table.schema.fields.map((f) => f.name)).map(csvCell).join("\t")];
  for (const row of rows) {
    lines.push(row.map(csvCell).join("\t"));
  }
  return lines.join("\n") + "\n";
}
