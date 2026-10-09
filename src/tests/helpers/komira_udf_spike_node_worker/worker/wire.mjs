// The worker's end of the UDF worker protocol (komira_udf_wire.h; the
// spike's framing is proxy/kudfw.h's header comment): blocking reads and
// writes on fd 3, the control channel, and reads of the cancel word in the
// shared memory file on fd 4.
//
// Everything here is synchronous. The worker has one thread, which runs
// user code; between requests it blocks in read(2) on the channel.

import fs from 'node:fs';

export const OP = Object.freeze({
  HELLO: 1, DESCRIBE: 2, VALIDATE: 3, LOAD: 4, UNLOAD: 5, OPEN_CONTEXT: 6, CLOSE_CONTEXT: 7,
  OPEN_INSTANCE: 8, CLOSE_INSTANCE: 9, CALL_BATCH: 10, FRAME_OPEN: 11, FRAME_IN: 12, FRAME_OUT: 13,
  FRAME_CLOSE: 14, AGG_OPEN: 15, AGG_UPDATE: 16, AGG_MERGE: 17, AGG_STATE: 18, AGG_FINISH: 19,
  AGG_CLOSE: 20, CANCEL: 21, SHUTDOWN: 22, OK: 128, ERROR: 129,
});

export const MAGIC = 0x4644554b;
export const WIRE_VERSION = 1;
export const FLAG_INLINE = 1;
export const FLAG_END = 2;
export const HEADER_BYTES = 40;
export const HEAD_BYTES = 64;

const SOCK = 3;
const CANCEL_FD = 4;

const header = Buffer.alloc(HEADER_BYTES);
const cancelWord = Buffer.alloc(8);
const napper = new Int32Array(new SharedArrayBuffer(4));

function readExact(buf, off, len) {
  while (len > 0) {
    let k;
    try {
      k = fs.readSync(SOCK, buf, off, len, null);
    } catch (e) {
      if (e.code === 'EAGAIN' || e.code === 'EINTR') {
        Atomics.wait(napper, 0, 0, 1);
        continue;
      }
      throw e;
    }
    if (k === 0) process.exit(0); // the engine closed the channel
    off += k;
    len -= k;
  }
}

function writeAll(parts) {
  let bufs = parts.filter((p) => p.byteLength > 0);
  while (bufs.length > 0) {
    let k;
    try {
      k = fs.writevSync(SOCK, bufs);
    } catch (e) {
      if (e.code === 'EAGAIN' || e.code === 'EINTR') {
        Atomics.wait(napper, 0, 0, 1);
        continue;
      }
      throw e;
    }
    while (bufs.length > 0 && k >= bufs[0].byteLength) {
      k -= bufs[0].byteLength;
      bufs.shift();
    }
    if (bufs.length > 0 && k > 0) bufs[0] = bufs[0].subarray(k);
  }
}

let pushedBack = null;

// The next request: {op, id, flags, handle, deadlineNs, callId, nGroups,
// emitFirstN, body}. `body` is a view of a fresh ArrayBuffer at a 64-byte
// offset, so typed arrays over its 64-aligned buffers need no copy.
export function nextRequest() {
  if (pushedBack !== null) {
    const m = pushedBack;
    pushedBack = null;
    return m;
  }
  readExact(header, 0, HEADER_BYTES);
  const magic = header.readUInt32LE(0);
  const op = header.readUInt32LE(4);
  const id = header.readBigUInt64LE(8);
  const flags = header.readUInt32LE(16);
  const len = Number(header.readBigUInt64LE(32));
  if (magic !== MAGIC || (flags & FLAG_INLINE) === 0 || len < HEAD_BYTES) {
    process.stderr.write(`komira udf worker: a request broke the framing (magic ${magic}, op ${op}, ${len} bytes)\n`);
    process.exit(70);
  }
  const payload = new Uint8Array(new ArrayBuffer(len));
  readExact(payload, 0, len);
  const dv = new DataView(payload.buffer);
  return {
    op,
    id,
    flags,
    handle: Number(dv.getBigUint64(0, true)),
    deadlineNs: dv.getBigInt64(8, true),
    callId: dv.getBigInt64(16, true),
    nGroups: dv.getUint32(24, true),
    emitFirstN: dv.getUint32(28, true),
    body: payload.subarray(HEAD_BYTES),
  };
}

// A request read inside a nested exchange that belongs to the main loop.
export function pushBack(m) {
  pushedBack = m;
}

export function reply(id, flags, parts = []) {
  let total = 0;
  for (const p of parts) total += p.byteLength;
  header.writeUInt32LE(MAGIC, 0);
  header.writeUInt32LE(OP.OK, 4);
  header.writeBigUInt64LE(id, 8);
  header.writeUInt32LE(flags | FLAG_INLINE, 16);
  header.writeUInt32LE(0, 20);
  header.writeBigUInt64LE(0n, 24);
  header.writeBigUInt64LE(BigInt(total), 32);
  writeAll([header, ...parts]);
}

export function replyU64(id, v) {
  const b = Buffer.alloc(8);
  b.writeBigUInt64LE(BigInt(v), 0);
  reply(id, 0, [b]);
}

function str(s) {
  const bytes = Buffer.from(s, 'utf8');
  const len = Buffer.alloc(4);
  len.writeUInt32LE(bytes.length, 0);
  return [len, bytes];
}

export function replyError(id, code, message, { row = -1, group = -1, trace = '' } = {}) {
  const fixed = Buffer.alloc(20);
  fixed.writeInt32LE(code, 0);
  fixed.writeBigInt64LE(BigInt(row), 4);
  fixed.writeBigInt64LE(BigInt(group), 12);
  const line = String(message).replace(/\s+/g, ' ').slice(0, 1000);
  const parts = [fixed, ...str(line), ...str(String(trace || '').slice(0, 4000))];
  let total = 0;
  for (const p of parts) total += p.byteLength;
  header.writeUInt32LE(MAGIC, 0);
  header.writeUInt32LE(OP.ERROR, 4);
  header.writeBigUInt64LE(id, 8);
  header.writeUInt32LE(FLAG_INLINE, 16);
  header.writeUInt32LE(0, 20);
  header.writeBigUInt64LE(0n, 24);
  header.writeBigUInt64LE(BigInt(total), 32);
  writeAll([header, ...parts]);
}

// Whether the engine cancelled request `id`: the cancel word holds the id of
// the request the host's cancel flag was seen set during.
export function cancelRequested(id) {
  fs.readSync(CANCEL_FD, cancelWord, 0, 8, 0);
  return cancelWord.readBigUInt64LE(0) === id;
}
