// komira-test/node: the runtime the worker serves (design sections 4.2 and
// 4.3), one request at a time. A UDF is a module-level export of a bundle
// in the code directory, named by its entry `<bundle>#<export>` (code form
// BUNDLE). The bundle holds only the user's module: apache-arrow and every
// other dependency the runtime needs come from the node_modules beside the
// worker, as a base image provides them.

import fs from 'node:fs';
import { createRequire } from 'node:module';
import path from 'node:path';

import { batchParts, readBatch, readMessages, readSchema } from './arrow_io.mjs';
import { ST, UdfError, column, raised, row, rowShape, scalar } from './calls.mjs';
import { replyCorrupt } from './corrupt.mjs';
import { Frame, Groups } from './frames.mjs';
import { OP, WIRE_VERSION, reply, replyError, replyU64 } from './wire.mjs';

const require = createRequire(import.meta.url);

const SHAPE = { 1: 'SCALAR', 2: 'ROW', 4: 'MAP_BATCHES_COLUMN', 8: 'MAP_BATCHES_FRAME', 16: 'MAP_BATCHES_FRAME_GROUPED', 32: 'AGG_PLAIN', 64: 'AGG_MERGEABLE', 128: 'STEP' };
const SHAPES = 1 | 2 | 4 | 8 | 32 | 64 | 128; // all but MAP_BATCHES_FRAME_GROUPED
const ENTRY = /^([A-Za-z0-9_][A-Za-z0-9_.-]*\.m?js)#([A-Za-z_$][A-Za-z0-9_$]*)$/;

// The caps describe answers, in komira_udf_capabilities order.
const CAPS = [
  0, // max_descriptor_version
  SHAPES,
  2, // threading: CONTEXT_PER_THREAD (one worker per engine thread)
  0, // thread_affine
  2, // transports: WORKER
  1, // hosting: EMBEDDED (node is the launcher; the runtime brings it)
  1, // devices: CPU
  0, // features
  2, // udf_class: MANAGED
  0, // global_lock
];
const RUNTIME_ID = 'komira-test/node';

// The export names of a bundle's source, read without running it: esbuild
// writes an ES module's exports as `export { a, b as c };`.
export function exportsOf(src) {
  const names = new Set();
  for (const m of src.matchAll(/export\s*\{([^}]*)\}/g))
    for (const part of m[1].split(',')) {
      const p = part.trim();
      if (p === '') continue;
      const as = p.split(/\s+as\s+/);
      names.add(as[as.length - 1].trim());
    }
  for (const m of src.matchAll(/export\s+(?:async\s+)?(?:function\*?|const|let|var|class)\s+([A-Za-z_$][A-Za-z0-9_$]*)/g)) names.add(m[1]);
  return names;
}

export class Runtime {
  constructor(codeDir, corrupt = false) {
    this.codeDir = codeDir;
    this.corrupt = corrupt;
    this.ids = 0;
    this.udfs = new Map();
    this.instances = new Map();
    this.frames = new Map();
    this.groups = new Map();
    this.modules = new Map();
    this.stats = { calls: 0, rows: 0, decode_ns: 0n, run_ns: 0n, encode_ns: 0n, idle_ns: 0n };
  }

  // The spec a VALIDATE or LOAD body carries, checked as validate does:
  // from the descriptor, the shape, the types and the bundle's text alone.
  spec(body) {
    let msgs;
    let args;
    let result;
    try {
      msgs = readMessages(body);
      args = readSchema(msgs[0]);
      result = readSchema(msgs[1]);
    } catch (e) {
      throw new UdfError(ST.UNSUPPORTED, `the spec's schemas: ${e.message}`);
    }
    const meta = args.metadata;
    const num = (k) => Number(meta.get(k) ?? '0');
    const s = {
      shape: SHAPE[num('shape')] ?? `shape bit ${num('shape')}`,
      shapeBit: num('shape'),
      form: num('form'),
      entry: meta.get('entry') ?? '',
      nullMode: num('null_mode'),
      descriptorVersion: num('descriptor_version'),
      descriptor: meta.get('descriptor') ?? '',
      args: args.fields,
      result: { isTable: meta.get('result') === 'table', fields: result.fields },
      state: meta.get('state') === '1' ? { fields: readSchema(msgs[2]).fields } : null,
    };
    if (s.form === 0) throw new UdfError(ST.DESCRIPTOR, 'the code form is CODE_FORM_UNSPECIFIED');
    if (s.form !== 2) throw new UdfError(ST.UNSUPPORTED, `code form ${s.form} is not built here; this runtime loads BUNDLE only`);
    if (s.descriptorVersion > CAPS[0])
      throw new UdfError(ST.DESCRIPTOR, `descriptor_version ${s.descriptorVersion} is newer than ${CAPS[0]}, the newest read here`);
    if (s.descriptor !== '') throw new UdfError(ST.DESCRIPTOR, 'descriptor version 0 is empty; these bytes are not canonical');
    if ((s.shapeBit & SHAPES) === 0 || (s.shapeBit & (s.shapeBit - 1)) !== 0)
      throw new UdfError(ST.UNSUPPORTED, `${s.shape} is not a shape this runtime runs`);
    const columnShapes = ['SCALAR', 'ROW', 'MAP_BATCHES_COLUMN', 'AGG_PLAIN', 'AGG_MERGEABLE'];
    if (columnShapes.includes(s.shape) && (s.result.isTable || s.result.fields.length !== 1))
      throw new UdfError(ST.UNSUPPORTED, `${s.shape} returns one column, not a table`);
    if (s.shape === 'AGG_MERGEABLE' && (s.state === null || s.state.fields.length !== 1))
      throw new UdfError(ST.UNSUPPORTED, 'AGG_MERGEABLE needs one state column');
    if (s.shape === 'ROW') {
      const names = s.args.map((f) => f.name);
      if (names.some((n) => n === '') || new Set(names).size !== names.length)
        throw new UdfError(ST.UNSUPPORTED, 'a ROW read set needs unique, non-empty field names');
    }
    const m = ENTRY.exec(s.entry);
    if (m === null) throw new UdfError(ST.DESCRIPTOR, `entry '${s.entry}' is not <bundle>.mjs#<export>`);
    s.bundle = path.join(this.codeDir, m[1]);
    s.exportName = m[2];
    let src;
    try {
      src = fs.readFileSync(s.bundle, 'utf8');
    } catch (e) {
      throw new UdfError(ST.DESCRIPTOR, `entry '${s.entry}': no bundle ${m[1]} in the code directory (${e.code})`);
    }
    if (!exportsOf(src).has(s.exportName))
      throw new UdfError(ST.DESCRIPTOR, `entry '${s.entry}': bundle ${m[1]} exports no '${s.exportName}'`);
    return s;
  }

