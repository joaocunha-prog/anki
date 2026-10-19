// Copyright: Ankitects Pty Ltd and contributors
// License: GNU AGPL, version 3 or later; http://www.gnu.org/licenses/agpl.html

use std::sync::Mutex;
use std::sync::MutexGuard;
use std::sync::PoisonError;

use anki::backend::Backend;
use anki::collection::Collection;
use anki::decks::DeckId as NativeDeckId;
use anki::error::AnkiError;
use anki::error::Result;
use anki::prelude::I18n;
use anki::prelude::TimestampMillis;
use anki::prelude::TimestampSecs;
use anki::services::BackendCollectionService;
use anki::services::BackendSyncService;
use anki::services::CardRenderingService;
use anki::services::CardsService;
use anki::services::CollectionService;
use anki::services::DecksService;
use anki::services::NotesService;
use anki::services::NotetypesService;
use anki::services::SchedulerService;
use anki_proto::backend::backend_error::Kind as ErrorKind;
use anki_proto::card_rendering::CompareAnswerRequest;
use anki_proto::card_rendering::ExtractAvTagsRequest;
use anki_proto::card_rendering::ExtractClozeForTypingRequest;
use anki_proto::card_rendering::RenderExistingCardRequest;
use anki_proto::cards::CardId;
use anki_proto::collection::CloseCollectionRequest;
use anki_proto::collection::OpenCollectionRequest;
use anki_proto::decks::DeckId;
use anki_proto::decks::DeckTreeNode;
use anki_proto::decks::DeckTreeRequest;
use anki_proto::decks::GetDeckNamesRequest;
use anki_proto::notes::AddNoteRequest;
use anki_proto::notes::DefaultsForAddingRequest;
use anki_proto::notes::NoteId;
use anki_proto::notetypes::NotetypeId;
use anki_proto::scheduler::bury_or_suspend_cards_request::Mode as BuryOrSuspendMode;
use anki_proto::scheduler::card_answer::Rating;
use anki_proto::scheduler::queued_cards::Queue;
use anki_proto::scheduler::BuryOrSuspendCardsRequest;
use anki_proto::scheduler::CardAnswer;
use anki_proto::scheduler::GetQueuedCardsRequest;
use anki_proto::scheduler::SchedulingStates;
use anki_proto::sync::sync_collection_response::ChangesRequired;
use anki_proto::sync::FullUploadOrDownloadRequest;
use anki_proto::sync::SyncAuth;
use anki_proto::sync::SyncCollectionRequest;
use anki_proto::sync::SyncLoginRequest;
use serde::Deserialize;
use serde::Serialize;
use serde_json::json;
use serde_json::Value;

use crate::render;
use crate::render::AvItem;

/// A command sent from Swift. The `cmd` key selects the variant.
#[derive(Deserialize, Debug)]
#[serde(tag = "cmd", rename_all = "camelCase", rename_all_fields = "camelCase")]
pub enum Command {
    Open {
        collection_path: String,
        media_folder: String,
        media_db: String,
        /// Where to save a backup before a full download replaces the collection.
        backup_folder: Option<String>,
    },
    Close,
    Login {
        username: String,
        password: String,
        endpoint: Option<String>,
    },
    /// Replies with `required`: "noChanges" if nothing needed syncing,
    /// "normalSync" if changes were exchanged, or "fullSync"/"fullDownload"/
    /// "fullUpload" if a one-way sync is needed first.
    Sync {
        auth: AuthJson,
        sync_media: bool,
    },
    FullSync {
        auth: AuthJson,
        upload: bool,
        /// From a prior normal sync, if available. Speeds up media syncing.
        server_media_usn: Option<i32>,
    },
    SyncMedia {
        auth: AuthJson,
    },
    MediaSyncStatus,
    DeckTree,
    DeckNames,
    SelectDeck {
        deck_id: i64,
    },
    NextCard,
    ShowAnswer {
        card_id: i64,
        typed: Option<String>,
    },
    Answer {
        card_id: i64,
        /// 1=again, 2=hard, 3=good, 4=easy
        ease: u8,
        milliseconds_taken: u32,
    },
    Undo,
    BuryCard {
        card_id: i64,
    },
    SuspendCard {
        card_id: i64,
    },
    Notetypes,
    AddDefaults,
    AddNote {
        notetype_id: i64,
        deck_id: i64,
        fields: Vec<String>,
        tags: Vec<String>,
    },
    StudiedToday,
}

