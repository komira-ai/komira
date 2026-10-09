// Replies that break the worker transport's contract, for the test of the
// engine's validation of everything a worker sends (--corrupt-output;
// tests/test_node_worker.mojo). A call_batch of one row whose value is a
// case number below gets that case's reply instead of its output; any other
// batch is answered normally. The first five DESCRIBEs of a test run get
// malformed replies (describeCorrupt).
//
// The RecordBatch messages are written by hand, not by apache-arrow, so a
// case can set any field to any value: a flatbuffer laid out front to back
// like the proxy's own writer (proxy/ipc.c), every uoffset pointing forward.

import fs from 'node:fs';
import path from 'node:path';

import { MAGIC, OP, FLAG_INLINE, HEADER_BYTES, writeRaw } from './wire.mjs';

class Fb {
  constructor() {
    this.b = new Uint8Array(4096);
    this.dv = new DataView(this.b.buffer);
    this.n = 0;
  }

  zero(k) {
    this.n += k;
  }

  pad(a) {
    while (this.n % a) this.n++;
  }

  // A table of `nslots` slots holding `fields` ({slot, size}), each aligned
  // to its size: {t, pos}, pos[i] being field i's position.
  table(nslots, fields) {
    const voff = new Array(nslots).fill(0);
    const fo = [];
    let o = 4;
    for (const f of fields) {
      o = Math.ceil(o / f.size) * f.size;
      fo.push(o);
      voff[f.slot] = o;
      o += f.size;
    }
    this.pad(2);
    const v = this.n;
    this.dv.setUint16(this.n, 4 + 2 * nslots, true);
    this.dv.setUint16(this.n + 2, o, true);
    for (let i = 0; i < nslots; i++) this.dv.setUint16(this.n + 4 + 2 * i, voff[i], true);
    this.n += 4 + 2 * nslots;
    this.pad(8);
    const t = this.n;
    this.dv.setInt32(t, t - v, true);
    this.n += o;
    return { t, v, pos: fo.map((x) => t + x) };
  }

  link(slot, target) {
    this.dv.setUint32(slot, target - slot, true);
  }

  // A vector of 16-byte structs of two int64s: its position.
  pairs(list) {
    while ((this.n + 4) % 8) this.n++;
    const at = this.n;
    this.dv.setUint32(at, list.length, true);
    this.n += 4;
    for (const [a, b] of list) {
      this.dv.setBigInt64(this.n, BigInt(a), true);
      this.dv.setBigInt64(this.n + 8, BigInt(b), true);
      this.n += 16;
    }
    return at;
  }
}

