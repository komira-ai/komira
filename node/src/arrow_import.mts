// The Arrow import's JavaScript half: the descriptions the addon makes of an
// Arrow C stream (arrow_import.c) become apache-arrow data, with no copy of a
// buffer the addon did not copy. Each format string maps to an apache-arrow
// DataType, each batch is built with makeData over the addon's ArrayBuffers,
// and the batches are wrapped in RecordBatches and one Table.
//
// The formats mapped are the exporter's set (src/arrow_ipc/README.md): every
// integer and float width, bool, date32 and date64, timestamps of every unit,
// decimal128 and decimal256, time, duration and interval, utf8, binary, large
// utf8 and large binary, dictionaries (indices of up to 32 bits), list, struct, map, and sparse and dense
// unions. Any other format raises UnsupportedOperation naming the column and
// the format string, from the schema, before a batch is read: a column is
// never read as some other type.
//
// Offsets. A C array's offset counts slots to skip in its buffers, and a
// struct's or sparse union's children are read at the parent's slot.
// apache-arrow keeps value buffers that start at the array's first slot, so
// each array is built over all its slots (offset + length) and then sliced,
// which moves the parent's offset into its children where Arrow requires it.
//
// This module is private: the package's public surface is not written yet.

import {
  Binary,
  Bool,
  type Data,
  DataType,
  DateDay,
  DateMillisecond,
  Decimal,
  DenseUnion,
  Dictionary,
  Duration,
  Field,
  Float16,
  Float32,
  Float64,
  Int16,
  Int32,
  Int64,
  Int8,
  Interval,
  IntervalUnit,
  LargeBinary,
  LargeUtf8,
  List,
  Map_,
  RecordBatch,
  Schema,
  SparseUnion,
  Struct,
  Table,
  Time,
  TimeUnit,
  Timestamp,
  Uint16,
  Uint32,
  Uint64,
  Uint8,
  Utf8,
  makeData,
  makeVector,
} from 'apache-arrow';

import { UnsupportedOperation } from './errors.ts';

// What arrowSchema returns: one node per field, as the C ArrowSchema holds it.
export interface SchemaDescription {
  format: string;
  name: string | null;
  flags: number;
  metadata: [string, string][] | null;
  children: SchemaDescription[];
  dictionary: SchemaDescription | null;
}

// What arrowNextBatch returns: one node per array. A buffer is null only for
// an absent validity bitmap.
export interface ArrayDescription {
  length: number;
  nullCount: number;
  offset: number;
  buffers: (ArrayBuffer | null)[];
  children: ArrayDescription[];
  dictionary: ArrayDescription | null;
}

// The calls of the addon this module uses.
export interface ArrowAddon {
  importArrowStream(capsule: unknown): Promise<object>;
  arrowSchema(result: object): SchemaDescription;
  arrowNextBatch(result: object): ArrayDescription | null;
  arrowClose(result: object): void;
}

// The ArrowSchema flags (the C Data Interface).
const FLAG_DICTIONARY_ORDERED = 1;
const FLAG_NULLABLE = 2;
const FLAG_MAP_KEYS_SORTED = 4;

// The formats that name a type with no parameter.
const SIMPLE: Record<string, () => DataType> = {
  c: () => new Int8(),
  C: () => new Uint8(),
  s: () => new Int16(),
  S: () => new Uint16(),
  i: () => new Int32(),
  I: () => new Uint32(),
  l: () => new Int64(),
  L: () => new Uint64(),
  e: () => new Float16(),
  f: () => new Float32(),
  g: () => new Float64(),
  b: () => new Bool(),
  u: () => new Utf8(),
  z: () => new Binary(),
  U: () => new LargeUtf8(),
  Z: () => new LargeBinary(),
  tdD: () => new DateDay(),
  tdm: () => new DateMillisecond(),
  tts: () => new Time(TimeUnit.SECOND, 32),
  ttm: () => new Time(TimeUnit.MILLISECOND, 32),
  ttu: () => new Time(TimeUnit.MICROSECOND, 64),
  ttn: () => new Time(TimeUnit.NANOSECOND, 64),
  tDs: () => new Duration(TimeUnit.SECOND),
  tDm: () => new Duration(TimeUnit.MILLISECOND),
  tDu: () => new Duration(TimeUnit.MICROSECOND),
  tDn: () => new Duration(TimeUnit.NANOSECOND),
  tiM: () => new Interval(IntervalUnit.YEAR_MONTH),
  tiD: () => new Interval(IntervalUnit.DAY_TIME),
  tin: () => new Interval(IntervalUnit.MONTH_DAY_NANO),
};

