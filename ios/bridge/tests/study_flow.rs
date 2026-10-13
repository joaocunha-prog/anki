// Copyright: Ankitects Pty Ltd and contributors
// License: GNU AGPL, version 3 or later; http://www.gnu.org/licenses/agpl.html

use anki_ios_bridge::Bridge;
use serde_json::json;
use serde_json::Value;

fn cmd(bridge: &Bridge, input: Value) -> Value {
    let out: Value = serde_json::from_str(&bridge.run_json(&input.to_string())).unwrap();
    if let Some(err) = out.get("error") {
        panic!("{input} failed: {err}");
    }
    out["ok"].clone()
}

fn cmd_err(bridge: &Bridge, input: Value) -> Value {
    let out: Value = serde_json::from_str(&bridge.run_json(&input.to_string())).unwrap();
    out.get("error")
        .cloned()
        .unwrap_or_else(|| panic!("{input} unexpectedly succeeded"))
}

fn open_bridge(dir: &tempfile::TempDir) -> Bridge {
    let bridge = Bridge::new(&["en"]);
    let path = |name: &str| dir.path().join(name).to_string_lossy().into_owned();
    std::fs::create_dir_all(path("collection.media")).unwrap();
    cmd(
        &bridge,
        json!({
            "cmd": "open",
            "collectionPath": path("collection.anki2"),
            "mediaFolder": path("collection.media"),
            "mediaDb": path("collection.media.db2"),
        }),
    );
    bridge
}

fn notetype_id(bridge: &Bridge, name: &str) -> i64 {
    let notetypes = cmd(bridge, json!({"cmd": "notetypes"}));
    notetypes
        .as_array()
        .unwrap()
        .iter()
        .find(|nt| nt["name"] == name)
        .unwrap_or_else(|| panic!("missing notetype {name}"))["id"]
        .as_i64()
        .unwrap()
}

