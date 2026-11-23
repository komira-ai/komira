# komira_test_fake_azure: a fake Azure Blob service in memory, for welded
# tests of Azure readers (fake_azure.mojo says what it serves and which fault
# it injects).
from .fake_azure import (
    FakeAzureConnector,
    FakeAzureState,
    FakeAzureStream,
    fake_azure_answer,
    fake_azure_unquote,
)
