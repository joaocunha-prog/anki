// Copyright: Ankitects Pty Ltd and contributors
// License: GNU AGPL, version 3 or later; http://www.gnu.org/licenses/agpl.html

//! The JSON sync commands, against a local sync server.

use std::path::Path;
use std::time::Duration;

use anki::sync::http_server::default_ip_header;
use anki::sync::http_server::SimpleServer;
use anki::sync::http_server::SyncServerConfig;
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

/// Start a sync server in the background, returning its endpoint.
fn start_server(base_folder: &Path) -> String {
    std::env::set_var("SYNC_USER1", "user:pass");
    let config = SyncServerConfig {
        host: "127.0.0.1".parse().unwrap(),
        port: 0,
        base_folder: base_folder.into(),
        ip_header: default_ip_header(),
    };
    let (tx, rx) = std::sync::mpsc::channel();
    std::thread::spawn(move || {
        let rt = tokio::runtime::Builder::new_multi_thread()
            .enable_all()
            .build()
            .unwrap();
        rt.block_on(async move {
            let (addr, server) = SimpleServer::make_server(config).await.unwrap();
            tx.send(addr).unwrap();
            let _ = server.await;
        });
    });
    format!("http://{}/", rx.recv().unwrap())
}

fn open_bridge(dir: &Path) -> Bridge {
    let bridge = Bridge::new(&["en"]);
    let path = |name: &str| dir.join(name).to_string_lossy().into_owned();
    std::fs::create_dir_all(path("collection.media")).unwrap();
    std::fs::create_dir_all(path("backups")).unwrap();
    cmd(
        &bridge,
        json!({
            "cmd": "open",
            "collectionPath": path("collection.anki2"),
            "mediaFolder": path("collection.media"),
            "mediaDb": path("collection.media.db2"),
            "backupFolder": path("backups"),
        }),
    );
    bridge
}

fn wait_for_media_sync(bridge: &Bridge) {
    for _ in 0..100 {
        let status = cmd(bridge, json!({"cmd": "mediaSyncStatus"}));
        if status["active"] == false {
            assert!(status["error"].is_null(), "{status}");
            return;
        }
        std::thread::sleep(Duration::from_millis(100));
    }
    panic!("media sync did not finish");
}

fn new_count(bridge: &Bridge) -> Value {
    cmd(bridge, json!({"cmd": "deckTree"}))["decks"][0]["new"].clone()
}

#[test]
fn full_and_normal_sync() {
    let server_dir = tempfile::tempdir().unwrap();
    let endpoint = start_server(server_dir.path());
    let dir_a = tempfile::tempdir().unwrap();
    let dir_b = tempfile::tempdir().unwrap();

    let a = open_bridge(dir_a.path());
    let err = cmd_err(
        &a,
        json!({"cmd": "login", "username": "user", "password": "wrong", "endpoint": endpoint}),
    );
    assert_eq!(err["kind"], "SYNC_AUTH_ERROR", "{err}");
    let auth = cmd(
        &a,
        json!({"cmd": "login", "username": "user", "password": "pass", "endpoint": endpoint}),
    );
    assert_eq!(auth["endpoint"], endpoint.as_str());
    assert!(!auth["hkey"].as_str().unwrap().is_empty());

    // device A adds a note, and replaces the empty server collection
    let deck_id = cmd(&a, json!({"cmd": "addDefaults"}))["deckId"].clone();
    let notetypes = cmd(&a, json!({"cmd": "notetypes"}));
    let basic = notetypes
        .as_array()
        .unwrap()
        .iter()
        .find(|nt| nt["name"] == "Basic")
        .unwrap()["id"]
        .clone();
    cmd(
        &a,
        json!({"cmd": "addNote", "notetypeId": basic, "deckId": deck_id,
               "fields": ["front", "back"], "tags": []}),
    );
    let out = cmd(&a, json!({"cmd": "sync", "auth": auth, "syncMedia": true}));
    assert_eq!(out["required"], "fullUpload", "{out}");
    cmd(
        &a,
        json!({"cmd": "fullSync", "auth": auth, "upload": true,
               "serverMediaUsn": out["serverMediaUsn"]}),
    );
    wait_for_media_sync(&a);

    // device B downloads it, keeping a backup of what it replaced
    let b = open_bridge(dir_b.path());
    assert_eq!(new_count(&b), 0);
    let out = cmd(&b, json!({"cmd": "sync", "auth": auth, "syncMedia": true}));
    assert_eq!(out["required"], "fullDownload", "{out}");
    cmd(
        &b,
        json!({"cmd": "fullSync", "auth": auth, "upload": false, "serverMediaUsn": null}),
    );
    wait_for_media_sync(&b);
    assert_eq!(new_count(&b), 1);
    let backups = std::fs::read_dir(dir_b.path().join("backups")).unwrap();
    assert_eq!(backups.count(), 1);

    // B studies the card, and A picks up the review with a normal sync
    let card_id = cmd(&b, json!({"cmd": "nextCard"}))["card"]["cardId"].clone();
    cmd(
        &b,
        json!({"cmd": "answer", "cardId": card_id, "ease": 3, "millisecondsTaken": 1000}),
    );
    let out = cmd(&b, json!({"cmd": "sync", "auth": auth, "syncMedia": true}));
    assert_eq!(out["required"], "normalSync", "{out}");
    wait_for_media_sync(&b);

    let shown = cmd(&a, json!({"cmd": "nextCard"}))["card"]["cardId"].clone();
    assert_eq!(shown, card_id);
    let out = cmd(&a, json!({"cmd": "sync", "auth": auth, "syncMedia": false}));
    assert_eq!(out["required"], "normalSync", "{out}");
    assert_eq!(new_count(&a), 0);
    // the card A was showing changed on B, so can no longer be answered
    let err = cmd_err(
        &a,
        json!({"cmd": "answer", "cardId": shown, "ease": 3, "millisecondsTaken": 1}),
    );
    assert_eq!(err["kind"], "CARD_NOT_CURRENT");

    cmd(&a, json!({"cmd": "close"}));
    cmd(&b, json!({"cmd": "close"}));
}