const TIMESTAMP_UNITS: Record<string, TimeUnit> = {
  s: TimeUnit.SECOND,
  m: TimeUnit.MILLISECOND,
  u: TimeUnit.MICROSECOND,
  n: TimeUnit.NANOSECOND,
};

// The index formats of a dictionary: the integers of up to 32 bits.
// apache-arrow 21.2.0 builds a dictionary of 64-bit indices but cannot read a
// value of it (a BigInt index into the dictionary throws), so 'l' and 'L' are
// refused by name.
const INDEX_FORMATS = new Set(['c', 'C', 's', 'S', 'i', 'I']);

function unsupported(path: string, format: string): never {
  throw new UnsupportedOperation(`column "${path}": Arrow format "${format}" is not supported`);
}

function childPath(parent: string, name: string | null): string {
  return parent === '' ? (name ?? '') : `${parent}.${name ?? ''}`;
}

// Dictionary ids, one per dictionary-encoded field, numbered in schema order.
interface Ids {
  next: number;
}

function decimalOf(format: string, path: string): Decimal {
  const parts = format.slice(2).split(',');
  const [precision, scale, width = '128'] = parts;
  const isInt = (s: string | undefined) => s !== undefined && /^-?[0-9]+$/.test(s);
  if (parts.length > 3 || !isInt(precision) || !isInt(scale) || (width !== '128' && width !== '256')) {
    unsupported(path, format);
  }
  return new Decimal(Number(scale), Number(precision), Number(width));
}

function valueTypeOf(s: SchemaDescription, path: string, ids: Ids): DataType {
  const f = s.format;
  const simple = SIMPLE[f];
  if (simple !== undefined) return simple();
  const children = () => s.children.map((c) => fieldOf(c, childPath(path, c.name), ids));
  if (f.length > 3 && f.startsWith('ts') && f[3] === ':' && f[2] in TIMESTAMP_UNITS) {
    const zone = f.slice(4);
    return new Timestamp(TIMESTAMP_UNITS[f[2]], zone === '' ? null : zone);
  }
  if (f.startsWith('d:')) return decimalOf(f, path);
  if (f === '+l' && s.children.length === 1) return new List(children()[0]);
  if (f === '+s') return new Struct(children());
  if (f === '+m' && s.children.length === 1) {
    const entries = children()[0];
    if (!(entries.type instanceof Struct) || entries.type.children.length !== 2) unsupported(path, f);
    return new Map_(entries as Field<Struct<{ key: DataType; value: DataType }>>, (s.flags & FLAG_MAP_KEYS_SORTED) !== 0);
  }
  if (f.startsWith('+us:') || f.startsWith('+ud:')) {
    const typeIds = f.slice(4) === '' ? [] : f.slice(4).split(',');
    if (typeIds.length !== s.children.length || typeIds.some((t) => !/^[0-9]+$/.test(t))) unsupported(path, f);
    const ids32 = typeIds.map(Number);
    return f[2] === 's' ? new SparseUnion(ids32, children()) : new DenseUnion(ids32, children());
  }
  return unsupported(path, f);
}

export function typeOf(s: SchemaDescription, path: string, ids: Ids): DataType {
  if (s.dictionary === null) return valueTypeOf(s, path, ids);
  if (!INDEX_FORMATS.has(s.format)) unsupported(path, s.format);
  const indices = SIMPLE[s.format]() as Int8 | Int16 | Int32 | Int64 | Uint8 | Uint16 | Uint32 | Uint64;
  const id = ids.next++;
  const values = typeOf(s.dictionary, path, ids);
  return new Dictionary(values, indices, id, (s.flags & FLAG_DICTIONARY_ORDERED) !== 0);
}

