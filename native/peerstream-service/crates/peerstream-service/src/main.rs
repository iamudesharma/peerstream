use anyhow::{bail, Context, Result};
use axum::{
    body::Body,
    extract::{DefaultBodyLimit, Request, State},
    http::{header, StatusCode},
    middleware::{self, Next},
    response::{
        sse::{Event, KeepAlive, Sse},
        IntoResponse, Response,
    },
    routing::{get, post},
    Json, Router,
};
use peerstream_service_core::{Worker, PROTOCOL};
use serde::Deserialize;
use serde_json::{json, Value};
use std::{
    convert::Infallible,
    io::{BufRead, Write},
    path::PathBuf,
    sync::{
        atomic::{AtomicBool, Ordering},
        Arc,
    },
    time::Duration,
};
use tokio::sync::{watch, Notify};
use tokio_stream::{wrappers::WatchStream, StreamExt};

#[derive(Clone)]
struct App {
    worker: Worker,
    token: Arc<String>,
    snapshots: watch::Receiver<Value>,
    stop: Arc<Notify>,
    stopping: Arc<AtomicBool>,
}
#[derive(Deserialize)]
struct Bootstrap {
    token: String,
}
#[derive(Deserialize)]
struct Command {
    op: String,
    #[serde(default)]
    args: Value,
}
async fn auth(State(app): State<App>, request: Request<Body>, next: Next) -> Response {
    let expected = format!("Bearer {}", app.token);
    if request.headers().contains_key(header::ORIGIN)
        || request
            .headers()
            .get(header::AUTHORIZATION)
            .and_then(|v| v.to_str().ok())
            != Some(&expected)
    {
        return StatusCode::UNAUTHORIZED.into_response();
    }
    next.run(request).await
}
async fn health(State(app): State<App>) -> Response {
    match app.worker.execute("health", json!({})).await {
        Ok(mut data) => {
            data["instance"] = json!(app.worker.instance.as_str());
            Json(data).into_response()
        }
        Err(_) => StatusCode::SERVICE_UNAVAILABLE.into_response(),
    }
}
async fn command(State(app): State<App>, Json(command): Json<Command>) -> Response {
    if command.op == "shutdown" {
        app.stopping.store(true, Ordering::Release);
        app.stop.notify_one();
        return Json(json!({"ok":true})).into_response();
    }
    match app.worker.execute(command.op, command.args).await {
        Ok(data) => {
            Json(json!({"instance":app.worker.instance.as_str(),"data":data})).into_response()
        }
        Err(error) => (
            StatusCode::UNPROCESSABLE_ENTITY,
            Json(json!({"error":error.to_string(),"code":if error.is::<peerstream_service_core::CacheMiss>() { "cache_miss" } else { "command_failed" }})),
        )
            .into_response(),
    }
}
async fn events(State(app): State<App>) -> impl IntoResponse {
    let stopping = app.stopping.clone();
    let stream = WatchStream::new(app.snapshots)
        .take_while(move |_| !stopping.load(Ordering::Acquire))
        .map(|value| {
            Ok::<_, Infallible>(Event::default().event("snapshot").data(value.to_string()))
        });
    Sse::new(stream).keep_alive(KeepAlive::new().interval(Duration::from_secs(15)))
}
#[tokio::main]
async fn main() -> Result<()> {
    tracing_subscriber::fmt()
        .with_writer(std::io::stderr)
        .init();
    let mut args = std::env::args().skip(1);
    let mut root = None;
    let mut native = None;
    while let Some(arg) = args.next() {
        match arg.as_str() {
            "--root" => root = args.next().map(PathBuf::from),
            "--native" => native = args.next().map(PathBuf::from),
            _ => bail!("unknown argument"),
        }
    }
    // Credentials travel through a private pipe, never argv or diagnostic logging.
    let line = std::io::stdin()
        .lock()
        .lines()
        .next()
        .context("missing bootstrap")??;
    if line.len() > 4096 {
        bail!("bootstrap too large");
    }
    let bootstrap: Bootstrap = serde_json::from_str(&line)?;
    if bootstrap.token.len() < 32 {
        bail!("invalid bootstrap token");
    }
    let worker = Worker::start(
        native.context("missing native library")?,
        root.context("missing isolated root")?,
    )
    .await?;
    let (tx, rx) = watch::channel(json!({"instance":worker.instance.as_str(),"sessions":[]}));
    let stop = Arc::new(Notify::new());
    let stopping = Arc::new(AtomicBool::new(false));
    let app = App {
        stopping: stopping.clone(),
        worker: worker.clone(),
        token: Arc::new(bootstrap.token),
        snapshots: rx,
        stop: stop.clone(),
    };
    let router = Router::new()
        .route("/v1/health", get(health))
        .route("/v1/command", post(command))
        .route("/v1/events", get(events))
        .layer(DefaultBodyLimit::max(10 * 1024 * 1024))
        .layer(middleware::from_fn_with_state(app.clone(), auth))
        .with_state(app);
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await?;
    println!(
        "{}",
        json!({"port":listener.local_addr()?.port(),"protocol":PROTOCOL,"instance":worker.instance.as_str()})
    );
    std::io::stdout().flush()?;
    let timer_worker = worker.clone();
    let timer = tokio::spawn(async move {
        let mut ticks = 0;
        loop {
            let snapshots = timer_worker.execute("snapshots", json!({})).await;
            let Ok(sessions) = snapshots else { break };
            let streaming = sessions.as_array().is_some_and(|rows| {
                rows.iter().any(|r| {
                    r.get("stream").is_some()
                        && r["stream"]["bufferedSecondsAhead"].as_f64().unwrap_or(0.0) < 10.0
                })
            });
            let elapsed = if streaming { 250 } else { 1000 };
            tx.send_replace(json!({"instance":timer_worker.instance.as_str(),"sessions":sessions}));
            ticks += elapsed;
            if ticks >= 60000 {
                let _ = timer_worker.execute("persist", json!({})).await;
                ticks = 0;
            }
            tokio::time::sleep(Duration::from_millis(elapsed)).await;
        }
    });
    let parent_watch = stop.clone();
    let parent_stopping = stopping.clone();
    // EOF means the owning UI has exited/crashed. No orphan process by default.
    std::thread::spawn(move || {
        let mut input = String::new();
        let _ = std::io::stdin().read_line(&mut input);
        parent_stopping.store(true, Ordering::Release);
        parent_watch.notify_one();
    });
    let shutdown = stop.clone();
    axum::serve(listener, router)
        .with_graceful_shutdown(async move {
            tokio::select! {_=tokio::signal::ctrl_c()=>{},_=shutdown.notified()=>{}}
            stopping.store(true, Ordering::Release);
        })
        .await?;
    timer.abort();
    let _ = worker.execute("shutdown", json!({})).await;
    Ok(())
}