  // The module of a bundle, imported once per worker (one context).
  module(file) {
    let mod = this.modules.get(file);
    if (mod === undefined) {
      mod = require(file);
      this.modules.set(file, mod);
    }
    return mod;
  }

  openInstance(udfId) {
    const u = this.udfs.get(udfId);
    if (u === undefined) throw new UdfError(ST.INTERNAL, `no udf ${udfId}`);
    let fn;
    try {
      fn = this.module(u.bundle)[u.exportName];
    } catch (e) {
      throw new UdfError(ST.LOAD, `importing ${path.basename(u.bundle)}: ${e.message}`, { trace: e.stack });
    }
    if (u.shape === 'AGG_MERGEABLE') {
      const ok = fn !== null && typeof fn === 'object' && ['init', 'update', 'merge', 'finish'].every((k) => typeof fn[k] === 'function');
      if (!ok) throw new UdfError(ST.LOAD, `'${u.exportName}' is not an aggregate ({init, update, merge, finish})`);
    } else if (typeof fn !== 'function') {
      throw new UdfError(ST.LOAD, `'${u.exportName}' is a ${fn === null ? 'null' : typeof fn}, not a function`);
    }
    const inst = { udf: u, fn, rowShape: u.shape === 'ROW' ? rowShape(u.args.map((f) => f.name)) : null };
    const id = ++this.ids;
    this.instances.set(id, inst);
    return id;
  }

  call(req) {
    const inst = this.instances.get(req.handle);
    if (inst === undefined) throw new UdfError(ST.INTERNAL, `no instance ${req.handle}`);
    const u = inst.udf;
    const t0 = process.hrtime.bigint();
    const batch = readBatch(readMessages(req.body)[0], u.args);
    const t1 = process.hrtime.bigint();
    const fmt = u.result.fields[0].fmt;
    let col;
    if (u.shape === 'SCALAR') col = scalar(inst.fn, req, batch, fmt);
    else if (u.shape === 'ROW') col = row(inst.fn, inst.rowShape, req, batch, fmt);
    else if (u.shape === 'MAP_BATCHES_COLUMN') col = column(inst.fn, req, batch, fmt);
    else throw new UdfError(ST.UNSUPPORTED, `call_batch on a ${u.shape} UDF`);
    const t2 = process.hrtime.bigint();
    if (!(this.corrupt && replyCorrupt(req.id, batch))) reply(req.id, 0, batchParts(col.values.length, [col]));
    const s = this.stats;
    s.calls++;
    s.rows += batch.length;
    s.decode_ns += t1 - t0;
    s.run_ns += t2 - t1;
    s.encode_ns += process.hrtime.bigint() - t2;
  }

  statsText() {
    const m = process.memoryUsage();
    const c = process.cpuUsage();
    const s = this.stats;
    return [
      `v8_heap_used=${m.heapUsed}`,
      `v8_heap_total=${m.heapTotal}`,
      `external=${m.external}`,
      `array_buffers=${m.arrayBuffers}`,
      `rss=${m.rss}`,
      `cpu_user_us=${c.user}`,
      `cpu_system_us=${c.system}`,
      `calls=${s.calls}`,
      `rows=${s.rows}`,
      `decode_ns=${s.decode_ns}`,
      `run_ns=${s.run_ns}`,
      `encode_ns=${s.encode_ns}`,
      `idle_ns=${s.idle_ns}`,
      `node=${process.versions.node}`,
      `v8=${process.versions.v8}`,
    ].join('\n');
  }

