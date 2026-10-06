{
  username = "jaarriet";
  userHome = "/Users/jaarriet";
  gitName = "Javier Arrieta";
  gitEmail = "javier.arrieta@oracle.com";
  gitDefaultBranch = "master";
  githubUser = "javierarrieta";
  pythonVersion = "3.12";
  llmModelsDir = "/Users/jaarriet/llm/models";
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

  # No Nix JDK on this laptop. It is a work machine and Java comes from
  # SDKMAN under ~/.sdkman (the init block lives in
  # modules/home-manager/shell.nix), which selects a JDK by rewriting
  # JAVA_HOME and PATH. Home Manager re-exports its session variables into
  # every new shell, so `sdk use java ...` would lose to pkgs.jdk21 at the
  # next prompt. `jdk.enable` is the opt-out in
  # modules/home-manager/dev-tools.nix and drops the package and JAVA_HOME
  # together, leaving SDKMAN authoritative for both.
  jdk = {
    enable = false;
  };
}
