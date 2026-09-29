# The closed release-channel set: its enumeration, its ORDER, and the
# membership test that must agree with it.
#
# Every consumer of the set — the deploy tool's package-repository placement,
# the control plane's per-channel ledger, the build guard that refuses a build
# pushing into a channel — iterates `release_channels()` or asks
# `is_valid_channel`. So the set is pinned here, where the one declaration is,
# rather than restated by each consumer's own test.

from komira_release_channels import (
    RELEASE_CHANNEL_GAMMA,
    RELEASE_CHANNEL_LIVE,
    is_valid_channel,
    release_channels,
)

from std.testing import assert_equal, assert_false, assert_true


def test_the_set_is_exactly_gamma_then_live() raises:
    """TWO channels, in RELEASE order: a version reaches `live` only by
    promotion from `gamma`, and an error message that lists the channels reads
    in the order a version travels."""
    var chans = release_channels()
    assert_equal(len(chans), 2, "the channel set is closed at two")
    assert_equal(chans[0], String("gamma"), "gamma is released FIRST")
    assert_equal(chans[1], String("live"), "live is reached by promotion")
    assert_equal(String(RELEASE_CHANNEL_GAMMA), String("gamma"))
    assert_equal(String(RELEASE_CHANNEL_LIVE), String("live"))


def test_every_enumerated_channel_is_valid() raises:
    """The membership test and the enumeration cannot disagree: every name
    `release_channels()` yields is a valid channel."""
    var chans = release_channels()
    for i in range(len(chans)):
        assert_true(
            is_valid_channel(chans[i]),
            String("enumerated channel '") + chans[i] + "' is not valid",
        )


def test_unknown_names_fail_closed() raises:
    """An unrecognized channel must never be accepted: falling back to `live`
    would publish an unvetted build to customers. The match is exact — no
    case folding, no trimming, no prefix."""
    assert_false(is_valid_channel(String("")), "empty is not a channel")
    assert_false(is_valid_channel(String("Live")), "the match is case-exact")
    assert_false(is_valid_channel(String("GAMMA")), "the match is case-exact")
    assert_false(is_valid_channel(String(" live")), "no trimming")
    assert_false(is_valid_channel(String("live ")), "no trimming")
    assert_false(is_valid_channel(String("liv")), "no prefix match")
    assert_false(is_valid_channel(String("beta")), "an unlisted channel")
    assert_false(is_valid_channel(String("stable")), "an unlisted channel")


def main() raises:
    test_the_set_is_exactly_gamma_then_live()
    test_every_enumerated_channel_is_valid()
    test_unknown_names_fail_closed()
    print("test_release_channels: 3 tests PASSED")
