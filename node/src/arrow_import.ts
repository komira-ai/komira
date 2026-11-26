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
// This module is private: Result (result.ts) reads a query's answer through
// openBatches and tableOf, and the Arrow tests read a stand-in producer's
// streams through readArrowStream.

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
const INDEX_TYPES: Record<string, () => Int8 | Uint8 | Int16 | Uint16 | Int32 | Uint32> = {
  c: () => new Int8(),
  C: () => new Uint8(),
  s: () => new Int16(),
  S: () => new Uint16(),
  i: () => new Int32(),
  I: () => new Uint32(),
};

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
  // The one child of a list or a map, whose format required exactly one.
  const only = () => children()[0] as Field;
  const unit = TIMESTAMP_UNITS[f.slice(2, 3)];
  if (f.length > 3 && f.startsWith('ts') && f[3] === ':' && unit !== undefined) {
    const zone = f.slice(4);
    return new Timestamp(unit, zone === '' ? null : zone);
  }
  if (f.startsWith('d:')) return decimalOf(f, path);
  if (f === '+l' && s.children.length === 1) return new List(only());
  if (f === '+s') return new Struct(children());
  if (f === '+m' && s.children.length === 1) {
    const entries = only();
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
  const index = INDEX_TYPES[s.format];
  if (index === undefined) unsupported(path, s.format);
  const indices = index();
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

// makeData, called with the props of the type this module picked at run time
// (its overloads pick the props by the type's class, known only statically).
const make = makeData as unknown as (props: { type: DataType } & Record<string, unknown>) => Data;

// The data of the array `a` of type `type`, over the addon's buffers. The
// addon checked that `a` has the children and the dictionary its schema has,
// so the children of `type` and of `a` pair up one to one.
export function dataOf(type: DataType, a: ArrayDescription): Data {
  const slots = a.offset + a.length;
  const nullBitmap = DataType.isUnion(type) ? undefined : view(a, 0, Uint8Array);
  // The array's null count is of its own slots, so it holds for all of them only at offset 0.
  const nullCount = nullBitmap === undefined ? 0 : a.offset === 0 ? a.nullCount : -1;
  const common = { type, length: slots, nullCount, nullBitmap };
  const childrenOf = (fields: Field[]) => fields.map((f, i) => dataOf(f.type, a.children[i] as ArrayDescription));
  let full: Data;
  if (DataType.isDictionary(type)) {
    const dictionary = makeVector(dataOf(type.dictionary, a.dictionary as ArrayDescription));
    // The index type's constructor is one of six; each takes an ArrayBuffer.
    full = make({ ...common, data: view<ArrayBufferView>(a, 1, type.indices.ArrayType), dictionary });
  } else if (DataType.isUnion(type)) {
    const children = childrenOf(type.children);
    const typeIds = view(a, 0, Int8Array);
    full = DataType.isDenseUnion(type)
      ? make({ type, length: slots, nullCount: -1, typeIds, valueOffsets: view(a, 1, Int32Array), children })
      : make({ type, length: slots, nullCount: -1, typeIds, children });
  } else if (DataType.isStruct(type)) {
    full = make({ ...common, children: childrenOf(type.children) });
  } else if (DataType.isList(type) || DataType.isMap(type)) {
    const [child] = childrenOf(type.children);
    full = make({ ...common, valueOffsets: view(a, 1, Int32Array), child });
  } else if (DataType.isUtf8(type) || DataType.isBinary(type)) {
    full = make({ ...common, valueOffsets: view(a, 1, Int32Array), data: view(a, 2, Uint8Array) });
  } else if (DataType.isLargeUtf8(type) || DataType.isLargeBinary(type)) {
    full = make({ ...common, valueOffsets: view(a, 1, BigInt64Array), data: view(a, 2, Uint8Array) });
  } else {
    // A fixed-width type, bool included: its values are buffer 1.
    full = make({ ...common, data: view(a, 1, type.ArrayType) });
  }
  // Slicing also cuts a struct's or sparse union's children to the array's slots.
  return full.slice(a.offset, a.length);
}

// The batches of `result` after `schema`, one RecordBatch per batch the addon
// hands out; `result` is closed when the generator ends, however it ends.
function* batchesOf(addon: ArrowAddon, result: object, schema: Schema): Generator<RecordBatch, void, undefined> {
  const type = new Struct(schema.fields);
  try {
    for (let a = addon.arrowNextBatch(result); a !== null; a = addon.arrowNextBatch(result)) {
      yield new RecordBatch(schema, dataOf(type, a) as Data<Struct>);
    }
  } finally {
    addon.arrowClose(result);
  }
}

// The schema of a drained `result` (an importArrowStream or sql result) and a
// generator of its batches, which closes `result` when it ends. A refused
// format throws UnsupportedOperation before any batch is read, with `result`
// closed.
export function openBatches(
  addon: ArrowAddon,
  result: object,
): { schema: Schema; batches: Generator<RecordBatch, void, undefined> } {
  let schema: Schema;
  try {
    schema = schemaOf(addon.arrowSchema(result));
  } catch (e) {
    addon.arrowClose(result);
    throw e;
  }
  return { schema, batches: batchesOf(addon, result, schema) };
}

// The Table of a drained `result`, every batch read; `result` is closed
// before this returns or throws.
export function tableOf(addon: ArrowAddon, result: object): Table {
  const { schema, batches } = openBatches(addon, result);
  return new Table(schema, [...batches]);
}

// The Table of the stream in `capsule` (an Arrow C stream capsule, arrow_c.h).
// The import's rejection, a refused format and every error of a batch
// propagate; whatever the result still holds is released before this returns.
export async function readArrowStream(addon: ArrowAddon, capsule: unknown): Promise<Table> {
  return tableOf(addon, await addon.importArrowStream(capsule));
}
