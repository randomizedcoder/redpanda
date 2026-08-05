// Copyright 2026 Redpanda Data, Inc.
//
// Use of this software is governed by the Business Source License
// included in the file licenses/BSL.md
//
// As of the Change Date specified in that file, in accordance with
// the Business Source License, use of this software will be governed
// by the Apache License, Version 2.0

#include "base/seastarx.h"
#include "net/uds_path.h"

#include <seastar/core/reactor.hh>
#include <seastar/core/seastar.hh>
#include <seastar/net/api.hh>
#include <seastar/testing/thread_test_case.hh>

#include <boost/test/test_tools.hpp>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>

#include <cerrno>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <stdexcept>
#include <unistd.h>

namespace {

/// Per-test scratch directory. Each BOOST_AUTO_TEST_CASE creates its own
/// mkdtemp() directory to avoid cross-test interference (tests may run in
/// parallel inside a single process when Seastar is configured that way).
class scratch_dir {
public:
    scratch_dir() {
        char tmpl[] = "/tmp/rp-uds-test-XXXXXX";
        const char* p = ::mkdtemp(tmpl);
        if (p == nullptr) {
            throw std::runtime_error("mkdtemp failed");
        }
        _dir = p;
    }
    scratch_dir(const scratch_dir&) = delete;
    scratch_dir& operator=(const scratch_dir&) = delete;
    ~scratch_dir() {
        std::error_code ec;
        std::filesystem::remove_all(_dir, ec);
    }
    const std::string& dir() const { return _dir; }
    std::string path(const std::string& name) const {
        return _dir + "/" + name;
    }

private:
    std::string _dir;
};

/// Bind a plain AF_UNIX socket at `path` and return the listening fd. Used
/// to simulate a "live" peer for the stale-socket probe test. Caller owns
/// the returned fd and must close() it.
int bind_listen_uds(const std::string& path) {
    int fd = ::socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);
    BOOST_REQUIRE(fd >= 0);
    sockaddr_un addr{};
    addr.sun_family = AF_UNIX;
    std::memcpy(addr.sun_path, path.c_str(), path.size());
    int rc = ::bind(fd, reinterpret_cast<sockaddr*>(&addr), sizeof(addr));
    BOOST_REQUIRE_MESSAGE(rc == 0, "bind failed: " << std::strerror(errno));
    rc = ::listen(fd, 1);
    BOOST_REQUIRE_MESSAGE(rc == 0, "listen failed: " << std::strerror(errno));
    return fd;
}

} // namespace

SEASTAR_THREAD_TEST_CASE(prepare_happy_path) {
    scratch_dir s;
    ss::sstring path{s.path("rp.sock")};
    BOOST_CHECK_NO_THROW(net::prepare_uds_path(path));
    // Lockfile should now exist.
    struct stat st{};
    BOOST_CHECK(::stat((std::string{path} + ".lock").c_str(), &st) == 0);
}

SEASTAR_THREAD_TEST_CASE(prepare_missing_parent_throws) {
    ss::sstring path{"/nonexistent_parent_xyzzy/rp.sock"};
    BOOST_CHECK_THROW(net::prepare_uds_path(path), std::runtime_error);
}

SEASTAR_THREAD_TEST_CASE(prepare_parent_is_file_throws) {
    scratch_dir s;
    // Create a regular file and treat it as a "directory" path.
    std::string notadir = s.path("notadir");
    {
        int fd = ::open(notadir.c_str(), O_WRONLY | O_CREAT, S_IRUSR | S_IWUSR);
        BOOST_REQUIRE(fd >= 0);
        ::close(fd);
    }
    ss::sstring path{notadir + "/rp.sock"};
    BOOST_CHECK_THROW(net::prepare_uds_path(path), std::runtime_error);
}

SEASTAR_THREAD_TEST_CASE(prepare_stale_socket_unlinked) {
    scratch_dir s;
    std::string sock = s.path("rp.sock");
    // Create a socket inode but do NOT listen on it.
    int fd = ::socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);
    BOOST_REQUIRE(fd >= 0);
    sockaddr_un addr{};
    addr.sun_family = AF_UNIX;
    std::memcpy(addr.sun_path, sock.c_str(), sock.size());
    BOOST_REQUIRE(
      ::bind(fd, reinterpret_cast<sockaddr*>(&addr), sizeof(addr)) == 0);
    ::close(fd);
    // No listener: connect() will get ECONNREFUSED — prepare_uds_path
    // should treat the inode as stale, unlink it, and continue.
    BOOST_CHECK_NO_THROW(net::prepare_uds_path(ss::sstring{sock}));
}

SEASTAR_THREAD_TEST_CASE(prepare_live_socket_throws) {
    scratch_dir s;
    std::string sock = s.path("rp.sock");
    int listen_fd = bind_listen_uds(sock);
    // Someone else is live on the socket: must refuse, must NOT unlink.
    BOOST_CHECK_THROW(
      net::prepare_uds_path(ss::sstring{sock}), std::runtime_error);
    // The live socket inode should still be present.
    struct stat st{};
    BOOST_CHECK(::stat(sock.c_str(), &st) == 0);
    ::close(listen_fd);
    ::unlink(sock.c_str());
}

