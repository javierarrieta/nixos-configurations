{ config, lib, ... }:
{
  services.llama-cpp-metrics = {
    enable = true;
  };
}
