# CPU-level variant fixtures

The inputs of the libkomira variant selector's tests, which check the selector of each language package
against [docs/design/isa_variants.md](../../../../docs/design/isa_variants.md), decision 5, on the same
files and the same table of choices: `_select_variant` in
[`python/komira/_native.py`](../../../komira/_native.py) by
[`../../test_variants.py`](../../test_variants.py), and `selectVariant` in
[`node/src/cpu.ts`](../../../../node/src/cpu.ts) by
[`node/tests/variants.test.ts`](../../../../node/tests/variants.test.ts). The table's `machine` column
spells the machine as Python's `platform.machine()` does; the Node test reads `x86_64` as `x64` and
`aarch64` as `arm64`, as `process.arch` spells them.

- `cpuinfo_*.txt` are `/proc/cpuinfo` texts of one CPU model each, written with the `flags` (x86)
  or `Features` (arm64) words that Linux reports for that model:

  | file | CPU | level |
  |---|---|---|
  | `cpuinfo_x86_64_core2.txt` | Core 2 Duo E8400 | below x86-64-v2 (no SSE4.2, no POPCNT) |
  | `cpuinfo_x86_64_westmere.txt` | Xeon X5670 | x86-64-v2 |
  | [`../cpuinfo_x86_64_v3.txt`](../cpuinfo_x86_64_v3.txt) | the CPU test's fixture | x86-64-v3 |
  | `cpuinfo_x86_64_skylake_sp.txt` | Xeon Gold 6148 | x86-64-v4 |
  | `cpuinfo_aarch64_cortex_a72.txt` | Raspberry Pi 4 | arm64 `generic` |
  | `cpuinfo_aarch64_neoverse_n1.txt` | Neoverse N1 | arm64 `neoverse-n1` |

- `VARIANTS_*` are manifests of rows that do not ship yet: x86-64 with v4, linux-arm64 with
  `neoverse-n1`, and macOS (one line, no features). The manifest linux-x86_64 ships is not here:
  the test reads `//tools/build/package/libkomira:libkomira_variants_manifest`, written from the
  platform row, as `shipped`.
- `choices.tsv` is the expected choice for each pair of a cpuinfo and a manifest, on the system
  and machine named: a variant's name, or `refused` and the features of the lowest variant the CPU
  lacks, in the manifest's order. `-` is no cpuinfo file.
