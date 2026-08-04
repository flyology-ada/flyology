use std::convert::Infallible;
use std::env;
use std::net::{IpAddr, Ipv4Addr, SocketAddr};

use bytes::Bytes;
use http_body_util::Full;
use hyper::body::Incoming;
use hyper::header::CONTENT_TYPE;
use hyper::server::conn::http1;
use hyper::service::service_fn;
use hyper::{Request, Response, StatusCode};
use hyper_util::rt::TokioIo;
use tokio::net::TcpListener;
use tokio::runtime::Builder;

const PLAINTEXT: &[u8] = b"Hello, World!";
const ONE_KIB: [u8; 1_024] = [b'x'; 1_024];

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

fn response(content_type: &'static str, body: &'static [u8]) -> Response<Full<Bytes>> {
    Response::builder()
        .header(CONTENT_TYPE, content_type)
        .body(Full::new(Bytes::from_static(body)))
        .expect("static response is valid")
}

async fn handle(request: Request<Incoming>) -> Result<Response<Full<Bytes>>, Infallible> {
    let result = match request.uri().path() {
        "/plaintext" => response("text/plain", PLAINTEXT),
        "/response-1k" => response("application/octet-stream", &ONE_KIB),
        _ => Response::builder()
            .status(StatusCode::NOT_FOUND)
            .header(CONTENT_TYPE, "text/plain")
            .body(Full::new(Bytes::from_static(b"not found")))
            .expect("static response is valid"),
    };
    Ok(result)
}

async fn serve(port: u16) -> Result<(), Box<dyn std::error::Error>> {
    let address = SocketAddr::new(IpAddr::V4(Ipv4Addr::LOCALHOST), port);
    let listener = TcpListener::bind(address).await?;
    println!("READY hyper http://127.0.0.1:{port}/plaintext");

    loop {
        let (stream, _) = listener.accept().await?;
        tokio::spawn(async move {
            let connection =
                http1::Builder::new().serve_connection(TokioIo::new(stream), service_fn(handle));
            if let Err(error) = connection.await {
                eprintln!("connection error: {error}");
            }
        });
    }
}

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let port = env::args()
        .nth(1)
        .map(|value| value.parse())
        .transpose()?
        .unwrap_or(18_094);
    Builder::new_multi_thread()
        .worker_threads(worker_count())
        .enable_all()
        .build()?
        .block_on(serve(port))
}
