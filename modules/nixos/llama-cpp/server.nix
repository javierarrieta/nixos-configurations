{ config, lib, ... }:
{
  options.services.llamaCppAgent.serverArgs = lib.mkOption {
    type = lib.types.listOf lib.types.str;
    default = [ ];
  };
}
