use std::env;
use std::net::{IpAddr, Ipv4Addr, SocketAddr};

use axum::Router;
use axum::http::header::CONTENT_TYPE;
use axum::http::{HeaderValue, StatusCode};
use axum::routing::get;
use tokio::net::TcpListener;
use tokio::runtime::Builder;

fn worker_count() -> usize {
    env::var("HTTP_BENCH_RUST_WORKERS")
        .ok()
        .map(|value| {
            value
                .parse()
                .expect("HTTP_BENCH_RUST_WORKERS must be positive")
        })
        .unwrap_or_else(|| {
            std::thread::available_parallelism()
                .map(usize::from)
                .unwrap_or(1)
        })
}

async fn routed_get() -> ([(axum::http::HeaderName, HeaderValue); 1], &'static str) {
    (
        [(CONTENT_TYPE, HeaderValue::from_static("text/plain"))],
        "Hello, World!",
    )
}

async fn serve(port: u16) -> Result<(), Box<dyn std::error::Error>> {
    let app = Router::new()
        .route("/benchmark/route.html", get(routed_get))
        .fallback(|| async { (StatusCode::NOT_FOUND, "not found") });
    let address = SocketAddr::new(IpAddr::V4(Ipv4Addr::LOCALHOST), port);
    let listener = TcpListener::bind(address).await?;
    println!("READY axum http://127.0.0.1:{port}/benchmark/route.html");
    axum::serve(listener, app).await?;
    Ok(())
}

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let port = env::args()
        .nth(1)
        .map(|value| value.parse())
        .transpose()?
        .unwrap_or(18_095);
    Builder::new_multi_thread()
        .worker_threads(worker_count())
        .enable_all()
        .build()?
        .block_on(serve(port))
}
