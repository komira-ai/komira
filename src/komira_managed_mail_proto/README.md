# `komira_managed_mail_proto`

## Responsibility

The managed mail API (`komira.managed_mail.v1`): the messages of a simple mail
app as protobuf definitions and the Mojo structs generated from them. The app
has mailboxes, a fixed set of folders (inbox, sent, archive, trash), threads,
a send queue and idempotent inbound delivery, and keeps the raw RFC 5322 bytes
of every message. It is its own JSON API, not IMAP or JMAP. A client and the
app exchange these messages as proto3 canonical JSON over HTTP; this package
is the published wire, and holds no server or client code.

- Resources: `Mailbox` (one address with a display name; a personal
  mailbox names its owner, a `Subject`), `Email`, `EmailAddress`, `EmailPart`,
  `Thread`, `Envelope`, `Submission` (one outbound message in the send queue)
  and `Attachment`.
- `ErrorResponse`, the body of every error reply,
  `{"error":{"code":...,"message":...}}`, with an `ApiError` inside. It is the
  shape `komira_http_server` writes for a fault, so a refusal and a fault
  decode the same way.
- A request and a response message per method: mailboxes (`ListMailboxes`,
  `CreateMailbox`, `DeleteMailbox`); emails and threads (`ListEmails`,
  `GetEmail`, `GetEmailRaw`, `GetEmailPart`, `UpdateEmail`, `GetThread`);
  sending (`SendEmail`, `GetSubmission`); `ExportMailbox`, an mbox file; and
  `EraseSubject`, which deletes the personal mailboxes of one subject.
  `RawBodyReply` stands for a reply body that is raw bytes, not JSON.
- The two contracts with a submission service that sends and receives mail
  for the app over HTTP: inbound delivery (`InboundEnvelope`,
  `InboundDelivery`, `InboundDeliveryResponse`) and HTTP submission
  (`RawMessageRequest`, `RawMessageResponse`).
- Enums: `MailboxKind`, `Folder`, `SubmissionState`.

`mail_service.proto` lists the methods and the HTTP route of each; it is
published as `.proto` source only (the `:mail_service` target), since a
generated `service` brings a gRPC client the app does not use.

## API

The definitions are in
[mail.proto](https://github.com/komira-ai/komira/blob/main/src/komira_managed_mail_proto/mail.proto)
and
[mail_service.proto](https://github.com/komira-ai/komira/blob/main/src/komira_managed_mail_proto/mail_service.proto);
the Mojo module is `komira_managed_mail_proto.mail`. Each message is a struct
whose constructor takes its fields in declaration order (a proto3 `optional`
field or a message field is an `Optional`, a `repeated` field a `List`, a
`bytes` field a `List[UInt8]`); an enum is a struct over its number
(`.value`), with one constant per value. Encode and decode with
`komira_proto_codec`'s `encode_json` and `decode_json` (or `encode_proto` and
`decode_proto` for protobuf binary).

The JSON form of one value of every message is
[tests/goldens/mail_v1.golden](https://github.com/komira-ai/komira/blob/main/src/komira_managed_mail_proto/tests/goldens/mail_v1.golden).

## Examples

Every example below runs as a test when the package is built.

Inbound delivery sends the raw message as the request body and its envelope
as proto3 JSON in the `Komira-Mail-Envelope` header field:

```mojo
from komira_managed_mail_proto.mail import InboundEnvelope
from komira_proto_codec import encode_json
from std.testing import assert_equal

var rcpt = List[String]()
rcpt.append(String("ada@example.com"))
var envelope = InboundEnvelope(
    String("bob@example.org"),  # mail_from
    rcpt^,  # rcpt_to
    String("e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"),  # sha256
)
assert_equal(
    encode_json(envelope),
    '{"mailFrom":"bob@example.org","rcptTo":["ada@example.com"],'
    + '"sha256":"e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"}',
)
```

An update names only the fields it changes, and the app reads a request
strictly: a key that is not a field is refused.

```mojo
from komira_managed_mail_proto.mail import Folder, UpdateEmailRequest
from komira_proto_codec import decode_json
from std.testing import assert_equal, assert_true

var patch = decode_json[UpdateEmailRequest]('{"emailId": "em-0001", "folder": "FOLDER_ARCHIVE"}')
assert_true(not patch.seen)
assert_equal(patch.folder.value().value, Folder.FOLDER_ARCHIVE)

var message = String()
try:
    _ = decode_json[UpdateEmailRequest]('{"emailId": "em-0001", "read": true}')
except e:
    message = String(e)
assert_true(message.startswith('JsonError: unknown field "read" at $'))
```

HTTP submission carries the raw message as a `bytes` field, base64 in JSON:

```mojo
from komira_managed_mail_proto.mail import RawMessageRequest
from komira_proto_codec import encode_json
from std.testing import assert_equal

var recipients = List[String]()
recipients.append(String("bob@example.org"))
var raw: List[UInt8] = [0x48, 0x69, 0x0D, 0x0A]  # "Hi\r\n"
var send = RawMessageRequest(String("ada@example.com"), recipients^, raw^)
assert_equal(
    encode_json(send),
    '{"envelopeFrom":"ada@example.com","recipients":["bob@example.org"],"raw":"SGkNCg=="}',
)
```

An error reply's body is an `ErrorResponse`. A fault body from
`komira_http_server` (`{"error":{"code":...,"message":...,"incidentId":...}}`)
decodes as one too:

```mojo
from komira_managed_mail_proto.mail import ErrorResponse
from komira_proto_codec import decode_json
from std.testing import assert_equal

var reply = decode_json[ErrorResponse](
    '{"error":{"code":"internal","message":"Internal error.","incidentId":"inc-7"}}'
)
assert_equal(reply.error.value().code, "internal")
assert_equal(reply.error.value().incident_id, "inc-7")
```