#[test]
fn add_study_answer_and_undo() {
    let dir = tempfile::tempdir().unwrap();
    let bridge = open_bridge(&dir);

    let defaults = cmd(&bridge, json!({"cmd": "addDefaults"}));
    let deck_id = defaults["deckId"].as_i64().unwrap();
    let basic = notetype_id(&bridge, "Basic");
    let notetypes = cmd(&bridge, json!({"cmd": "notetypes"}));
    let basic_fields = &notetypes
        .as_array()
        .unwrap()
        .iter()
        .find(|nt| nt["id"] == basic)
        .unwrap()["fields"];
    assert_eq!(basic_fields, &json!(["Front", "Back"]));

    cmd(
        &bridge,
        json!({"cmd": "addNote", "notetypeId": basic, "deckId": deck_id,
               "fields": ["capital of France [sound:paris.mp3]", "Paris"], "tags": ["geo"]}),
    );
    let err = cmd_err(
        &bridge,
        json!({"cmd": "addNote", "notetypeId": basic, "deckId": deck_id,
               "fields": ["only one"], "tags": []}),
    );
    assert_eq!(err["kind"], "INVALID_INPUT");

    let tree = cmd(&bridge, json!({"cmd": "deckTree"}));
    let default_deck = &tree["decks"][0];
    assert_eq!(default_deck["name"], "Default");
    assert_eq!(default_deck["new"], 1);

    cmd(&bridge, json!({"cmd": "selectDeck", "deckId": deck_id}));
    let next = cmd(&bridge, json!({"cmd": "nextCard"}));
    assert_eq!(next["counts"]["new"], 1);
    assert_eq!(next["deckName"], "Default");
    let card = &next["card"];
    let card_id = card["cardId"].as_i64().unwrap();
    let question = card["questionHtml"].as_str().unwrap();
    assert!(question.contains("capital of France"));
    assert!(question.contains(r#"href="anki-play:q:0""#));
    assert_eq!(
        card["questionAv"],
        json!([{"type": "sound", "filename": "paris.mp3"}])
    );
    assert_eq!(card["buttonLabels"].as_array().unwrap().len(), 4);
    assert_eq!(card["queue"], "new");
    assert_eq!(card["hasTypeAnswer"], false);

    let answer = cmd(&bridge, json!({"cmd": "showAnswer", "cardId": card_id}));
    let answer_html = answer["answerHtml"].as_str().unwrap();
    assert!(answer_html.contains("Paris"));
    assert!(answer_html.contains("capital of France"));

    cmd(
        &bridge,
        json!({"cmd": "answer", "cardId": card_id, "ease": 3, "millisecondsTaken": 1500}),
    );
    // answering again is rejected, as the card is no longer current
    let err = cmd_err(
        &bridge,
        json!({"cmd": "answer", "cardId": card_id, "ease": 3, "millisecondsTaken": 1}),
    );
    assert_eq!(err["kind"], "INVALID_INPUT");

    // the card is now in learning, and will be shown again shortly
    let next = cmd(&bridge, json!({"cmd": "nextCard"}));
    assert_eq!(next["counts"]["new"], 0);

    let undone = cmd(&bridge, json!({"cmd": "undo"}));
    assert!(!undone["operation"].as_str().unwrap().is_empty());
    let next = cmd(&bridge, json!({"cmd": "nextCard"}));
    assert_eq!(next["counts"]["new"], 1);

    // after suspending, nothing is left to study
    cmd(&bridge, json!({"cmd": "suspendCard", "cardId": card_id}));
    let next = cmd(&bridge, json!({"cmd": "nextCard"}));
    assert!(next["card"].is_null());
    assert!(next["congrats"].is_object());

    assert!(cmd(&bridge, json!({"cmd": "studiedToday"})).is_string());
    cmd(&bridge, json!({"cmd": "close"}));
    let err = cmd_err(&bridge, json!({"cmd": "deckTree"}));
    assert_eq!(err["kind"], "INVALID_INPUT");
}

#[test]
fn type_in_the_answer() {
    let dir = tempfile::tempdir().unwrap();
    let bridge = open_bridge(&dir);
    let notetype = notetype_id(&bridge, "Basic (type in the answer)");
    let deck_id = cmd(&bridge, json!({"cmd": "addDefaults"}))["deckId"].clone();
    cmd(
        &bridge,
        json!({"cmd": "addNote", "notetypeId": notetype, "deckId": deck_id,
               "fields": ["dog in Portuguese", "cachorro"], "tags": []}),
    );
    let next = cmd(&bridge, json!({"cmd": "nextCard"}));
    let card = &next["card"];
    assert_eq!(card["hasTypeAnswer"], true);
    assert!(card["questionHtml"]
        .as_str()
        .unwrap()
        .contains(r#"id="typeans""#));
    let answer = cmd(
        &bridge,
        json!({"cmd": "showAnswer", "cardId": card["cardId"], "typed": "cachoro"}),
    );
    let html = answer["answerHtml"].as_str().unwrap();
    assert!(html.contains(r#"<div id="typeans">"#), "{html}");
    assert!(html.contains("typeBad") || html.contains("typeMissed"), "{html}");
    assert!(!html.contains("[[type:"));
}

#[test]
fn invalid_commands_are_reported() {
    let bridge = Bridge::new(&["en"]);
    let out: Value = serde_json::from_str(&bridge.run_json("{\"cmd\": \"nope\"}")).unwrap();
    assert_eq!(out["error"]["kind"], "INVALID_INPUT");
    let err = cmd_err(&bridge, json!({"cmd": "deckTree"}));
    assert!(!err["message"].as_str().unwrap().is_empty());
    // a bad sync server URL is rejected before any network access
    let err = cmd_err(
        &bridge,
        json!({"cmd": "login", "username": "a", "password": "b", "endpoint": "not a url"}),
    );
    assert_eq!(err["kind"], "INVALID_INPUT");
}

/// Talks to the real AnkiWeb, so is not run by default.
#[test]
#[ignore]
fn ankiweb_rejects_bad_credentials() {
    let bridge = Bridge::new(&["en"]);
    let err = cmd_err(
        &bridge,
        json!({"cmd": "login", "username": "nobody@example.com", "password": "wrong"}),
    );
    assert_eq!(err["kind"], "SYNC_AUTH_ERROR", "{err}");
}
