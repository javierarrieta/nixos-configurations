{
  config,
  lib,
  hostname,
  userOptions,
  ...
}:

{
  home.username = userOptions.username;
  home.homeDirectory = userOptions.userHome;
}
