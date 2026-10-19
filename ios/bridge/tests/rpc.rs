// Copyright: Ankitects Pty Ltd and contributors
// License: GNU AGPL, version 3 or later; http://www.gnu.org/licenses/agpl.html

//! The protobuf RPC, and its sharing of the collection with the JSON commands.

use anki_ios_bridge::anki_bridge_free_buffer;
use anki_ios_bridge::anki_bridge_rpc;
use anki_ios_bridge::Bridge;
use anki_proto::backend::backend_error::Kind;
use anki_proto::backend::BackendError;
use anki_proto::collection::OpChangesWithId;
use anki_proto::collection::OpenCollectionRequest;
use anki_proto::decks::Deck;
use anki_proto::decks::DeckTreeNode;
use anki_proto::decks::DeckTreeRequest;
use anki_proto::generic::Empty;
use prost::Message;
use prost_reflect::DescriptorPool;
use serde_json::json;
use serde_json::Value;

/// (service, method) indices, from the same descriptors and helper that
/// generate the Python/TypeScript (and Swift) clients.
fn method_index(service: &str, method: &str) -> (u32, u32) {
    let descriptors = std::fs::read(env!("DESCRIPTORS_BIN")).expect("descriptors");
    let pool = DescriptorPool::decode(descriptors.as_ref()).unwrap();
    let (_, services) = anki_proto_gen::get_services(&pool);
    let service = services
        .iter()
        .find(|s| s.name == format!("Backend{service}"))
        .unwrap_or_else(|| panic!("missing service {service}"));
    let method = service
        .all_methods()
        .find(|m| m.name == method)
        .unwrap_or_else(|| panic!("missing method {method}"));
    (service.index as u32, method.index as u32)
}

fn rpc<T: Message + Default>(
    bridge: &Bridge,
    service: &str,
    method: &str,
    input: impl Message,
) -> T {
    let (s, m) = method_index(service, method);
    match bridge.rpc(s, m, &input.encode_to_vec()) {
        Ok(bytes) => T::decode(bytes.as_slice()).unwrap(),
        Err(bytes) => panic!(
            "{method} failed: {:?}",
            BackendError::decode(bytes.as_slice())
        ),
    }
}

fn rpc_err(bridge: &Bridge, service: u32, method: u32, input: &[u8]) -> BackendError {
    let bytes = bridge
        .rpc(service, method, input)
        .expect_err("unexpectedly succeeded");
    BackendError::decode(bytes.as_slice()).unwrap()
}

fn cmd(bridge: &Bridge, input: Value) -> Value {
    let out: Value = serde_json::from_str(&bridge.run_json(&input.to_string())).unwrap();
    if let Some(err) = out.get("error") {
        panic!("{input} failed: {err}");
    }
    out["ok"].clone()
}

fn open_request(dir: &tempfile::TempDir) -> OpenCollectionRequest {
    let path = |name: &str| dir.path().join(name).to_string_lossy().into_owned();
    std::fs::create_dir_all(path("collection.media")).unwrap();
    OpenCollectionRequest {
        collection_path: path("collection.anki2"),
        media_folder_path: path("collection.media"),
        media_db_path: path("collection.media.db2"),
    }
}

