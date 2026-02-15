{ config, lib, hostname, ... }:

{
  _module.args.userOptions = {
    username = "javier";
    userHome = "/home/javier";
    gitName = "Javier Arrieta";
    gitEmail = "javier@techdelivery.es";
    gitDefaultBranch = "main";
    githubUser = "javierarrieta";
    pythonVersion = "3.13";
    homeManagerConfigDir = "/home/javier/code/home-manager-config";
  };

  home.username = "javier";
  home.homeDirectory = "/home/javier";
}
