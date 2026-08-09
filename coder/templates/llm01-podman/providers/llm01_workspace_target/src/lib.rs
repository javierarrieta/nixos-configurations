use std::borrow::Cow;
use std::collections::HashMap;
use std::fs;
use std::path::Path;
use std::sync::{Arc, RwLock};

use anyhow::{anyhow, Result};
use async_trait::async_trait;
use reqwest::Client as HttpClient;
use serde::{Deserialize, Serialize};

use tf_provider::schema::{Attribute, AttributeConstraint, AttributeType, Block, Description, Schema};
use tf_provider::value::{ValueBool, ValueEmpty, ValueNumber, ValueString};
use tf_provider::{map, AttributePath, Diagnostics, DynamicDataSource, DynamicResource, Provider, Resource};


/// Provider configuration.
#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct Llm01Config<'a> {
    #[serde(borrow)]
    pub endpoint: ValueString<'a>,
    #[serde(borrow)]
    pub cert_path: ValueString<'a>,
}

/// Resource state.
#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct WorkspaceTargetState<'a> {
    #[serde(borrow)]
    pub workspace: ValueString<'a>,
    pub size_gb: ValueNumber,
    pub active: ValueBool,
}

/// Private state carries the opaque per-workspace capability (sensitive).
#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct WorkspaceTargetPrivate<'a> {
    #[serde(borrow)]
    pub capability: ValueString<'a>,
}

/// Response envelope from the llm01 helper.
#[derive(Debug, Deserialize)]
pub struct HelperResponse {
    pub ok: bool,
    #[serde(default)]
    pub capability: Option<String>,
    #[serde(default)]
    pub error: Option<String>,
    #[serde(default)]
    pub device: Option<String>,
    #[serde(default)]
    pub mountpoint: Option<String>,
}

/// mTLS HTTP client for the llm01 helper API.
#[derive(Clone)]
pub struct HelperClient {
    endpoint: String,
    http: HttpClient,
}

impl HelperClient {
    pub fn new(endpoint: &str, cert_path: &str) -> Result<Self> {
        let ca_pem = fs::read(Path::new(cert_path).join("ca.pem"))?;
        let cert_pem = fs::read(Path::new(cert_path).join("cert.pem"))?;
        let key_pem = fs::read(Path::new(cert_path).join("key.pem"))?;

        let ca = reqwest::Certificate::from_pem(&ca_pem)?;
        let mut identity_pem = cert_pem;
        identity_pem.extend_from_slice(b"\n");
        identity_pem.extend_from_slice(&key_pem);
        let identity = reqwest::Identity::from_pem(&identity_pem)?;

        let http = HttpClient::builder()
            .add_root_certificate(ca)
            .identity(identity)
            .build()
            .map_err(|e| anyhow!(e))?;
        Ok(Self {
            endpoint: endpoint.trim_end_matches('/').to_string(),
            http,
        })
    }

    async fn call(
        &self,
        method: &str,
        path: &str,
        body: Option<serde_json::Value>,
        capability: Option<&str>,
    ) -> Result<HelperResponse> {
        let url = format!("{}/v1/{}", self.endpoint, path);
        let mut req = self.http.request(method.parse()?, &url);
        if let Some(cap) = capability {
            req = req.header("X-Coder-Capability", cap);
        }
        if let Some(body) = body {
            req = req.json(&body);
        }
        let resp = req.send().await?;
        let status = resp.status();
        let text = resp.text().await?;
        let parsed: HelperResponse = serde_json::from_str(&text)?;
        if status.is_success() && parsed.ok {
            Ok(parsed)
        } else {
            Err(anyhow!(
                "helper error {}: {}",
                status,
                parsed.error.unwrap_or_else(|| text.clone())
            ))
        }
    }

    pub async fn acquire(
        &self,
        workspace: &str,
        existing_capability: Option<&str>,
    ) -> Result<String> {
        let resp = self
            .call("POST", &format!("lease/{}/acquire", workspace), None, existing_capability)
            .await?;
        resp.capability.ok_or_else(|| anyhow!("helper returned no capability"))
    }

