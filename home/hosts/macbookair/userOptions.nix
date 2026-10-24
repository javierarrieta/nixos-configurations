{
  username = "javier";
  userHome = "/Users/javier";
  gitName = "Javier Arrieta";
  gitEmail = "javier@techdelivery.es";
  gitDefaultBranch = "main";
  githubUser = "javierarrieta";
  pythonVersion = "3.12";
  homeManagerConfigDir = "/Users/javier/code/nixos-configurations";

  # Adds `llm01-halogen-public`, a second route to the same halogen model through titan's public
  # front door, for when this laptop is off both the LAN and the WireGuard mesh. The LAN provider
  # stays the default -- see the `llm01-halogen` block in modules/home-manager/dev-tools.nix for why
  # the value is a keychain lookup and why the key is not in this file.
  #
  # Requires the keychain entry on THIS machine; it is not created by Nix and does not travel between
  # MacBooks:
  #   security add-generic-password -a javier -s llm-titan -U -w
  pi.publicApiKey = "!security find-generic-password -a javier -s llm-titan -w";
}
