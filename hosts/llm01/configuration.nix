{
  config,
  lib,
  pkgs,
  unstablePkgs,
  nix-sweep,
  home-manager,
  halogen-flash,
  ...
}:
{
  imports = [
    # Hardware
    ./disko.nix
    ./hardware-configuration.nix

    # Modules
    ../../modules/nixos/base.nix
    ../../modules/nixos/system-packages.nix
    ../../modules/nixos/ssh.nix
    ../../modules/nixos/prometheus.nix
    ../../modules/nixos/rsyslog.nix
    ../../modules/nixos/sops-base.nix
    ../../modules/nixos/nix-sweep.nix
    ../../modules/nixos/comin.nix
    ../../modules/nixos/comin-health-gate.nix
    ../../modules/nixos/coder-host.nix
    ../../modules/nixos/openiscsi.nix
    halogen-flash.nixosModules.default

    # Users
    ../../common/users.nix
  ];

  # Module enablement
  base.enable = true;
  systemPackages.enable = true;
  ssh.enable = true;
  prometheus.nodeExporter.enable = true;
  prometheus.nodeExporter.collectors = [
    "drm"
    "textfile"
  ];
  # The NixOS node_exporter does not read a textfile dir unless told to, and
  # `collectors` above replaces the module default rather than extending it.
  # The halogen weights sync publishes desired/live/state there; a fetch that
  # fails hours after its deploy reported success is otherwise invisible.
  # Same pattern as modules/nixos/k3s-snapshot-monitor.nix.
  services.prometheus.exporters.node.extraFlags = [
    "--collector.textfile.directory=/var/lib/node-exporter/textfiles"
  ];
  rsyslog.enable = true;
  sopsBase.enable = true;
  nixSweep.enable = true;
  cominGitOps.enable = true;
  cominGitOps.pollInterval = 900;
  cominGitOps.confirmerMode = "auto";
  cominGitOps.healthGate.enable = true;
  cominGitOps.healthGate.checks = [
    "current-system"
    "halogen-flash"
  ];
  # The service answers /health only once the checkpoint is resident, and a
  # weight load takes minutes, so the gate waits rather than calling a healthy
  # start failed. This used to also have to outlast the fetch: a
  # download.revision change blocked ExecStartPre on a ~112 GiB download for
  # hours. Since halogen-flash 21a686c the fetch runs in a background unit and
  # the deploy returns immediately, so that reason no longer applies and this
  # window covers the weight LOAD only. 4h is kept deliberately -- see
  # docs/superpowers/specs/2026-10-15-zero-downtime-weights-bump-design.md §11 --
  # so it is now generous rather than tight, and retuning it is its own decision.
  cominGitOps.healthGate.halogenWarmupSec = 14400; # 4h
  coderHost.enable = true;
  # The built-in Coder provisioner runs in k3s and reaches llm01's Podman/helper
  # APIs from the LAN; restrict to the cluster network only.
  coderHost.allowedApiSources = [ "192.168.0.0/24" ];

  # SOPS host-specific secrets (base secrets are provided by sops-base module)
  #
  # Five `wireguard/*` secrets used to be declared here and materialised on every
  # deploy. Nothing ever read them: llm01 has no `networking.wireguard` interface, no
  # /etc/wireguard, and no wireguard unit -- confirmed on the host. They were the tail
  # of an older design that bridged llm01 to the VPS hub; llm01 lives inside the home
  # LAN (192.168.0.29) and is not a member of the new 192.168.133.0/24 mesh either.
  # The values themselves were deleted from secrets.yaml on 2026-10-05 (recipients
  # unchanged, 4 before and after), so nothing is left to materialise or leak.
  #
  # One loose end, and it is not in this repo: the public key in that block is the same
  # string the operator companion doc records as the old hub's own wg0 identity on the
  # VPS. Either the block was a copy of the hub's identity rather than an llm01 keypair,
  # or the doc mislabels it. If it was the hub's, the key is still live in
  # /etc/wireguard there and the real fix is rotation -- deleting it from a sops file
  # revokes nothing. The old hub also still carries the dead `192.168.2.4` peer entry.
  sops.secrets."ssh_keys/llm01_host_private" = {
    mode = "0600";
    owner = "root";
    path = "/etc/ssh/ssh_host_ed25519_key";
  };
  sops.secrets."ssh_keys/llm01_host_public" = {
    mode = "0644";
    owner = "root";
    path = "/etc/ssh/ssh_host_ed25519_key.pub";
  };

  # Disk configuration
  disko.enableConfig = true;

  # Boot (boot loader and initrd come from base module)
  security.tpm2.enable = true; # Enables TPM2 userspace tools

  # Hardware
  hardware.graphics.enable = true;
  hardware.enableRedistributableFirmware = true;
  boot.initrd.kernelModules = [
    "amdgpu"
    "nfs"
    "nfs4"
  ];

  # Kernel configuration
  boot.kernelPackages = pkgs.linuxPackages_latest;
  # GPU memory params per upstream's measured configuration
  # (halogen-flash-server README, "the host settings these numbers were
  # measured on"): gttsize/pages_limit scale to installed RAM — llm01 has
  # ~126 GiB usable, so the 128 GB row applies (124 GiB = 99.3% of RAM; the
  # values are ceilings, not reservations). amd_iommu=off is upstream's one
  # measured lever: 13-16% of prefill vs amd_iommu=pt, at the cost of DMA
  # translation machine-wide and the NPU. vm_update_mode/noretry/
  # sg_display are deliberately NOT set (upstream: "leave them off").
  # cwsr_enable=0 is our own addition: ROCm#5724 GPU-hang workaround.
  boot.kernelParams = [
    "amdgpu.gttsize=126976"
    "ttm.pages_limit=32505856"
    "amd_iommu=off"
    "amdgpu.cwsr_enable=0"
  ];
  # Modprobe copies of the same values (module-load time; kernel params
  # above win when both apply) — kept in sync to avoid divergent GTT sizing
  # depending on load order.
  boot.extraModprobeConfig = ''
    options amdgpu gttsize=126976
    options ttm pages_limit=32505856
  '';

  # Network
  networking.networkmanager.enable = true;
  networking.hostName = "llm01";

  # System packages (common set comes from system-packages module)
  systemPackages.extraPackages =
    (with pkgs; [
      zsh
      wireguard-tools
      dig
      hdparm
      nix-tree
      nix-index
      python3Packages.huggingface-hub
      qemu
    ])
    ++ (with unstablePkgs; [
      rocmPackages.rocm-smi
      rocmPackages.clr
    ]);

  home-manager.users.javier.imports = [
    ../../modules/home-manager/llm.nix
  ];

  # System users for LLM services
  users.users = {
    ollama = {
      isSystemUser = true;
      group = "ollama";
      uid = 27002;
      extraGroups = [
        "render"
        "video"
      ];
    };
  };

  users.groups = {
    ollama = {
      gid = 27002;
    };
  };

  # Services
  services = {
    # SSH comes entirely from the ssh module (PermitRootLogin = "no")
    # Node exporter enable/collectors come from the prometheus module
    prometheus.exporters.node.openFirewall = true;
  };

  # Logs are forwarded to Loki via rsyslog; keep the local journal small.
  # Same value base.nix already ships, stated explicitly because the intent (Loki
  # holds the history, the journal is a ring buffer) is the point. An option, not
  # an extraConfig append: two SystemMaxUse lines in one file work only because
  # journald keeps the last one.
  base.journald.systemMaxUse = "500M";

  # halogen-flash-server (Strix Halo, Qwen3.8-Flash-Next, ROCm) is the
  # serving stack on this host. It owns the iGPU's ~112-120 GiB GTT pool, so
  # nothing else configured here may claim it.
  #
  # The llama.cpp stack that used to sit here is gone (2026-09-30): the
  # service was already disabled and halogen-flash replaced it. Note that
  # `llamaPkgs.vulkan` was also in systemPackages.extraPackages, so the
  # package stayed in the system closure even with the service off -- that is
  # why removal, not just leaving it disabled, was the point.
  services.halogenFlash = {
    enable = true;
    # Rootless podman: the container runs as ollama. The uid pin below is NOT
    # cosmetic and must not be deleted -- the flake module derives the unit's
    # XDG_RUNTIME_DIR and a tmpfiles rule from `users.users.ollama.uid`, so a
    # null uid yields `XDG_RUNTIME_DIR=/run/user/` (root's dir; podman cannot
    # use it) and, worse, `d /run/user/ 0700 ollama`, which would chown and
    # chmod /run/user itself and break every other user's runtime dir. Both
    # confirmed by eval, not theory.
    #
    # The declared 27002 is also not what /etc/passwd has: ollama is uid 993
    # gid 990 here, because NixOS does not retune the uid of an existing user
    # and the pin was added after ollama already existed. Nothing depends on the
    # two agreeing -- the unit and its tmpfiles dir both use the declared value,
    # so they stay self-consistent -- but it does mean podman's
    # `loginctl enable-linger 993` warning is noise about a runtime dir the
    # service never uses. Do not chase 993; do not resolve the mismatch by
    # dropping the pin.
    user = "ollama";
    podmanHome = "/opt/llm/halogen"; # ollama's podman storage + unit $HOME (image layers live here)
    mode = "all";
    modelsDir = "/opt/llm/models/halogen"; # ~130 GiB of headroom needed
    download.enable = true;
    # No `download.revision` here on purpose: it comes from the flake's
    # `defaultWeightsRevision`, so the image and the model version it is
    # known-good with live together and move together in one reviewed PR.
    # Overriding it here would split that pair across two repos again.
    # Pull the pinned image at service start, as `user` — rootless podman
    # stores images per-user, so a root `podman pull` would be invisible to
    # this unit. Safe to leave on because the module pins `image` by digest:
    # if the registry is unreachable but that exact digest is already local
    # the unit still succeeds, so an outage does not take the server down.
    # A digest that is neither pullable nor present fails the unit, and the
    # role units Require it — loud, and caught by the comin health gate.
    pull.enable = true;
    # Vision sidecar: the flake module (bumped to 8206b5c) now passes
    # HALOGEN_VISION_TOWER=1, the upstream shorthand for "find the sidecar
    # beside the checkpoint inside the /models mount". The pre-bump module
    # passed a host absolute path that does not exist inside the container.
    enableVision = true;
    # KV sizing: how many conversations stay resident, not how fast they run.
    # Read from the live server on 2026-10-20 (/health, /cache, /metrics):
    # nothing queued (queue_waited_total 0, requests_deferred 0) but the pool
    # sat at 393728/524288 positions with 3 conversations held and 64 cache
    # entries evicted. The pool default is 2 x HALOGEN_CTX, so at the native
    # 262144 context two full-length conversations fill it and slots 3 and 4
    # only ever serve shorter ones. HALOGEN_CTX is deliberately NOT lowered:
    # halogen is this host's only payload, and a prompt over that cap is a
    # hard 400 rather than a truncation.
    #
    # Paid for with memory, not precision. HALOGEN_KV8=1 would fit 925184
    # positions in the ~27 GiB the bf16 524288 took, but its published quality
    # evidence stops short of how this host is used: docs/quality.md runs its
    # needle battery only to 32768 and says of itself that it "says the model
    # finds a fact it was given, not that its reasoning holds at depth", and
    # the 128k/250k parity quoted for KV8 is retrieval of planted facts, not
    # reasoning over 200k of code -- which is what this endpoint serves.
    # So the pool grows in bf16 instead; upstream lists 786432 (~34 GiB) as a
    # supported configuration on the same 128 GiB reference machine. If int8
    # is ever revisited, settle it on recorded real prompts replayed at
    # temperature 0 against both arms, not on perplexity.
    #
    # Why 786432: a request reserves prompt + max_tokens, so a 200k turn at the
    # default 8192 budget holds ~208k positions -- 2.5 of those fit today,
    # ~3.7 after this. The pool must be restated explicitly or it drops back to
    # 2 x ctx. HALOGEN_KV_POOL_FIT (default on) lowers an ask that will not fit
    # and logs what it chose, so the settled value is a post-deploy check at
    # /health, not a promise made here. Do not go to the 1048576 cap without
    # HALOGEN_MAX_TOK=16384: a 1M pool leaves no room for the prefill arena on
    # a 128 GiB machine. If 786432 itself does not fit, HALOGEN_MAX_TOK=16384
    # is the precision-free way to make room (that scratch is ~9 GiB at 32768)
    # for ~8% slower prefill. The pool is also RAM the 47.7 GiB n-gram table
    # would otherwise page-cache -- if long prompts start crawling on disk
    # reads, the fix is a smaller pool or a larger HALOGEN_HOST_RESERVE_GIB.
    #
    # CACHE_BRANCHES=3 is the fan-out case: 2 branches is a conversation plus
    # one side turn, 3 is a parent forked into two subagents, and at 2 the
    # parent's resume point is the one the children's stores replace, so the
    # parent re-reads its history next turn. Costs ~0.8 GiB (32 entries, was
    # 24). HALOGEN_KV_SLOTS stays at 4: eight admits more clients at ~10 tok/s
    # each against ~19, and nothing is queueing.
    environment = {
      HALOGEN_KV_POOL_POSITIONS = "786432";
      HALOGEN_CACHE_BRANCHES = "3";
    };
    # Weight exclusions (skip the unused w4b/ht43 checkpoints so a future bump
    # fits /opt/llm) come from the module's `download.exclude` default, which
    # lives beside defaultRepo/defaultWeightsRevision in halogen-flash-flake.
    # Override here only if llm01 ever needs a different set.
  };

  # Nix settings
  nix.settings = {
    download-buffer-size = 536870912;
  };
  nixpkgs.config.allowUnfree = true;
  nixpkgs.config.allowUnfreePredicate = pkg: builtins.elem (lib.getName pkg) [ "open-webui" ];

  system.stateVersion = "25.11";
}
