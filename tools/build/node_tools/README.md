# node_tools

[`node_tools.mjs`](node_tools.mjs) is the one program the `node_modules` rules
([`tools/build/node/modules.bzl`](../node/modules.bzl)) run with the pinned node:
`assemble` lays out `node_modules` from a package-lock.json and pinned tarballs, `run` runs a program of
node_modules over a copy of a source tree. It uses node's own library only (zlib for the tarballs, crypto for
the sha512 check): no shell, no npm, no network. The contract and the planted defects are in
[the node README](../node/README.md#node_modules-from-a-package-lockjson).
