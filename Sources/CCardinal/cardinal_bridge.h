// C API of CardinalBridge (CardinalBridge/src/lib.rs): Cardinal's file name index
// (Vendor/cardinal) for fileCommander's search. Build the library with ./build-cardinal.sh.
#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

typedef struct CardinalIndex CardinalIndex;

typedef struct {
    /// `count` NUL-terminated UTF-8 paths, back to back; NULL when there are none.
    char *paths;
    size_t paths_len;
    size_t count;
    /// More than `limit` items matched; only the first `limit` are in `paths`.
    bool truncated;
    bool cancelled;
    /// NUL-terminated message when the query could not run (e.g. a syntax error); else NULL.
    char *error;
} CardinalSearchResult;

/// Starts indexing `root` (absolute, symlinks resolved) in the background and returns at once.
/// `cache_file` (nullable) is a snapshot from cardinal_index_save to load instead of walking.
CardinalIndex *cardinal_index_open(const char *root, const char *cache_file);

/// 0 = indexing, 1 = ready, 2 = closed or failed.
uint8_t cardinal_index_state(const CardinalIndex *index);

/// Items found so far while indexing; once ready, the number of indexed items.
uint64_t cardinal_index_item_count(const CardinalIndex *index);

/// Whether the index holds `path` (absolute, symlinks resolved) and everything below it: the root or
/// below it, and not in a folder it skips (other volumes, cloud storage, other apps' containers…).
bool cardinal_index_covers(const CardinalIndex *index, const char *path);

/// A ticket for one search, for cardinal_index_search and cardinal_cancel_search.
uint64_t cardinal_search_ticket(void);

/// Runs a Cardinal query and returns matches below `scope`. `content` (nullable, "" = none) keeps
/// files (or symlinks to them) containing that text, read only after the scope and hidden filters; files up to
/// `max_file_size` bytes with a NUL in their first 8 KB never match it. Blocks until the index is
/// ready and the search finishes. Free the result with cardinal_search_result_free.
CardinalSearchResult cardinal_index_search(const CardinalIndex *index, const char *query, const char *scope,
                                           const char *content, bool case_insensitive, bool include_hidden,
                                           uint64_t max_file_size, size_t limit, uint64_t ticket);

/// Cancels the search holding `ticket` (from any thread, even before it starts).
void cardinal_cancel_search(uint64_t ticket);

/// Writes a snapshot of a ready index to `path` (blocking).
bool cardinal_index_save(const CardinalIndex *index, const char *path);

/// Stops indexing/watching and frees the index. Returns at once.
void cardinal_index_close(CardinalIndex *index);

void cardinal_search_result_free(CardinalSearchResult result);
