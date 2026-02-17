{ modulesPath, ... }:
{
  disko.devices = {
    disk = {
      disk0 = {
        device = "/dev/disk/by-id/CHANGE_ME";
        type = "disk";
        content = {
          type = "gpt";
          partitions = {
            boot = {
              size = "1G";
              type = "EF00";
              content = {
                type = "filesystem";
                format = "vfat";
                mountpoint = "/boot";
                mountOptions = [ "fmask=0077" "dmask=0077" ];
              };
            };
            luks-root = {
              size = "50G";
              content = {
                type = "luks";
                name = "disk0-root";
                extraOpenArgs = [ ];
                settings = {
                  allowDiscards = true;
                };
                content = {
                  type = "filesystem";
                  format = "ext4";
                  mountpoint = "/";
                };
              };
            };
            swap = {
              size = "8G";
              content = {
                type = "swap";
                resumeDevice = true;
              };
            };
            luks-llm = {
              size = "100%";
              content = {
                type = "luks";
                name = "disk0-llm";
                extraOpenArgs = [ ];
                settings = {
                  allowDiscards = true;
                };
                content = {
                  type = "filesystem";
                  format = "ext4";
                  mountpoint = "/opt/llm";
                };
              };
            };
          };
        };
      };
    };
  };
}
