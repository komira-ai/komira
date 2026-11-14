//! Whole-word replacement. A word is a maximal run of ASCII letters, digits and `_`, as
//! `git grep -w` reads one, so `komira_gcp_firestore` never matches inside
//! `komira_gcp_firestore_v1` and `komira_json` matches in `src/komira_json:komira_json`.

use std::collections::BTreeMap;

/// True for a byte that is part of a word.
pub fn is_word_byte(b: u8) -> bool {
    b.is_ascii_alphanumeric() || b == b'_'
}

/// The byte ranges of the words of `text`, in order.
pub fn word_spans(text: &str) -> Vec<(usize, usize)> {
    let bytes = text.as_bytes();
    let mut spans = Vec::new();
    let mut i = 0;
    while i < bytes.len() {
        if is_word_byte(bytes[i]) {
            let start = i;
            while i < bytes.len() && is_word_byte(bytes[i]) {
                i += 1;
            }
            spans.push((start, i));
        } else {
            i += 1;
        }
    }
    spans
}

/// True when `word` occurs in `text` as a whole word.
pub fn contains_word(text: &str, word: &str) -> bool {
    word_spans(text)
        .into_iter()
        .any(|(start, end)| &text[start..end] == word)
}

/// `text` with every word that is a key of `map` replaced by its value, in one pass (a
/// replacement is never itself replaced), or `None` when no word is a key. Word boundaries are
/// ASCII bytes, so the slices stay on UTF-8 character boundaries.
pub fn replace_words(text: &str, map: &BTreeMap<String, String>) -> Option<String> {
    let mut out = String::with_capacity(text.len());
    let mut last = 0;
    let mut changed = false;
    for (start, end) in word_spans(text) {
        if let Some(new) = map.get(&text[start..end]) {
            out.push_str(&text[last..start]);
            out.push_str(new);
            last = end;
            changed = true;
        }
    }
    if !changed {
        return None;
    }
    out.push_str(&text[last..]);
    Some(out)
}

/// The number of lines of `old` and `new` that differ, line by line. Both have the same number of
/// lines: a replacement never adds or removes a line break.
pub fn changed_lines(old: &str, new: &str) -> usize {
    old.split('\n')
        .zip(new.split('\n'))
        .filter(|(a, b)| a != b)
        .count()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn map(pairs: &[(&str, &str)]) -> BTreeMap<String, String> {
        pairs
            .iter()
            .map(|(a, b)| (a.to_string(), b.to_string()))
            .collect()
    }

    #[test]
    fn spans_split_on_every_non_word_byte() {
        let text = "a_1 b-c//d:e é f";
        let words: Vec<&str> = word_spans(text)
            .into_iter()
            .map(|(s, e)| &text[s..e])
            .collect();
        assert_eq!(words, ["a_1", "b", "c", "d", "e", "f"]);
        assert!(word_spans("").is_empty());
        assert!(word_spans("-- ..").is_empty());
    }

    #[test]
    fn replaces_whole_words_only() {
        let m = map(&[
            ("komira_json", "json"),
            ("komira_gcp_firestore", "gcp_firestore"),
        ]);
        let text = "from komira_json import X\n\
                    import komira_json_index\n\
                    //src/komira_json:komira_json\n\
                    komira_gcp_firestore_v1 libkomira_json KOMIRA_JSON komira_gcp_firestore.";
        assert_eq!(
            replace_words(text, &m).as_deref(),
            Some(
                "from json import X\n\
                 import komira_json_index\n\
                 //src/json:json\n\
                 komira_gcp_firestore_v1 libkomira_json KOMIRA_JSON gcp_firestore."
            )
        );
    }

    #[test]
    fn a_replacement_is_not_replaced_again() {
        let m = map(&[("komira_a", "komira_b"), ("komira_b", "c")]);
        assert_eq!(
            replace_words("komira_a komira_b", &m).as_deref(),
            Some("komira_b c")
        );
    }

    #[test]
    fn text_with_no_key_is_unchanged() {
        let m = map(&[("komira_json", "json")]);
        assert_eq!(replace_words("komira_jsonx json", &m), None);
        assert_eq!(replace_words("", &m), None);
    }

    #[test]
    fn keeps_non_ascii_text_around_a_replacement() {
        let m = map(&[("komira_json", "json")]);
        assert_eq!(
            replace_words("«komira_json»é", &m).as_deref(),
            Some("«json»é")
        );
    }

    #[test]
    fn contains_word_matches_whole_words() {
        assert!(contains_word("var json = 1", "json"));
        assert!(!contains_word("var jsonx = 1", "json"));
        assert!(!contains_word("", "json"));
    }

    #[test]
    fn counts_the_lines_that_differ() {
        assert_eq!(changed_lines("a\nb\nc", "a\nB\nC"), 2);
        assert_eq!(changed_lines("a\n", "a\n"), 0);
    }
}
