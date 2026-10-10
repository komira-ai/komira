// The dynamic symbol table of the addon c_shared_lib built (BUCK, `addon`)
// defines exactly the two symbols node looks up when it loads a Node-API
// module, napi_register_module_v1 and node_api_module_get_api_version_v1:
// -fvisibility=hidden keeps every other function of addon.c out of it, the
// non-static addon_next_count included. The ELF file is read here, field by
// field (ELF-64, little-endian), so the test needs no tool from the worker.
'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const SHT_DYNSYM = 11;
const STB_LOCAL = 0;
const SHN_UNDEF = 0;

// The names of the symbols .dynsym defines with global or weak binding.
function definedDynamicSymbols(file) {
  const b = fs.readFileSync(file);
  assert.equal(b.toString('latin1', 0, 4), '\x7fELF', `${file} is not an ELF file`);
  assert.equal(b[4], 2, `${file} is not ELF-64`);
  assert.equal(b[5], 1, `${file} is not little-endian`);
  const shoff = Number(b.readBigUInt64LE(0x28));
  const shentsize = b.readUInt16LE(0x3a);
  const shnum = b.readUInt16LE(0x3c);
  const section = (i) => {
    const at = shoff + i * shentsize;
    return {
      type: b.readUInt32LE(at + 4),
      offset: Number(b.readBigUInt64LE(at + 0x18)),
      size: Number(b.readBigUInt64LE(at + 0x20)),
      link: b.readUInt32LE(at + 0x28),
      entsize: Number(b.readBigUInt64LE(at + 0x38)),
    };
  };
  const dynsyms = [];
  for (let i = 0; i < shnum; i++) if (section(i).type === SHT_DYNSYM) dynsyms.push(section(i));
  assert.equal(dynsyms.length, 1, `${file} has ${dynsyms.length} .dynsym sections`);
  const sym = dynsyms[0];
  const str = section(sym.link);
  const names = [];
  for (let at = sym.offset; at < sym.offset + sym.size; at += sym.entsize) {
    const bind = b[at + 4] >> 4;
    const shndx = b.readUInt16LE(at + 6);
    if (bind === STB_LOCAL || shndx === SHN_UNDEF) continue;
    const start = str.offset + b.readUInt32LE(at);
    names.push(b.toString('latin1', start, b.indexOf(0, start)));
  }
  return names.sort();
}

const got = definedDynamicSymbols(path.join(__dirname, 'addon.node'));
assert.deepEqual(got, ['napi_register_module_v1', 'node_api_module_get_api_version_v1'],
  `the addon exports ${JSON.stringify(got)}`);
console.log(`addon exports ${got.join(', ')}`);
