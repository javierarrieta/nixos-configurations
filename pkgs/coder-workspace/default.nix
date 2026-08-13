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
      gnutar
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
    # Runtime glibc wiring so unpatched binaries (VS Code Server's node and
    # code-server, extension native modules) can exec and resolve shared
    # libraries through standard FHS paths, equivalent to NixOS nix-ld.
    mkdir -p /lib /lib64 /usr/lib /usr/lib64 /usr/bin /sbin
    ln -sfn ${pkgs.glibc}/lib/ld-linux-x86-64.so.2 /lib64/ld-linux-x86-64.so.2
    ln -sfn ${pkgs.glibc}/lib/ld-linux-x86-64.so.2 /lib/ld-linux-x86-64.so.2
    for lib in libc.so.6 libm.so.6 libdl.so.2 libpthread.so.0 librt.so.1 libresolv.so.2 libnss_dns.so.2 libnss_files.so.2; do
      ln -sfn ${pkgs.glibc}/lib/\$lib /lib64/\$lib
      ln -sfn ${pkgs.glibc}/lib/\$lib /usr/lib/\$lib
      ln -sfn ${pkgs.glibc}/lib/\$lib /usr/lib64/\$lib
    done
    ln -sfn ${pkgs.stdenv.cc.cc.lib}/lib/libstdc++.so.6 /lib64/libstdc++.so.6
    ln -sfn ${pkgs.stdenv.cc.cc.lib}/lib/libstdc++.so.6 /usr/lib/libstdc++.so.6
    ln -sfn ${pkgs.stdenv.cc.cc.lib}/lib/libstdc++.so.6 /usr/lib64/libstdc++.so.6
    ln -sfn ${pkgs.libgcc}/lib/libgcc_s.so.1 /lib64/libgcc_s.so.1
    ln -sfn ${pkgs.libgcc}/lib/libgcc_s.so.1 /usr/lib/libgcc_s.so.1
    ln -sfn ${pkgs.libgcc}/lib/libgcc_s.so.1 /usr/lib64/libgcc_s.so.1
    ln -sfn ${pkgs.zlib}/lib/libz.so.1 /lib64/libz.so.1
    ln -sfn ${pkgs.zlib}/lib/libz.so.1 /usr/lib/libz.so.1
    ln -sfn ${pkgs.zlib}/lib/libz.so.1 /usr/lib64/libz.so.1
    # 'sh' shebang needs /usr/bin/env; VS Code CLI's GNU prereq probes need
    # ldd and /sbin/ldconfig.
    ln -sfn ${pkgs.coreutils}/bin/env /usr/bin/env
    ln -sfn ${pkgs.glibc.bin}/bin/ldconfig /sbin/ldconfig
    ln -sfn ${pkgs.glibc.bin}/bin/ldd /usr/bin/ldd
    # VS Code Server's CLI checks /etc/NIXOS (not os-release) to detect NixOS
    # and then selects the default glibc server build. Do NOT add a musl loader
    # at /lib: the CLI's musl probe would then pick the Alpine/musl server,
    # whose musl node cannot run against the glibc libraries wired above.
    touch /etc/NIXOS
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
