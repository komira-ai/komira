# `komira_chat_proto`

## Responsibility

The chat API (`komira.chat.v1`): the messages of a small Slack-like chat as
protobuf definitions and the Mojo structs generated from them. A client and
the chat server exchange them as proto3 canonical JSON over HTTP; this package
is the published wire, and holds no server or client code.

- Resources: `Subject` (a token's issuer and subject), `User`, `Channel`
  (public, private or a DM), `Member`, `Message` (one event of a channel's
  timeline: a message, an edit, a delete, a join or a leave), `FileInfo`,
  `ReadState`, `ChannelSync`, `HttpHeader`, and `ApiError`, the body of every
  error reply.
- A request and a response message per method: users (`GetMe`, `GetUser`,
  `ListUsers`); channels and members (`CreateChannel`, `GetChannel`,
  `ListChannels`, `UpdateChannel`, `JoinChannel`, `LeaveChannel`,
  `AddMembers`, `RemoveMember`, `ListMembers`, `OpenDm`); messages
  (`SendMessage`, `EditMessage`, `DeleteMessage`, `ListMessages`,
  `ListThread`, `ListMentions`); read state and sync (`MarkRead`, `Sync`);
  files (`CreateUpload`, `CompleteUpload`, `GetDownloadUrl`); search
  (`SearchMessages`); and erasure of one subject (`EraseSubject`).
- Enums: `ChannelKind`, `EventKind`, `FileState`.

Each channel's timeline is numbered 1, 2, 3, ... (`seq`); a thread reply
names its root's `seq`, and an edit or a delete names its target's.
`chat_service.proto` lists the methods and the HTTP route of each; it is
published as `.proto` source only (the `:chat_service` target), since a
generated `service` brings a gRPC client the chat server does not use.

## API

The definitions are in
[chat.proto](https://github.com/komira-ai/komira/blob/main/src/komira_chat_proto/chat.proto)
and
[chat_service.proto](https://github.com/komira-ai/komira/blob/main/src/komira_chat_proto/chat_service.proto);
the Mojo module is `komira_chat_proto.chat`. Each message is a struct whose
constructor takes its fields in declaration order (a proto3 `optional` field or
a message field is an `Optional`, a `repeated` field a `List`); an enum is a
struct over its number (`.value`), with one constant per value. Encode and
decode with `komira_proto_codec`'s `encode_json` and `decode_json` (or
`encode_proto` and `decode_proto` for protobuf binary).

The JSON form of one value of every message is
[tests/goldens/chat_v1.golden](https://github.com/komira-ai/komira/blob/main/src/komira_chat_proto/tests/goldens/chat_v1.golden).

## Examples

Every example below runs as a test when the package is built.

A send request as a client writes it; an `int64` is a JSON string:

```mojo
from komira_chat_proto.chat import SendMessageRequest
from komira_proto_codec import encode_json
from std.testing import assert_equal

var files = List[String]()
var send = SendMessageRequest(
    String("c-general"),  # channel_id
    String("hi @bob"),  # body
    Int64(40),  # thread_root_seq: a reply in the thread of message 40
    String("m-0001"),  # client_msg_id
    files^,  # file_ids
)
assert_equal(
    encode_json(send),
    '{"channelId":"c-general","body":"hi @bob","threadRootSeq":"40","clientMsgId":"m-0001"}',
)
```

The server reads a request strictly: a key that is not a field is refused.

```mojo
from komira_chat_proto.chat import MarkReadRequest
from komira_proto_codec import decode_json
from std.testing import assert_equal, assert_true

var read = decode_json[MarkReadRequest]('{"channelId": "c-general", "readSeq": "43"}')
assert_equal(read.read_seq, Int64(43))

var message = String()
try:
    _ = decode_json[MarkReadRequest]('{"channelId": "c-general", "seq": "43"}')
except e:
    message = String(e)
assert_true(message.startswith('JsonError: unknown field "seq" at $'))
```

An `optional` field that is present is written even when it holds its
default, so an update can clear a channel's topic:

```mojo
from komira_chat_proto.chat import UpdateChannelRequest
from komira_proto_codec import encode_json
from std.testing import assert_equal

var clear = UpdateChannelRequest(
    String("c-general"),  # channel_id
    None,  # name: unchanged
    Optional[String](String("")),  # topic: cleared
    None,  # archived: unchanged
)
assert_equal(encode_json(clear), '{"channelId":"c-general","topic":""}')
```

## Build files

This package is built with buildrules' `mojo_package` and packaged for mopm as `komira_chat_proto`, version 0.1.0
(`mopm.toml`). Its library is the generator's output, committed at `generated/komira_chat_proto_generated/` and
compiled as the module `komira_chat_proto` (`[targets] lib` of `mopm.toml`); its tests are `tests/`. It depends on one sibling package, `komira_proto_codec` (`{ path = "../komira_proto_codec", version = "0.1" }`), so the `.conda` of this package records `mojo-komira_proto_codec >=0.1,<0.2` as its dependency
and holds none of their files. The files that are not sources:

| file | what |
|---|---|
| `mopm.toml` | the mopm manifest: name, version, the Mojo version, the dependencies and where the library and its tests are |
| `mopm.lock` | the toolchain pins and the path dependencies, direct and transitive (no registry is reached: every dependency is a sibling) |
| `mopm-toolchain.toml` | the exact mopm and Mojo versions the build uses (written by hand) |
| `buildrules.mojo.lock.bzl`, `buildrules.mojo.bzl` | written by `buildrules mojo sync` from the files above and from the manifests of the siblings; `buildrules mojo check` fails when they are stale |

The `.proto` files are the inputs of the generator. `komira_chat_proto_generated_gen` writes the Mojo for them,
`komira_chat_proto_generated_fresh` compares it with the committed directory and fails when they differ, and
`:lib` is built only after that check has passed. Regenerate with
`./buck2 run komira//tools/build/gen:regen -- komira//src/komira_chat_proto:komira_chat_proto_generated`.
`mojo_package` does not run that check itself, so the gate is a target beside it (`BUCK`).

After any change to a `.proto` file, a test, or a manifest of this package or of a sibling, regenerate, run
`buildrules mojo sync` with the packages staged, commit what it writes, and build `komira//src/komira_chat_proto:lib`
on the farm.

`:conda` is buildrules' `mojo_conda` over `:lib`, packed with the manifests of the path dependencies beside its own
(`members`); `:conda_holds` reads it back and fails when the dependencies are not exactly the ones above.
`:komira_chat_proto` is `:lib` as komira's Mojo rules take it (`mojo_adopted_library`): its `deps` are the adopted
target of each package in `[dependencies]`, and the rule refuses a list that is not the closure `:lib` was built from.
It also compiles and runs the README's examples (`[tests][readme]`) against `:lib`.
