// The spike descriptor, version 1, as this runtime reads it: the message and
// canonical form of komira_udf_spike_abi/komira_udf_spike_descriptor.h (the
// C runtimes decode it with native/spike_descriptor.c, and this file gives
// the same refusals, with the same messages). validate compares the spec
// with it (design section 3.1) and opens no code.

import { ST, UdfError } from './calls.mjs';

export const DESCRIPTOR_VERSION = 1;

const SHAPE_NAME = { 1: 'SCALAR', 2: 'ROW', 4: 'MAP_BATCHES_COLUMN', 8: 'MAP_BATCHES_FRAME', 16: 'MAP_BATCHES_FRAME_GROUPED', 32: 'AGG_PLAIN', 64: 'AGG_MERGEABLE', 128: 'STEP' };
const BY_NAME = 2 | 8 | 16; // ROW and MAP_BATCHES_FRAME, grouped or not
const MAX_FIELDS = 128;

const bad = (what) => new UdfError(ST.DESCRIPTOR, `the descriptor is not canonical: ${what}`);

class Reader {
  constructor(bytes) {
    this.b = bytes;
    this.at = 0;
  }

  more() {
    return this.at < this.b.length;
  }

  // A varint in its shortest form, at most 32 bits wide.
  varint() {
    let x = 0n;
    for (let i = 0; i < 10; i++) {
      if (this.at >= this.b.length) throw bad('a varint runs past the end');
      const c = this.b[this.at++];
      x |= BigInt(c & 0x7f) << BigInt(7 * i);
      if ((c & 0x80) === 0) {
        if (i > 0 && c === 0) throw bad('a varint is longer than its shortest form');
        if (x > 0xffffffffn) throw bad('a varint above 32 bits');
        return Number(x);
      }
    }
    throw bad('a varint of more than ten bytes');
  }

  bytes() {
    const l = this.varint();
    if (l > this.b.length - this.at) throw bad('a length runs past the end');
    const s = this.b.subarray(this.at, this.at + l);
    this.at += l;
    return s;
  }

  // The next tag, held to the canonical order: [field, wire type].
  tag(state, repeated) {
    const t = this.varint();
    const field = Math.floor(t / 8);
    const wt = t & 7;
    if (field === 0) throw bad('field number 0');
    if (field < state.last) throw bad('fields out of ascending order');
    if (field === state.last && !repeated.includes(field)) throw bad(`field ${field} appears twice`);
    state.last = field;
    return [field, wt];
  }
}

function wantWt(field, wt, want) {
  if (wt !== want) throw bad(`field ${field} has wire type ${wt}, not ${want}`);
}

const utf8 = new TextDecoder();

// message SpikeField { string name = 1; string format = 2; }
function fieldMsg(bytes) {
  const r = new Reader(bytes);
  const st = { last: 0 };
  const f = { name: null, format: null };
  while (r.more()) {
    const [field, wt] = r.tag(st, []);
    if (field !== 1 && field !== 2) throw bad(`an unknown field ${field} in a field`);
    wantWt(field, wt, 2);
    const s = r.bytes();
    if (s.length === 0) throw bad('an empty string is emitted');
    if (field === 1) f.name = utf8.decode(s);
    else f.format = utf8.decode(s);
  }
  if (f.format === null) throw bad('a field without a format');
  return f;
}

function push(list, bytes) {
  if (list.length >= MAX_FIELDS) throw bad('more fields than this decoder holds');
  list.push(fieldMsg(bytes));
}

export function decode(bytes) {
  const r = new Reader(bytes);
  const st = { last: 0 };
  const d = { entry: '', shapes: 0, args: [], result: [], resultIsTable: false, state: null, recorded: null };
  while (r.more()) {
    const [field, wt] = r.tag(st, [3, 4]);
    switch (field) {
      case 1: {
        wantWt(field, wt, 2);
        const s = r.bytes();
        if (s.length === 0) throw bad('an empty entry is emitted');
        d.entry = utf8.decode(s);
        break;
      }
      case 2: {
        wantWt(field, wt, 0);
        const v = r.varint();
        if (v === 0) throw bad('shapes 0 is emitted');
        d.shapes = v;
        break;
      }
      case 3:
      case 4:
        wantWt(field, wt, 2);
        push(field === 3 ? d.args : d.result, r.bytes());
        break;
      case 5: {
        wantWt(field, wt, 0);
        if (r.varint() !== 1) throw bad('result_is_table is emitted as other than true');
        d.resultIsTable = true;
        break;
      }
      case 6:
        wantWt(field, wt, 2);
        d.state = fieldMsg(r.bytes());
        break;
      case 7: {
        wantWt(field, wt, 2);
        const rr = new Reader(r.bytes());
        const rst = { last: 0 };
        d.recorded = { fields: [], keys: [] };
        while (rr.more()) {
          const [f2, wt2] = rr.tag(rst, [1, 2]);
          if (f2 !== 1 && f2 !== 2) throw bad(`an unknown field ${f2} in recorded_fields`);
          wantWt(f2, wt2, 2);
          push(f2 === 1 ? d.recorded.fields : d.recorded.keys, rr.bytes());
        }
        break;
      }
      default:
        throw bad(`an unknown field ${field} in the descriptor`);
    }
  }
  return d;
}

