# kci_pkg_upload fidelity fixtures

`kci_pkg_upload`'s legacy upload is meant to be the request `uv publish`
sends, byte for byte. That is a claim about another program's wire format,
so it is measured, not transcribed from documentation: `uv_fidelity`
([`main.zig`](main.zig), [`uv_fidelity.zig`](uv_fidelity.zig)) builds small,
deterministic probe wheels, runs the pinned `uv publish`
([third_party/uv](../../../../third_party/uv/README.md)) at a recorder bound to
127.0.0.1, and writes what arrived. The welded Mojo test
[`test_pkg_upload_uv_fidelity.mojo`](../test_pkg_upload_uv_fidelity.mojo)
builds the same upload with the Mojo client and compares it with the
recording, byte for byte, after putting the client's boundary where uv's
random one was (both are 67 characters, so even the Content-Length agrees).

No real registry is contacted: the publish URL is
`http://127.0.0.1:<ephemeral>/legacy/`, the credential is a fixed placeholder
that is not a token of any index, uv runs with no environment but its own
scratch directories, its configuration and keyring disabled, and trusted
publishing set to never.

## The files

Per case (`minimal`, `rich`, `description_header`; `uv_fidelity.zig` says
what each covers):

| file | what |
|---|---|
| `<case>.whl` | the probe wheel uv uploaded: every member dated at the MS-DOS epoch (date field 0x0021, time 0), members sorted by name, stored (not deflated), mode 0644 |
| `<case>.METADATA` | that wheel's `.dist-info/METADATA`, the text the Mojo client takes as `upload_meta` (it has no archive reader) |
| `<case>.request` | what uv sent: `KEY value` lines (`METHOD`, `PATH`, `CONTENT-TYPE`, `ACCEPT`, `BOUNDARY`, `FILENAME`, `BODY-LENGTH`), a blank line, then the raw request body |

The Authorization header is not stored. The capture refuses a request whose
Authorization is not exactly `Basic base64("__token__:" + placeholder)`, and
the Mojo test asserts its own header is the same function of the same
placeholder.

## The targets

All in [`src/kci_pkg_upload/BUCK`](../../BUCK):

| target | what | built by the pull-request check |
|---|---|---|
| `:uv_fidelity_unit` | `zig test` of [`uv_fidelity_test.zig`](uv_fidelity_test.zig): the wheel is deterministic and is the committed `.whl`; each committed `.METADATA` is the generator's; the recorder's parser; a recorded request renders to the committed `.request` byte for byte; a capture with another Authorization, or none, is refused | yes |
| `:uv_fidelity` | the tool, built only behind `:uv_fidelity_unit` | yes |
| `:uv_fidelity_capture` | runs the pinned uv on the worker; its output is a directory of the nine fixture files | no |
| `:uv_fidelity_check` | captures the same way and compares with the committed files (each `.request` after its boundary is normalised); fails with a diff summary naming each file that differs and its first differing byte | no |

The capture and the check need the uv download, so they are declared only
when `-c komira.uv_fidelity=true` is given: no `//...` build and no
pull-request check builds them.

## Refreshing the fixtures

Everything runs on the farm; nothing runs uv or the tool on your machine.

1. Check first: `./buck2 build -c komira.uv_fidelity=true //src/kci_pkg_upload:uv_fidelity_check`.
   Green means the fixtures already reproduce. Red prints what differs.
2. Capture: `./buck2 build -c komira.uv_fidelity=true //src/kci_pkg_upload:uv_fidelity_capture --show-full-output`.
   The last line names the output directory under `buck-out`.
3. Copy the nine files of that directory over the ones here, and review
   the diff: a changed `.request` means uv now sends something else, and
   the Mojo client (`legacy_upload.mojo`, `core_metadata.mojo`) must change
   with it, or `test_pkg_upload_uv_fidelity.mojo` goes red.
4. Build `//src/kci_pkg_upload:kci_pkg_upload` (the Mojo test) and
   `//src/kci_pkg_upload:uv_fidelity_unit` (which embeds the fixtures).
