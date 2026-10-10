# What a clone of a SharedCredsSource shares, over a provider that keeps its
# OWN cache by value (the shape of DefaultChainCredsSource: not shared, not
# thread safe, not cloned by copying its source).
#
# The provider here is Copyable and caches its first credential in a plain
# field. If a clone of the shared source copied the provider, each clone would
# have an empty cache of its own and call the endpoint again; shared, the one
# provider answers every clone from its one cache, so the endpoint is called
# exactly once however many clones sign.

from std.memory import ArcPointer
from std.testing import assert_equal

from komira_aws_core import AwsCredential, AwsCredsSource, SharedCredsSource


struct _Endpoint(Movable):
    var calls: Int

    def __init__(out self):
        self.calls = 0


struct _CachingProvider(AwsCredsSource, Copyable, Movable, Deinitable):
    var _endpoint: ArcPointer[_Endpoint]
    var _cached: Optional[AwsCredential]

    def __init__(out self, endpoint: ArcPointer[_Endpoint]):
        self._endpoint = endpoint
        self._cached = None

    def credentials(mut self) raises -> AwsCredential:
        if self._cached:
            return self._cached.value()
        self._endpoint[].calls += 1
        var cred = AwsCredential(
            String("ASIACACHED"), String("CANARY-SECRET"), String("CANARY-TOKEN")
        )
        self._cached = Optional[AwsCredential](cred)
        return cred


def test_clones_read_one_provider_cache() raises:
    var endpoint = ArcPointer[_Endpoint](_Endpoint())
    var src = SharedCredsSource[_CachingProvider](_CachingProvider(endpoint))
    var a = src.copy()
    var b = a.copy()
    assert_equal(src.credentials().access_key_id, "ASIACACHED")
    assert_equal(a.credentials().access_key_id, "ASIACACHED")
    assert_equal(b.credentials().access_key_id, "ASIACACHED")
    assert_equal(endpoint[].calls, 1, "a clone resolved on its own")
    # A clone of a clone made after the first read shares it too.
    var late = b.copy()
    assert_equal(late.credentials().access_key_id, "ASIACACHED")
    assert_equal(endpoint[].calls, 1, "a late clone resolved on its own")


def main() raises:
    test_clones_read_one_provider_cache()
    print("OK")
