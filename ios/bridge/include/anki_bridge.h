// Copyright: Ankitects Pty Ltd and contributors
// License: GNU AGPL, version 3 or later; http://www.gnu.org/licenses/agpl.html

// C interface to Anki's Rust core. See ios/bridge/src/lib.rs.

#ifndef ANKI_BRIDGE_H
#define ANKI_BRIDGE_H

#ifdef __cplusplus
extern "C" {
#endif

typedef struct AnkiBridge AnkiBridge;

/// `langs` is a comma-separated list of preferred languages, or NULL.
AnkiBridge *anki_bridge_new(const char *langs);
void anki_bridge_free(AnkiBridge *bridge);

/// Run a JSON command. The returned string must be freed with
/// anki_bridge_free_string().
char *anki_bridge_command(const AnkiBridge *bridge, const char *input);
void anki_bridge_abort_sync(const AnkiBridge *bridge);
void anki_bridge_free_string(char *s);

#ifdef __cplusplus
}
#endif

#endif
