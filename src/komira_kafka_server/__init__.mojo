"""komira_kafka_server — a Kafka-protocol server for the komira broker.

Today the package holds only its wire codec, the `wire` subpackage
(`komira_kafka_server.wire`): framing, primitive types, the v2 RecordBatch
with CRC-32C, and the request/response message schemas. It is pure bytes and
imports nothing outside itself.

The server part (connection handling and request dispatch on top of the
broker core) arrives later, in this same package, next to `wire`.
"""
