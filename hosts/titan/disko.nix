# titan disk layout (spec D13).
#
# mdraid-1 first, LVM on top. The RAID1 is what survives one dead NVMe; LVM on
# top of it is what makes the two halves resizeable later. Order matters: LVM
# inside md, never md inside LVM.
#
# The ESP stays a plain partition on nvme0n1 rather than a RAID1 mirror: systemd-boot
# on a mirrored ESP is a support burden for a boot path that rarely changes, and
# losing the ESP is recoverable from rescue mode in minutes.
#
# lv-pvc holds PersistentVolume data ONLY. etcd lives on lv-root with the rest of
# the system, and its snapshots go straight to S3 (spec §13b), so a pvc LV that
# also had to hold snapshots would need capacity sized against a second axis.
#
# ~29 G is left unallocated in vg0 on purpose: a full LV is an outage, and the
# headroom is what lets `lvextend` fix that without moving a partition.
{ ... }:
{
  disko.devices = {
    disk = {
      nvme0 = {
        type = "disk";
        device = "/dev/disk/by-path/pci-0000:02:00.0-nvme-1";
        content = {
          type = "gpt";
          partitions = {
            esp = {
              type = "EF00";
              size = "1G";
              content = {
                type = "filesystem";
                format = "vfat";
                mountpoint = "/boot";
              };
            };
            raid = {
              size = "100%";
              content = {
                type = "mdraid";
                name = "titan";
              };
            };
          };
        };
      };
      nvme1 = {
        type = "disk";
        device = "/dev/disk/by-path/pci-0000:03:00.0-nvme-1";
        content = {
          type = "gpt";
          partitions = {
            raid = {
              size = "100%";
              content = {
                type = "mdraid";
                name = "titan";
              };
            };
          };
        };
      };
    };
    mdadm = {
      titan = {
        type = "mdadm";
        level = 1;
        metadata = "1.2";
        # --homehost makes the array self-identify and stops mdadm_autoassemble
        # from importing a stale foreign array on a replacement disk.
        extraArgs = [
          "--homehost=titan"
        ];
        content = {
          type = "lvm_pv";
          vg = "vg0";
        };
      };
    };
    lvm_vg = {
      vg0 = {
        type = "lvm_vg";
        lvs = {
          root = {
            size = "150G";
            content = {
              type = "filesystem";
              format = "ext4";
              mountpoint = "/";
              mountOptions = [
                "defaults"
                "noatime"
              ];
            };
          };
          pvc = {
            size = "240G";
            content = {
              type = "filesystem";
              format = "ext4";
              mountpoint = "/var/lib/rancher/k3s/storage";
              mountOptions = [
                "defaults"
                "noatime"
              ];
            };
          };
        };
      };
    };
  };
}