    pub async fn provision(&self, workspace: &str, capability: &str, size_gb: i64) -> Result<()> {
        self.call(
            "POST",
            &format!("workspaces/{}/provision", workspace),
            Some(serde_json::json!({ "size_gb": size_gb })),
            Some(capability),
        )
        .await?;
        Ok(())
    }

    pub async fn attach(&self, workspace: &str, capability: &str) -> Result<()> {
        self.call(
            "POST",
            &format!("workspaces/{}/attach", workspace),
            None,
            Some(capability),
        )
        .await?;
        Ok(())
    }

    pub async fn detach(&self, workspace: &str, capability: &str) -> Result<()> {
        self.call(
            "POST",
            &format!("workspaces/{}/detach", workspace),
            None,
            Some(capability),
        )
        .await?;
        Ok(())
    }

    pub async fn destroy(&self, workspace: &str, capability: &str) -> Result<()> {
        self.call(
            "DELETE",
            &format!("workspaces/{}", workspace),
            None,
            Some(capability),
        )
        .await?;
        Ok(())
    }

    pub async fn release(&self, workspace: &str, capability: &str) -> Result<()> {
        self.call(
            "POST",
            &format!("lease/{}/release", workspace),
            None,
            Some(capability),
        )
        .await?;
        Ok(())
    }
}

/// Shared state: the helper client is built at configure time and shared with
/// resource instances.
#[derive(Clone, Default)]
pub struct Shared {
    pub client: Arc<RwLock<Option<HelperClient>>>,
}

/// The provider.
#[derive(Clone, Default)]
pub struct Llm01Provider {
    pub shared: Shared,
}

#[async_trait]
impl Provider for Llm01Provider {
    type Config<'a> = Llm01Config<'a>;
    type MetaState<'a> = ValueEmpty;

    fn schema(&self, _diags: &mut Diagnostics) -> Option<Schema> {
        Some(Schema {
            version: 1,
            block: Block {
                version: 1,
                description: Description::plain("llm01 workspace target provider"),
                attributes: map! {
                  "endpoint" => Attribute {
                    attr_type: AttributeType::String,
                    description: Description::plain("llm01 helper base URL, e.g. https://llm01:2377"),
                    constraint: AttributeConstraint::Required,
                    ..Default::default()
                  },
                  "cert_path" => Attribute {
                    attr_type: AttributeType::String,
                    description: Description::plain("directory containing ca.pem, cert.pem, key.pem for mTLS"),
                    constraint: AttributeConstraint::Required,
                    ..Default::default()
                  },
                },
                ..Default::default()
            },
        })
    }

    async fn validate<'a>(
        &self,
        _diags: &mut Diagnostics,
        _config: Self::Config<'a>,
    ) -> Option<()> {
        Some(())
    }

    async fn configure<'a>(
        &self,
        _diags: &mut Diagnostics,
        _terraform_version: String,
        config: Self::Config<'a>,
    ) -> Option<()> {
        let endpoint = config.endpoint.as_str();
        let cert_path = config.cert_path.as_str();
        if endpoint.is_empty() || cert_path.is_empty() {
            _diags.root_error("missing provider config", "endpoint and cert_path are required");
            return None;
        }
        match HelperClient::new(endpoint, cert_path) {
            Ok(client) => {
                *self.shared.client.write().unwrap() = Some(client);
                Some(())
            }
            Err(err) => {
                _diags.root_error(
                    "failed to configure helper client",
                    format!("cannot build mTLS client: {:#}", err),
                );
                None
            }
        }
    }

    fn get_resources(
        &self,
        _diags: &mut Diagnostics,
    ) -> Option<HashMap<String, Box<dyn DynamicResource>>> {
        Some(map! {
            "workspace_target" => WorkspaceTargetResource { shared: self.shared.clone() },
        })
    }

    fn get_data_sources(
        &self,
        _diags: &mut Diagnostics,
    ) -> Option<HashMap<String, Box<dyn DynamicDataSource>>> {
        Some(HashMap::new())
    }
}

