{
  username = "jaarriet";
  userHome = "/Users/jaarriet";
  gitName = "Javier Arrieta";
  gitEmail = "javier.arrieta@oracle.com";
  gitDefaultBranch = "master";
  githubUser = "javierarrieta";
  pythonVersion = "3.12";
  llmModelsDir = "/Users/jaarriet/llm/models";
  workspaces = {
    fashion_token = "/Users/jaarriet/code/fashion_token";
  };
  homeManagerConfigDir = "/Users/jaarriet/code/nixos-configurations";

  # No pi on this laptop. There is no darwin NAR for it in pi.cachix.org
  # (upstream pushes from a ubuntu-latest cron only), so the package
  # compiles here and needs registry.npmjs.org at build time -- this
  # network answers 403 for @anthropic-ai/sandbox-runtime, which takes the
  # whole home generation down with it. `pi.enable` is the opt-out in
  # modules/home-manager/dev-tools.nix; it drops the package, the vendored
  # skills and the ~/.pi/agent config together.
  pi = {
    enable = false;
  };
}
