// Copyright 2026 Redpanda Data, Inc.
//
// Use of this software is governed by the Business Source License
// included in the file licenses/BSL.md
//
// As of the Change Date specified in that file, in accordance with
// the Business Source License, use of this software will be governed
// by the Apache License, Version 2.0

#pragma once

#include "base/seastarx.h"

#include <seastar/core/sstring.hh>

#include <cstdint>
#include <optional>

namespace net {

/// Prepare an AF_UNIX socket path for bind().
///
/// Performs the following steps on shard 0:
///  1. Validates the parent directory exists and is writable.
///  2. If `path` exists:
///      - If it is a socket, attempts connect(2). On ECONNREFUSED the
///        socket is treated as stale and unlinked (a warning is logged).
///        On successful connect, throws — another broker is live.
///      - If it is not a socket, throws (never unlinks arbitrary files).
///  3. Acquires an advisory lock on `<path>.lock` via flock(2). The lock
///     fd is owned by this process for the lifetime of the listener; it
///     is released when the process exits.
///
/// Throws std::runtime_error on any unrecoverable precondition failure.
void prepare_uds_path(const ss::sstring& path);

/// Apply `chmod(path, mode)`. Called post-listen on shard 0 after the
/// socket inode has been created by bind(). Throws std::runtime_error on
/// failure. `mode` defaults to 0660 if nullopt.
void chmod_uds_path(const ss::sstring& path, std::optional<uint32_t> mode);

/// Post-bind verification (defense-in-depth).
///
/// Re-stats `path` with lstat(2) and asserts that the inode we ended up
/// with is:
///   - a socket (`S_ISSOCK`), not a symlink / regular file / anything else;
///   - owned by the current effective UID.
///
/// This closes the TOCTOU window between `prepare_uds_path`'s stat/unlink
/// and the subsequent bind()+chmod() call: if a local attacker with write
/// access to the parent directory swapped the target inode for a symlink
/// or a file they own, the mismatch is caught here and the broker fails
/// to start instead of serving traffic on a surprise inode.
///
/// Throws std::runtime_error if the invariant is violated.
void verify_uds_bound(const ss::sstring& path);

/// Best-effort cleanup of a UDS path at graceful shutdown. Unlinks both
/// `path` and `<path>.lock`. ENOENT is ignored; all other errors are
/// logged but not thrown (shutdown must proceed).
void cleanup_uds_path(const ss::sstring& path);

} // namespace net
