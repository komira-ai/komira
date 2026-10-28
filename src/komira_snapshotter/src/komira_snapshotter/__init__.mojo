"""`komira_snapshotter` — the provider-agnostic CDC change-stream seam.

This package hosts the ONE seam every change-stream provider (DynamoDB Streams,
Firestore Watch, ...) conforms to, so a snapshotter's apply+write+commit+
checkpoint half is written ONCE, generic over `[L: ChangeStreamListener]`
(one generic binary plus per-provider listeners). It carries NO provider client
code — those live in per-provider packages (komira_aws_dynamodb /
komira_gcp_firestore) that DEPEND on this seam and conform to it.
"""