#[derive(Deserialize, Serialize, Debug, Clone)]
#[serde(rename_all = "camelCase")]
pub struct AuthJson {
    pub hkey: String,
    pub endpoint: Option<String>,
}

impl From<AuthJson> for SyncAuth {
    fn from(auth: AuthJson) -> Self {
        SyncAuth {
            hkey: auth.hkey,
            endpoint: auth.endpoint.filter(|e| !e.trim().is_empty()),
            io_timeout_secs: None,
        }
    }
}

/// Errors returned by commands. Most come from the core; the rest are
/// specific to the bridge, and get their own `kind` so Swift can react.
pub enum BridgeError {
    Anki(AnkiError),
    /// The card being answered is no longer the bridge's current card, eg
    /// because a sync or undo happened in the meantime.
    CardNotCurrent,
}

impl From<AnkiError> for BridgeError {
    fn from(err: AnkiError) -> Self {
        BridgeError::Anki(err)
    }
}

/// How a `[[type:...]]` answer should be checked.
struct TypeAnswer {
    expected: String,
    combining: bool,
    ignore_case: bool,
}

/// The card currently shown to the user, kept so that the answer can be
/// recorded without round-tripping scheduling states through Swift.
struct CurrentCard {
    card_id: i64,
    states: SchedulingStates,
    answer_text: String,
    answer_av: Vec<AvItem>,
    type_answer: Option<TypeAnswer>,
}

/// The JSON commands and the protobuf RPC ([Bridge::rpc]) share a single
/// [Backend], and so a single open collection, sync state and media sync.
pub struct Bridge {
    backend: Backend,
    current: Mutex<Option<CurrentCard>>,
    backup_folder: Mutex<Option<String>>,
}

impl Bridge {
    pub fn new<S: AsRef<str>>(langs: &[S]) -> Self {
        Bridge {
            // as pylib/rsbridge does
            backend: Backend::new(I18n::new(langs), false),
            current: Mutex::new(None),
            backup_folder: Mutex::new(None),
        }
    }

    /// The backend shared by the JSON commands and the RPC.
    pub fn backend(&self) -> &Backend {
        &self.backend
    }

    /// Call a backend service method with protobuf-encoded input, exactly as
    /// pylib/rsbridge does. On success, returns the encoded response; on
    /// failure, an encoded [anki_proto::backend::BackendError].
    pub fn rpc(
        &self,
        service: u32,
        method: u32,
        input: &[u8],
    ) -> std::result::Result<Vec<u8>, Vec<u8>> {
        self.backend.run_service_method(service, method, input)
    }

    /// Run a command encoded as JSON, returning a JSON reply.
    pub fn run_json(&self, input: &str) -> String {
        let reply = match serde_json::from_str::<Command>(input) {
            Ok(cmd) => match self.run(cmd) {
                Ok(value) => json!({ "ok": value }),
                Err(err) => self.error_json(err),
            },
            Err(err) => json!({"error": {"kind": "INVALID_INPUT", "message": err.to_string()}}),
        };
        reply.to_string()
    }

    fn error_json(&self, err: BridgeError) -> Value {
        let err = match err {
            BridgeError::Anki(err) => err,
            BridgeError::CardNotCurrent => {
                return json!({"error": {"kind": "CARD_NOT_CURRENT", "message": "card is no longer current"}})
            }
        };
        let err = err.into_protobuf(self.backend.i18n());
        let kind = ErrorKind::try_from(err.kind)
            .map(|k| k.as_str_name())
            .unwrap_or("UNKNOWN");
        json!({"error": {"kind": kind, "message": err.message}})
    }

