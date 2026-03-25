{ modulesPath, ... }:
{
  disko.devices = {
    disk = {
      disk0 = {
        device = "/dev/disk/by-id/ata-M.2_SSD_512GB_GSID24C0400225";
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
              size = "70G";
              content = {
                type = "luks";
                name = "disk0-root";
                extraOpenArgs = [ ];
                passwordFile = "/tmp/disko-password";
                settings = {
                  allowDiscards = true;
                  crypttabExtraOpts = [ "tpm2-device=auto" ];
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
              };
            };
            longhorn = {
              size = "280G";
              content = {
                type = "luks";
                name = "disk0-longhorn";
                extraOpenArgs = [ ];
                passwordFile = "/tmp/disko-password";
                settings = {
                  allowDiscards = true;
                  crypttabExtraOpts = [ "tpm2-device=auto" ];
                };
                content = {
                  type = "filesystem";
                  format = "ext4";
                  mountpoint = "/var/lib/longhorn";
                };
              };
            };
            containerd = {
              size = "100%";
              content = {
                type = "filesystem";
                format = "ext4";
                mountpoint = "/var/lib/containerd";
              };
            };
          };
        };
      };
    };
  };
}
