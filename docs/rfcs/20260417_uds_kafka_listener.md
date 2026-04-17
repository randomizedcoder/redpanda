- Feature Name: Experimental Unix Domain Socket listener for Kafka API
- Status: draft
- Start Date: 2026-04-17
- Authors: randomizedcoder
- Issue: none

# Executive Summary

Add an experimental `AF_UNIX` (Unix Domain Socket, UDS) listener to Redpanda's
Kafka API so that producer/consumer workloads co-located on the same host as
the broker can bypass the TCP/IP stack entirely. Configured via an optional
`unix_path` field on existing `kafka_api` entries. TCP listeners, inter-broker
RPC, Admin API, pandaproxy, and Schema Registry are unchanged.

## What is being proposed

A new optional `unix_path` field on each `kafka_api` entry. When set, that
entry is bound via `ss::unix_domain_addr` instead of a host/port pair. A
single broker can expose both TCP and UDS listeners simultaneously and
serve identical topic/partition state on both. Authentication reuses the
existing `authentication_method: sasl|none` field. TLS is rejected on UDS
listeners by a configuration validator. `rpk` is extended to accept
`unix:///path/to/socket` in its `--brokers` / `-X brokers=...` flags via a
custom `franz-go` dialer.

## Why (short reason)

Production deployments frequently run producer/consumer pods on the same
Kubernetes node as the broker pod. "Loopback TCP is fast" is regularly
assumed, but service-mesh sidecars (Istio, Linkerd), CNI dataplanes
(Cilium, Calico), and host-level iptables rules intercept traffic on
127.0.0.1. UDS bypasses every layer above the kernel's `af_unix` driver
and removes that uncertainty. It also halves the syscall count per
message (one `sendmsg`/`recvmsg` pair instead of a TCP segment round-trip
through the socket buffer).

## How (short plan)

1. Add `unix_path` (and optional `unix_socket_mode`) to
   `config::broker_authn_endpoint`. Mutually exclusive with `address + port`.
2. Add a cross-list validator that rejects TLS on UDS listeners and
   forbids advertising UDS listener names.
3. Branch the Kafka `server_configuration` construction in
   `application_services.cc` to build `ss::socket_address(ss::unix_domain_addr(path))`
   when `unix_path` is set; `net::server` needs no changes (Seastar's
   existing accept-dispatch path is already AF_UNIX-aware).
4. Add stale-socket recovery (`connect(2)` probe + `unlink` of dead
   sockets, advisory `flock` on a sibling lockfile).
5. Extend `rpk` to recognise the `unix://` URI scheme.

## Impact

UDS is **additive**. Every existing deployment continues to work unchanged.
The only operational change is the need to provision a shared filesystem
(e.g. `hostPath` or `emptyDir` with a tmpfs medium) visible to both
broker and client pods if users want to opt in.

Drawbacks:

- Only Go/C/C++ Kafka clients that can be pointed at an AF_UNIX socket can
  use this listener. The Java client and librdkafka do not currently
  support UDS. Users on those clients continue to use TCP.
- TLS on UDS is rejected. Operators who want cryptographic identity on a
  UDS path must rely on filesystem permissions (mode/owner) for now;
  `SO_PEERCRED`-based authn is explicitly out of scope for v1.

# Motivation

## Why are we doing this?

When a producer and broker share a Kubernetes node, the "local" TCP path
between them is not actually local in any meaningful sense — it traverses
iptables, conntrack, and frequently a service-mesh proxy. Each of these
is a known source of tail-latency variance and of CPU overhead. A UDS
listener removes them entirely. Early exploratory benchmarks on this
repo's Nix-based test harness will be captured in this RFC's
*Measurements* section once Phase 4 lands.

## What use cases does it support?

- **Sidecar producer/consumer pods** on the same node as the broker pod,
  exchanging data through a shared emptyDir.
- **Single-node development and test deployments** that want to exercise
  the protocol without opening a TCP port.
- **High-throughput ingest pipelines** colocated with the broker where
  tail latency matters.

## What is the expected outcome?

Measurable reduction in produce/consume tail latency (p99) and syscall
count per message when clients and broker are on the same host, with
zero behavioural change for existing TCP-only deployments.

# Guide-level explanation

## Configuring a UDS listener

`redpanda.yaml` allows multiple `kafka_api` entries. A UDS entry is a
regular entry with `unix_path` set instead of `address`/`port`:

```yaml
redpanda:
  kafka_api:
    - name: external
      address: 0.0.0.0
      port: 9092
      authentication_method: sasl
    - name: local-uds
      unix_path: /run/redpanda/kafka.sock
      unix_socket_mode: 0660              # optional; default 0660
      authentication_method: none          # SASL also supported
  advertised_kafka_api:
    - name: external                        # UDS listeners MUST NOT be advertised
      address: broker-0.cluster.example
      port: 9092
```

