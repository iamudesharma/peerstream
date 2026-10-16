mod abi;
use abi::*;
use anyhow::{bail, Context, Result};
use libloading::Library;
use serde_json::{json, Value};
use std::{
    collections::HashMap,
    ffi::{c_char, c_void, CStr, CString},
    fs::{File, OpenOptions},
    os::fd::AsRawFd,
    path::{Path, PathBuf},
    sync::Arc,
};
use tokio::sync::{mpsc, oneshot};
use uuid::Uuid;

#[derive(Debug)]
pub struct CacheMiss;
impl std::fmt::Display for CacheMiss {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("No usable cached torrent metadata")
    }
}
impl std::error::Error for CacheMiss {}

pub const PROTOCOL: u32 = 1;
type SessionPtr = *mut c_void;
fn c(value: &str) -> Result<CString> {
    Ok(CString::new(value)?)
}
fn text(value: &[c_char]) -> String {
    let end = value.iter().position(|v| *v == 0).unwrap_or(value.len());
    String::from_utf8_lossy(&value[..end].iter().map(|v| *v as u8).collect::<Vec<_>>()).into_owned()
}
fn key(value: &str) -> Result<&str> {
    if !(32..=64).contains(&value.len())
        || !value
            .bytes()
            .all(|v| v.is_ascii_lowercase() || v.is_ascii_digit())
    {
        bail!("invalid cache identity");
    }
    Ok(value)
}
macro_rules! call {
    ($self:expr, $name:literal, $typ:ty $(, $arg:expr)*) => {{
        let function = $self.library.get::<$typ>(concat!($name, "\0").as_bytes())?;
        function($($arg),*)
    }};
}
fn disk_bytes(path: &Path) -> Result<u64> {
    use std::os::unix::fs::MetadataExt;
    if !path.exists() {
        return Ok(0);
    }
    let metadata = std::fs::symlink_metadata(path)?;
    if metadata.file_type().is_symlink() {
        return Ok(0);
    }
    if metadata.is_file() {
        return Ok(metadata.blocks() * 512);
    }
    let mut bytes = 0;
    for entry in std::fs::read_dir(path)? {
        bytes += disk_bytes(&entry?.path())?;
    }
    Ok(bytes)
}
unsafe extern "C" fn discard_alert(_: i32, _: i64, _: *const c_char, _: *mut c_void) {}

