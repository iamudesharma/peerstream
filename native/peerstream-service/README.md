# PeerStream companion prototype

See [implementation and adoption gates](../../docs/UX_PERFORMANCE_ROADMAP.md).

Run from the repository root:

```sh
tool/service-cargo.sh fmt --all --check
tool/service-cargo.sh clippy --all-targets --locked -- -D warnings
tool/service-cargo.sh test --locked
tool/service-cargo.sh build --release --locked
```

The executable requires `--root` (isolated writable storage) and `--native` (the source-built bridge library). It accepts one JSON bootstrap line with a random `token` on stdin, writes one readiness JSON line to stdout, and shuts down on stdin EOF. Never put tokens in command arguments. Do not use the real replay-cache root during prototype validation.

`GET /v1/health`, `GET /v1/events` and `POST /v1/command` require a Bearer token. Commands use `{ "op": "...", "args": { "instance": "..." } }`. The service core is the command schema authority; health reports capabilities and protocol version. The Dart adapter handles instance identity and stale sessions. Payload bytes never enter the control API.

This is an app-launched sandbox-inheriting helper, not an installed daemon or login item. Keep the default backend until the documented adoption gates pass.

Cached torrent URL replay advertises `capabilities.cachedMetadataResume` in health.
An `add` with `resumeOnly: true` tries owned `resume.dat`, then `source.torrent`,
without accepting or fetching new metadata. HTTP 422 with `code: cache_miss` is
the only signal permitting the caller to fetch metadata and retry creation.
Other errors must propagate because command completion may be ambiguous.