Rules enforced by configuration validation:

- Each `kafka_api` entry has either `address + port` **or** `unix_path`,
  never both, never neither.
- `unix_path` must be absolute and shorter than 108 bytes
  (`sizeof(sockaddr_un::sun_path) - 1`).
- `unix_socket_mode`, if set, is an octal integer in `[0000, 0777]`. It is
  applied via `chmod(2)` immediately after `listen(2)`.
- If an entry in `kafka_api_tls` has the same `name` as a UDS
  `kafka_api` entry, config parsing fails with
  `"TLS not supported on UDS listener <name>"`.
- If an entry in `advertised_kafka_api` has the same `name` as a UDS
  `kafka_api` entry, config parsing fails with
  `"cannot advertise UDS listener <name>"`.
- Duplicate `unix_path` across `kafka_api` entries is rejected.

## Connecting from rpk

```sh
rpk topic produce my-topic --brokers unix:///run/redpanda/kafka.sock
rpk topic consume my-topic --brokers unix:///run/redpanda/kafka.sock
```

Because UDS listeners are not advertised in Kafka metadata responses
(see §*Advertised addresses*), an rpk client bootstrapped against a UDS
seed will discover only the broker's **TCP** listeners when it issues
`Metadata`. In a co-located single-node layout this is fine —
the TCP listener may simply bind on `127.0.0.1`. In a multi-node
cluster, the metadata response will name the cluster's external TCP
endpoints, and follow-up client connections will flow over TCP.
Operators who need every connection to stay on UDS must either pin
`rpk` to a single broker via flags or accept a single-connection
model. This is documented as a known limitation for v1.

# Reference-level explanation

## Interaction with other features

- **Inter-broker RPC** (`rpc_server`) is unchanged — TCP only.
- **Admin API**, **pandaproxy**, **Schema Registry** are unchanged — TCP only.
- **Advertised addresses** (`advertised_kafka_api`): UDS listener names
  are forbidden from appearing here. This keeps the Kafka `Metadata`
  response reachable by remote clients.
- **TLS**: rejected on UDS listeners (see §*Drawbacks*).
- **SASL**: supported on UDS listeners identically to TCP. A user who
  wants the least-overhead local path sets `authentication_method: none`
  and relies on the socket's filesystem permissions.
- **Quotas, connection-rate limits, conn-quota bindings**: unchanged;
  they operate on `net::connection` after accept, which is transport-agnostic.

## Telemetry & Observability

- Existing `redpanda_rpc_*`, `redpanda_kafka_*` Prometheus metrics apply
  transparently (they are keyed on `server_name`, not transport).
- New log lines at `info` level:
  - `unlinking stale socket <path>`: printed when startup finds an
    orphan AF_UNIX file whose owning process has exited.
  - `UDS kafka listener <name> ready at <path> mode 0<oct>`: printed
    after `listen(2)` + `chmod(2)` succeed on shard 0.
- No new metrics proposed for v1. If telemetry need emerges after
  production use, a `redpanda_kafka_transport{type="uds|tcp"}` label on
  the existing connection-count gauge would be the minimal-change path.

## Corner cases dissected by example

1. **Socket path pre-exists as a live socket**: another broker (or the
   same broker under two data dirs) is running. Startup probes via
   `connect(2)`; a successful connect means "live", startup fails with a
   clear error naming the path. No unlink. This prevents the common
   "two brokers silently overwriting each other" footgun.

2. **Socket path pre-exists as a stale socket**: previous broker exited
   without cleanup (e.g. SIGKILL, node crash). `connect(2)` returns
   `ECONNREFUSED`. Startup logs a warning, `unlink(2)`s the path, and
   proceeds. An advisory `flock` on `<path>.lock` guards against two
   brokers racing through this window.

3. **Socket path exists but is not a socket**: startup fails loudly. We
   never unlink arbitrary regular files.

4. **Parent directory missing or not writable**: startup fails with a
   clear message naming the directory.

5. **Path longer than 107 bytes**: rejected at config parse time with
   `"unix_path too long (N bytes, max 107)"`.

6. **TLS name collision**: a `kafka_api` entry with `name: alpha` and
   `unix_path: /tmp/a.sock` plus a `kafka_api_tls` entry with
   `name: alpha` fails validation with
   `"TLS not supported on UDS listener alpha"`.

7. **Advertisement collision**: a UDS `kafka_api` entry whose `name`
   appears in `advertised_kafka_api` is rejected at parse time.

8. **Graceful shutdown**: after `server.stop()`, the broker unlinks the
   socket path and its `<path>.lock` sibling (ignoring `ENOENT`).

9. **Ungraceful shutdown (SIGKILL / node crash)**: the socket file
   remains. Corner case 2 covers the next startup.