const TYPE = { l: 'int64', g: 'float64', i: 'int32', '+s': 'struct' };
const typeName = (fmt) => TYPE[fmt] ?? `'${fmt}'`;

function differs(specFmt, f, where) {
  if (f.format === specFmt) return;
  throw new UdfError(ST.DESCRIPTOR, `${where}: the spec says ${typeName(specFmt)}, the descriptor ${typeName(f.format)}`);
}

const byteOrder = (a, b) => Buffer.compare(Buffer.from(a, 'utf8'), Buffer.from(b, 'utf8'));

function listOrder(list, name) {
  for (let i = 0; i < list.length; i++) {
    if (list[i].name === null) throw new UdfError(ST.DESCRIPTOR, `recorded_fields.${name}[${i}] has no name`);
    if (i === 0) continue;
    const c = byteOrder(list[i - 1].name, list[i].name);
    if (c === 0) throw new UdfError(ST.DESCRIPTOR, `recorded_fields.${name} repeats the name '${list[i].name}'`);
    if (c > 0)
      throw new UdfError(ST.DESCRIPTOR, `recorded_fields.${name} is not sorted by name: '${list[i - 1].name}' before '${list[i].name}'`);
  }
}

// validate's comparison: `s` is the spec (runtime.mjs, Runtime.spec), with
// `descriptorVersion` and `descriptor` (hex) from its metadata.
export function check(s) {
  if (s.descriptorVersion === 0)
    throw new UdfError(ST.DESCRIPTOR, 'descriptor_version 0 carries no descriptor, and validate compares the signature the descriptor records');
  if (s.descriptorVersion > DESCRIPTOR_VERSION)
    throw new UdfError(ST.DESCRIPTOR, `descriptor_version ${s.descriptorVersion} is newer than ${DESCRIPTOR_VERSION}, the newest read here`);
  const d = decode(Buffer.from(s.descriptor, 'hex'));
  if (d.entry !== s.entry) throw new UdfError(ST.DESCRIPTOR, `the descriptor's entry '${d.entry}' is not the spec's entry '${s.entry}'`);
  const shape = s.shapeBit;
  if ((d.shapes & shape) === 0 || (shape & (shape - 1)) !== 0)
    throw new UdfError(ST.DESCRIPTOR, `the descriptor does not list the shape ${SHAPE_NAME[shape] ?? 'an unknown shape'} for this entry`);
  if ((shape & BY_NAME) !== 0) {
    if (d.recorded !== null) {
      const { fields, keys } = d.recorded;
      listOrder(fields, 'fields');
      listOrder(keys, 'key_fields');
      for (const k of keys)
        if (fields.some((f) => f.name === k.name)) throw new UdfError(ST.DESCRIPTOR, `recorded_fields: the key '${k.name}' is also in fields`);
      const union = [...fields, ...keys].sort((a, b) => byteOrder(a.name, b.name));
      const args = [...s.args].sort((a, b) => byteOrder(a.name, b.name));
      const same = union.length === args.length && union.every((f, i) => f.name === args[i].name);
      if (!same)
        throw new UdfError(
          ST.READ_SET_MISMATCH,
          `the descriptor records the fields {${union.map((f) => f.name).join(', ')}}, the spec's arg_types are named {${args.map((f) => f.name).join(', ')}}`,
        );
      for (let i = 0; i < args.length; i++) differs(args[i].fmt, union[i], `arg_types field '${args[i].name}'`);
    }
  } else {
    if (s.args.length !== d.args.length)
      throw new UdfError(ST.DESCRIPTOR, `arg_types: the spec has ${s.args.length}, the descriptor ${d.args.length}`);
    s.args.forEach((f, i) => differs(f.fmt, d.args[i], `arg_types[${i}]`));
  }
  const table = s.result.isTable;
  const word = (t) => (t ? 'a table' : 'a column');
  if (table !== d.resultIsTable) throw new UdfError(ST.DESCRIPTOR, `return_type: the spec says ${word(table)}, the descriptor ${word(d.resultIsTable)}`);
  if (s.result.fields.length !== d.result.length)
    throw new UdfError(ST.DESCRIPTOR, `return_type: the spec has ${s.result.fields.length} fields, the descriptor ${d.result.length}`);
  s.result.fields.forEach((f, i) => differs(f.fmt, d.result[i], table ? `return_type[${i}]` : 'return_type'));
  if ((s.state !== null) !== (d.state !== null))
    throw new UdfError(ST.DESCRIPTOR, `state_type: the spec has ${s.state !== null ? 'one' : 'none'}, the descriptor ${d.state !== null ? 'one' : 'none'}`);
  if (s.state !== null) differs(s.state.fields[0].fmt, d.state, 'state_type');
}
