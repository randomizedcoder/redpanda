# nix/tests/constants.nix
#
# Shared configuration for all Redpanda Nix tests.
# Centralizes ports, timeouts, config templates, and image size limits
# so changes propagate to every test automatically.
{
  ports = {
    kafka = 9092;
    admin = 9644;
    rpc = 33145;
    pandaproxy = 8082;
    schemaRegistry = 8081;
  };

  timeouts = {
    startup = 60;
    shutdown = 30;
    produce = 10;
    schemaRegistry = 15;
    lifecycle = 120;
  };

  # Generate a developer-mode redpanda.yaml for testing.
  # dataDir is a placeholder string replaced at runtime via sed.
  #
  # When kafkaUnixPath is non-null, a second kafka_api entry is emitted
  # alongside the TCP one so tests can exercise mixed-transport (UDS +
  # TCP) deployments — the default production shape for same-node
  # colocation on K8s where service meshes/CNIs intercept loopback TCP.
  mkRedpandaYaml =
    {
      dataDir ? "DATA_DIR_PLACEHOLDER",
      nodeId ? 0,
      kafkaPort ? 9092,
      adminPort ? 9644,
      rpcPort ? 33145,
      kafkaUnixPath ? null,
      kafkaUnixMode ? "0660",
    }:
    let
      # Plain string (not indented) so whitespace is preserved verbatim
      # when concatenated into the indented YAML body below. Indent
      # level matches the `- address:` line of the TCP kafka_api entry
      # (4 spaces for list-item dash, 6 for sub-properties).
      udsEntry =
        if kafkaUnixPath != null then
          "    - unix_path: ${kafkaUnixPath}\n"
          + "      unix_socket_mode: ${kafkaUnixMode}\n"
          + "      name: uds\n"
        else
          "";
    in
    ''
      redpanda:
        data_directory: ${dataDir}
        developer_mode: true
        node_id: ${toString nodeId}
        rpc_server:
          address: 127.0.0.1
          port: ${toString rpcPort}
        kafka_api:
          - address: 127.0.0.1
            port: ${toString kafkaPort}
            name: tcp
    ''
    + udsEntry
    + ''
        admin:
          - address: 127.0.0.1
            port: ${toString adminPort}
        seed_servers: []
      pandaproxy:
        pandaproxy_api:
          - address: 127.0.0.1
            port: 8082
      schema_registry:
        schema_registry_api:
          - address: 127.0.0.1
            port: 8081
    '';

  imageSizeLimits = {
    redpanda = 600;
    redpandaDebug = 700;
    rpk = 200;
  };

  testMessages = {
    small = "hello-from-nix-test";
    medium = "medium-payload-with-some-additional-data-for-testing-purposes-1234567890";
  };
}
