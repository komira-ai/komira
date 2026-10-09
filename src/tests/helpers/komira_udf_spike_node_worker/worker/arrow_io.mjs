// Arrow IPC messages, worker side, with apache-arrow (resolved from the
// node_modules beside the worker, never bundled with user code).
//
// In: the engine's Schema messages (LOAD, VALIDATE) and RecordBatch messages
// (arguments, frame inputs, aggregate inputs), decoded with apache-arrow's
// Message codec. A column's buffers are typed-array views of the request's
// payload: no copy. Out: one RecordBatch message per output, its metadata
// encoded by apache-arrow, its body the column buffers the runtime filled,
// written with one writev and no further copy.

import { Field, Float64, Int32, Int64, Message, MessageHeader, makeData, makeVector } from 'apache-arrow';
import {
  BufferRegion,
  FieldNode,
  RecordBatch as RecordBatchHeader,
} from 'apache-arrow/ipc/metadata/message';

const ALIGN = 64;

export function widthOf(fmt) {
  return fmt === 'i' ? 4 : 8;
}

// The C Data format of an apache-arrow type the transport carries, or null.
export function fmtOf(type) {
  if (type instanceof Int64 || (type.typeId === 2 && type.bitWidth === 64 && type.isSigned)) return 'l';
  if (type instanceof Int32 || (type.typeId === 2 && type.bitWidth === 32 && type.isSigned)) return 'i';
  if (type instanceof Float64 || (type.typeId === 3 && type.precision === 2)) return 'g';
  return null;
}

function arrowType(fmt) {
  return fmt === 'l' ? new Int64() : fmt === 'i' ? new Int32() : new Float64();
}

// The last RecordBatch metadata decoded, and its header: a batch's metadata
// depends only on its layout (lengths, null counts, buffer regions), so
// batch after batch of one call site repeats it, and apache-arrow's
// flatbuffer decode is skipped when the bytes are the same.
let lastMeta = null;
let lastDecoded = null;

function sameBytes(a, b) {
  if (a.byteLength !== b.byteLength) return false;
  for (let i = 0; i < a.byteLength; i++) if (a[i] !== b[i]) return false;
  return true;
}

function decode(meta) {
  if (lastMeta !== null && sameBytes(lastMeta, meta)) return lastDecoded;
  const message = Message.decode(meta);
  const d = { message, header: message.header() };
  if (message.headerType === MessageHeader.RecordBatch) {
    lastMeta = meta.slice();
    lastDecoded = d;
  }
  return d;
}

// Every encapsulated message in `bytes`: {message, header, body}.
export function readMessages(bytes) {
  const out = [];
  const dv = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  let at = 0;
  while (at + 8 <= bytes.byteLength) {
    if (dv.getUint32(at, true) !== 0xffffffff) throw new Error(`no IPC continuation marker at byte ${at}`);
    const metaLen = dv.getInt32(at + 4, true);
    if (metaLen === 0) break;
    const { message, header } = decode(bytes.subarray(at + 8, at + 8 + metaLen));
    const bodyAt = at + 8 + metaLen;
    const body = bytes.subarray(bodyAt, bodyAt + message.bodyLength);
    out.push({ message, header, body });
    at = bodyAt + message.bodyLength;
    at = Math.ceil(at / 8) * 8;
  }
  return out;
}

// A Schema message's fields as {name, fmt, nullable}, and its metadata.
export function readSchema({ message, header }) {
  if (message.headerType !== MessageHeader.Schema) throw new Error('expected an IPC Schema message');
  const schema = header;
  const fields = schema.fields.map((f) => {
    const fmt = fmtOf(f.type);
    if (fmt === null) throw new Error(`field ${f.name}: type ${f.type} is not carried`);
    return { name: f.name, fmt, nullable: f.nullable };
  });
  return { fields, metadata: message.metadata };
}

function view(body, region, ctor, n) {
  const off = body.byteOffset + Number(region.offset);
  if (off % ctor.BYTES_PER_ELEMENT !== 0) return new ctor(body.slice(Number(region.offset), Number(region.offset) + n * ctor.BYTES_PER_ELEMENT).buffer);
  return new ctor(body.buffer, off, n);
}

const CTOR = { l: BigInt64Array, g: Float64Array, i: Int32Array };

