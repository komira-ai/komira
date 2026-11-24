// Builders of the stream descriptions the stand-in producer takes
// (tests/arrow_stand_in.c): a column is a schema node and an array node, and
// a stream is a struct of columns with its batches. The buffers are the bytes
// the Arrow columnar format lays out, written here by hand so a test states
// exactly what the importer is given.

export interface SchemaSpec {
  format: string;
  name?: string;
  flags?: number;
  metadata?: [string, string][];
  children?: SchemaSpec[];
  dictionary?: SchemaSpec;
}

export interface ArraySpec {
  length: number;
  nullCount?: number;
  offset?: number;
  buffers: (ArrayBufferView | number | null)[];
  children?: ArraySpec[];
  dictionary?: ArraySpec;
  misalign?: boolean;
}

export interface StreamSpec {
  schema: SchemaSpec;
  batches: ArraySpec[];
  pool?: ArrayBufferView[];
  schemaError?: { status: number; message?: string };
  nextError?: { at: number; status: number; message?: string };
  releasedSchema?: boolean;
}

export const NULLABLE = 2;

// A validity (or bool) bitmap: bit i is set when `set[i]`, least significant
// bit first.
export function bitmap(set: boolean[]): Uint8Array {
  const out = new Uint8Array(Math.ceil(set.length / 8));
  set.forEach((on, i) => {
    if (on) out[i >> 3] |= 1 << (i & 7);
  });
  return out;
}

// The validity bitmap of `values` (null is unset) and its null count, or no
// bitmap when nothing is null.
export function validity(values: unknown[]): { bitmap: Uint8Array | null; nullCount: number } {
  const nulls = values.filter((v) => v === null).length;
  return { bitmap: nulls === 0 ? null : bitmap(values.map((v) => v !== null)), nullCount: nulls };
}

// A fixed-width column of `length` slots: `data` holds every slot's value
// (any value at a null); `valid` gives the slots that are not null.
export function fixed(
  name: string,
  format: string,
  length: number,
  data: ArrayBufferView,
  valid: boolean[] | null = null,
): { schema: SchemaSpec; array: ArraySpec } {
  return {
    schema: { format, name, flags: NULLABLE },
    array: {
      length,
      nullCount: valid === null ? 0 : valid.filter((v) => !v).length,
      buffers: [valid === null ? null : bitmap(valid), data],
    },
  };
}

// The offsets and bytes of variable-length values (null is an empty slot).
export function varlen(values: (string | Uint8Array | null)[], wide: boolean): [ArrayBufferView, Uint8Array] {
  const parts = values.map((v) => (v === null ? new Uint8Array(0) : typeof v === 'string' ? new TextEncoder().encode(v) : v));
  const ends = [0];
  for (const p of parts) ends.push(ends[ends.length - 1] + p.length);
  const data = new Uint8Array(ends[ends.length - 1]);
  parts.forEach((p, i) => data.set(p, ends[i]));
  return [wide ? BigInt64Array.from(ends, BigInt) : Int32Array.from(ends), data];
}

// A utf8 ('u', 'U') or binary ('z', 'Z') column.
export function varlenColumn(name: string, format: string, values: (string | Uint8Array | null)[]): {
  schema: SchemaSpec;
  array: ArraySpec;
} {
  const { bitmap: valid, nullCount } = validity(values);
  const [offsets, data] = varlen(values, format === 'U' || format === 'Z');
  return {
    schema: { format, name, flags: NULLABLE },
    array: { length: values.length, nullCount, buffers: [valid, offsets, data] },
  };
}

// A stream whose batch i is a struct of the columns `batches[i]`; the schema
// is the first batch's.
export function streamOf(
  batches: { schema: SchemaSpec; array: ArraySpec }[][],
  extra: Partial<StreamSpec> = {},
): StreamSpec {
  const first = batches[0] ?? [];
  return {
    schema: { format: '+s', name: '', children: first.map((c) => c.schema) },
    batches: batches.map((cols) => ({
      length: cols[0]?.array.length ?? 0,
      buffers: [null],
      children: cols.map((c) => c.array),
    })),
    ...extra,
  };
}

// The bytes of a typed array.
export function bytesOf(b: ArrayBuffer | null): number[] {
  return b === null ? [] : Array.from(new Uint8Array(b));
}

export function bytes(v: ArrayBufferView): number[] {
  return Array.from(new Uint8Array(v.buffer, v.byteOffset, v.byteLength));
}
