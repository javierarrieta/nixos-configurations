{
  username = "coder";
  userHome = "/home/coder";
  gitName = "Javier Arrieta";
  gitEmail = "javier@techdelivery.es";
  gitDefaultBranch = "main";
  githubUser = "javierarrieta";
  pythonVersion = "3.12";
  homeManagerConfigDir = "/home/coder/code/nixos-configurations";

  # HM manages dotfiles only; all software comes from the workspace image.
  configOnly = true;

  # pi: halogen inference endpoint as reachable from inside this workspace
  # container. `host.containers.internal` is the podman gateway on llm01,
  # where halogen-flash-server listens on :8731. Consumed by
  # modules/home-manager/dev-tools.nix (piModels).
  pi.baseUrl = "http://host.containers.internal:8731/v1";
}