  // One request; replies before it returns. SHUTDOWN exits the process.
  handle(req) {
    try {
      this.dispatch(req);
    } catch (e) {
      const u = raised(e, -1);
      replyError(req.id, u.code, u.message, u);
    }
  }

  dispatch(req) {
    switch (req.op) {
      case OP.HELLO: {
        const dv = new DataView(req.body.buffer, req.body.byteOffset, req.body.byteLength);
        const mine = [WIRE_VERSION, 1, 0];
        const got = [0, 4, 8].map((o) => (req.body.byteLength >= o + 4 ? dv.getUint32(o, true) : -1));
        if (got[0] !== mine[0] || got[1] !== mine[1])
          throw new UdfError(ST.ABI, `HELLO: the engine speaks wire ${got[0]}, ABI ${got[1]}.${got[2]}; this worker ${mine.join('.')}`);
        const b = Buffer.alloc(12);
        mine.forEach((v, i) => b.writeUInt32LE(v, 4 * i));
        reply(req.id, 0, [b]);
        return;
      }
      case OP.DESCRIBE: {
        const fixed = Buffer.alloc(40);
        CAPS.forEach((v, i) => fixed.writeUInt32LE(v, 4 * i));
        const strs = [RUNTIME_ID, `node${process.versions.node.split('.')[0]}`].flatMap((s) => {
          const bytes = Buffer.from(s, 'utf8');
          const len = Buffer.alloc(4);
          len.writeUInt32LE(bytes.length, 0);
          return [len, bytes];
        });
        reply(req.id, 0, [fixed, ...strs]);
        return;
      }
      case OP.VALIDATE:
        this.spec(req.body);
        reply(req.id, 0);
        return;
      case OP.LOAD: {
        const s = this.spec(req.body);
        const id = ++this.ids;
        this.udfs.set(id, s);
        replyU64(req.id, id);
        return;
      }
      case OP.UNLOAD:
        this.udfs.delete(req.handle);
        reply(req.id, 0);
        return;
      case OP.OPEN_CONTEXT:
        replyU64(req.id, ++this.ids);
        return;
      case OP.CLOSE_CONTEXT:
        reply(req.id, 0, [Buffer.from(this.statsText(), 'utf8')]);
        return;
      case OP.OPEN_INSTANCE:
        replyU64(req.id, this.openInstance(req.handle));
        return;
      case OP.CLOSE_INSTANCE:
        this.instances.delete(req.handle);
        reply(req.id, 0);
        return;
      case OP.CALL_BATCH:
        this.call(req);
        return;
      case OP.FRAME_OPEN: {
        const inst = this.instances.get(req.handle);
        if (inst === undefined) throw new UdfError(ST.INTERNAL, `no instance ${req.handle}`);
        const id = ++this.ids;
        this.frames.set(id, new Frame(id, inst, inst.udf.shape));
        replyU64(req.id, id);
        return;
      }
      case OP.FRAME_OUT: {
        const f = this.frames.get(req.handle);
        if (f === undefined) throw new UdfError(ST.INTERNAL, `no frame ${req.handle}`);
        f.out(req);
        return;
      }
      case OP.FRAME_IN:
        throw new UdfError(ST.INTERNAL, 'FRAME_IN with no frame waiting for input');
      case OP.FRAME_CLOSE: {
        const f = this.frames.get(req.handle);
        if (f !== undefined) f.close();
        this.frames.delete(req.handle);
        reply(req.id, 0);
        return;
      }
      case OP.AGG_OPEN: {
        const inst = this.instances.get(req.handle);
        if (inst === undefined) throw new UdfError(ST.INTERNAL, `no instance ${req.handle}`);
        const id = ++this.ids;
        this.groups.set(id, new Groups(inst));
        replyU64(req.id, id);
        return;
      }
      case OP.AGG_UPDATE:
      case OP.AGG_MERGE: {
        const g = this.groups.get(req.handle);
        if (g === undefined) throw new UdfError(ST.INTERNAL, `no groups ${req.handle}`);
        g.update(req, req.op === OP.AGG_MERGE);
        reply(req.id, 0);
        return;
      }
      case OP.AGG_STATE:
      case OP.AGG_FINISH: {
        const g = this.groups.get(req.handle);
        if (g === undefined) throw new UdfError(ST.INTERNAL, `no groups ${req.handle}`);
        const col = g.emit(req.emitFirstN, req.op === OP.AGG_FINISH);
        reply(req.id, 0, batchParts(col.values.length, [col]));
        return;
      }
      case OP.AGG_CLOSE:
        this.groups.delete(req.handle);
        reply(req.id, 0);
        return;
      case OP.SHUTDOWN:
        reply(req.id, 0);
        process.exit(0);
        return;
      default:
        throw new UdfError(ST.INTERNAL, `op ${req.op} is not a request this worker serves`);
    }
  }
}