    /// Ask a running login or (normal or full) sync to stop.
    pub fn abort_sync(&self) {
        let _ = BackendSyncService::abort_sync(&self.backend);
    }

    pub fn run(&self, cmd: Command) -> std::result::Result<Value, BridgeError> {
        Ok(match cmd {
            Command::Open {
                collection_path,
                media_folder,
                media_db,
                backup_folder,
            } => {
                *lock(&self.backup_folder) = backup_folder;
                match BackendCollectionService::open_collection(
                    &self.backend,
                    OpenCollectionRequest {
                        collection_path,
                        media_folder_path: media_folder,
                        media_db_path: media_db,
                    },
                ) {
                    // opening twice is harmless, eg if the RPC opened it first
                    Ok(()) | Err(AnkiError::CollectionAlreadyOpen) => {}
                    Err(err) => return Err(err.into()),
                }
                Value::Null
            }
            Command::Close => {
                lock(&self.current).take();
                self.close_collection()?;
                Value::Null
            }
            Command::Login {
                username,
                password,
                endpoint,
            } => {
                let endpoint = endpoint.filter(|e| !e.trim().is_empty());
                let auth = BackendSyncService::sync_login(
                    &self.backend,
                    SyncLoginRequest {
                        username,
                        password,
                        endpoint: endpoint.clone(),
                    },
                )?;
                json!({ "hkey": auth.hkey, "endpoint": endpoint })
            }
            Command::Sync { auth, sync_media } => self.normal_sync(auth, sync_media)?,
            Command::FullSync {
                auth,
                upload,
                server_media_usn,
            } => {
                self.full_sync(auth.into(), upload, server_media_usn)?;
                Value::Null
            }
            Command::SyncMedia { auth } => {
                BackendSyncService::sync_media(&self.backend, auth.into())?;
                Value::Null
            }
            Command::MediaSyncStatus => self.media_sync_status(),
            Command::DeckTree => self.with_col(|col| {
                let tree = DecksService::deck_tree(
                    col,
                    DeckTreeRequest {
                        now: TimestampSecs::now().0,
                    },
                )?;
                let current = DecksService::get_current_deck(col)?.id;
                Ok(json!({
                    "decks": tree.children.iter().map(deck_node_json).collect::<Vec<_>>(),
                    "currentDeckId": current,
                }))
            })?,
            Command::DeckNames => self.with_col(|col| {
                let names = DecksService::get_deck_names(
                    col,
                    GetDeckNamesRequest {
                        skip_empty_default: false,
                        include_filtered: false,
                    },
                )?;
                Ok(Value::Array(
                    names
                        .entries
                        .into_iter()
                        .map(|e| json!({"id": e.id, "name": e.name}))
                        .collect(),
                ))
            })?,
            Command::SelectDeck { deck_id } => {
                lock(&self.current).take();
                self.with_col(|col| {
                    DecksService::set_current_deck(col, DeckId { did: deck_id }).map(|_| ())
                })?;
                Value::Null
            }
            Command::NextCard => self.next_card()?,
            Command::ShowAnswer { card_id, typed } => self.show_answer(card_id, typed)?,
            Command::Answer {
                card_id,
                ease,
                milliseconds_taken,
            } => {
                self.answer(card_id, ease, milliseconds_taken)?;
                Value::Null
            }
            Command::Undo => {
                lock(&self.current).take();
                let out = self.with_col(CollectionService::undo)?;
                json!({ "operation": out.operation })
            }
            Command::BuryCard { card_id } => {
                self.bury_or_suspend(card_id, BuryOrSuspendMode::BuryUser)?
            }
            Command::SuspendCard { card_id } => {
                self.bury_or_suspend(card_id, BuryOrSuspendMode::Suspend)?
            }
            Command::Notetypes => self.with_col(|col| {
                let names = NotetypesService::get_notetype_names(col)?;
                let mut out = vec![];
                for entry in names.entries {
                    let fields =
                        NotetypesService::get_field_names(col, NotetypeId { ntid: entry.id })?;
                    out.push(json!({"id": entry.id, "name": entry.name, "fields": fields.vals}));
                }
                Ok(Value::Array(out))
            })?,
            Command::AddDefaults => self.with_col(|col| {
                let defaults = NotesService::defaults_for_adding(
                    col,
                    DefaultsForAddingRequest {
                        home_deck_of_current_review_card: 0,
                    },
                )?;
                Ok(json!({"deckId": defaults.deck_id, "notetypeId": defaults.notetype_id}))
            })?,
            Command::AddNote {
                notetype_id,
                deck_id,
                fields,
                tags,
            } => self.with_col(|col| {
                let mut note = NotesService::new_note(col, NotetypeId { ntid: notetype_id })?;
                if fields.len() != note.fields.len() {
                    anki::invalid_input!("wrong number of fields");
                }
                note.fields = fields;
                note.tags = tags;
                let resp = NotesService::add_note(
                    col,
                    AddNoteRequest {
                        note: Some(note),
                        deck_id,
                    },
                )?;
                Ok(json!({ "noteId": resp.note_id }))
            })?,
            Command::StudiedToday => {
                let text = self.with_col(SchedulerService::studied_today)?;
                Value::String(text.val)
            }
        })
    }

