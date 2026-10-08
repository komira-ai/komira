"""komira_kafka_server — a Kafka-protocol server for the komira broker.

Today the package holds its wire codec, the `wire` subpackage
(`komira_kafka_server.wire`): framing, primitive types, the v2 RecordBatch
with CRC-32C, and the request/response message schemas, which are pure bytes
and import nothing outside `wire`; and `produce_error`
(`produce_error_for`), which maps a partition append's error to its Produce
error code by the fixed tokens of the object store's error texts. The
package has no dependencies: `produce_error` carries its own copies of those
tokens.

The server part (connection handling and request dispatch on top of the
broker core) arrives later, in this same package, next to `wire`.
"""
