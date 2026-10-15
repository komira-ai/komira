// The two programs the node_modules rules run with the pinned node
// (tools/build/node/modules.bzl, tools/build/node/README.md):
//
//   node_tools.mjs assemble <spec.json> <out>   lay out node_modules from package-lock.json and pinned tarballs
//   node_tools.mjs run <spec.json> <out>        run a program of node_modules over a source tree
//
// Everything is node's own library: no shell, no npm, no network, no install
// script. Every failure prints one `node_modules:` line naming the package or
// the program and exits non-zero; a half-written output is never accepted
// because the action fails.
import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import zlib from 'node:zlib';

function die(msg) {
    console.error(`node_modules: ${msg}`);
    process.exit(1);
}

function readJson(file, what) {
    try {
        return JSON.parse(fs.readFileSync(file, 'utf8'));
    } catch (e) {
        return die(`${what} ${file} is not readable JSON: ${e.message}`);
    }
}

// ---- tar --------------------------------------------------------------------

function octal(field) {
    const s = Buffer.from(field).toString('latin1').replace(/[\0 ]+$/, '').replace(/^ +/, '');
    if (s === '') return 0;
    if (!/^[0-7]+$/.test(s)) throw new Error(`header field ${JSON.stringify(s)} is not octal`);
    return parseInt(s, 8);
}

function cstr(field) {
    const b = Buffer.from(field);
    const z = b.indexOf(0);
    return b.subarray(0, z < 0 ? b.length : z).toString('utf8');
}

// pax extended header records: "<len> <key>=<value>\n".
function paxRecords(data) {
    const out = {};
    let off = 0;
    while (off < data.length) {
        const sp = data.indexOf(0x20, off);
        if (sp < 0) throw new Error('pax record without a length');
        const len = parseInt(data.subarray(off, sp).toString('latin1'), 10);
        if (!(len > sp - off) || off + len > data.length) throw new Error('pax record length is wrong');
        const rec = data.subarray(sp + 1, off + len - 1).toString('utf8');
        const eq = rec.indexOf('=');
        if (eq > 0) out[rec.slice(0, eq)] = rec.slice(eq + 1);
        off += len;
    }
    return out;
}

// Yields {name, type, mode, data} for every entry of an uncompressed tar.
function* tarEntries(buf) {
    let off = 0;
    let longName = null;
    let pax = {};
    while (off + 512 <= buf.length) {
        const h = buf.subarray(off, off + 512);
        if (h.every((b) => b === 0)) return;
        let sum = 0;
        for (let i = 0; i < 512; i++) sum += i >= 148 && i < 156 ? 32 : h[i];
        if (sum !== octal(h.subarray(148, 156))) throw new Error('a tar header checksum is wrong');
        const type = h[156] === 0 ? '0' : String.fromCharCode(h[156]);
        const size = octal(h.subarray(124, 136));
        const mode = octal(h.subarray(100, 108));
        let name = cstr(h.subarray(0, 100));
        if (cstr(h.subarray(257, 262)) === 'ustar') {
            const prefix = cstr(h.subarray(345, 500));
            if (prefix) name = `${prefix}/${name}`;
        }
        off += 512;
        if (off + size > buf.length) throw new Error('the tar ends inside an entry');
        const data = buf.subarray(off, off + size);
        off += Math.ceil(size / 512) * 512;
        if (type === 'x') { pax = { ...pax, ...paxRecords(data) }; continue; }
        if (type === 'g' || type === 'K') continue;
        if (type === 'L') { longName = cstr(data); continue; }
        if (pax.path !== undefined) name = pax.path;
        if (longName !== null) name = longName;
        pax = {};
        longName = null;
        yield { name, type, mode, data };
    }
}

// What npm does with a tarball: the first path component is dropped whatever
// it is; links are not extracted. Files are 0644, or 0755 when the tarball
// marks them executable. Returns the number of files written.
function extractPackage(tgz, dest) {
    let files = 0;
    let links = 0;
    fs.mkdirSync(dest, { recursive: true });
    for (const e of tarEntries(zlib.gunzipSync(tgz))) {
        const parts = e.name.split('/').filter((p) => p !== '' && p !== '.');
        if (parts.includes('..') || e.name.startsWith('/')) throw new Error(`the entry ${JSON.stringify(e.name)} leaves the package`);
        const rel = parts.slice(1);
        if (e.type === '1' || e.type === '2') { links++; continue; }
        if (rel.length === 0) continue;
        const target = path.join(dest, ...rel);
        if (e.type === '5') {
            fs.mkdirSync(target, { recursive: true, mode: 0o755 });
        } else if (e.type === '0' || e.type === '7') {
            fs.mkdirSync(path.dirname(target), { recursive: true });
            fs.writeFileSync(target, e.data);
            fs.chmodSync(target, e.mode & 0o111 ? 0o755 : 0o644);
            files++;
        }
    }
    return { files, links };
}

