"""`komira_xml_conformance`: komira_xml's canonical form against the AWS
conformance harness's XML equivalence, over botocore's rest-xml corpus.

Test-only; nothing depends on it, and it exports nothing. Its one welded
test, tests/test_xml_canonical_differential.mojo, is the whole check; the
package exists so that test gates a target of its own instead of
komira_aws_core.
"""