/// The `llm01_workspace_target` resource.
#[derive(Clone, Default)]
pub struct WorkspaceTargetResource {
    pub shared: Shared,
}

impl WorkspaceTargetResource {
    fn client(&self, diags: &mut Diagnostics) -> Option<HelperClient> {
        match self.shared.client.read().unwrap().clone() {
            Some(client) => Some(client),
            None => {
                diags.root_error_short("helper client is not configured");
                None
            }
        }
    }
}

#[async_trait]
impl Resource for WorkspaceTargetResource {
    type State<'a> = WorkspaceTargetState<'a>;
    type PrivateState<'a> = WorkspaceTargetPrivate<'a>;
    type ProviderMetaState<'a> = ValueEmpty;

    fn schema(&self, _diags: &mut Diagnostics) -> Option<Schema> {
        Some(Schema {
            version: 1,
            block: Block {
                version: 1,
                description: Description::plain("iSCSI-backed workspace target on llm01"),
                attributes: map! {
                  "workspace" => Attribute {
                    attr_type: AttributeType::String,
                    description: Description::plain("Coder workspace name"),
                    constraint: AttributeConstraint::Required,
                    ..Default::default()
                  },
                  "size_gb" => Attribute {
                    attr_type: AttributeType::Number,
                    description: Description::plain("volume size in GiB (10-200)"),
                    constraint: AttributeConstraint::Required,
                    ..Default::default()
                  },
                  "active" => Attribute {
                    attr_type: AttributeType::Bool,
                    description: Description::plain("whether the workspace is running"),
                    constraint: AttributeConstraint::Required,
                    ..Default::default()
                  },
                },
                ..Default::default()
            },
        })
    }

