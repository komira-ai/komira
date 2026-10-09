// The entry of a worker_threads thread of the workers build: the thread is one
// context's isolate. It loads the addon (a context-aware module: this
// environment gets instance data of its own), builds the adapter and
// attaches to the slot it was started for. From then on engine threads queue
// that slot's calls on this environment's threadsafe function, and the
// thread stays alive for as long as that function is referenced
// (close_context releases it).
'use strict';

const { workerData } = require('node:worker_threads');

const addon = require(workerData.addonPath);
const adapter = require('./adapter.js').create(addon, { codeDir: workerData.codeDir });
addon.attachWorker(adapter, workerData.slot, workerData.codeDir, workerData.addonPath);
