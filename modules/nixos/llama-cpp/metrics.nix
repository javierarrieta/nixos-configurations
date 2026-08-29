{ config, lib, ... }:
{
  config = {
    services.llama-cpp-metrics = {
      enable = true;
    };
  };
}