// One encapsulated RecordBatch message and its body, as parts to write.
//   rows, nodes [[length, nulls]], regions [[offset, length]]: the header;
//   body: the body bytes sent; bodyLength: the length the message declares
//   (the body's by default); headerType: 3 (RecordBatch) or another;
//   compressed: a BodyCompression table is present; marker: the
//   continuation; metaLenDelta: added to the declared metadata length;
//   last: the vector written last ('nodes' or 'buffers'), which `truncate`
//   cuts after its count, so its elements lie past the metadata.
// Flatbuffer faults, each in one place: withHeader false leaves the
// Message's header field out; rbSlots is the RecordBatch vtable's slot
// count; nodesPastMeta points the nodes vector past the metadata;
// rbVtableBefore points the RecordBatch table's vtable 2 bytes before the
// metadata; typeAt puts the header type field's offset past the metadata, k
// bytes into the body, where the byte is a RecordBatch's type (3). fill:
// [offset, byte] pairs written into the body.
function message({
  rows,
  nodes,
  regions,
  body = 64,
  bodyLength = body,
  headerType = 3,
  compressed = false,
  marker = 0xffffffff,
  metaLenDelta = 0,
  last = 'nodes',
  truncate = false,
  withHeader = true,
  rbSlots = 5,
  nodesPastMeta = false,
  rbVtableBefore = false,
  typeAt = null,
  fill = [],
}) {
  const fb = new Fb();
  fb.zero(4); // root uoffset
  // Message: version (0), header_type (1), header (2), bodyLength (3)
  const mf = [{ slot: 3, size: 8 }];
  if (withHeader) mf.push({ slot: 2, size: 4 });
  mf.push({ slot: 0, size: 2 }, { slot: 1, size: 1 });
  const m = fb.table(5, mf);
  const mpos = (slot) => m.pos[mf.findIndex((f) => f.slot === slot)];
  fb.link(0, m.t);
  fb.dv.setBigInt64(mpos(3), BigInt(bodyLength), true);
  fb.dv.setInt16(mpos(0), 4, true); // V5
  fb.dv.setUint8(mpos(1), headerType);
  // RecordBatch: length (0), nodes (1), buffers (2), compression (3)
  const fields = [
    { slot: 0, size: 8 },
    { slot: 1, size: 4 },
    { slot: 2, size: 4 },
  ];
  if (compressed) fields.push({ slot: 3, size: 4 });
  const rb = fb.table(rbSlots, fields);
  if (withHeader) fb.link(mpos(2), rb.t);
  if (rbVtableBefore) fb.dv.setInt32(rb.t, rb.t + 2, true);
  fb.dv.setBigInt64(rb.pos[0], BigInt(rows), true);
  if (compressed) fb.link(rb.pos[3], fb.table(2, []).t);
  let end;
  const vec = (which) => {
    const at = fb.pairs(which === 'nodes' ? nodes : regions);
    fb.link(rb.pos[which === 'nodes' ? 1 : 2], at);
    end = at + 4;
  };
  vec(last === 'nodes' ? 'buffers' : 'nodes');
  vec(last);
  if (nodesPastMeta) fb.dv.setUint32(rb.pos[1], 1 << 20, true);
  const metaLen = truncate ? end : Math.ceil(fb.n / 8) * 8;
  if (typeAt !== null) fb.dv.setUint16(m.v + 4 + 2 * 1, metaLen + typeAt - m.t, true);
  const prefix = new Uint8Array(8 + metaLen);
  const dv = new DataView(prefix.buffer);
  dv.setUint32(0, marker, true);
  dv.setInt32(4, metaLen + metaLenDelta, true);
  prefix.set(fb.b.subarray(0, metaLen), 8);
  const bytes = new Uint8Array(body);
  for (const [at, v] of fill) bytes[at] = v;
  if (typeAt !== null) bytes[typeAt] = 3;
  return [prefix, bytes];
}

const one = (rows, nulls, regions, more = {}) => message({ rows, nodes: [[rows, nulls]], regions, ...more });