    /// Run `func` with the backend's collection, failing if it is not open.
    fn with_col<T>(&self, func: impl FnOnce(&mut Collection) -> Result<T>) -> Result<T> {
        self.backend.with_col(func)
    }

    /// Close the collection if open, after stopping any media sync.
    fn close_collection(&self) -> Result<()> {
        match BackendCollectionService::close_collection(
            &self.backend,
            CloseCollectionRequest {
                downgrade_to_schema11: false,
            },
        ) {
            Ok(()) | Err(AnkiError::CollectionNotOpen) => Ok(()),
            Err(err) => Err(err),
        }
    }

    // Studying
    ///////////////

    fn next_card(&self) -> Result<Value> {
        self.with_col(|col| self.next_card_inner(col))
    }

    fn next_card_inner(&self, col: &mut Collection) -> Result<Value> {
        let queued = SchedulerService::get_queued_cards(
            col,
            GetQueuedCardsRequest {
                fetch_limit: 1,
                intraday_learning_only: false,
            },
        )?;
        let counts = json!({
            "new": queued.new_count,
            "learn": queued.learning_count,
            "review": queued.review_count,
        });
        let deck_name = DecksService::get_current_deck(col)?.name;

        let Some(qc) = queued.cards.into_iter().next() else {
            lock(&self.current).take();
            let info = SchedulerService::congrats_info(col)?;
            return Ok(json!({
                "card": null,
                "counts": counts,
                "deckName": deck_name,
                "congrats": {
                    "learnRemaining": info.learn_remaining,
                    "secsUntilNextLearn": info.secs_until_next_learn,
                    "reviewRemaining": info.review_remaining,
                    "newRemaining": info.new_remaining,
                    "haveUserBuried": info.have_user_buried,
                    "haveSchedBuried": info.have_sched_buried,
                    "deckDescription": anki::text::html_to_text_line(&info.deck_description, false),
                }
            }));
        };
        let card = qc.card.unwrap_or_default();
        let states = qc.states.unwrap_or_default();

        let rendered = CardRenderingService::render_existing_card(
            col,
            RenderExistingCardRequest {
                card_id: card.id,
                browser: false,
                partial_render: false,
            },
        )?;
        let question = CardRenderingService::extract_av_tags(
            col,
            ExtractAvTagsRequest {
                text: render::nodes_to_text(&rendered.question_nodes),
                question_side: true,
            },
        )?;
        let answer = CardRenderingService::extract_av_tags(
            col,
            ExtractAvTagsRequest {
                text: render::nodes_to_text(&rendered.answer_nodes),
                question_side: false,
            },
        )?;
        let mut question_html = render::av_refs_to_play_buttons(&question.text);
        let mut type_answer = None;
        if let Some(spec) = render::type_answer_field(&question_html) {
            match self.resolve_type_answer(col, card.note_id, card.template_idx, &spec)? {
                Ok(Some(ta)) => {
                    question_html = render::type_tag_to_input(&question_html);
                    type_answer = Some(ta);
                }
                // empty field: nothing to type
                Ok(None) => question_html = render::replace_type_tag(&question_html, ""),
                Err(message) => question_html = render::replace_type_tag(&question_html, &message),
            }
        }
        let question_html = CardRenderingService::encode_iri_paths(col, question_html.into())?.val;
        let button_labels = SchedulerService::describe_next_states(col, states.clone())?.vals;
        let home_deck = if card.original_deck_id != 0 {
            card.original_deck_id
        } else {
            card.deck_id
        };
        let config = match col
            .get_deck(NativeDeckId(home_deck))?
            .and_then(|deck| deck.config_id())
        {
            Some(dcid) => col.get_deck_config(dcid, true)?.unwrap_or_default(),
            None => Default::default(),
        };
        let queue = match Queue::try_from(qc.queue).unwrap_or(Queue::New) {
            Queue::New => "new",
            Queue::Learning => "learn",
            Queue::Review => "review",
        };

        let reply = json!({
            "card": {
                "cardId": card.id,
                "questionHtml": question_html,
                "questionAv": render::av_tags_to_items(question.av_tags),
                "css": rendered.css,
                "ord": card.template_idx,
                "queue": queue,
                "buttonLabels": button_labels,
                "hasTypeAnswer": type_answer.is_some(),
                "autoplay": !config.inner.disable_autoplay,
                "replayQuestion": !config.inner.skip_question_when_replaying_answer,
            },
            "counts": counts,
            "deckName": deck_name,
            "congrats": null,
        });
        *lock(&self.current) = Some(CurrentCard {
            card_id: card.id,
            states,
            answer_text: answer.text,
            answer_av: render::av_tags_to_items(answer.av_tags),
            type_answer,
        });
        Ok(reply)
    }

