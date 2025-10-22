// SPDX-License-Identifier: GPL-3.0

use api::api::v1::{greeter_client::GreeterClient, HelloRequest};
use clap::Parser;

#[derive(Parser)]
#[command(version, about, long_about = None)]
struct Cli {
  // The port to listen on (defaults to 8080)
  #[arg(long, default_value_t = 8080)]
  port: u16,
  // The person to greet (optional)
  #[arg(long, required = false)]
  name: Option<String>,
}

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
  let args = Cli::parse();

  let mut client = GreeterClient::connect(format!("http://0.0.0.0:{}", args.port)).await?;
  let request = tonic::Request::new(HelloRequest {name: args.name.unwrap_or_default()});
  let response = client.say_hello(request).await?;

  println!("{}", response.into_inner().message);

  Ok(())
}
