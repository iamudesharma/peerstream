// C layouts from torrent_bridge.h. Layout parity is checked by the native smoke test.
#![allow(non_camel_case_types)]
#[repr(C)]
#[derive(Clone, Copy)]
pub struct lt_torrent_status {
    pub id: i64,
    pub name: [std::ffi::c_char; 512],
    pub save_path: [std::ffi::c_char; 1024],
    pub error_msg: [std::ffi::c_char; 256],
    pub state: i32,
    pub progress: f32,
    pub download_rate: i32,
    pub upload_rate: i32,
    pub total_done: i64,
    pub total_wanted: i64,
    pub total_uploaded: i64,
    pub num_peers: i32,
    pub num_seeds: i32,
    pub num_pieces: i32,
    pub pieces_done: i32,
    pub is_paused: i32,
    pub is_finished: i32,
    pub has_metadata: i32,
    pub queue_position: i32,
}
#[repr(C)]
#[derive(Clone, Copy)]
pub struct lt_file_info {
    pub index: i32,
    pub name: [std::ffi::c_char; 512],
    pub path: [std::ffi::c_char; 1024],
    pub size: i64,
    pub is_streamable: i32,
}
#[repr(C)]
#[derive(Clone, Copy)]
pub struct lt_stream_status {
    pub id: i64,
    pub torrent_id: i64,
    pub file_index: i32,
    pub url: [std::ffi::c_char; 256],
    pub file_size: i64,
    pub read_head: i64,
    pub stream_state: i32,
    pub buffer_seconds: f32,
    pub buffer_pieces: i32,
    pub readahead_window: i32,
    pub active_peers: i32,
    pub download_rate: i32,
    pub active_deadlines: i32,
    pub target_buffer_seconds: f32,
    pub cached_verified_bytes: i64,
    pub newly_downloaded_bytes: i64,
    pub local_reread_bytes: i64,
    pub first_http_range_at_ms: i64,
    pub first_piece_requested_at_ms: i64,
    pub first_piece_completed_at_ms: i64,
    pub first_byte_sent_at_ms: i64,
    pub last_seek_response_ms: i32,
}
#[repr(C)]
#[derive(Clone, Copy)]
pub struct lt_bt_config {
    pub cache_size: i64,
    pub reader_read_ahead: i32,
    pub preload_cache: i32,
    pub connections_limit: i32,
    pub torrent_disconnect_timeout: i32,
    pub force_encrypt: i32,
    pub disable_tcp: i32,
    pub disable_utp: i32,
    pub disable_upload: i32,
    pub disable_dht: i32,
    pub disable_upnp: i32,
    pub enable_ipv6: i32,
    pub download_rate_limit: i32,
    pub upload_rate_limit: i32,
    pub peers_listen_port: i32,
    pub responsive_mode: i32,
}