struct Entry {
    native: i64,
    stream: Option<i64>,
    cache_key: String,
    request: String,
    created: std::time::Instant,
    offline: bool,
}
struct Native {
    library: Library,
    session: SessionPtr,
    root: PathBuf,
    entries: HashMap<String, Entry>,
    requests: HashMap<String, (String, Value)>,
    _lock: File,
    budget: i64,
    persistence_failed: bool,
}
impl Native {
    /// All pointers and dynamically loaded functions remain on this owner thread.
    fn open(library: &Path, root: &Path) -> Result<Self> {
        std::fs::create_dir_all(root)?;
        let root = root.canonicalize()?;
        let lock = OpenOptions::new()
            .read(true)
            .write(true)
            .create(true)
            .truncate(false)
            .open(root.join("owner.lock"))?;
        // The OS releases this advisory lock on process death.
        if unsafe { libc::flock(lock.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) } != 0 {
            bail!("storage already owned");
        }
        std::fs::create_dir_all(root.join("payload"))?;
        let library = unsafe { Library::new(library) }?;
        let mut native = Self {
            library,
            session: std::ptr::null_mut(),
            root,
            entries: HashMap::new(),
            requests: HashMap::new(),
            _lock: lock,
            budget: 128 * 1024 * 1024,
            persistence_failed: false,
        };
        unsafe {
            let state = c(native
                .root
                .join("session.dat")
                .to_str()
                .context("root encoding")?)?;
            call!(
                native,
                "lt_set_session_state_path",
                unsafe extern "C" fn(*const c_char),
                state.as_ptr()
            );
            native.session = call!(
                native,
                "lt_create_session",
                unsafe extern "C" fn(*const c_char, i32, i32) -> SessionPtr,
                c("0.0.0.0")?.as_ptr(),
                0,
                0
            );
        }
        if native.session.is_null() {
            bail!("native initialization failed");
        }
        native.profile(false)?;
        Ok(native)
    }
    fn profile(&mut self, low: bool) -> Result<Value> {
        self.budget = if low { 64 } else { 128 } * 1024 * 1024;
        unsafe {
            let mut config: lt_bt_config = std::mem::zeroed();
            call!(
                self,
                "lt_get_default_config",
                unsafe extern "C" fn(*mut lt_bt_config),
                &mut config
            );
            config.cache_size = self.budget;
            config.reader_read_ahead = 85;
            config.preload_cache = 10;
            config.connections_limit = 32;
            config.torrent_disconnect_timeout = 120;
            config.responsive_mode = 1;
            call!(
                self,
                "lt_configure_session",
                unsafe extern "C" fn(SessionPtr, *const lt_bt_config),
                self.session,
                &config
            );
        }
        Ok(json!({"pieceCacheBudgetBytes":self.budget}))
    }
    fn entry(&self, request: &Value) -> Result<&Entry> {
        self.entries
            .get(request["session"].as_str().context("missing session")?)
            .context("unknown or expired session")
    }
    fn persist(&mut self) -> Result<Value> {
        let mut failed = false;
        unsafe {
            for entry in self.entries.values() {
                if call!(
                    self,
                    "lt_get_file_count",
                    unsafe extern "C" fn(SessionPtr, i64) -> i32,
                    self.session,
                    entry.native
                ) <= 0
                {
                    // Magnet metadata is not available yet; there is no resume
                    // record to save. DHT state is still persisted below.
                    continue;
                }
                let path = c(self
                    .root
                    .join("payload")
                    .join(&entry.cache_key)
                    .join("resume.dat")
                    .to_str()
                    .context("path encoding")?)?;
                let saved = call!(
                    self,
                    "lt_save_torrent_state",
                    unsafe extern "C" fn(SessionPtr, i64, *const c_char) -> i32,
                    self.session,
                    entry.native,
                    path.as_ptr()
                );
                failed |= saved != 1;
            }
            let path = c(self
                .root
                .join("session.dat")
                .to_str()
                .context("path encoding")?)?;
            let saved = call!(
                self,
                "lt_save_session_state",
                unsafe extern "C" fn(SessionPtr, *const c_char) -> i32,
                self.session,
                path.as_ptr()
            );
            failed |= saved != 1;
        }
        self.persistence_failed = failed;
        if failed {
            bail!("Resume state could not be saved. Check the storage drive.");
        }
        Ok(json!({}))
    }
    fn execute(&mut self, op: &str, request: Value) -> Result<Value> {
        unsafe {
            match op {
                "snapshots" => {
                    call!(
                        self,
                        "lt_poll_alerts",
                        unsafe extern "C" fn(
                            SessionPtr,
                            Option<unsafe extern "C" fn(i32, i64, *const c_char, *mut c_void)>,
                            *mut c_void,
                        ),
                        self.session,
                        Some(discard_alert),
                        std::ptr::null_mut()
                    );
                    let expired: Vec<_> = self
                        .entries
                        .iter()
                        .filter(|(_, e)| {
                            e.stream.is_none() && !e.offline && e.created.elapsed().as_secs() >= 30
                        })
                        .map(|(id, _)| id.clone())
                        .collect();
                    for id in expired {
                        self.execute("release", json!({"session":id}))?;
                    }
                    let rows: Vec<_> = self
                        .entries
                        .keys()
                        .map(|id| self.snapshot(&json!({"session":id})))
                        .collect::<Result<_>>()?;
                    Ok(json!(rows))
                }
                "health" => {
                    let mut footprint = 0_u64;
                    let mut resident = 0_u64;
                    call!(
                        self,
                        "lt_get_process_memory",
                        unsafe extern "C" fn(*mut u64, *mut u64) -> i32,
                        &mut footprint,
                        &mut resident
                    );
                    let version = call!(
                        self,
                        "lt_bridge_version",
                        unsafe extern "C" fn() -> *const c_char
                    );
                    Ok(
                        json!({"protocol":PROTOCOL,"capabilities":{"cachedMetadataResume":true},"bridgeVersion":CStr::from_ptr(version).to_string_lossy(),"sessions":self.entries.len(),"pieceCacheBudgetBytes":self.budget,"storageReady":self.root.is_dir(),"resumePersistenceFailed":self.persistence_failed,"physicalFootprintBytes":footprint,"residentBytes":resident,"experimental":true}),
                    )
                }
                "profile" => self.profile(request["lowMemory"].as_bool().unwrap_or(false)),
                "add" => {
                    let request_id = request["requestId"]
                        .as_str()
                        .context("missing request id")?
                        .to_owned();
                    let fingerprint = request.to_string();
                    if let Some((previous, response)) = self.requests.get(&request_id) {
                        if previous != &fingerprint {
                            bail!("request id reused with different input");
                        }
                        return Ok(response.clone());
                    }
                    if self.entries.len() >= 2 {
                        bail!("session limit reached");
                    }
                    let cache_key = key(request["cacheKey"]
                        .as_str()
                        .context("missing cache identity")?)?
                    .to_owned();
                    if self.entries.values().any(|v| v.cache_key == cache_key) {
                        bail!("torrent already owned by a session");
                    }
                    let save = self.root.join("payload").join(&cache_key);
                    std::fs::create_dir_all(&save)?;
                    let path = c(save.to_str().context("path encoding")?)?;
                    let resume = save.join("resume.dat");
                    let mut id = -1;
                    if resume.is_file() {
                        let state = c(resume.to_str().context("path encoding")?)?;
                        id = call!(
                            self,
                            "lt_add_torrent_with_state",
                            unsafe extern "C" fn(
                                SessionPtr,
                                *const c_char,
                                *const c_char,
                                i32,
                            ) -> i64,
                            self.session,
                            state.as_ptr(),
                            path.as_ptr(),
                            1
                        );
                    }
                    if id < 0 && request["resumeOnly"].as_bool().unwrap_or(false) {
                        let cached = save.join("source.torrent");
                        if cached.is_file() {
                            id = call!(
                                self,
                                "lt_add_torrent_file",
                                unsafe extern "C" fn(
                                    SessionPtr,
                                    *const c_char,
                                    *const c_char,
                                    i32,
                                ) -> i64,
                                self.session,
                                c(cached.to_str().context("path encoding")?)?.as_ptr(),
                                path.as_ptr(),
                                1
                            );
                        }
                        if id < 0 {
                            return Err(CacheMiss.into());
                        }
                    }
                    if id < 0 {
                        if let Some(magnet) = request["magnet"].as_str() {
                            if !magnet.starts_with("magnet:?") {
                                bail!("invalid magnet");
                            }
                            id = call!(
                                self,
                                "lt_add_magnet",
                                unsafe extern "C" fn(
                                    SessionPtr,
                                    *const c_char,
                                    *const c_char,
                                    i32,
                                ) -> i64,
                                self.session,
                                c(magnet)?.as_ptr(),
                                path.as_ptr(),
                                1
                            );
                        } else {
                            let bytes: Vec<u8> =
                                serde_json::from_value(request["torrent"].clone())?;
                            if bytes.len() > 2 * 1024 * 1024 {
                                bail!("torrent metadata too large");
                            }
                            let torrent_path = save.join("source.torrent");
                            std::fs::write(&torrent_path, bytes)?;
                            id = call!(
                                self,
                                "lt_add_torrent_file",
                                unsafe extern "C" fn(
                                    SessionPtr,
                                    *const c_char,
                                    *const c_char,
                                    i32,
                                ) -> i64,
                                self.session,
                                c(torrent_path.to_str().context("path encoding")?)?.as_ptr(),
                                path.as_ptr(),
                                1
                            );
                        }
                    }
                    if id < 0 {
                        bail!("native source rejected");
                    }
                    let token = Uuid::new_v4().to_string();
                    let response = json!({"session":token});
                    self.entries.insert(
                        token.clone(),
                        Entry {
                            native: id,
                            stream: None,
                            cache_key,
                            request: request_id.clone(),
                            created: std::time::Instant::now(),
                            offline: false,
                        },
                    );
                    self.requests
                        .insert(request_id, (fingerprint, response.clone()));
                    Ok(response)
                }
                "files" => {
                    let id = self.entry(&request)?.native;
                    let count = call!(
                        self,
                        "lt_get_file_count",
                        unsafe extern "C" fn(SessionPtr, i64) -> i32,
                        self.session,
                        id
                    );
                    if count <= 0 {
                        return Ok(json!([]));
                    }
                    if count > 10000 {
                        bail!("too many files");
                    }
                    let mut files: Vec<lt_file_info> = vec![std::mem::zeroed(); count as usize];
                    let result = call!(
                        self,
                        "lt_get_files",
                        unsafe extern "C" fn(SessionPtr, i64, *mut lt_file_info, i32) -> i32,
                        self.session,
                        id,
                        files.as_mut_ptr(),
                        count
                    );
                    if result < 0 {
                        bail!("metadata unavailable");
                    }
                    Ok(json!(files.iter().take(result as usize).map(|f| json!({"index":f.index,"name":text(&f.name),"relativePath":text(&f.path),"size":f.size,"isStreamable":f.is_streamable != 0})).collect::<Vec<_>>()))
                }
                "download" => {
                    let native = self.entry(&request)?.native;
                    let count = call!(
                        self,
                        "lt_get_file_count",
                        unsafe extern "C" fn(SessionPtr, i64) -> i32,
                        self.session,
                        native
                    );
                    let index = request["fileIndex"]
                        .as_i64()
                        .context("missing file index")?;
                    if count <= 0 || count > 10000 || index < 0 || index >= i64::from(count) {
                        bail!("invalid selected file");
                    }
                    let mut priorities = vec![0_i32; count as usize];
                    priorities[index as usize] = 1;
                    call!(
                        self,
                        "lt_set_file_priorities",
                        unsafe extern "C" fn(SessionPtr, i64, *const i32, i32),
                        self.session,
                        native,
                        priorities.as_ptr(),
                        count
                    );
                    self.entries
                        .get_mut(request["session"].as_str().unwrap())
                        .unwrap()
                        .offline = true;
                    Ok(json!({}))
                }
                "start" => {
                    let entry = self.entry(&request)?;
                    if entry.stream.is_some() {
                        bail!("session already streaming");
                    }
                    if self.entries.values().any(|v| v.stream.is_some()) {
                        bail!("foreground stream already active");
                    }
                    let id = call!(
                        self,
                        "lt_start_stream",
                        unsafe extern "C" fn(SessionPtr, i64, i32, i64) -> i64,
                        self.session,
                        entry.native,
                        request["fileIndex"]
                            .as_i64()
                            .context("missing file index")? as i32,
                        self.budget
                    );
                    if id < 0 {
                        bail!("stream creation failed");
                    }
                    self.entries
                        .get_mut(request["session"].as_str().unwrap())
                        .unwrap()
                        .stream = Some(id);
                    self.snapshot(&request)
                }
                "snapshot" => self.snapshot(&request),
                "complete" => {
                    let id = self.entry(&request)?.native;
                    let result = call!(
                        self,
                        "lt_is_file_complete",
                        unsafe extern "C" fn(SessionPtr, i64, i32) -> i32,
                        self.session,
                        id,
                        request["fileIndex"].as_i64().context("missing index")? as i32
                    );
                    Ok(json!(result == 1))
                }
                "position" | "duration" => {
                    let stream = self.entry(&request)?.stream.context("stream not started")?;
                    if op == "duration" {
                        call!(
                            self,
                            "lt_set_stream_duration",
                            unsafe extern "C" fn(SessionPtr, i64, i64) -> i32,
                            self.session,
                            stream,
                            request["durationMs"].as_i64().unwrap_or(0)
                        );
                    } else {
                        call!(
                            self,
                            "lt_set_stream_position",
                            unsafe extern "C" fn(SessionPtr, i64, i64, i64, i32) -> i32,
                            self.session,
                            stream,
                            request["byteOffset"].as_i64().unwrap_or(0).max(0),
                            request["windowBytes"].as_i64().unwrap_or(0).max(0),
                            i32::from(request["urgent"] == true)
                        );
                    }
                    Ok(json!({}))
                }
                "webSeed" => {
                    let id = self.entry(&request)?.native;
                    let url = request["url"].as_str().context("missing seed")?;
                    if !(url.starts_with("https://") || url.starts_with("http://")) {
                        bail!("invalid seed");
                    }
                    call!(
                        self,
                        "lt_add_web_seed",
                        unsafe extern "C" fn(SessionPtr, i64, *const c_char) -> i32,
                        self.session,
                        id,
                        c(url)?.as_ptr()
                    );
                    Ok(json!({}))
                }
                "release" => {
                    // Storage failure must never prevent stopping network and
                    // Range work. Keep the failed-save status in diagnostics.
                    let resume_saved = self.persist().is_ok();
                    let token = request["session"].as_str().context("missing session")?;
                    if let Some(entry) = self.entries.remove(token) {
                        if let Some(stream) = entry.stream {
                            call!(
                                self,
                                "lt_stop_stream",
                                unsafe extern "C" fn(SessionPtr, i64),
                                self.session,
                                stream
                            );
                        }
                        call!(
                            self,
                            "lt_remove_torrent",
                            unsafe extern "C" fn(SessionPtr, i64, i32),
                            self.session,
                            entry.native,
                            0
                        );
                        self.requests.remove(&entry.request);
                    }
                    Ok(json!({"resumeSaved":resume_saved}))
                }
                "persist" => self.persist(),
                "cacheUsage" => {
                    Ok(json!({"allocatedBytes":disk_bytes(&self.root.join("payload"))?}))
                }
                "cacheIndex" => self.read_index(),
                "cachePreferences" => {
                    let mut index = self.read_index()?;
                    for field in [
                        "maxCacheBytes",
                        "preferredAudioLanguage",
                        "preferredSubtitleLanguage",
                    ] {
                        if let Some(value) = request.get(field) {
                            index[field] = value.clone();
                        }
                    }
                    self.write_index(&index)?;
                    Ok(index)
                }
                "cacheRecord" => {
                    let identity =
                        key(request["cacheKey"].as_str().context("missing identity")?)?;
                    let entry = self
                        .entries
                        .values()
                        .find(|e| e.cache_key == identity)
                        .context("cache session not owned")?;
                    let native = entry.native;
                    let files=self.execute("files",json!({"session":self.entries.iter().find(|(_,e)| e.native==native).unwrap().0}))?;
                    let file_index = request["file"]["index"]
                        .as_i64()
                        .context("file index missing")?;
                    let file = files
                        .as_array()
                        .unwrap()
                        .iter()
                        .find(|f| f["index"] == file_index)
                        .context("unknown file")?;
                    let relative =
                        Path::new(file["relativePath"].as_str().context("file path missing")?);
                    if relative.is_absolute()
                        || relative
                            .components()
                            .any(|p| !matches!(p, std::path::Component::Normal(_)))
                    {
                        bail!("invalid native file path");
                    }
                    let verified = call!(
                        self,
                        "lt_is_file_complete",
                        unsafe extern "C" fn(SessionPtr, i64, i32) -> i32,
                        self.session,
                        native,
                        file_index as i32
                    ) == 1;
                    let mut record = request.clone();
                    record.as_object_mut().unwrap().remove("instance");
                    record["filePath"] =
                        json!(self.root.join("payload").join(identity).join(relative));
                    record["complete"] = json!(verified);
                    if verified {
                        record["byteSize"] = file["size"].clone();
                    }
                    let mut index = self.read_index()?;
                    let rows = index["entries"].as_array_mut().context("invalid index")?;
                    if let Some(old) = rows.iter().find(|r| r["cacheKey"] == identity) {
                        record["pinned"] = old["pinned"].clone();
                        if old["file"] == record["file"] {
                            record["timeBytePoints"] = old["timeBytePoints"].clone();
                        }
                    }
                    rows.retain(|r| r["cacheKey"] != identity);
                    rows.push(record);
                    self.write_index(&index)?;
                    Ok(json!({}))
                }
                "cachePin" => {
                    let identity =
                        key(request["cacheKey"].as_str().context("missing identity")?)?;
                    let mut index = self.read_index()?;
                    let row = index["entries"]
                        .as_array_mut()
                        .context("invalid index")?
                        .iter_mut()
                        .find(|r| r["cacheKey"] == identity)
                        .context("entry unavailable")?;
                    row["pinned"] = json!(request["pinned"] == true);
                    self.write_index(&index)?;
                    Ok(json!({}))
                }
                "cacheObserve" => {
                    let identity =
                        key(request["cacheKey"].as_str().context("missing identity")?)?;
                    let points = request["points"].as_array().context("missing points")?;
                    if points.len() > 64 {
                        bail!("too many observations");
                    }
                    let mut index = self.read_index()?;
                    if let Some(row) = index["entries"]
                        .as_array_mut()
                        .context("invalid index")?
                        .iter_mut()
                        .find(|r| r["cacheKey"] == identity)
                    {
                        row["timeBytePoints"] = json!(points);
                    }
                    self.write_index(&index)?;
                    Ok(json!({}))
                }
                "cachePrune" => {
                    let mut index = self.read_index()?;
                    let limit = index["maxCacheBytes"].as_u64().context("invalid budget")?;
                    let rows = index["entries"].as_array_mut().context("invalid index")?;
                    rows.sort_by_key(|r| r["lastUsedAt"].as_i64().unwrap_or(0));
                    let mut total = disk_bytes(&self.root.join("payload"))?;
                    let mut removed = vec![];
                    for row in rows.iter() {
                        if total <= limit {
                            break;
                        }
                        let Some(identity) = row["cacheKey"].as_str() else {
                            continue;
                        };
                        if row["pinned"] == true
                            || row["cacheKey"] == request["protectedKey"]
                            || self.entries.values().any(|e| e.cache_key == identity)
                        {
                            continue;
                        }
                        let path = self.root.join("payload").join(key(identity)?);
                        let size = disk_bytes(&path)?;
                        if path.exists() {
                            std::fs::remove_dir_all(path)?;
                        }
                        total = total.saturating_sub(size);
                        removed.push(identity.to_owned());
                    }
                    rows.retain(|r| !removed.iter().any(|id| r["cacheKey"] == *id));
                    self.write_index(&index)?;
                    Ok(json!({"allocatedBytes":total,"overBudget":total>limit}))
                }
                "cacheList" => {
                    let mut list = vec![];
                    for item in std::fs::read_dir(self.root.join("payload"))? {
                        let item = item?;
                        if item.file_type()?.is_dir() {
                            list.push(json!({"cacheKey":item.file_name().to_string_lossy(),"active":self.entries.values().any(|e| e.cache_key == item.file_name().to_string_lossy())}));
                        }
                    }
                    Ok(json!(list))
                }
                "cacheRemove" | "cacheClear" => {
                    if !self.entries.is_empty() {
                        bail!("release sessions before cache maintenance");
                    }
                    let root = self.root.join("payload");
                    if op == "cacheClear" {
                        std::fs::remove_dir_all(&root)?;
                        std::fs::create_dir_all(&root)?;
                    } else {
                        let path = root.join(key(request["cacheKey"]
                            .as_str()
                            .context("missing identity")?)?);
                        if path.exists() {
                            std::fs::remove_dir_all(path)?;
                        }
                    }
                    let mut index = self.read_index()?;
                    let rows = index["entries"].as_array_mut().context("invalid index")?;
                    if op == "cacheClear" {
                        rows.clear();
                    } else {
                        rows.retain(|r| r["cacheKey"] != request["cacheKey"]);
                    }
                    self.write_index(&index)?;
                    Ok(json!({}))
                }
                _ => bail!("unsupported command"),
            }
        }
    }
    fn read_index(&self) -> Result<Value> {
        let path = self.root.join("peerstream-playback-cache.json");
        if path.exists() {
            Ok(serde_json::from_slice(&std::fs::read(path)?)?)
        } else {
            Ok(json!({"version":1,"maxCacheBytes":5368709120_u64,"entries":[]}))
        }
    }
    fn write_index(&self, value: &Value) -> Result<()> {
        let path = self.root.join("peerstream-playback-cache.json");
        let temp = self.root.join("peerstream-playback-cache.json.tmp");
        let mut file = File::create(&temp)?;
        std::io::Write::write_all(&mut file, &serde_json::to_vec(value)?)?;
        file.sync_all()?;
        std::fs::rename(temp, path)?;
        Ok(())
    }
    fn snapshot(&self, request: &Value) -> Result<Value> {
        let entry = self.entry(request)?;
        unsafe {
            let mut status: lt_torrent_status = std::mem::zeroed();
            if call!(
                self,
                "lt_get_status",
                unsafe extern "C" fn(SessionPtr, i64, *mut lt_torrent_status) -> i32,
                self.session,
                entry.native,
                &mut status
            ) == 0
            {
                bail!("session unavailable");
            }
            if !self.root.is_dir() {
                return Ok(
                    json!({"session":request["session"],"error":true,"message":"Storage drive disconnected. Reconnect it and retry."}),
                );
            }
            if status.state == -2 || !text(&status.error_msg).is_empty() {
                return Ok(
                    json!({"session":request["session"],"error":true,"message":"The source stopped delivering video. Retry or choose another source."}),
                );
            }
            let mut result = json!({"session":request["session"],"name":text(&status.name),"progress":status.progress,"downloadRate":status.download_rate,"uploadRate":status.upload_rate,"downloadedBytes":status.total_done,"totalBytes":status.total_wanted,"peers":status.num_peers,"seeds":status.num_seeds,"phase":if status.has_metadata==0 {"metadata"} else {"downloading"}});
            if let Some(stream) = entry.stream {
                let mut s: lt_stream_status = std::mem::zeroed();
                if call!(
                    self,
                    "lt_get_stream_status",
                    unsafe extern "C" fn(SessionPtr, i64, *mut lt_stream_status) -> i32,
                    self.session,
                    stream,
                    &mut s
                ) != 0
                {
                    let complete = call!(
                        self,
                        "lt_is_file_complete",
                        unsafe extern "C" fn(SessionPtr, i64, i32) -> i32,
                        self.session,
                        entry.native,
                        s.file_index
                    ) == 1;
                    result["stream"] = json!({"isComplete":complete,"url":text(&s.url),"fileIndex":s.file_index,"fileSizeBytes":s.file_size,"readHeadBytes":s.read_head,"bufferedSecondsAhead":s.buffer_seconds,"bufferedPiecesAhead":s.buffer_pieces,"activeDeadlines":s.active_deadlines,"targetBufferSeconds":s.target_buffer_seconds,"cachedVerifiedBytes":s.cached_verified_bytes,"newlyDownloadedBytes":s.newly_downloaded_bytes,"localRereadBytes":s.local_reread_bytes,"firstRangeMs":s.first_http_range_at_ms,"firstPieceRequestedMs":s.first_piece_requested_at_ms,"firstPieceCompletedMs":s.first_piece_completed_at_ms,"firstByteMs":s.first_byte_sent_at_ms,"lastSeekResponseMs":s.last_seek_response_ms});
                }
            }
            Ok(result)
        }
    }
}
impl Drop for Native {
    fn drop(&mut self) {
        let _ = self.persist();
        unsafe {
            if let Ok(destroy) = self
                .library
                .get::<unsafe extern "C" fn(SessionPtr)>(b"lt_destroy_session\0")
            {
                if !self.session.is_null() {
                    destroy(self.session);
                }
            }
        }
    }
}
struct Work {
    op: String,
    request: Value,
    response: oneshot::Sender<Result<Value>>,
}
#[derive(Clone)]
pub struct Worker {
    tx: mpsc::Sender<Work>,
    pub instance: Arc<String>,
}
impl Worker {
    pub async fn start(library: PathBuf, root: PathBuf) -> Result<Self> {
        let (tx, mut rx) = mpsc::channel::<Work>(32);
        let (ready, receive) = oneshot::channel();
        std::thread::Builder::new()
            .name("peerstream-native".into())
            .spawn(move || {
                let mut native = match Native::open(&library, &root) {
                    Ok(native) => {
                        let _ = ready.send(Ok(()));
                        native
                    }
                    Err(error) => {
                        let _ = ready.send(Err(error));
                        return;
                    }
                };
                while let Some(work) = rx.blocking_recv() {
                    if work.op == "shutdown" {
                        let result = native.persist();
                        drop(native);
                        let _ = work.response.send(result);
                        return;
                    }
                    let _ = work.response.send(native.execute(&work.op, work.request));
                }
            })?;
        receive.await??;
        Ok(Self {
            tx,
            instance: Arc::new(Uuid::new_v4().to_string()),
        })
    }
    pub async fn execute(&self, op: impl Into<String>, mut request: Value) -> Result<Value> {
        if let Some(instance) = request.get("instance") {
            if instance != self.instance.as_str() {
                bail!("service instance changed");
            }
        }
        if request.is_null() {
            request = json!({});
        }
        let (response, receive) = oneshot::channel();
        self.tx
            .send(Work {
                op: op.into(),
                request,
                response,
            })
            .await
            .context("service stopped")?;
        receive.await.context("native worker stopped")?
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn identities_reject_traversal() {
        assert!(key("../../outside").is_err());
        assert!(key(&"a".repeat(40)).is_ok());
        assert!(key(&"A".repeat(40)).is_err());
    }
    #[test]
    fn bounded_c_strings() {
        assert_eq!(text(&[65, 0, 66]), "A");
        assert_eq!(text(&[65, 66]), "AB");
    }
    #[test]
    fn abi_alignment() {
        assert_eq!(std::mem::size_of::<lt_file_info>(), 1560);
        assert_eq!(std::mem::size_of::<lt_bt_config>(), 72);
    }
}
