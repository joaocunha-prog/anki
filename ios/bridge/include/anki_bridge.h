// Copyright: Ankitects Pty Ltd and contributors
// License: GNU AGPL, version 3 or later; http://www.gnu.org/licenses/agpl.html

// C interface to Anki's Rust core. See ios/bridge/src/lib.rs.

#ifndef ANKI_BRIDGE_H
#define ANKI_BRIDGE_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct AnkiBridge AnkiBridge;

/// Bytes returned by anki_bridge_rpc(). `data` is NULL when `len` is 0.
/// If `is_error` is true, `data` holds an encoded anki.backend.BackendError
/// instead of the method's response.
typedef struct {
    uint8_t *data;
    size_t len;
    bool is_error;
} AnkiBuffer;

/// `langs` is a comma-separated list of preferred languages, or NULL.
AnkiBridge *anki_bridge_new(const char *langs);
void anki_bridge_free(AnkiBridge *bridge);

/// Call a backend service method with a protobuf-encoded request, like
/// pylib's rsbridge does. `service`/`method` are the generated indices.
/// `input` may be NULL when `input_len` is 0. The JSON commands below operate
/// on the same backend and collection. Free the result with
/// anki_bridge_free_buffer().
AnkiBuffer anki_bridge_rpc(const AnkiBridge *bridge, uint32_t service,
                           uint32_t method, const uint8_t *input,
                           size_t input_len);
void anki_bridge_free_buffer(AnkiBuffer buffer);

/// Run a JSON command. The returned string must be freed with
/// anki_bridge_free_string().
char *anki_bridge_command(const AnkiBridge *bridge, const char *input);
void anki_bridge_abort_sync(const AnkiBridge *bridge);
void anki_bridge_free_string(char *s);

#ifdef __cplusplus
}
#endif

#endif