// ---- assemble ---------------------------------------------------------------

// npm's os/cpu/libc test: a list of allowed names, or of `!name` refusals.
function platformOk(list, current) {
    if (!Array.isArray(list) || list.length === 0) return true;
    const refused = list.filter((x) => x.startsWith('!')).map((x) => x.slice(1));
    const allowed = list.filter((x) => !x.startsWith('!'));
    if (refused.includes(current)) return false;
    return allowed.length === 0 || allowed.includes(current);
}

const NM = 'node_modules/';

function assemble(specFile, out) {
    const spec = readJson(specFile, 'the spec');
    const lock = readJson(spec.lockfile, 'the lockfile');
    if (lock.lockfileVersion !== 3 || typeof lock.packages !== 'object' || lock.packages === null) {
        die(`${spec.lockfile}: not a lockfileVersion 3 package-lock.json`);
    }
    const current = { os: 'linux', cpu: 'x64', libc: 'glibc' };
    const problems = [];
    const installed = [];
    const skipped = [];
    const withBin = [];
    const installScripts = [];

    const paths = Object.keys(lock.packages).filter((p) => p !== '').sort((a, b) => a.length - b.length || (a < b ? -1 : 1));
    for (const p of paths) {
        const e = lock.packages[p];
        if (!p.startsWith(NM)) continue; // a workspace member: no tarball (kpin skips it too)
        if (e.link) continue;
        const at = p.lastIndexOf(NM);
        const name = e.name ?? p.slice(at + NM.length);
        const key = `${name}@${e.version}`;
        const dest = path.join(out, p.slice(NM.length));
        if (e.hasInstallScript) installScripts.push(`${p} ${key}`);
        const why = ['os', 'cpu', 'libc'].find((f) => !platformOk(e[f], current[f]));
        if (why !== undefined) {
            if (e.optional) { skipped.push(`${p} ${key}: optional, ${why} ${JSON.stringify(e[why])} excludes ${current[why]}`); continue; }
            problems.push(`${key} (${p}) needs ${why} ${JSON.stringify(e[why])} and is not optional`);
            continue;
        }
        if (e.inBundle) {
            // Inside its parent's tarball: it must be there.
            if (!fs.existsSync(path.join(dest, 'package.json'))) problems.push(`${key} (${p}) is bundled but its parent's tarball holds no ${p}/package.json`);
            else if (e.bin) withBin.push([p, e]);
            continue;
        }
        const tarball = spec.tarballs[key];
        if (tarball === undefined) { problems.push(`${key} (${p}) has no pinned tarball: pins.lock.bzl is stale (kpin update)`); continue; }
        const want = e.integrity;
        if (typeof want !== 'string' || !want.startsWith('sha512-')) { problems.push(`${key} (${p}) has no sha512 integrity in the lockfile`); continue; }
        if (spec.sri512[key] !== want) { problems.push(`${key}: the lockfile says ${want}, the pinned lock says ${spec.sri512[key]} (kpin check)`); continue; }
        const bytes = fs.readFileSync(tarball);
        const got = 'sha512-' + crypto.createHash('sha512').update(bytes).digest('base64');
        if (got !== want) { problems.push(`${key}: the tarball is ${got}, the lockfile says ${want}`); continue; }
        try {
            const r = extractPackage(bytes, dest);
            const pj = readJson(path.join(dest, 'package.json'), `${key}: package.json of`);
            if (pj.name !== name || pj.version !== e.version) {
                problems.push(`${key}: its package.json says ${pj.name}@${pj.version}`);
                continue;
            }
            installed.push(p);
            if (r.links > 0) skipped.push(`${p} ${key}: ${r.links} link entr${r.links === 1 ? 'y' : 'ies'} in the tarball, not extracted (npm drops them)`);
        } catch (err) {
            problems.push(`${key}: ${err.message}`);
            continue;
        }
        if (e.bin) withBin.push([p, e]);
    }

    // .bin: for every package with executables, a relative symlink in the
    // node_modules directory that holds it (so nested packages link in their
    // own nested .bin), the executable made executable. The shallowest
    // package wins a name two want.
    const bins = new Map();
    for (const [p, e] of withBin) {
        const at = p.lastIndexOf(NM);
        const parent = p.slice(0, at + NM.length - 1); // .../node_modules
        const pkgRel = p.slice(at + NM.length);
        const name = e.name ?? pkgRel;
        const table = typeof e.bin === 'string' ? { [name.split('/').pop()]: e.bin } : e.bin;
        for (const [cmd, file] of Object.entries(table)) {
            const clean = path.posix.normalize(file).replace(/^\.\//, '');
            if (clean.startsWith('..') || clean.startsWith('/')) { problems.push(`${name}: bin ${cmd} leaves the package`); continue; }
            const target = path.join(out, p.slice(NM.length), clean);
            if (!fs.existsSync(target)) { skipped.push(`${p}: bin ${cmd} -> ${clean} is not in the tarball, no link`); continue; }
            const dir = path.join(out, parent.slice(NM.length - 1), '.bin');
            const link = path.join(dir, cmd);
            if (bins.has(link)) continue;
            bins.set(link, true);
            fs.mkdirSync(dir, { recursive: true });
            fs.chmodSync(target, 0o755);
            fs.symlinkSync(path.relative(dir, target), link);
        }
    }

    if (problems.length > 0) {
        for (const x of problems.slice(0, 40)) console.error(`node_modules: ${x}`);
        if (problems.length > 40) console.error(`node_modules: ... and ${problems.length - 40} more`);
        process.exit(1);
    }
    fs.writeFileSync(path.join(out, '.komira-node-modules.json'), JSON.stringify({ installed: installed.length, installScriptsNotRun: installScripts, skipped }, null, 2) + '\n');
    console.error(`node_modules: ${installed.length} packages, ${bins.size} bin links, ${skipped.length} skipped, ${installScripts.length} install scripts not run`);
}

// ---- run --------------------------------------------------------------------

function copyTree(src, dst) {
    fs.mkdirSync(dst, { recursive: true });
    for (const d of fs.readdirSync(src, { withFileTypes: true })) {
        const s = path.join(src, d.name);
        const t = path.join(dst, d.name);
        if (d.isDirectory()) copyTree(s, t);
        else {
            fs.copyFileSync(s, t);
            fs.chmodSync(t, fs.statSync(s).mode & 0o111 ? 0o755 : 0o644);
        }
    }
}

function run(specFile, out) {
    const spec = readJson(specFile, 'the spec');
    const scratch = process.env.KOMIRA_SCRATCH;
    if (!scratch) die('KOMIRA_SCRATCH is not set (the rule sets it)');
    const work = path.join(scratch, 'work');
    copyTree(path.resolve(spec.tree), work);
    const pkg = path.join(work, spec.package);
    fs.mkdirSync(pkg, { recursive: true });
    fs.symlinkSync(path.resolve(spec.modules), path.join(pkg, 'node_modules'));
    const program = path.join(pkg, spec.program);
    if (!fs.existsSync(program)) die(`${spec.program} is not in ${spec.package}/ (a package missing from node_modules, or a bin it does not declare)`);
    const home = path.join(scratch, 'home');
    const tmp = path.join(scratch, 'tmp');
    fs.mkdirSync(home, { recursive: true });
    fs.mkdirSync(tmp, { recursive: true });
    const env = {
        LC_ALL: 'C',
        TZ: 'UTC0',
        HOME: home,
        TMPDIR: tmp,
        PATH: [path.dirname(process.execPath), path.join(scratch, 'bin')].join(':'),
        LD_LIBRARY_PATH: process.env.LD_LIBRARY_PATH ?? '',
        ...spec.env,
    };
    const r = spawnSync(process.execPath, [program, ...spec.args], { cwd: pkg, env, stdio: 'inherit' });
    if (r.error) die(`${spec.program}: ${r.error.message}`);
    if (r.status !== 0) die(`${spec.program} ${r.signal ? `was killed by ${r.signal}` : `exited ${r.status}`}`);
    if (spec.outDir) {
        const from = path.join(pkg, spec.outDir);
        if (!fs.existsSync(from)) die(`${spec.program} passed but wrote no ${spec.outDir}/`);
        copyTree(from, out);
    } else {
        fs.writeFileSync(out, '');
    }
}

const [mode, specFile, out] = process.argv.slice(2);
if (mode === 'assemble' && specFile && out) assemble(specFile, out);
else if (mode === 'run' && specFile && out) run(specFile, out);
else die('usage: node_tools.mjs assemble|run <spec.json> <out>');
