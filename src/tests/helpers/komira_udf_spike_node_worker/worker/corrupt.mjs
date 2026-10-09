// Replies that break the worker transport's contract, for the test of the
// engine's validation of everything a worker sends (--corrupt-output;
// tests/test_node_worker.mojo). A call_batch of one row whose value is a
// case number below gets that case's reply instead of its output; any other
// batch is answered normally.
//
// The RecordBatch messages are written by hand, not by apache-arrow, so a
// case can set any field to any value: a flatbuffer laid out front to back
// like the proxy's own writer (proxy/ipc.c), every uoffset pointing forward.

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
    return { t, pos: fo.map((x) => t + x) };
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
}) {
  const fb = new Fb();
  fb.zero(4); // root uoffset
  // Message: version (0), header_type (1), header (2), bodyLength (3)
  const m = fb.table(5, [
    { slot: 3, size: 8 },
    { slot: 2, size: 4 },
    { slot: 0, size: 2 },
    { slot: 1, size: 1 },
  ]);
  fb.link(0, m.t);
  fb.dv.setBigInt64(m.pos[0], BigInt(bodyLength), true);
  fb.dv.setInt16(m.pos[2], 4, true); // V5
  fb.dv.setUint8(m.pos[3], headerType);
  // RecordBatch: length (0), nodes (1), buffers (2), compression (3)
  const fields = [
    { slot: 0, size: 8 },
    { slot: 1, size: 4 },
    { slot: 2, size: 4 },
  ];
  if (compressed) fields.push({ slot: 3, size: 4 });
  const rb = fb.table(5, fields);
  fb.link(m.pos[1], rb.t);
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
  const metaLen = truncate ? end : Math.ceil(fb.n / 8) * 8;
  const prefix = new Uint8Array(8 + metaLen);
  const dv = new DataView(prefix.buffer);
  dv.setUint32(0, marker, true);
  dv.setInt32(4, metaLen + metaLenDelta, true);
  prefix.set(fb.b.subarray(0, metaLen), 8);
  return [prefix, new Uint8Array(body)];
}

const one = (rows, nulls, regions, more = {}) => message({ rows, nodes: [[rows, nulls]], regions, ...more });

// Each case's RecordBatch reply, by number; the reason the proxy gives is
// beside it (proxy/ipc.c, kudfw_ipc_decode).
const BATCHES = {
  1: () => one(1, 0, [[0, 0], [1 << 20, 8]]), // a buffer lies outside the body
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
};

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
