use anyhow::Result;
use tf_provider::serve;

use terraform_provider_llm01::Llm01Provider;

#[tokio::main(flavor = "current_thread")]
async fn main() -> Result<()> {
    serve("llm01", Llm01Provider::default()).await
}