10. **Mixed-transport round-trip** (the primary test case): a producer on
    UDS writes to topic `t`, a consumer on TCP reads from the same
    topic; offsets, timestamps and payloads are identical. Transport
    MUST be invisible at the Kafka protocol layer.

## Detailed design - What needs to change to get there

### Config layer

- `src/v/config/broker_authn_endpoint.h`: add
  `std::optional<ss::sstring> unix_path;` and
  `std::optional<uint32_t> unix_socket_mode;`. Keep existing `address`
  field. `net::unresolved_address` itself is a `serde::envelope` wire
  type and is **not** modified, preserving cross-version compatibility.
- `src/v/config/broker_authn_endpoint.cc`:
  - `YAML::convert::encode` emits either `address`/`port` or
    `unix_path`/`unix_socket_mode`, never both.
  - `YAML::convert::decode` enforces exactly-one-of at the parser level
    (returns `false` otherwise).
  - `json::rjson_serialize` mirrors the encode branches.
  - New `validate_broker_authn_endpoint(const broker_authn_endpoint&)`
    returning `std::optional<ss::sstring>` for semantic checks
    (absolute path, length < 108, non-empty, mode in range).

### Cross-list validator

- `src/v/config/node_config.cc`: `validate_kafka_uds_constraints(kafka_api,
  kafka_api_tls, advertised_kafka_api)`. Wired into the existing
  `node_config::validate()` chain. Rules enumerated in §*Guide-level
  explanation*.

### Bind-time construction

- `src/v/redpanda/application_services.cc` around the Kafka
  `server_configuration` assembly:
  ```cpp
  ss::socket_address saddr;
  if (ep.unix_path.has_value()) {
      vassert(!credentials,
              "TLS not permitted on UDS listener {}", ep.name);
      prepare_uds_path(*ep.unix_path);
      saddr = ss::socket_address(ss::unix_domain_addr(*ep.unix_path));
  } else {
      saddr = net::resolve_dns(ep.address).get();
  }
  c.addrs.emplace_back(ep.name, saddr, credentials);
  ```

- New helper `src/v/net/uds_path.{h,cc}` exposes `prepare_uds_path()` and
  `cleanup_uds_path()`:
  - `prepare_uds_path` verifies parent dir; probes an existing path via
    `connect(2)`; unlinks iff stale and `S_ISSOCK`; acquires `flock` on
    `<path>.lock`.
  - `cleanup_uds_path` unlinks both files, swallowing `ENOENT`.

### Why `net::server` needs no changes