function metadataOf(pairs: [string, string][] | null): Map<string, string> {
  return new Map(pairs ?? []);
}

export function fieldOf(s: SchemaDescription, path: string, ids: Ids): Field {
  return new Field(s.name ?? '', typeOf(s, path, ids), (s.flags & FLAG_NULLABLE) !== 0, metadataOf(s.metadata));
}

// The apache-arrow Schema of a stream's schema (a struct, which the addon checked).
export function schemaOf(s: SchemaDescription): Schema {
  const ids: Ids = { next: 0 };
  const fields = s.children.map((c) => fieldOf(c, childPath('', c.name), ids));
  return new Schema(fields, metadataOf(s.metadata));
}

// The buffer `i` of `a`, viewed as `View`, or undefined for an absent bitmap.
function view<T>(a: ArrayDescription, i: number, View: new (b: ArrayBuffer) => T): T | undefined {
  const b = a.buffers[i];
  return b === null || b === undefined ? undefined : new View(b);
}

// The data of the array `a` of type `type`, over the addon's buffers.
export function dataOf(type: DataType, a: ArrayDescription): Data {
  const slots = a.offset + a.length;
  const nullBitmap = DataType.isUnion(type) ? undefined : view(a, 0, Uint8Array);
  // The array's null count is of its own slots, so it holds for all of them only at offset 0.
  const nullCount = nullBitmap === undefined ? 0 : a.offset === 0 ? a.nullCount : -1;
  const common = { type, length: slots, nullCount, nullBitmap };
    let full: Data;
  if (DataType.isDictionary(type)) {
    const dictionary = makeVector(dataOf(type.dictionary, a.dictionary as ArrayDescription));
    full = makeData({ ...common, data: view(a, 1, type.indices.ArrayType), dictionary });
  } else if (DataType.isUnion(type)) {
    const children = type.children.map((f, i) => dataOf(f.type, a.children[i]));
    const typeIds = view(a, 0, Int8Array);
    full = DataType.isDenseUnion(type)
      ? makeData({ type, length: slots, nullCount: -1, typeIds, valueOffsets: view(a, 1, Int32Array), children })
      : makeData({ type, length: slots, nullCount: -1, typeIds, children });
  } else if (DataType.isStruct(type)) {
    full = makeData({ ...common, children: type.children.map((f, i) => dataOf(f.type, a.children[i])) });
  } else if (DataType.isList(type) || DataType.isMap(type)) {
    const child = dataOf(type.children[0].type, a.children[0]);
    full = makeData({ ...common, valueOffsets: view(a, 1, Int32Array), child });
  } else if (DataType.isUtf8(type) || DataType.isBinary(type)) {
    full = makeData({ ...common, valueOffsets: view(a, 1, Int32Array), data: view(a, 2, Uint8Array) });
  } else if (DataType.isLargeUtf8(type) || DataType.isLargeBinary(type)) {
    full = makeData({ ...common, valueOffsets: view(a, 1, BigInt64Array), data: view(a, 2, Uint8Array) });
  } else {
    // A fixed-width type, bool included: its values are buffer 1.
    full = makeData({ ...common, data: view(a, 1, type.ArrayType) });
  }
  // Slicing also cuts a struct's or sparse union's children to the array's slots.
  return full.slice(a.offset, a.length);
}

// The Table of the stream in `capsule` (an Arrow C stream capsule, arrow_c.h).
// The import's rejection, a refused format and every error of a batch
// propagate; whatever the result still holds is released before this returns.
export async function readArrowStream(addon: ArrowAddon, capsule: unknown): Promise<Table> {
  const result = await addon.importArrowStream(capsule);
  try {
    const schema = schemaOf(addon.arrowSchema(result));
    const type = new Struct(schema.fields);
    const batches: RecordBatch[] = [];
    for (let a = addon.arrowNextBatch(result); a !== null; a = addon.arrowNextBatch(result)) {
      batches.push(new RecordBatch(schema, dataOf(type, a)));
    }
    return new Table(schema, batches);
  } finally {
    addon.arrowClose(result);
  }
}
