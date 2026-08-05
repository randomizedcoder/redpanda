// Copyright 2026 Redpanda Data, Inc.
//
// Use of this software is governed by the Business Source License
// included in the file licenses/BSL.md
//
// As of the Change Date specified in that file, in accordance with
// the Business Source License, use of this software will be governed
// by the Apache License, Version 2.0

#include "net/uds_path.h"

#include "base/seastarx.h"
#include "base/vlog.h"

#include <seastar/util/log.hh>

#include <sys/file.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>

#include <cerrno>
#include <cstring>
#include <fcntl.h>
#include <filesystem>
#include <stdexcept>
#include <string>
#include <unistd.h>

namespace net {

namespace {

static ss::logger udslog("net_uds");

[[noreturn]] void throw_errno(const std::string& op, const ss::sstring& path) {
    const int e = errno;
    throw std::runtime_error(
      fmt::format(
        "UDS {}: path='{}': {} (errno={})", op, path, std::strerror(e), e));
}

/// Returns true if a connect(2) to `path` succeeds (some process is
/// listening), false if ECONNREFUSED (stale socket file), rethrows for
/// anything else.
bool probe_connect(const ss::sstring& path) {
    int fd = ::socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);
    if (fd < 0) {
        throw_errno("probe_connect socket()", path);
    }
    sockaddr_un addr{};
    addr.sun_family = AF_UNIX;
    if (path.size() >= sizeof(addr.sun_path)) {
        ::close(fd);
        throw std::runtime_error(
          fmt::format(
            "UDS probe_connect: path too long ({} bytes): '{}'",
            path.size(),
            path));
    }
    std::memcpy(addr.sun_path, path.c_str(), path.size());
    int rc = ::connect(fd, reinterpret_cast<sockaddr*>(&addr), sizeof(addr));
    int e = errno;
    ::close(fd);
    if (rc == 0) {
        return true;
    }
    if (e == ECONNREFUSED) {
        return false;
    }
    errno = e;
    throw_errno("probe_connect connect()", path);
}

} // namespace

void prepare_uds_path(const ss::sstring& path) {
    std::filesystem::path fspath{std::string{path}};
    auto parent = fspath.parent_path();
    if (parent.empty()) {
        throw std::runtime_error(
          fmt::format("UDS prepare: path '{}' has no parent directory", path));
    }
    struct stat parent_st{};
    if (::stat(parent.c_str(), &parent_st) != 0) {
        throw_errno("stat(parent)", path);
    }
    if (!S_ISDIR(parent_st.st_mode)) {
        throw std::runtime_error(
          fmt::format(
            "UDS prepare: parent '{}' of '{}' is not a directory",
            parent.string(),
            path));
    }
    if (::access(parent.c_str(), W_OK) != 0) {
        throw_errno("access(parent, W_OK)", path);
    }

    struct stat st{};
    if (::stat(path.c_str(), &st) == 0) {
        if (!S_ISSOCK(st.st_mode)) {
            throw std::runtime_error(
              fmt::format(
                "UDS prepare: path '{}' exists and is not a socket "
                "(mode={:#o}); refusing to unlink",
                path,
                st.st_mode));
        }
        // Existing socket: probe to decide whether it is stale.
        if (probe_connect(path)) {
            throw std::runtime_error(
              fmt::format(
                "UDS prepare: path '{}' is a live socket — another broker "
                "appears to be listening",
                path));
        }
        vlog(
          udslog.warn,
          "Unlinking stale UDS socket at '{}' (connect probe refused)",
          path);
        if (::unlink(path.c_str()) != 0 && errno != ENOENT) {
            throw_errno("unlink(stale)", path);
        }
    } else if (errno != ENOENT) {
        throw_errno("stat", path);
    }

    // Advisory lock on <path>.lock. The lock fd is intentionally leaked:
    // kernel releases on process exit, which is the desired lifetime.
    ss::sstring lock_path = path + ".lock";
    int lock_fd = ::open(
      lock_path.c_str(),
      O_RDWR | O_CREAT | O_CLOEXEC,
      S_IRUSR | S_IWUSR | S_IRGRP | S_IWGRP);
    if (lock_fd < 0) {
        throw_errno("open(lockfile)", lock_path);
    }
    if (::flock(lock_fd, LOCK_EX | LOCK_NB) != 0) {
        int e = errno;
        ::close(lock_fd);
        if (e == EWOULDBLOCK) {
            throw std::runtime_error(
              fmt::format(
                "UDS prepare: another process holds the advisory lock on "
                "'{}'",
                lock_path));
        }
        errno = e;
        throw_errno("flock", lock_path);
    }
    // lock_fd intentionally leaked — lifetime = process.
}

void chmod_uds_path(const ss::sstring& path, std::optional<uint32_t> mode) {
    const mode_t m = mode.value_or(0660);
    if (::chmod(path.c_str(), m) != 0) {
        throw_errno(fmt::format("chmod({:#o})", m), path);
    }
}

void verify_uds_bound(const ss::sstring& path) {
    // lstat(2) does NOT follow symlinks — the whole point of this check is
    // to detect if something replaced our target inode with a symlink
    // between prepare_uds_path()'s stat/unlink and the subsequent bind().
    struct stat st{};
    if (::lstat(path.c_str(), &st) != 0) {
        throw_errno("verify_uds_bound lstat", path);
    }
    if (!S_ISSOCK(st.st_mode)) {
        throw std::runtime_error(
          fmt::format(
            "UDS verify: path '{}' is not a socket after bind "
            "(mode={:#o}); possible symlink-race attack, refusing to start",
            path,
            st.st_mode));
    }
    const uid_t me = ::geteuid();
    if (st.st_uid != me) {
        throw std::runtime_error(
          fmt::format(
            "UDS verify: path '{}' is owned by uid {} but we run as uid {}; "
            "possible inode-swap attack, refusing to start",
            path,
            st.st_uid,
            me));
    }
}

void cleanup_uds_path(const ss::sstring& path) {
    if (::unlink(path.c_str()) != 0 && errno != ENOENT) {
        vlog(
          udslog.warn,
          "cleanup: unlink('{}') failed: {}",
          path,
          std::strerror(errno));
    }
    ss::sstring lock_path = path + ".lock";
    if (::unlink(lock_path.c_str()) != 0 && errno != ENOENT) {
        vlog(
          udslog.warn,
          "cleanup: unlink('{}') failed: {}",
          lock_path,
          std::strerror(errno));
    }
}

} // namespace net