SEASTAR_THREAD_TEST_CASE(prepare_regular_file_throws_no_unlink) {
    scratch_dir s;
    std::string path = s.path("not_a_socket");
    {
        int fd = ::open(path.c_str(), O_WRONLY | O_CREAT, S_IRUSR | S_IWUSR);
        BOOST_REQUIRE(fd >= 0);
        ::write(fd, "hello", 5);
        ::close(fd);
    }
    BOOST_CHECK_THROW(
      net::prepare_uds_path(ss::sstring{path}), std::runtime_error);
    // Regular file must NOT be unlinked.
    struct stat st{};
    BOOST_CHECK(::stat(path.c_str(), &st) == 0);
    BOOST_CHECK(S_ISREG(st.st_mode));
}

SEASTAR_THREAD_TEST_CASE(cleanup_removes_socket_and_lock) {
    scratch_dir s;
    ss::sstring path{s.path("rp.sock")};
    net::prepare_uds_path(path);
    // prepare_uds_path creates the lockfile but not the socket inode;
    // simulate a bound socket by creating it.
    int fd = ::socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);
    BOOST_REQUIRE(fd >= 0);
    sockaddr_un addr{};
    addr.sun_family = AF_UNIX;
    std::memcpy(addr.sun_path, path.c_str(), path.size());
    BOOST_REQUIRE(
      ::bind(fd, reinterpret_cast<sockaddr*>(&addr), sizeof(addr)) == 0);
    ::close(fd);
    net::cleanup_uds_path(path);
    struct stat st{};
    BOOST_CHECK(::stat(path.c_str(), &st) != 0);
    BOOST_CHECK(::stat((std::string{path} + ".lock").c_str(), &st) != 0);
}

SEASTAR_THREAD_TEST_CASE(cleanup_idempotent_on_missing) {
    scratch_dir s;
    ss::sstring path{s.path("rp.sock")};
    // Nothing at path — cleanup must not throw and must not log errors
    // loud enough to fail the test.
    BOOST_CHECK_NO_THROW(net::cleanup_uds_path(path));
}

SEASTAR_THREAD_TEST_CASE(chmod_applies_mode) {
    scratch_dir s;
    std::string sock = s.path("rp.sock");
    int fd = bind_listen_uds(sock);
    net::chmod_uds_path(ss::sstring{sock}, std::optional<uint32_t>{0640});
    struct stat st{};
    BOOST_REQUIRE(::stat(sock.c_str(), &st) == 0);
    // Only the permission bits of st_mode are mode-sensitive; mask them.
    BOOST_CHECK_EQUAL(st.st_mode & 0777u, 0640u);
    ::close(fd);
    ::unlink(sock.c_str());
}

SEASTAR_THREAD_TEST_CASE(chmod_default_0660) {
    scratch_dir s;
    std::string sock = s.path("rp.sock");
    int fd = bind_listen_uds(sock);
    net::chmod_uds_path(ss::sstring{sock}, std::nullopt);
    struct stat st{};
    BOOST_REQUIRE(::stat(sock.c_str(), &st) == 0);
    BOOST_CHECK_EQUAL(st.st_mode & 0777u, 0660u);
    ::close(fd);
    ::unlink(sock.c_str());
}

SEASTAR_THREAD_TEST_CASE(seastar_unix_domain_listen_roundtrip) {
    // End-to-end sanity that ss::unix_domain_addr works under Seastar and
    // accepts a connection made via a plain AF_UNIX client. This is the
    // Seastar-side of the integration that application_services.cc relies
    // on.
    scratch_dir s;
    ss::sstring path{s.path("rp.sock")};
    auto addr = ss::socket_address(ss::unix_domain_addr(std::string{path}));
    ss::listen_options lo;
    lo.reuse_address = true;
    auto server = ss::engine().listen(addr, lo);

    // Client: plain blocking AF_UNIX connect.
    int client = ::socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);
    BOOST_REQUIRE(client >= 0);
    sockaddr_un sun{};
    sun.sun_family = AF_UNIX;
    std::memcpy(sun.sun_path, path.c_str(), path.size());
    // Seastar accept() runs on the reactor; dispatch it and the write
    // concurrently.
    auto accepted = server.accept();
    int rc = ::connect(client, reinterpret_cast<sockaddr*>(&sun), sizeof(sun));
    BOOST_REQUIRE_MESSAGE(rc == 0, "connect failed: " << std::strerror(errno));
    auto [connection, remoteaddr] = accepted.get();
    (void)remoteaddr;
    ::close(client);
    // Dropping `connection` and `server` via scope closes both endpoints.
    // scratch_dir destructor cleans up the socket inode.
}
