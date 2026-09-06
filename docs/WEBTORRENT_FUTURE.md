# Future WebTorrent adapter

The Web MVP returns an unsupported playback capability while metadata screens
remain available. A future adapter can implement the existing `TorrentEngine`
interface through JavaScript interop without changing feature code.

Prototype WebTorrent's service-worker streaming API, WebRTC tracker connectivity,
browser codec support, teardown, and statistics. Browser peers only connect to
WebRTC-capable peers, so every legal entry needs WebSocket trackers and an active
web seed. MP4 is the first acceptance format because browser support varies.