// Each case's RecordBatch reply, by number; the reason the proxy gives is
// beside it (proxy/ipc.c, kudfw_ipc_decode). The buffer check is six
// conditions, each refused alone by one case: 1 (values past the body), 18
// to 22. Cases 23, 24 and 33 are not corrupt, and the proxy must accept
// them: 23 and 24 each end one buffer exactly at the end of the body, and 33's
// RecordBatch vtable stops before the compression slot (absent, as a
// flatbuffer reader must read it). Case 25's payload is 7 bytes.
const BATCHES = {
  1: () => one(1, 0, [[0, 0], [1 << 20, 8]]), // a buffer lies outside the body: values past it
  2: () => one(2, 0, [[0, 0], [0, 8]]), // a values buffer is shorter than the column
  3: () => message({ rows: 3, nodes: [[3, 0], [3, 0]], regions: [[0, 0], [0, 24], [0, 0], [0, 24]] }), // columns differ
  4: () => one(4, 5, [[0, 1], [0, 32]]), // a null count is out of range
  5: () => message({ rows: 2, nodes: [[3, 0]], regions: [[0, 0], [0, 24]] }), // a column's length differs
  6: () => one(16, 1, [[0, 1], [64, 128]], { body: 192 }), // a validity bitmap is shorter
  7: () => one(1, 0, [[0, 0], [1, 8]]), // a values buffer is not aligned
  8: () => one(2n ** 61n, 0, [[0, 0], [0, 0]]), // rows * 8 wraps to 0: values shorter
  9: () => one(1, 0, [[0, 0], [0, 8]], { compressed: true }), // compressed
  10: () => one(1, 0, [[0, 0], [0, 8]], { headerType: 1 }), // a Schema header
  11: () => one(1, 0, [[0, 0], [0, 8]], { marker: 0 }), // no continuation marker
  12: () => one(1, 0, [[0, 0], [0, 8]], { metaLenDelta: 4 }), // metadata length not a multiple of 8
  13: () => one(1, 0, [[0, 0], [0, 8]], { metaLenDelta: 1 << 20 }), // metadata length past the payload
  14: () => one(1, 0, [[0, 0], [0, 8]], { bodyLength: 128 }), // body past the payload
  15: () => one(-1, 0, [[0, 0], [0, 8]]), // a negative row count
  16: () => one(1, 0, [[0, 0], [0, 8]], { last: 'nodes', truncate: true }), // nodes past the metadata
  17: () => one(1, 0, [[0, 0], [0, 8]], { last: 'buffers', truncate: true }), // buffers past the metadata
  18: () => one(1, 1, [[1 << 20, 1], [0, 8]]), // outside the body: a validity bitmap past it
  19: () => one(1, 1, [[-64, 1], [0, 8]]), // outside the body: a negative validity offset
  20: () => one(1, 0, [[0, -1], [0, 8]]), // outside the body: a negative validity length
  21: () => one(1, 0, [[0, 0], [-8, 8]]), // outside the body: a negative values offset
  22: () => one(1, 0, [[0, 0], [0, -8]]), // outside the body: a negative values length
  23: () => one(1, 0, [[0, 0], [56, 8]]), // accepted: values end at the body's end (one 0)
  24: () => one(1, 1, [[63, 1], [0, 8]]), // accepted: the bitmap ends at the body's end (one null)
  25: () => [Uint8Array.of(0xff, 0xff, 0xff, 0xff, 0, 0, 0)], // shorter than a message prefix
  26: () => one(1, 0, [[0, 0], [0, 8]], { withHeader: false }), // a Message with no header
  27: () => one(1, 0, [[0, 0], [0, 8]], { nodesPastMeta: true }), // malformed: nodes past the metadata
  28: () => message({ rows: 1, nodes: [[1, 0]], regions: [[0, 0], [0, 8], [0, 0], [0, 8]] }), // buffers differ
  29: () => message({ rows: 1, nodes: [[1, 0], [1, 0]], regions: [[0, 0], [0, 8]] }), // columns differ
  30: () => one(1, 0, [[0, 0], [0, 8]], { bodyLength: -64 }), // a negative body length
  31: () => one(1, -1, [[0, 0], [0, 8]]), // a negative null count
  32: () => one(1, 0, [[0, 0], [0, 8]], { rbVtableBefore: true }), // malformed: a vtable before the metadata
  33: () => one(1, 0, [[0, 0], [0, 8]], { rbSlots: 3 }), // accepted: a vtable too short for slot 3 (one 0)
  34: () => one(1, 0, [[0, 0], [0, 8]], { typeAt: 32 }), // not a RecordBatch: the type field is past the metadata
};

function header({ magic = MAGIC, op = OP.OK, id, flags = FLAG_INLINE, len }) {
  const h = Buffer.alloc(HEADER_BYTES);
  h.writeUInt32LE(magic, 0);
  h.writeUInt32LE(op, 4);
  h.writeBigUInt64LE(id, 8);
  h.writeUInt32LE(flags, 16);
  h.writeBigUInt64LE(BigInt(len), 32);
  return h;
}

function errorBody(code, message, messageLen = null) {
  const b = Buffer.alloc(20 + 4 + message.length + 4);
  b.writeInt32LE(code, 0);
  b.writeBigInt64LE(-1n, 4);
  b.writeBigInt64LE(-1n, 12);
  b.writeUInt32LE(messageLen ?? message.length, 20);
  b.write(message, 24, 'latin1');
  b.writeUInt32LE(0, 24 + message.length);
  return b;
}

const ERR_RAISED = 6;