Seastar's `posix_network_stack::listen()`
(`external/+non_module_dependencies+seastar/src/net/posix-stack.cc:923-925`)
already branches on `sa.is_af_unix()` and returns a
`posix_server_socket_impl` that supports cross-shard accept dispatch via
`smp::submit_to` (lines 706-749). Non-zero shards use
`posix_ap_network_stack::listen()` (lines 948-950) which creates a
`posix_ap_server_socket_impl` that registers an accept proxy — it never
calls `bind(2)`. Load balancing via the `connection_distribution`
algorithm (Redpanda's default) hashes a monotonic counter for AF_UNIX
(`get_port_or_counter`, lines 572-578). The upshot: Redpanda's existing
per-shard `ss::engine().listen(endpoint.addr, lo)` call in
`src/v/net/server.cc:83-117` does the right thing for AF_UNIX with zero
modifications.

### rpk (Go)

- `src/go/rpk/pkg/config/params.go`: accept `unix:///abs/path` in broker
  lists, normalising to `{Network: "unix", Address: "/abs/path"}` entries.
- The shared `[]kgo.Opt` factory installs a UDS-aware `kgo.Dialer` that
  routes `unix://...` addresses through `net.Dial("unix", path)` and
  delegates everything else to the default dialer.
- All rpk subcommands using the shared factory inherit UDS support for
  free (`rpk topic|cluster|group|acl ...`). `rpk` Admin-API commands
  remain TCP-only.

## Detailed design - How it works

Startup sequence for a broker with a dual listener:

1. Config parser validates each `kafka_api` entry and the cross-list
   constraints.
2. For each UDS entry, `prepare_uds_path` runs on shard 0 before
   `server_configuration` is constructed.
3. Every shard's `net::server::start()` calls
   `ss::engine().listen(endpoint.addr, lo)`. On shard 0 this executes
   `bind + listen`. On other shards this registers an accept proxy.
4. Post-start, shard 0 executes `chmod(path, mode)` to apply the
   configured `unix_socket_mode`.
5. Shard 0 accepts connections and dispatches to target shards via
   `smp::submit_to`; the Kafka protocol handler is invoked on the target
   shard exactly as for TCP.

Shutdown:

1. `server.stop()` closes all accept sockets.
2. For every UDS entry, the Kafka service's post-stop hook calls
   `cleanup_uds_path`, unlinking both the socket and lockfile.

## Drawbacks

- **TLS unsupported**: forces operators who need cryptographic identity
  on a local path to wait for a follow-up peer-cred authn PR or continue
  using TLS over 127.0.0.1.
- **Java / librdkafka clients cannot use UDS**: only Go (via franz-go),
  plain C (via `AF_UNIX` + Kafka wire protocol), and C++ clients that
  support AF_UNIX can benefit.
- **Metadata response carries only TCP endpoints**: a client
  bootstrapped on UDS may follow metadata to TCP for follow-up
  connections in multi-broker clusters. Documented in §*Guide-level
  explanation*.
- **Filesystem permissions are the only access control** when SASL is
  disabled. Operators must ensure the socket path's parent directory
  and mode are set appropriately.
- **Operational complexity**: two listener types mean two sets of
  cluster health checks and dashboards if users want per-transport
  visibility. Deferred until there is demonstrated demand.

## Rationale and Alternatives

### Why add UDS at all?

See *Motivation*. The short form is: "loopback is fast" is empirically
false under service meshes and CNIs, and broker pods colocated with
client pods are a common Redpanda deployment pattern. Measured deltas
will be added to this RFC before merge.

### Why extend `broker_authn_endpoint` rather than introduce a new type?

Alternatives considered:

1. **Add `unix_path` to existing type (chosen).** Minimal surface change;
   the existing `one_or_many_property<broker_authn_endpoint>` and
   admin-API schema generator pick up the new field automatically.
2. **Overload `address` with a `unix://...` URI scheme.** Rejected: the
   `address` field is currently a bare hostname parsed by
   `net::unresolved_address`, and embedding a URI here leaks transport
   concerns into a type that many other subsystems serialise over the
   wire.
3. **Introduce a new top-level `kafka_api_uds` config key.** Rejected:
   doubles the config surface and duplicates TLS/SASL key handling.

### Why not touch `net::unresolved_address`?

It's a `serde::envelope` type, meaning it participates in the
on-the-wire format used between brokers and between Redpanda versions.
Adding a variant/optional unix_path field would require a version bump
with tightly-coupled compatibility shims. Keeping it as a pure
host+port type preserves the clean boundary.

### Why reject TLS-on-UDS rather than allow it?

Seastar's `ss::tls::listen` wraps any server_socket, so it would
technically work. Rejected because:
- UDS is already constrained to the host, so most users don't need
  encryption.
- Certificate management for a local socket is awkward — whose SAN does
  it carry?
- Testing the combination meaningfully adds surface without clear wins.

A future PR can lift the restriction if demand appears.

### Why not SO_PEERCRED-based authn?

Attractive for UDS — `getsockopt(SO_PEERCRED)` returns the connecting
uid/gid/pid — but the mapping from uid to Kafka principal needs design
(PAM? Static uid→principal table? Linux user-namespace awareness?). That
design belongs in a follow-up RFC and should not block the basic UDS
listener.

## Unresolved questions

- **Metadata routing from a UDS bootstrap**: whether rpk should refuse
  to follow TCP metadata responses when started with a `unix://` seed,
  or whether it should hybridise (UDS for metadata + local traffic, TCP
  for remote shards). Current plan: do nothing, document the behaviour,
  leave finer control for a follow-up.
- **`chmod` race window**: between `listen(2)` and `chmod(2)` on shard 0
  there is a brief interval where the socket has default umask mode.
  Whether this matters depends on the filesystem's surrounding ACLs. If
  it does, one option is to `fchmod(listen_fd)` — but that affects only
  the fd, not the path. Alternative: `umask(0)` guard around the bind.
  Decide during implementation.
- **Lockfile location**: `<unix_path>.lock` co-located with the socket
  is simpler; a dedicated lock directory
  (`/var/run/redpanda/locks/<hash>.lock`) is tidier. Default to
  co-located unless operators flag an issue.
- **Follow-up microvm test**: extend the Nix test harness with a
  `microvm.nix`-based nixosTest that boots a VM, runs the broker, and
  exercises crash recovery (`kill -9` → restart → stale-socket cleanup).
  Tracked separately; not a blocker for this RFC.

## Measurements

*(To be populated after Phase 4 lands — placeholder section.)*

- Per-message end-to-end latency p50/p99 via `rpk topic produce|consume`
  under fixed rate: TCP-loopback vs UDS.
- Syscall counts per message via
  `perf stat -e syscalls:sys_enter_sendmsg,syscalls:sys_enter_recvmsg`.
- Per-shard CPU from `redpanda_cpu_busy_seconds_total` diff.
- Microbench (`src/v/net/tests/uds_bench.cc`) sweeping payload sizes
  {64 B, 1 KiB, 16 KiB, 1 MiB} and pipeline depths {1, 8, 32}.
