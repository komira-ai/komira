# A program started from a test's staged tree, to show where a binary that is
# itself test data finds its own resources. It reads `probe/value.txt` under
# its share/ directory: exit 0 when the text is the fixture's, 4 when it is
# other text, 3 when the file is absent.
#
# It uses komira_runtime_paths.data_path, the rule komira_resources applies,
# rather than komira_resources itself: that library's gated test runs this
# program, so depending on the gated library would be a cycle.
from komira_runtime_paths import data_path
from std.sys import exit


def main():
    var text: String
    try:
        with open(data_path("probe/value.txt"), "r") as f:
            text = f.read()
    except:
        exit(3)
        return
    exit(0 if text == "declared fixture\n" else 4)