// Each case's whole reply (header and payload), by number: framing breaks
// (channel.c, kudfw_request; the proxy kills the worker) and malformed
// ERROR replies (kudfw_reply_status; the worker stays usable).
const FRAMES = {
  101: (id) => [header({ id, len: 0, magic: 0x12345678 })], // not the wire's magic
  102: (id) => [header({ id: id + 1n, len: 0 })], // another request's id
  103: (id) => [header({ id, len: 0, op: OP.LOAD })], // an op that is not a reply
  104: (id) => [header({ id, len: 0, flags: 0 })], // no INLINE flag
  105: (id) => [header({ id, len: 2n ** 31n + 1n })], // a payload over the limit, never sent
  111: (id) => [header({ id, op: OP.ERROR, len: 10 }), Buffer.alloc(10)], // shorter than an error
  112: (id) => {
    const b = errorBody(ERR_RAISED, 'cut', 1000); // a message longer than the payload
    return [header({ id, op: OP.ERROR, len: b.length }), b];
  },
  113: (id) => {
    const b = errorBody(0, 'an ERROR reply with code 0');
    return [header({ id, op: OP.ERROR, len: b.length }), b];
  },
  114: (id) => {
    const b = errorBody(-5, 'an ERROR reply with code -5');
    return [header({ id, op: OP.ERROR, len: b.length }), b];
  },
  115: (id) => [header({ id, op: OP.ERROR, len: 20 }), errorBody(ERR_RAISED, '').subarray(0, 20)], // no message length
  116: (id) => {
    const b = errorBody(ERR_RAISED, 'a trace longer than the payload');
    b.writeUInt32LE(1000, b.length - 4);
    return [header({ id, op: OP.ERROR, len: b.length }), b];
  },
};

function u32(v) {
  const b = Buffer.alloc(4);
  b.writeUInt32LE(v, 0);
  return b;
}

// DESCRIBE replies that break its encoding (proxy/proxy.c, t_describe), one
// per DESCRIBE in this order, each refused by one length check: shorter than
// the fixed fields and a length; a runtime id of 128 bytes (its buffer's
// size, which leaves no room for the NUL); an id whose bytes and the next
// length run past the reply; a runtime ABI of 64 bytes; an ABI cut short.
// Later DESCRIBEs get `good`, the right reply. Each runtime the test opens
// starts its own admission worker, which answers that runtime's one
// DESCRIBE, so the count is kept in a file in the test's TMPDIR (the
// launcher passes it on), which only this test's workers share.
const DESCRIBES = path.join(process.env.TMPDIR ?? '/tmp', 'komira-udf-corrupt-describes');

function nextDescribe() {
  let n = 0;
  try {
    n = Number(fs.readFileSync(DESCRIBES, 'utf8'));
  } catch {
    n = 0;
  }
  fs.writeFileSync(DESCRIBES, String(n + 1));
  return n;
}

export function describeCorrupt(id, fixed, good) {
  const name = Buffer.from('komira-test/node');
  const bad = [
    () => [fixed, Buffer.alloc(3)],
    () => [fixed, u32(128), Buffer.alloc(128, 0x61), u32(4), Buffer.from('node')],
    () => [fixed, u32(name.length), name, Buffer.alloc(3)],
    () => [fixed, u32(name.length), name, u32(64), Buffer.alloc(64, 0x61)],
    () => [fixed, u32(name.length), name, u32(6), Buffer.from('node2')],
  ];
  const k = nextDescribe();
  const parts = k < bad.length ? bad[k]() : good;
  let len = 0;
  for (const p of parts) len += p.byteLength;
  writeRaw([header({ id, len }), ...parts]);
}

// Answer request `id` with corrupt case `batch`'s reply, if the batch names
// one: true when it did.
export function replyCorrupt(id, batch) {
  if (batch.length !== 1 || batch.cols.length !== 1 || batch.cols[0].nullCount !== 0) return false;
  const k = Number(batch.cols[0].values[0]);
  if (BATCHES[k] !== undefined) {
    const parts = BATCHES[k]();
    let len = 0;
    for (const p of parts) len += p.byteLength;
    writeRaw([header({ id, len }), ...parts]);
    return true;
  }
  if (FRAMES[k] !== undefined) {
    writeRaw(FRAMES[k](id));
    // The payload case's bytes never follow: a proxy that waited for them
    // would wait forever, so the worker exits and the wait ends in EOF.
    if (k === 105) process.exit(0);
    return true;
  }
  return false;
}
