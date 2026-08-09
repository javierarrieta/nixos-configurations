{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.coderHost;
  helperPackage = pkgs.callPackage ../../pkgs/coder-iscsi-helper { };

  isV6 = src: lib.hasInfix ":" src;
  v4Sources = lib.filter (s: !isV6 s) cfg.allowedApiSources;
  v6Sources = lib.filter isV6 cfg.allowedApiSources;

  apiPorts = [
    2376
    2377
  ];

  # Build iptables/ip6tables accept rules restricted to the provisioner
  # network. NixOS's allowedTCPPorts cannot express source restrictions, so
  # we append rules to the nixos-fw chain before the final drop.
  fwRulesFor =
    table: sources:
    lib.concatMapStringsSep "\n" (
      src:
      lib.concatMapStringsSep "\n" (
        port: "${table} -A nixos-fw -s ${src} -p tcp --dport ${toString port} -j nixos-fw-accept"
      ) apiPorts
    ) sources;
in
{
  imports = [ ../../modules/nixos/openiscsi.nix ];

  options.coderHost = {
    enable = lib.mkEnableOption "Coder container host (rootless Podman API + iSCSI helper)";
    podmanApiAddress = lib.mkOption {
      type = lib.types.str;
      default = "0.0.0.0:2376";
      description = "TLS Podman API listen address";
    };
    allowedApiSources = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "CIDRs allowed to reach the Podman (2376) and iSCSI helper (2377) APIs. Empty = closed.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.allowedApiSources != [ ];
        message = "coderHost.allowedApiSources must list the Coder provisioner network; the APIs must not be world-open.";
      }
    ];

    virtualisation.podman = {
      enable = true;
      dockerCompat = true;
      dockerSocket.enable = false;
    };

    openiscsi.enable = true;

    users.groups.coder.gid = 27003;
    users.users.coder = {
      isSystemUser = true;
      group = "coder";
      uid = 27003;
      home = "/home/coder";
      shell = pkgs.bash;
      linger = true;
      subUidRanges = [
        {
          startUid = 100000;
          count = 65536;
        }
      ];
      subGidRanges = [
        {
          startGid = 100000;
          count = 65536;
        }
      ];
    };

    # The podman-api system service runs as the coder user, so the TLS
    # credentials must be readable by that user.
    sops.secrets = {
      "coder/podman_server_cert" = {
        owner = "coder";
        group = "coder";
        mode = "0444";
        path = "/run/secrets/podman/server.crt";
      };
      "coder/podman_server_key" = {
        owner = "coder";
        group = "coder";
        mode = "0400";
        path = "/run/secrets/podman/server.key";
      };
      "coder/podman_client_ca" = {
        owner = "coder";
        group = "coder";
        mode = "0444";
        path = "/run/secrets/podman/client-ca.crt";
      };
      "coder/truenas_api_key" = {
        owner = "root";
        mode = "0400";
        path = "/run/secrets/coder/truenas-api-key";
      };
    };

    systemd.tmpfiles.rules = [
      "d /home/coder 0755 coder coder -"
      "d /home/coder/.config 0700 coder coder -"
      "d /home/coder/.config/containers 0700 coder coder -"
      "d /srv/coder 0755 root root -"
      "d /srv/coder/workspaces 0755 root root -"
    ];

    # A system service (not systemd.user.services, which would start for
    # every user's manager) scoped to the coder user. Linger keeps
    # /run/user/27003 alive so rootless podman has a runtime directory.
    systemd.services.podman-api = {
      description = "Rootless Podman Docker API";
      wantedBy = [ "multi-user.target" ];
      after = [
        "network-online.target"
        "user-runtime-dir@27003.service"
      ];
      wants = [ "network-online.target" ];
      path = [ "/run/wrappers" ];
      serviceConfig = {
        User = "coder";
        Group = "coder";
        Type = "simple";
        ExecStart = "${pkgs.podman}/bin/podman system service --time=0 --tls-cert=/run/secrets/podman/server.crt --tls-key=/run/secrets/podman/server.key --tls-client-ca=/run/secrets/podman/client-ca.crt tcp://${cfg.podmanApiAddress}";
        Restart = "on-failure";
        RestartSec = "5s";
        Environment = [ "XDG_RUNTIME_DIR=/run/user/27003" ];
      };
    };

    systemd.services.coder-iscsi-helper = {
      description = "Coder workspace iSCSI helper";
      wantedBy = [ "multi-user.target" ];
      after = [
        "network-online.target"
        "iscsid.service"
      ];
      wants = [ "network-online.target" ];
      # mount/umount are setuid wrappers; the rest live in the system path.
      # NixOS appends /bin to each entry, so use the parent directories.
      path = [
        "/run/wrappers"
        "/run/current-system/sw"
      ];
      serviceConfig = {
        ExecStart = "${helperPackage}/bin/coder-iscsi-helper";
        User = "root";
        Restart = "on-failure";
        Environment = [
          "CODER_HELPER_LISTEN=0.0.0.0:2377"
          "CODER_HELPER_TLS_CERT=/run/secrets/podman/server.crt"
          "CODER_HELPER_TLS_KEY=/run/secrets/podman/server.key"
          "CODER_HELPER_CLIENT_CA=/run/secrets/podman/client-ca.crt"
          "CODER_HELPER_TRUENAS_API_KEY_FILE=/run/secrets/coder/truenas-api-key"
          "CODER_HELPER_STATE_DIR=/var/lib/coder-iscsi-helper"
          "CODER_HELPER_WORKSPACE_BASE=/srv/coder/workspaces"
          "CODER_HELPER_DATASET_PARENT=tank/iscsi/k8s"
          "CODER_HELPER_IQN_BASENAME=iqn.2005-10.org.freenas.ctl"
          "CODER_HELPER_TARGET_PORTAL=192.168.0.6:3260"
          "CODER_HELPER_PODMAN_BIN=/run/current-system/sw/bin/podman"
        ];
      };
    };

    networking.firewall.extraCommands =
      (fwRulesFor "iptables" v4Sources)
      + lib.optionalString (v6Sources != [ ]) "\n${fwRulesFor "ip6tables" v6Sources}";
  };
}