#[test]
fn rpc_and_json_share_the_collection() {
    let dir = tempfile::tempdir().unwrap();
    let bridge = Bridge::new(&["en"]);
    let req = open_request(&dir);
    // open with the RPC; a later JSON open is a no-op
    let _: Empty = rpc(&bridge, "CollectionService", "open_collection", req.clone());
    cmd(
        &bridge,
        json!({"cmd": "open", "collectionPath": req.collection_path,
               "mediaFolder": req.media_folder_path, "mediaDb": req.media_db_path}),
    );

    // a note added with JSON shows up in the RPC's deck tree
    let defaults = cmd(&bridge, json!({"cmd": "addDefaults"}));
    let notetypes = cmd(&bridge, json!({"cmd": "notetypes"}));
    let basic = notetypes
        .as_array()
        .unwrap()
        .iter()
        .find(|nt| nt["name"] == "Basic")
        .unwrap()["id"]
        .clone();
    cmd(
        &bridge,
        json!({"cmd": "addNote", "notetypeId": basic, "deckId": defaults["deckId"],
               "fields": ["front", "back"], "tags": []}),
    );
    let tree: DeckTreeNode = rpc(
        &bridge,
        "DecksService",
        "deck_tree",
        DeckTreeRequest {
            now: anki::prelude::TimestampSecs::now().0,
        },
    );
    let default = &tree.children[0];
    assert_eq!(default.name, "Default");
    assert_eq!(default.new_count, 1);

    // a deck added with the RPC shows up in the JSON deck list
    let mut deck: Deck = rpc(&bridge, "DecksService", "new_deck", Empty {});
    deck.name = "Added by RPC".into();
    let added: OpChangesWithId = rpc(&bridge, "DecksService", "add_deck", deck);
    let names = cmd(&bridge, json!({"cmd": "deckNames"}));
    assert!(names
        .as_array()
        .unwrap()
        .iter()
        .any(|d| d["id"] == added.id && d["name"] == "Added by RPC"));

    // closing with JSON closes it for the RPC too
    cmd(&bridge, json!({"cmd": "close"}));
    let (s, m) = method_index("DecksService", "deck_tree");
    let err = rpc_err(&bridge, s, m, &DeckTreeRequest { now: 0 }.encode_to_vec());
    assert_eq!(err.kind(), Kind::InvalidInput);
    assert!(!err.message.is_empty());
}

#[test]
fn rpc_errors() {
    let dir = tempfile::tempdir().unwrap();
    let bridge = Bridge::new(&["en"]);
    let _: Empty = rpc(
        &bridge,
        "CollectionService",
        "open_collection",
        open_request(&dir),
    );

    // opening twice is an error for the RPC, as on the desktop
    let (s, m) = method_index("CollectionService", "open_collection");
    let err = rpc_err(&bridge, s, m, &open_request(&dir).encode_to_vec());
    assert_eq!(err.kind(), Kind::InvalidInput);

    // an error from the core, eg a missing deck
    let (s, m) = method_index("DecksService", "get_deck");
    let err = rpc_err(
        &bridge,
        s,
        m,
        &anki_proto::decks::DeckId { did: 12345 }.encode_to_vec(),
    );
    assert_eq!(err.kind(), Kind::NotFoundError, "{err:?}");

    // undecodable input
    let err = rpc_err(&bridge, s, m, &[0xff, 0xff, 0xff]);
    assert_eq!(err.kind(), Kind::ProtoError, "{err:?}");

    // unknown indices
    let err = rpc_err(&bridge, 9999, 0, &[]);
    assert_eq!(err.kind(), Kind::InvalidInput);
    let err = rpc_err(&bridge, s, 9999, &[]);
    assert_eq!(err.kind(), Kind::InvalidInput);
}

#[test]
fn rpc_through_the_c_abi() {
    let dir = tempfile::tempdir().unwrap();
    let bridge = Bridge::new(&["en"]);
    let input = open_request(&dir).encode_to_vec();
    let (s, m) = method_index("CollectionService", "open_collection");
    unsafe {
        // an empty response has no data
        let out = anki_bridge_rpc(&bridge, s, m, input.as_ptr(), input.len());
        assert!(!out.is_error);
        assert_eq!(out.len, 0);
        assert!(out.data.is_null());
        anki_bridge_free_buffer(out);

        // empty input may be passed as null
        let (s, m) = method_index("DecksService", "new_deck");
        let out = anki_bridge_rpc(&bridge, s, m, std::ptr::null(), 0);
        assert!(!out.is_error);
        let deck = Deck::decode(std::slice::from_raw_parts(out.data, out.len)).unwrap();
        assert_eq!(deck.id, 0);
        anki_bridge_free_buffer(out);

        let out = anki_bridge_rpc(&bridge, 9999, 0, std::ptr::null(), 0);
        assert!(out.is_error);
        let err = BackendError::decode(std::slice::from_raw_parts(out.data, out.len)).unwrap();
        assert_eq!(err.kind(), Kind::InvalidInput);
        anki_bridge_free_buffer(out);
    }
}
