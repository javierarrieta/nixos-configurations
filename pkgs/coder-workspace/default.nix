{ pkgs }:
pkgs.dockerTools.buildImage {
  name = "coder-workspace";
  tag = "pinned";
  copyToRoot = pkgs.buildEnv {
    name = "coder-workspace-root";
    paths = with pkgs; [
      bash
      bashInteractive
      coreutils
      git
      curl
      cacert
      gcc
      gnumake
      binutils
      findutils
      gnugrep
      gnused
      which
      tar
      gzip
      openssh
    ];
    pathsToLink = [
      "/bin"
      "/etc"
    ];
  };
  runAsRoot = ''
    ${pkgs.dockerTools.shadowSetup}
    groupadd --gid 1000 coder
    useradd --uid 1000 --gid 1000 --create-home --home-dir /home/coder --shell /bin/bash coder
    ln -sfn ${pkgs.bash}/bin/bash /bin/sh
    mkdir -p /tmp /run /etc
    cat > /etc/os-release <<'EOF'
    NAME="NixOS"
    ID=nixos
    ID_LIKE=""
    VERSION="25.11 (Xantusia)"
    VERSION_ID="25.11"
    PRETTY_NAME="NixOS 25.11 (Xantusia)"
    EOF
    chmod 1777 /tmp /run
    chmod 0755 /home/coder
    chown 1000:1000 /home/coder
  '';
  config = {
    User = "1000:1000";
    WorkingDir = "/home/coder";
    Env = [
      "PATH=/bin:/usr/bin"
      "HOME=/home/coder"
      "SSL_CERT_FILE=/etc/ssl/certs/ca-bundle.crt"
    ];
    Cmd = [ "/bin/sh" ];
  };
}
