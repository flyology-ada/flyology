use std::env;

use actix_web::{App, HttpResponse, HttpServer, web};

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

async fn routed_get() -> HttpResponse {
    HttpResponse::Ok()
        .content_type("text/plain")
        .body("Hello, World!")
}

#[actix_web::main]
async fn main() -> std::io::Result<()> {
    let port = env::args()
        .nth(1)
        .map(|value| {
            value
                .parse()
                .expect("port must be an unsigned 16-bit integer")
        })
        .unwrap_or(18_096);
    let workers = worker_count();
    let server =
        HttpServer::new(|| App::new().route("/benchmark/route.html", web::get().to(routed_get)))
            .workers(workers)
            .disable_signals()
            .bind(("127.0.0.1", port))?
            .run();
    println!("READY actix-web http://127.0.0.1:{port}/benchmark/route.html");
    server.await
}
