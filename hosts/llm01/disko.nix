{ modulesPath, ... }:
{
  disko.devices = {
    disk = {
      disk0 = {
        device = "/dev/disk/by-id/nvme-SanDisk_SSD_Plus_500GB_A3N_25504G800078";
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
                  crypttabExtraOpts = [ "tpm2-device=auto" ]; 
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
