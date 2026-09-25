{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    unstable.url = "github:NixOS/nixpkgs/nixos-unstable";
    sops-nix.url = "github:Mic92/sops-nix";
    home-manager = {
      url = "github:nix-community/home-manager/release-26.05";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    disko.url = "github:nix-community/disko";
    disko.inputs.nixpkgs.follows = "nixpkgs";
    comin = {
      url = "github:nlewo/comin";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    nix-sweep.url = "github:jzbor/nix-sweep";
    comfyui-nix.url = "github:utensils/comfyui-nix";
    nixos-wsl = {
      url = "github:nix-community/nixos-wsl";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    codex-cli-nix = {
      url = "github:sadjow/codex-cli-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    llama-cpp = {
      url = "github:ggml-org/llama.cpp/b10649";
    };

    # halogen-flash-server (Strix Halo inference) deployment module.
    # Swap the local path for github:javierarrieta/halogen-flash-flake once
    # pushed; the repo is independent and only feeds this flake via nixosModules.
    halogen-flash = {
      url = "github:javierarrieta/halogen-flash-flake";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # herdr: terminal-native runtime for AI coding agents. Consumed from
    # herdr-nix, which wraps upstream's prebuilt per-platform release
    # binaries, rather than herdr's own source flake -- that one drags in
    # the full Rust + Zig toolchain and compiles on every install and update
    # with no binary cache behind it. This way it is a hash-verified download.
    # AGPL-3.0-or-later, which nixpkgs treats as free, so the unfree
    # whitelist in mkHomeConfig does not have to be widened for it.
    herdr-nix = {
      url = "github:herdrdev/herdr-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # pi: terminal coding agent. Upstream ships no flake (earendil-works/pi#2310)
    # and `pi-coding-agent` is absent from nixos-26.05, so it comes from
    # lukasl-dev/pi.nix -- a bun2nix build of upstream, currently v0.87.1, with
    # a public binary cache at https://pi.cachix.org (add it to your substituters
    # or the first build per system compiles from source).
    #
    # Deliberately NOT `follows = nixpkgs`: the flake pins its own
    # nixos-unstable plus a separate nixpkgs-26.05-darwin tree for Intel
    # macOS, and the package expects the newer branch. It builds its own
    # self-contained closure, so the version skew is contained to pi.
    pi.url = "github:lukasl-dev/pi.nix";

    # nix-darwin is here for one thing: writing /etc/nix/nix.conf on the two
    # laptops so the pi binary cache is trusted by the nix daemon. See
    # modules/darwin/pi-cache.nix for why home-manager cannot do this.
    # Follows the repo's nixpkgs so the Macs share one package tree with the
    # rest of the fleet; nixpkgs is multi-platform despite the branch name.
    nix-darwin = {
      url = "github:LnL7/nix-darwin/nix-darwin-26.05";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Agent skills vendored straight from their upstream repos and symlinked into
    # ~/.pi/agent/skills by modules/home-manager/dev-tools.nix. These were
    # previously installed imperatively with the `skills` CLI (~/.agents/skills +
    # .skill-lock.json), which nothing in this repo could reproduce.
    #
    # `flake = false`: none of the three ships a flake, so each is locked as a
    # plain source tree and we reference `skills/<name>` out of it directly.
    caveman-skills = {
      url = "github:JuliusBrussee/caveman";
      flake = false;
    };
    gitguardian-skills = {
      url = "github:gitguardian/agent-skills";
      flake = false;
    };
    vercel-skills = {
      url = "github:vercel-labs/skills";
      flake = false;
    };
  };

  # pi.cachix.org carries the prebuilt pi-coding-agent output (verified: the
  # 0.87.1 x86_64-linux NAR is there, cache.nixos.org returns 404 for it), so
  # without this every system compiles pi from source on first use.
  #
  # A flake's nixConfig only applies when it is the flake being operated on and
  # needs one-time approval: either answer the prompt from `home-manager switch
  # --flake .#<host>` / `nix build .#...`, or set `accept-flake-config = true`
  # in ~/.config/nix/nix.conf. It is NOT inherited by machines that merely
  # consume this repo as an input, so on a fresh host add the substituter to
  # nix.conf / nix.settings directly.
  nixConfig = {
    extra-substituters = [ "https://pi.cachix.org" ];
    extra-trusted-public-keys = [ "pi.cachix.org-1:lGeoGJaZ5ZDabuRzkcD5EBTNnDM4HJ1vqeOxlWk1Flk=" ];
  };

  outputs =
    {
      self,
      nixpkgs,
      unstable,
      sops-nix,
      disko,
      home-manager,
      comin,
      nix-sweep,
      comfyui-nix,
      nixos-wsl,
      codex-cli-nix,
      llama-cpp,
      halogen-flash,
      herdr-nix,
      pi,
      nix-darwin,
      caveman-skills,
      gitguardian-skills,
      vercel-skills,
      ...
    }:
    let
      mkExtraArgs = system: {
        unstablePkgs = import unstable {
          localSystem = system;
          config.allowUnfree = false;
        };
        pkgsUnfree = import nixpkgs {
          localSystem = system;
          config.allowUnfree = true;
        };
        unstablePkgsUnfree = import unstable {
          localSystem = system;
          config.allowUnfree = true;
        };
        llamaPkgs = llama-cpp.packages.${system};
        # Prebuilt herdr binary for this system (see the herdr-nix input note).
        herdrPkg = herdr-nix.packages.${system}.default;
        # pi binary for this system (see the pi input note). Package only --
        # the agent config is rendered by modules/home-manager/dev-tools.nix
        # rather than the flake's own homeModules, so the merge semantics stay
        # reviewable in this repo.
        piPkg = pi.packages.${system}.coding-agent;
        # Vendored skill sources, consumed by modules/home-manager/dev-tools.nix.
        agentSkills = {
          caveman = caveman-skills;
          gitguardian = gitguardian-skills;
          vercel = vercel-skills;
        };
      };

      mkHomeConfig =
        {
          hostname,
          system ? "aarch64-darwin",
        }:
        home-manager.lib.homeManagerConfiguration {
          pkgs = import nixpkgs {
            inherit system;
            # bun is unfree (source-available license); pin it to 1.4.0 via the
            # overlay below and allow only that package through, leaving other
            # unfree packages gated.
            config.allowUnfreePredicate = pkg: builtins.elem (nixpkgs.lib.getName pkg) [ "bun" ];
            overlays = [ (import ./home/bun-overlay.nix { }).overlays.default ];
          };
          modules = [ ./home/hosts/${hostname}/home.nix ];
          extraSpecialArgs = (mkExtraArgs system) // {
            inherit codex-cli-nix;
            inherit hostname;
            userOptions = import ./home/hosts/${hostname}/userOptions.nix;
          };
        };
    in
    {
      homeConfigurations = {
        oracle = mkHomeConfig {
          hostname = "oracle";
        };
        macbookair = mkHomeConfig {
          hostname = "macbookair";
        };
        macbookpro = mkHomeConfig {
          hostname = "macbookpro";
        };
        vps = mkHomeConfig {
          hostname = "vps";
          system = "x86_64-linux";
        };
        coder-workspace = mkHomeConfig {
          hostname = "coder-workspace";
          system = "x86_64-linux";
        };
      };

      # macOS system configuration for the two laptops.
      #
      # Intentionally narrow: it only carries the pi binary cache. Dotfiles stay
      # on the standalone homeConfigurations above and are still applied with
      # `home-manager --flake .#macbookpro switch`; this is applied separately
      # with `sudo darwin-rebuild switch --flake .#macbookpro`.
      #
      # Read before the first apply. nix.enable defaults to true in nix-darwin,
      # so darwin-rebuild takes over /etc/nix/nix.conf, the nix-daemon launchd
      # unit and nix.package (pkgs.nix from this flake's nixpkgs-26.05). If a
      # laptop runs Determinate Nix, its nix.conf gets replaced -- diff the two
      # first, and `darwin-rebuild --rollback` is available afterwards.
      darwinConfigurations.macbookpro = nix-darwin.lib.darwinSystem {
        modules = [
          ./modules/darwin/pi-cache.nix
          {
            piCache.enable = true;
            nixpkgs.hostPlatform = "aarch64-darwin";
          }
        ];
      };

      darwinConfigurations.macbookair = nix-darwin.lib.darwinSystem {
        modules = [
          ./modules/darwin/pi-cache.nix
          {
            piCache.enable = true;
            nixpkgs.hostPlatform = "aarch64-darwin";
          }
        ];
      };

      nixosConfigurations.llm01 = nixpkgs.lib.nixosSystem {
        specialArgs = {
          inherit
            unstable
            home-manager
            comfyui-nix
            nix-sweep
            halogen-flash
            ;
        }
        // (mkExtraArgs "x86_64-linux");
        modules = [
          {
            nixpkgs.hostPlatform.system = "x86_64-linux";
            nixpkgs.overlays = [
              comfyui-nix.overlays.default
            ];
          }
          ./hosts/llm01
          disko.nixosModules.disko
          sops-nix.nixosModules.sops
          home-manager.nixosModules.home-manager
          comin.nixosModules.comin
          comfyui-nix.nixosModules.default
          nix-sweep.nixosModules.default
        ];
      };

      nixosConfigurations.ryzen7 = nixpkgs.lib.nixosSystem {
        specialArgs = {
          inherit unstable home-manager nix-sweep;
        }
        // (mkExtraArgs "x86_64-linux");
        modules = [
          {
            nixpkgs.hostPlatform.system = "x86_64-linux";
          }
          ./hosts/ryzen7
          disko.nixosModules.disko
          sops-nix.nixosModules.sops
          home-manager.nixosModules.home-manager
          nix-sweep.nixosModules.default
        ];
      };

      nixosConfigurations.wsl = nixpkgs.lib.nixosSystem {
        specialArgs = {
          inherit
            unstable
            home-manager
            nix-sweep
            nixos-wsl
            ;
        }
        // (mkExtraArgs "x86_64-linux");
        modules = [
          {
            nixpkgs.hostPlatform.system = "x86_64-linux";
          }
          ./hosts/wsl
          nixos-wsl.nixosModules.wsl
          home-manager.nixosModules.home-manager
          nix-sweep.nixosModules.default
        ];
      };

      nixosConfigurations.k8s-node01 = nixpkgs.lib.nixosSystem {
        specialArgs = {
          inherit unstable home-manager nix-sweep;
        }
        // (mkExtraArgs "x86_64-linux");
        modules = [
          {
            nixpkgs.hostPlatform.system = "x86_64-linux";
          }
          ./hosts/k8s-node01
          disko.nixosModules.disko
          sops-nix.nixosModules.sops
          home-manager.nixosModules.home-manager
          comin.nixosModules.comin
          nix-sweep.nixosModules.default
        ];
      };

      nixosConfigurations.k8s-node02 = nixpkgs.lib.nixosSystem {
        specialArgs = {
          inherit unstable home-manager nix-sweep;
        }
        // (mkExtraArgs "x86_64-linux");
        modules = [
          {
            nixpkgs.hostPlatform.system = "x86_64-linux";
          }
          ./hosts/k8s-node02
          disko.nixosModules.disko
          sops-nix.nixosModules.sops
          home-manager.nixosModules.home-manager
          comin.nixosModules.comin
          nix-sweep.nixosModules.default
        ];
      };

      nixosConfigurations.k8s-node03 = nixpkgs.lib.nixosSystem {
        specialArgs = {
          inherit unstable home-manager nix-sweep;
        }
        // (mkExtraArgs "x86_64-linux");
        modules = [
          {
            nixpkgs.hostPlatform.system = "x86_64-linux";
          }
          ./hosts/k8s-node03
          disko.nixosModules.disko
          sops-nix.nixosModules.sops
          home-manager.nixosModules.home-manager
          comin.nixosModules.comin
          nix-sweep.nixosModules.default
        ];
      };

      nixosConfigurations.k8s-node04 = nixpkgs.lib.nixosSystem {
        specialArgs = {
          inherit unstable home-manager nix-sweep;
        }
        // (mkExtraArgs "x86_64-linux");
        modules = [
          {
            nixpkgs.hostPlatform.system = "x86_64-linux";
          }
          ./hosts/k8s-node04
          disko.nixosModules.disko
          sops-nix.nixosModules.sops
          home-manager.nixosModules.home-manager
          comin.nixosModules.comin
          nix-sweep.nixosModules.default
        ];
      };

      nixosConfigurations.k8s-node05 = nixpkgs.lib.nixosSystem {
        specialArgs = {
          inherit unstable home-manager nix-sweep;
        }
        // (mkExtraArgs "x86_64-linux");
        modules = [
          {
            nixpkgs.hostPlatform.system = "x86_64-linux";
          }
          ./hosts/k8s-node05
          disko.nixosModules.disko
          sops-nix.nixosModules.sops
          home-manager.nixosModules.home-manager
          comin.nixosModules.comin
          nix-sweep.nixosModules.default
        ];
      };

      nixosConfigurations.k8s-server03 = nixpkgs.lib.nixosSystem {
        specialArgs = {
          inherit unstable home-manager nix-sweep;
        }
        // (mkExtraArgs "x86_64-linux");
        modules = [
          {
            nixpkgs.hostPlatform.system = "x86_64-linux";
          }
          ./hosts/k8s-server03
          disko.nixosModules.disko
          sops-nix.nixosModules.sops
          home-manager.nixosModules.home-manager
          comin.nixosModules.comin
          nix-sweep.nixosModules.default
        ];
      };

      nixosConfigurations.k8s-server02 = nixpkgs.lib.nixosSystem {
        specialArgs = {
          inherit unstable home-manager nix-sweep;
        }
        // (mkExtraArgs "x86_64-linux");
        modules = [
          {
            nixpkgs.hostPlatform.system = "x86_64-linux";
          }
          ./hosts/k8s-server02
          disko.nixosModules.disko
          sops-nix.nixosModules.sops
          home-manager.nixosModules.home-manager
          comin.nixosModules.comin
          nix-sweep.nixosModules.default
        ];
      };

      nixosConfigurations.k8s-server01 = nixpkgs.lib.nixosSystem {
        specialArgs = {
          inherit unstable home-manager nix-sweep;
        }
        // (mkExtraArgs "x86_64-linux");
        modules = [
          {
            nixpkgs.hostPlatform.system = "x86_64-linux";
          }
          ./hosts/k8s-server01
          disko.nixosModules.disko
          sops-nix.nixosModules.sops
          home-manager.nixosModules.home-manager
          comin.nixosModules.comin
          nix-sweep.nixosModules.default
        ];
      };

      nixosConfigurations.k8s-pi01 = nixpkgs.lib.nixosSystem {
        system = "aarch64-linux";
        specialArgs = {
          inherit unstable home-manager nix-sweep;
        }
        // (mkExtraArgs "aarch64-linux");
        modules = [
          { nixpkgs.hostPlatform.system = "aarch64-linux"; }
          ./hosts/k8s-pi01
          sops-nix.nixosModules.sops
          home-manager.nixosModules.home-manager
          comin.nixosModules.comin
          nix-sweep.nixosModules.default
        ];
      };

      nixosConfigurations.k8s-pi01-minimal = nixpkgs.lib.nixosSystem {
        system = "aarch64-linux";
        specialArgs = {
          inherit unstable home-manager;
        }
        // (mkExtraArgs "aarch64-linux");
        modules = [
          { nixpkgs.hostPlatform.system = "aarch64-linux"; }
          ./hosts/k8s-pi01/minimal-image.nix
          comin.nixosModules.comin
        ];
      };

      nixosConfigurations.k8s-pi02 = nixpkgs.lib.nixosSystem {
        system = "aarch64-linux";
        specialArgs = {
          inherit unstable home-manager nix-sweep;
        }
        // (mkExtraArgs "aarch64-linux");
        modules = [
          { nixpkgs.hostPlatform.system = "aarch64-linux"; }
          ./hosts/k8s-pi02
          sops-nix.nixosModules.sops
          home-manager.nixosModules.home-manager
          comin.nixosModules.comin
          nix-sweep.nixosModules.default
        ];
      };

      nixosConfigurations.k8s-pi02-minimal = nixpkgs.lib.nixosSystem {
        system = "aarch64-linux";
        specialArgs = {
          inherit unstable home-manager;
        }
        // (mkExtraArgs "aarch64-linux");
        modules = [
          { nixpkgs.hostPlatform.system = "aarch64-linux"; }
          ./hosts/k8s-pi02/minimal-image.nix
          comin.nixosModules.comin
        ];
      };

      nixosConfigurations.k8s-pi03 = nixpkgs.lib.nixosSystem {
        system = "aarch64-linux";
        specialArgs = {
          inherit unstable home-manager nix-sweep;
        }
        // (mkExtraArgs "aarch64-linux");
        modules = [
          { nixpkgs.hostPlatform.system = "aarch64-linux"; }
          ./hosts/k8s-pi03
          sops-nix.nixosModules.sops
          home-manager.nixosModules.home-manager
          comin.nixosModules.comin
          nix-sweep.nixosModules.default
        ];
      };

      nixosConfigurations.k8s-pi03-minimal = nixpkgs.lib.nixosSystem {
        system = "aarch64-linux";
        specialArgs = {
          inherit unstable home-manager;
        }
        // (mkExtraArgs "aarch64-linux");
        modules = [
          { nixpkgs.hostPlatform.system = "aarch64-linux"; }
          ./hosts/k8s-pi03/minimal-image.nix
          comin.nixosModules.comin
        ];
      };

      packages.x86_64-linux.sd-image-k8s-pi01 =
        (self.nixosConfigurations.k8s-pi01.extendModules {

          modules = [
            { nixpkgs.hostPlatform.system = "aarch64-linux"; }

            { nixpkgs.buildPlatform.system = "x86_64-linux"; }

            "${nixpkgs}/nixos/modules/installer/sd-card/sd-image-aarch64.nix"

          ];

        }).config.system.build.sdImage;

      packages.x86_64-linux.sd-image-k8s-pi01-minimal =
        (self.nixosConfigurations.k8s-pi01-minimal.extendModules {

          modules = [

            {
              nixpkgs.buildPlatform.system = "x86_64-linux";
              nixpkgs.hostPlatform.system = "aarch64-linux";
              nixpkgs.overlays = [ comin.overlays.default ];
              networking.hostName = "k8s-pi01";
              image.baseName = "nixos-sd-image-k8s-pi01-minimal";
            }

            "${nixpkgs}/nixos/modules/installer/sd-card/sd-image-aarch64.nix"

          ];

        }).config.system.build.sdImage;

      packages.aarch64-darwin.sd-image-k8s-pi01 =
        (self.nixosConfigurations.k8s-pi01.extendModules {

          modules = [
            { nixpkgs.hostPlatform.system = "aarch64-linux"; }

            "${nixpkgs}/nixos/modules/installer/sd-card/sd-image-aarch64.nix"

          ];

        }).config.system.build.sdImage;

      packages.aarch64-darwin.sd-image-k8s-pi01-minimal =
        (self.nixosConfigurations.k8s-pi01-minimal.extendModules {

          modules = [

            {
              networking.hostName = "k8s-pi01";
              image.baseName = "nixos-sd-image-k8s-pi01-minimal";
            }

            "${nixpkgs}/nixos/modules/installer/sd-card/sd-image-aarch64.nix"

          ];

        }).config.system.build.sdImage;

      packages.x86_64-linux.sd-image-k8s-pi02 =
        (self.nixosConfigurations.k8s-pi02.extendModules {

          modules = [

            { nixpkgs.buildPlatform.system = "x86_64-linux"; }

            "${nixpkgs}/nixos/modules/installer/sd-card/sd-image-aarch64.nix"

          ];

        }).config.system.build.sdImage;

      packages.aarch64-darwin.sd-image-k8s-pi02 =
        (self.nixosConfigurations.k8s-pi02.extendModules {

          modules = [

            "${nixpkgs}/nixos/modules/installer/sd-card/sd-image-aarch64.nix"

          ];

        }).config.system.build.sdImage;

      packages.x86_64-linux.sd-image-k8s-pi02-minimal =
        (self.nixosConfigurations.k8s-pi02-minimal.extendModules {

          modules = [

            {
              nixpkgs.buildPlatform.system = "x86_64-linux";
              nixpkgs.hostPlatform.system = "aarch64-linux";
              nixpkgs.overlays = [ comin.overlays.default ];
              networking.hostName = "k8s-pi02";
              image.baseName = "nixos-sd-image-k8s-pi02-minimal";
            }

            "${nixpkgs}/nixos/modules/installer/sd-card/sd-image-aarch64.nix"

          ];

        }).config.system.build.sdImage;

      packages.aarch64-darwin.sd-image-k8s-pi02-minimal =
        (self.nixosConfigurations.k8s-pi02-minimal.extendModules {

          modules = [
            { nixpkgs.hostPlatform.system = "aarch64-linux"; }

            {
              networking.hostName = "k8s-pi02";
              image.baseName = "nixos-sd-image-k8s-pi02-minimal";
            }

            "${nixpkgs}/nixos/modules/installer/sd-card/sd-image-aarch64.nix"

          ];

        }).config.system.build.sdImage;

      packages.x86_64-linux.sd-image-k8s-pi03 =
        (self.nixosConfigurations.k8s-pi03.extendModules {

          modules = [

            { nixpkgs.buildPlatform.system = "x86_64-linux"; }

            "${nixpkgs}/nixos/modules/installer/sd-card/sd-image-aarch64.nix"

          ];

        }).config.system.build.sdImage;

      packages.x86_64-linux.sd-image-k8s-pi03-minimal =
        (self.nixosConfigurations.k8s-pi03-minimal.extendModules {

          modules = [

            {
              nixpkgs.buildPlatform.system = "x86_64-linux";
              nixpkgs.hostPlatform.system = "aarch64-linux";
              nixpkgs.overlays = [ comin.overlays.default ];
              networking.hostName = "k8s-pi03";
              image.baseName = "nixos-sd-image-k8s-pi03-minimal";
            }

            "${nixpkgs}/nixos/modules/installer/sd-card/sd-image-aarch64.nix"

          ];

        }).config.system.build.sdImage;

      packages.aarch64-darwin.sd-image-k8s-pi03 =
        (self.nixosConfigurations.k8s-pi03.extendModules {

          modules = [
            { nixpkgs.hostPlatform.system = "aarch64-linux"; }

            {
              networking.hostName = "k8s-pi03";
              image.baseName = "nixos-sd-image-k8s-pi03";
            }

            "${nixpkgs}/nixos/modules/installer/sd-card/sd-image-aarch64.nix"

          ];

        }).config.system.build.sdImage;

      packages.aarch64-darwin.sd-image-k8s-pi03-minimal =
        (self.nixosConfigurations.k8s-pi03-minimal.extendModules {

          modules = [

            {
              networking.hostName = "k8s-pi03";
              image.baseName = "nixos-sd-image-k8s-pi03-minimal";
            }

            "${nixpkgs}/nixos/modules/installer/sd-card/sd-image-aarch64.nix"

          ];

        }).config.system.build.sdImage;

      packages.x86_64-linux.coder-iscsi-helper =
        nixpkgs.legacyPackages.x86_64-linux.callPackage ./pkgs/coder-iscsi-helper
          { };

      formatter.x86_64-linux = nixpkgs.legacyPackages.x86_64-linux.nixfmt-tree;
      formatter.aarch64-darwin = nixpkgs.legacyPackages.aarch64-darwin.nixfmt-tree;
    };
}
