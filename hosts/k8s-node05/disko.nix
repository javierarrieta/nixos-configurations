{ modulesPath, ... }:
{
  disko.devices = {
    disk = {
      disk0 = {
        device = "/dev/sda";
        type = "disk";
        content = {
          type = "gpt";
          partitions = {
            boot = {
              size = "512M";
              type = "EF00";
              content = {
                type = "filesystem";
                format = "vfat";
                mountpoint = "/boot";
                mountOptions = [
                  "fmask=0077"
                  "dmask=0077"
                ];
              };
            };
            root = {
              size = "120G";
              content = {
                type = "filesystem";
                format = "ext4";
                mountpoint = "/";
              };
            };
            longhorn = {
              size = "100G";
              content = {
                type = "filesystem";
                format = "ext4";
                mountpoint = "/var/lib/longhorn";
              };
            };
          };
        };
      };
    };
  };
}
