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
}
