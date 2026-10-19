{
  username = "coder";
  userHome = "/home/coder";
  gitName = "Javier Arrieta";
  gitEmail = "javier@techdelivery.es";
  gitDefaultBranch = "main";
  githubUser = "javierarrieta";
  pythonVersion = "3.12";
  # Unlike the bare metal hosts, a workspace has no ~/code: the Coder agent lands
  # directly in /home/coder (agent `dir` in both templates), so every repo -- this
  # one included -- is cloned straight into $HOME. Read by
  # modules/home-manager/shell.nix for $CODE_DIR, which `hm-pull` and `hm-update`
  # use to locate this repo's checkout.
  codeDir = "/home/coder";
  homeManagerConfigDir = "/home/coder/nixos-configurations";

  # HM manages dotfiles only; all software comes from the workspace image.
  configOnly = true;

  # pi: halogen inference endpoint as reachable from inside this workspace
  # container. `host.containers.internal` is the podman gateway on llm01,
  # where halogen-flash-server listens on :8731. Consumed by
  # modules/home-manager/dev-tools.nix (piModels).
  #
  # This attribute is the llm01 podman workspace specifically, even though its
  # name is generic. Workspaces Coder provisions on titan are k8s pods, where
  # host.containers.internal does not resolve; they build
  # home/hosts/coder-workspace-titan instead.
  pi.baseUrl = "http://host.containers.internal:8731/v1";
}
