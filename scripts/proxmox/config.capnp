using Workerd = import "/workerd/workerd.capnp";

const config :Workerd.Config = (
  services = [
    (name = "seekhunt", worker = (
      modules = [(name = "worker.mjs", esModule = embed "worker.mjs")],
      compatibilityDate = "@COMPATIBILITY_DATE@",
      bindings = [
        (name = "ROOMS", durableObjectNamespace = "GameRoom"),
        (name = "ASSETS", service = "assets"),
      ],
      # Keep this key stable: changing it creates a different set of rooms.
      durableObjectNamespaces = [
        (className = "GameRoom", uniqueKey = "seekhunt-gameroom-v1", enableSql = true),
      ],
      durableObjectStorage = (localDisk = "state"),
    )),
    (name = "state", disk = (path = "/var/lib/seekhunt", writable = true)),
    (name = "assets", disk = (path = "apps/web/dist")),
  ],
  sockets = [
    (name = "http", address = "*:8787", http = (
      forwardedProtoHeader = "X-Forwarded-Proto",
    ), service = "seekhunt"),
  ],
);