    async fn validate<'a>(
        &self,
        _diags: &mut Diagnostics,
        _config: Self::State<'a>,
    ) -> Option<()> {
        Some(())
    }

    async fn read<'a>(
        &self,
        _diags: &mut Diagnostics,
        state: Self::State<'a>,
        private_state: Self::PrivateState<'a>,
        _provider_meta_state: Self::ProviderMetaState<'a>,
    ) -> Option<(Self::State<'a>, Self::PrivateState<'a>)> {
        Some((state, private_state))
    }

    async fn plan_create<'a>(
        &self,
        _diags: &mut Diagnostics,
        proposed_state: Self::State<'a>,
        _config_state: Self::State<'a>,
        _provider_meta_state: Self::ProviderMetaState<'a>,
    ) -> Option<(Self::State<'a>, Self::PrivateState<'a>)> {
        Some((proposed_state, WorkspaceTargetPrivate::default()))
    }

    async fn plan_update<'a>(
        &self,
        _diags: &mut Diagnostics,
        prior_state: Self::State<'a>,
        proposed_state: Self::State<'a>,
        _config_state: Self::State<'a>,
        prior_private_state: Self::PrivateState<'a>,
        _provider_meta_state: Self::ProviderMetaState<'a>,
    ) -> Option<(
        Self::State<'a>,
        Self::PrivateState<'a>,
        Vec<AttributePath>,
    )> {
        // workspace and size_gb are immutable; a change forces replacement.
        let mut replace = Vec::new();
        if proposed_state.workspace != prior_state.workspace {
            replace.push(AttributePath::new("workspace"));
        }
        if proposed_state.size_gb != prior_state.size_gb {
            replace.push(AttributePath::new("size_gb"));
        }
        Some((proposed_state, prior_private_state, replace))
    }

    async fn plan_destroy<'a>(
        &self,
        _diags: &mut Diagnostics,
        _prior_state: Self::State<'a>,
        prior_private_state: Self::PrivateState<'a>,
        _provider_meta_state: Self::ProviderMetaState<'a>,
    ) -> Option<Self::PrivateState<'a>> {
        Some(prior_private_state)
    }

    async fn create<'a>(
        &self,
        diags: &mut Diagnostics,
        planned_state: Self::State<'a>,
        _config_state: Self::State<'a>,
        _planned_private_state: Self::PrivateState<'a>,
        _provider_meta_state: Self::ProviderMetaState<'a>,
    ) -> Option<(Self::State<'a>, Self::PrivateState<'a>)> {
        let client = match self.client(diags) {
            Some(client) => client,
            None => return None,
        };
        let workspace = planned_state.workspace.as_str().to_string();
        let size_gb = planned_state.size_gb.unwrap_or(10);
        let active = planned_state.active.unwrap_or(false);

        let capability = match client.acquire(&workspace, None).await {
            Ok(cap) => cap,
            Err(err) => {
                diags.root_error_short(format!("acquire failed: {}", err));
                return None;
            }
        };

        if active {
            if let Err(err) = client.provision(&workspace, &capability, size_gb).await {
                diags.root_error_short(format!("provision failed: {}", err));
                return None;
            }
            if let Err(err) = client.attach(&workspace, &capability).await {
                diags.root_error_short(format!("attach failed: {}", err));
                return None;
            }
        }

        Some((
            planned_state,
            WorkspaceTargetPrivate {
                capability: ValueString::Value(Cow::Owned(capability)),
            },
        ))
    }

    async fn update<'a>(
        &self,
        diags: &mut Diagnostics,
        _prior_state: Self::State<'a>,
        planned_state: Self::State<'a>,
        _config_state: Self::State<'a>,
        planned_private_state: Self::PrivateState<'a>,
        _provider_meta_state: Self::ProviderMetaState<'a>,
    ) -> Option<(Self::State<'a>, Self::PrivateState<'a>)> {
        let client = match self.client(diags) {
            Some(client) => client,
            None => return None,
        };
        let workspace = planned_state.workspace.as_str().to_string();
        let size_gb = planned_state.size_gb.unwrap_or(10);
        let active = planned_state.active.unwrap_or(false);
        let existing_cap = planned_private_state.capability.as_str().to_string();

        if active {
            // Reacquire idempotently (fresh if the lease was released), then
            // provision (reconciles existing objects) and attach.
            let capability = match client.acquire(&workspace, Some(&existing_cap)).await {
                Ok(cap) => cap,
                Err(err) => {
                    diags.root_error_short(format!("reacquire failed: {}", err));
                    return None;
                }
            };
            if let Err(err) = client.provision(&workspace, &capability, size_gb).await {
                diags.root_error_short(format!("provision failed: {}", err));
                return None;
            }
            if let Err(err) = client.attach(&workspace, &capability).await {
                diags.root_error_short(format!("attach failed: {}", err));
                return None;
            }
            Some((
                planned_state,
                WorkspaceTargetPrivate {
                    capability: ValueString::Value(Cow::Owned(capability)),
                },
            ))
        } else {
            // Stopping: detach and release the lease. Keep the capability in
            // state so a later start can reacquire idempotently.
            if let Err(err) = client.detach(&workspace, &existing_cap).await {
                diags.root_error_short(format!("detach failed: {}", err));
                return None;
            }
            if let Err(err) = client.release(&workspace, &existing_cap).await {
                diags.root_error_short(format!("release failed: {}", err));
                return None;
            }
            Some((planned_state, planned_private_state))
        }
    }

    async fn destroy<'a>(
        &self,
        diags: &mut Diagnostics,
        _prior_state: Self::State<'a>,
        planned_private_state: Self::PrivateState<'a>,
        _provider_meta_state: Self::ProviderMetaState<'a>,
    ) -> Option<()> {
        let client = match self.client(diags) {
            Some(client) => client,
            None => return None,
        };
        let workspace = _prior_state.workspace.as_str().to_string();
        let capability = planned_private_state.capability.as_str().to_string();
        if capability.is_empty() {
            diags.root_error_short("no capability in private state; cannot destroy target");
            return None;
        }
        if let Err(err) = client.destroy(&workspace, &capability).await {
            diags.root_error_short(format!("destroy failed: {}", err));
            return None;
        }
        Some(())
    }
}