    fn show_answer(
        &self,
        card_id: i64,
        typed: Option<String>,
    ) -> std::result::Result<Value, BridgeError> {
        self.with_col(|col| self.show_answer_inner(col, card_id, typed))?
            .ok_or(BridgeError::CardNotCurrent)
    }

    /// Returns None if `card_id` is not the current card.
    fn show_answer_inner(
        &self,
        col: &mut Collection,
        card_id: i64,
        typed: Option<String>,
    ) -> Result<Option<Value>> {
        // lock order: col before current
        let current = lock(&self.current);
        let Some(current) = current.as_ref().filter(|c| c.card_id == card_id) else {
            return Ok(None);
        };
        let mut text = render::av_refs_to_play_buttons(&current.answer_text);
        let comparison = match &current.type_answer {
            Some(ta) => {
                let html = CardRenderingService::compare_answer(
                    col,
                    CompareAnswerRequest {
                        expected: ta.expected.clone(),
                        provided: typed.unwrap_or_default(),
                        combining: ta.combining,
                        ignore_case: ta.ignore_case,
                    },
                )?
                .val;
                format!(r#"<div id="typeans">{html}</div>"#)
            }
            None => String::new(),
        };
        text = render::replace_type_tag(&text, &comparison);
        let html = CardRenderingService::encode_iri_paths(col, text.into())?.val;
        Ok(Some(
            json!({ "answerHtml": html, "answerAv": current.answer_av }),
        ))
    }

    /// Work out what a `[[type:...]]` tag expects, as the desktop reviewer
    /// does. Returns Ok(None) if the field is empty, and Err(message) if the
    /// field does not exist.
    fn resolve_type_answer(
        &self,
        col: &mut Collection,
        note_id: i64,
        template_idx: u32,
        spec: &str,
    ) -> Result<std::result::Result<Option<TypeAnswer>, String>> {
        // modifiers come before the field name, eg "cloze:nc:ci:Text"
        let (modifiers, field) = spec.rsplit_once(':').unwrap_or(("", spec));
        let mut cloze = false;
        let mut combining = true;
        let mut ignore_case = false;
        for modifier in modifiers.split(':') {
            match modifier {
                "cloze" => cloze = true,
                "nc" => combining = false,
                "ci" => ignore_case = true,
                _ => {}
            }
        }
        let note = NotesService::get_note(col, NoteId { nid: note_id })?;
        let names = NotetypesService::get_field_names(
            col,
            NotetypeId {
                ntid: note.notetype_id,
            },
        )?;
        let Some(idx) = names.vals.iter().position(|n| n == field) else {
            return Ok(Err(self
                .backend
                .i18n()
                .studying_type_answer_unknown_field(field.to_string())
                .into_owned()));
        };
        let mut expected = note.fields[idx].clone();
        if cloze {
            expected = CardRenderingService::extract_cloze_for_typing(
                col,
                ExtractClozeForTypingRequest {
                    text: expected,
                    ordinal: template_idx + 1,
                },
            )?
            .val;
        }
        if expected.trim().is_empty() {
            return Ok(Ok(None));
        }
        // compare_answer strips HTML and media references itself
        Ok(Ok(Some(TypeAnswer {
            expected,
            combining,
            ignore_case,
        })))
    }

    fn answer(
        &self,
        card_id: i64,
        ease: u8,
        milliseconds_taken: u32,
    ) -> std::result::Result<(), BridgeError> {
        let current = lock(&self.current).take();
        let Some(current) = current.filter(|c| c.card_id == card_id) else {
            return Err(BridgeError::CardNotCurrent);
        };
        let states = current.states;
        let (rating, new_state) = match ease {
            1 => (Rating::Again, states.again),
            2 => (Rating::Hard, states.hard),
            3 => (Rating::Good, states.good),
            4 => (Rating::Easy, states.easy),
            _ => return Err(invalid("invalid ease").into()),
        };
        self.with_col(|col| {
            SchedulerService::answer_card(
                col,
                CardAnswer {
                    card_id,
                    current_state: states.current,
                    new_state,
                    rating: rating as i32,
                    answered_at_millis: TimestampMillis::now().0,
                    milliseconds_taken,
                },
            )
            .map(|_| ())
        })?;
        Ok(())
    }

    fn bury_or_suspend(&self, card_id: i64, mode: BuryOrSuspendMode) -> Result<Value> {
        lock(&self.current).take();
        self.with_col(|col| {
            // ensure card exists before acting on it
            let _card = CardsService::get_card(col, CardId { cid: card_id })?;
            SchedulerService::bury_or_suspend_cards(
                col,
                BuryOrSuspendCardsRequest {
                    card_ids: vec![card_id],
                    note_ids: vec![],
                    mode: mode as i32,
                },
            )
            .map(|_| ())
        })?;
        Ok(Value::Null)
    }

    // Syncing
    ///////////////

    fn normal_sync(&self, auth: AuthJson, sync_media: bool) -> Result<Value> {
        // Abortable with [Self::abort_sync]: the backend rolls back the open
        // transaction and tells the server to clean up. Media is synced in
        // the background afterwards, unless a full sync is required.
        let before = self.sync_state()?;
        let resp = BackendSyncService::sync_collection(
            &self.backend,
            SyncCollectionRequest {
                auth: Some(auth.into()),
                sync_media,
            },
        )?;
        let mut required = ChangesRequired::try_from(resp.required);
        // The core reports a completed normal sync as "no changes"; tell
        // Swift that changes were exchanged, so it reloads its screens.
        if required == Ok(ChangesRequired::NoChanges) && self.sync_state()? != before {
            required = Ok(ChangesRequired::NormalSync);
        }
        if required != Ok(ChangesRequired::NoChanges) {
            // the card may have been changed on another device
            lock(&self.current).take();
        }
        let required = match required {
            Ok(ChangesRequired::NoChanges) => "noChanges",
            Ok(ChangesRequired::NormalSync) => "normalSync",
            Ok(ChangesRequired::FullSync) => "fullSync",
            Ok(ChangesRequired::FullDownload) => "fullDownload",
            Ok(ChangesRequired::FullUpload) => "fullUpload",
            Err(_) => "fullSync",
        };
        Ok(json!({
            "required": required,
            "serverMessage": resp.server_message,
            "newEndpoint": resp.new_endpoint,
            "serverMediaUsn": resp.server_media_usn,
        }))
    }

    /// Changes when a normal sync exchanged data with the server.
    fn sync_state(&self) -> Result<(TimestampMillis, i32)> {
        self.with_col(|col| {
            let meta = col.sync_meta()?;
            Ok((meta.modified, meta.usn.0))
        })
    }

    fn full_sync(&self, auth: SyncAuth, upload: bool, server_media_usn: Option<i32>) -> Result<()> {
        lock(&self.current).take();
        if !upload {
            // like the desktop, keep a copy of what is about to be replaced
            if let Some(folder) = lock(&self.backup_folder).clone() {
                if let Some(task) = self.with_col(|col| col.maybe_backup(folder, true))? {
                    task.join().map_err(|_| invalid("backup failed"))??;
                }
            }
        }
        // The backend stops any media sync first, and reopens the collection
        // regardless of the outcome. Abortable with [Self::abort_sync].
        // Given a usn, it then starts the media sync itself.
        BackendSyncService::full_upload_or_download(
            &self.backend,
            FullUploadOrDownloadRequest {
                auth: Some(auth.clone()),
                upload,
                server_usn: server_media_usn,
            },
        )?;
        if server_media_usn.is_none() {
            BackendSyncService::sync_media(&self.backend, auth)?;
        }
        Ok(())
    }

    /// Whether a media sync is running, and the error it failed with, if
    /// any. A failure is reported by the first call after it finished.
    fn media_sync_status(&self) -> Value {
        match BackendSyncService::media_sync_status(&self.backend) {
            Ok(status) => json!({ "active": status.active, "error": null }),
            // stopped on request, eg by a full sync or by closing
            Err(AnkiError::Interrupted) => json!({ "active": false, "error": null }),
            Err(err) => json!({ "active": false, "error": err.message(self.backend.i18n()) }),
        }
    }
}

fn deck_node_json(node: &DeckTreeNode) -> Value {
    json!({
        "id": node.deck_id,
        "name": node.name,
        "level": node.level,
        "collapsed": node.collapsed,
        "filtered": node.filtered,
        "new": node.new_count,
        "learn": node.learn_count,
        "review": node.review_count,
        "total": node.total_including_children,
        "children": node.children.iter().map(deck_node_json).collect::<Vec<_>>(),
    })
}

impl Drop for Bridge {
    fn drop(&mut self) {
        // Stops any media sync, which holds its own clone of the backend, and
        // would otherwise keep the collection open.
        let _ = self.close_collection();
    }
}

/// Lock a mutex, ignoring poisoning: a panic is caught at the FFI boundary,
/// and later commands should still be able to run.
fn lock<T>(mutex: &Mutex<T>) -> MutexGuard<'_, T> {
    mutex.lock().unwrap_or_else(PoisonError::into_inner)
}

fn invalid(message: &str) -> AnkiError {
    AnkiError::InvalidInput {
        source: snafu::FromString::without_source(message.to_string()),
    }
}
