// Copyright: Ankitects Pty Ltd and contributors
// License: GNU AGPL, version 3 or later; http://www.gnu.org/licenses/agpl.html

//! Helpers that turn rendered card text into HTML for the iOS web view,
//! mirroring what the desktop reviewer does in Python.

use std::sync::LazyLock;

use anki_proto::card_rendering::av_tag::Value as AvValue;
use anki_proto::card_rendering::rendered_template_node::Value as NodeValue;
use anki_proto::card_rendering::AvTag;
use anki_proto::card_rendering::RenderedTemplateNode;
use regex::Captures;
use regex::Regex;
use serde::Serialize;

static AV_REF_RE: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"\[anki:play:([qa]):(\d+)\]").unwrap());
static TYPE_RE: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"\[\[type:(.+?)\]\]").unwrap());
static SOUND_RE: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"\[sound:[^\]]+\]").unwrap());

const PLAY_ICON: &str = r#"<svg class="playImage" viewBox="0 0 64 64" version="1.1"><circle cx="32" cy="32" r="29"></circle><path d="M56.502,32.301l-37.502,20.101l0.329,-40.804l37.173,20.703Z"></path></svg>"#;

/// A sound/video file or text-to-speech request the app should play.
#[derive(Serialize, Debug, Clone, PartialEq)]
#[serde(rename_all = "camelCase", tag = "type")]
pub enum AvItem {
    Sound {
        filename: String,
    },
    Tts {
        text: String,
        lang: String,
        speed: f32,
    },
}

/// Concatenate the output of a full (non-partial) render.
pub fn nodes_to_text(nodes: &[RenderedTemplateNode]) -> String {
    nodes
        .iter()
        .filter_map(|node| match &node.value {
            Some(NodeValue::Text(text)) => Some(text.as_str()),
            Some(NodeValue::Replacement(repl)) => Some(repl.current_text.as_str()),
            None => None,
        })
        .collect()
}

pub fn av_tags_to_items(tags: Vec<AvTag>) -> Vec<AvItem> {
    tags.into_iter()
        .filter_map(|tag| match tag.value? {
            AvValue::SoundOrVideo(filename) => Some(AvItem::Sound { filename }),
            AvValue::Tts(tts) => Some(AvItem::Tts {
                text: tts.field_text,
                lang: tts.lang,
                speed: tts.speed,
            }),
        })
        .collect()
}

/// Replace `[anki:play:q:0]` references with replay buttons. Tapping one
/// navigates to `anki-play:q:0`, which the app intercepts.
pub fn av_refs_to_play_buttons(text: &str) -> String {
    AV_REF_RE
        .replace_all(text, |caps: &Captures| {
            format!(
                r#"<a class="replay-button soundLink" href="anki-play:{}:{}">{PLAY_ICON}</a>"#,
                &caps[1], &caps[2]
            )
        })
        .into_owned()
}

/// The field referenced by the first `[[type:...]]` tag, if any.
pub fn type_answer_field(text: &str) -> Option<String> {
    TYPE_RE.captures(text).map(|caps| caps[1].to_string())
}

/// Replace a type-in-the-answer tag on the question side with an input box.
pub fn type_tag_to_input(text: &str) -> String {
    TYPE_RE
        .replace(
            text,
            r#"<center><input type="text" id="typeans" autocomplete="off" autocapitalize="off" autocorrect="off" spellcheck="false"></center>"#,
        )
        .into_owned()
}

/// Replace a type-in-the-answer tag on the answer side with `replacement`,
/// removing any further tags.
pub fn replace_type_tag(text: &str, replacement: &str) -> String {
    let once = TYPE_RE.replace(text, regex::NoExpand(replacement));
    TYPE_RE.replace_all(&once, "").into_owned()
}

/// Strip the `[sound:...]` references from an expected typed answer.
pub fn strip_sound_refs(text: &str) -> String {
    SOUND_RE.replace_all(text, "").into_owned()
}

#[cfg(test)]
mod test {
    use super::*;

    #[test]
    fn play_buttons() {
        let out = av_refs_to_play_buttons("a [anki:play:q:0] b [anki:play:a:12]");
        assert!(out.contains(r#"href="anki-play:q:0""#));
        assert!(out.contains(r#"href="anki-play:a:12""#));
        assert!(!out.contains("[anki:play"));
    }

    #[test]
    fn type_tags() {
        let text = "front [[type:Back]] tail";
        assert_eq!(type_answer_field(text).as_deref(), Some("Back"));
        assert!(type_tag_to_input(text).contains(r#"id="typeans""#));
        assert_eq!(replace_type_tag(text, "$1<b>"), "front $1<b> tail");
        assert_eq!(type_answer_field("nothing"), None);
    }

    #[test]
    fn sound_refs() {
        assert_eq!(strip_sound_refs("dog[sound:dog.mp3]"), "dog");
    }
}