// A RecordBatch message decoded against `fields`: {length, cols}, each col
// {fmt, length, nullCount, validity (Uint8Array or null), values}.
export function readBatch({ message, header, body }, fields) {
  if (message.headerType !== MessageHeader.RecordBatch) throw new Error('expected an IPC RecordBatch message');
  const rb = header;
  if (rb.nodes.length !== fields.length || rb.buffers.length !== 2 * fields.length)
    throw new Error(`a batch of ${rb.nodes.length} columns for ${fields.length} bound fields`);
  const length = Number(rb.length);
  const cols = fields.map((f, i) => {
    const node = rb.nodes[i];
    const vb = rb.buffers[2 * i];
    const db = rb.buffers[2 * i + 1];
    const n = Number(node.length);
    const nullCount = Number(node.nullCount);
    const validity = nullCount > 0 ? body.subarray(Number(vb.offset), Number(vb.offset) + Math.ceil(n / 8)) : null;
    return { fmt: f.fmt, length: n, nullCount, validity, values: view(body, db, CTOR[f.fmt], n) };
  });
  return { length, cols };
}

// A decoded column as an apache-arrow Vector over the same memory.
export function toVector(col) {
  return makeVector(
    makeData({
      type: arrowType(col.fmt),
      length: col.length,
      nullCount: col.nullCount,
      nullBitmap: col.validity,
      data: col.values,
    }),
  );
}

export function fieldOf(name, fmt, nullable) {
  return new Field(name, arrowType(fmt), nullable);
}

function padLen(n) {
  return Math.ceil(n / ALIGN) * ALIGN;
}

const zeros = new Uint8Array(ALIGN);

// One RecordBatch message of `length` rows from `cols` ({fmt, values,
// validity, nullCount}); the parts to write, in order.
export function batchParts(length, cols) {
  const nodes = [];
  const regions = [];
  const body = [];
  let at = 0;
  const push = (bytes) => {
    const off = at;
    if (bytes !== null && bytes.byteLength > 0) {
      body.push(bytes);
      const pad = padLen(bytes.byteLength) - bytes.byteLength;
      if (pad > 0) body.push(zeros.subarray(0, pad));
      at += padLen(bytes.byteLength);
    }
    return new BufferRegion(off, bytes === null ? 0 : bytes.byteLength);
  };
  for (const c of cols) {
    nodes.push(new FieldNode(length, c.nullCount));
    const v = c.nullCount > 0 ? c.validity : null;
    regions.push(push(v));
    const values = new Uint8Array(c.values.buffer, c.values.byteOffset, length * widthOf(c.fmt));
    regions.push(push(values));
  }
  const key = `${length}|${cols.map((c) => `${c.fmt}${c.nullCount}`).join(',')}`;
  let prefix = prefixes.get(key);
  if (prefix === undefined) {
    prefix = messagePrefix(length, nodes, regions, at);
    if (prefixes.size >= 64) prefixes.clear();
    prefixes.set(key, prefix);
  }
  return [prefix, ...body];
}

// Encoded metadata by layout (row count, and per column its type and null
// count, which fix every buffer region): the flatbuffer encode is skipped
// for a layout seen before.
const prefixes = new Map();

// The continuation, metadata length and metadata of a RecordBatch message
// whose body (`bodyLength` bytes) follows, padded so the body starts
// 64-aligned.
function messagePrefix(length, nodes, regions, bodyLength) {
  const meta = Message.encode(Message.from(new RecordBatchHeader(length, nodes, regions, null), bodyLength));
  const metaLen = padLen(8 + meta.byteLength) - 8;
  const prefix = new Uint8Array(8 + metaLen);
  const dv = new DataView(prefix.buffer);
  dv.setUint32(0, 0xffffffff, true);
  dv.setInt32(4, metaLen, true);
  prefix.set(meta, 8);
  return prefix;
}

// Outputs whose layout is wrong, for the test of the engine's validation
// of worker outputs (--corrupt-output; tests/test_node_worker.mojo): by the
// batch's row count, 1: a values buffer past the body; 2: a values buffer
// shorter than the column; 3: two columns where one is bound; 4: a null
// count above the length. null for any other count.
export function corruptParts(length) {
  const body = new Uint8Array(ALIGN);
  const one = (n, nulls, regions) => [messagePrefix(n, [new FieldNode(n, nulls)], regions, ALIGN), body];
  if (length === 1) return one(1, 0, [new BufferRegion(0, 0), new BufferRegion(1 << 20, 8)]);
  if (length === 2) return one(2, 0, [new BufferRegion(0, 0), new BufferRegion(0, 8)]);
  if (length === 3) {
    const nodes = [new FieldNode(3, 0), new FieldNode(3, 0)];
    const regions = [new BufferRegion(0, 0), new BufferRegion(0, 24), new BufferRegion(0, 0), new BufferRegion(0, 24)];
    return [messagePrefix(3, nodes, regions, ALIGN), body];
  }
  if (length === 4) return one(4, 5, [new BufferRegion(0, 1), new BufferRegion(0, 32)]);
  return null;
}
