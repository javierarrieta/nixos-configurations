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

    # pi (the terminal coding agent) is no longer a flake input: it now comes from
    # `unstablePkgs.pi-coding-agent`, see `piPkg` below.
    #
    # HISTORY -- why the upstream flake input was dropped (2026-11-08). It used to
    # be `pi.url = "github:earendil-works/pi/stable"`, where `stable` is a branch
    # upstream's nix.yml fast-forwards to the newest release tag once all four
    # systems build. Two things made that route unusable for 1.5.0:
    #
    # 1. `stable` never advanced past v1.4.0 (4a080252, 2026-10-22) even though
    #    v1.5.0 (f9a26365, 2026-11-02) is a descendant of it -- because of (2).
    # 2. The v1.5.0 tag does not evaluate at all, with its own pinned nixpkgs or
    #    ours: `importNpmLock` over packages/coding-agent/install-lock dies with
    #    `error: attribute 'integrity' missing` because pi-schema is not packed in
    #    the install lock. Upstream fixed it in d71c66e0 "fix(nix): pack pi-schema
    #    for the install lock", which is on `main` but in no release yet.
    #
    # So the only way to run 1.5.0 today was nixpkgs' own pi-coding-agent, which
    # also removes the old cost of the upstream flake: no binary cache upstream
    # meant every host compiled the npm workspace once per version. To go back,
    # re-add the input (ref = "stable") and restore
    # `piPkg = pi.packages.${system}.pi;` once `stable` has moved past the release
    # you want -- nixos-26.05 is NOT an option, it is frozen at 0.75.4.

    # Agent skills vendored straight from their upstream repos and symlinked into
    # ~/.pi/agent/skills by modules/home-manager/dev-tools.nix. These were
    # previously installed imperatively with the `skills` CLI (~/.agents/skills +
    # .skill-lock.json), which nothing in this repo could reproduce.
    #
    # `flake = false`: none of these ship a flake, so each is locked as a plain
    # source tree and we reference `skills/<name>` out of it directly. The
    # asd-ste100 entry is the one whose tree is flat (SKILL.md at the root); see
    # piVendoredSkills in modules/home-manager/dev-tools.nix.
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
    # ASD-STE100 Simplified Technical English rewrite skill. Single-skill repo,
    # MIT, upstream default branch is `master` (nix resolves it; no ref pinned).
    asd-ste100-skill = {
      url = "github:danyuchn/asd-ste100-skill";
      flake = false;
    };
    # Fish-shell-scripting skill (porada/domfiles). Multi-skill monorepo whose
    # default branch is `master`, not `main`; nix resolves it, no ref pinned.
    # MIT. Only `skills/fish-shell-scripting` is vendored -- the other eleven
    # skills in that repo stay out of pi's routing table deliberately.
    domfiles-skills = {
      url = "github:porada/domfiles";
      flake = false;
    };
    # Elephant-Goldfish Model (EGM): draft specs, then stress-test them with
    # fresh-context "Goldfish" reviewers. Apache-2.0, no flake, so a plain
    # source tree. Vendored whole rather than skill-by-skill: its skills read
    # `agents/<persona>.md` and `resources/document_standards/<name>.md` from
    # the *repo root* at run time, and upstream says a skills-only install
    # breaks it (docs/harnesses.md). See `skillDir` in
    # modules/home-manager/pi/egm.nix for how that is reconciled with the
    # `<input>/skills/<name>` layout every other entry uses.
    #
    # Upstream ships manifests for Claude Code, Codex and Antigravity and none
    # for pi; the pi mapping lives in this repo, not in a fork of the skill text.
    egm-skills = {
      url = "github:google/elephant-goldfish-model";
      flake = false;
    };
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
      halogen-flash,
      herdr-nix,
      caveman-skills,
      gitguardian-skills,
      vercel-skills,
      asd-ste100-skill,
      domfiles-skills,
      egm-skills,
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
        # Prebuilt herdr binary for this system (see the herdr-nix input note).
        herdrPkg = herdr-nix.packages.${system}.default;
        # pi binary for this system. Package only -- the agent config is rendered
        # by modules/home-manager/dev-tools.nix rather than the flake's own
        # homeModules, so the merge semantics stay reviewable in this repo.
        #
        # 1.5.0 from nixos-unstable, prebuilt on cache.nixos.org. It used to be
        # `pi.packages.${system}.pi` from upstream's own flake; see the `pi` note
        # in `inputs` for why that input is gone (v1.5.0 does not evaluate, and
        # `stable` is still 1.4.0). Do not swap this for `pkgs`/nixos-26.05: that
        # tree freezes pi-coding-agent at 0.75.4.
        #
        # Re-imports `unstable` rather than reusing `unstablePkgs` above because
        # this attrset is not `rec`; Nix caches the import, so it is the same
        # package set either way.
        piPkg =
          (import unstable {
            localSystem = system;
            config.allowUnfree = false;
          }).pi-coding-agent;
        # Vendored skill sources, consumed by modules/home-manager/dev-tools.nix.
        agentSkills = {
          caveman = caveman-skills;
          gitguardian = gitguardian-skills;
          vercel = vercel-skills;
          asd-ste100 = asd-ste100-skill;
          domfiles = domfiles-skills;
          egm = egm-skills;
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
            overlays = [
              (import ./home/bun-overlay.nix { }).overlays.default
              # Apple Silicon macOS only; see pkgs/rec/default.nix for why the
              # overlay is safe to leave applied on the Linux hosts.
              (import ./pkgs/rec/overlay.nix)
            ];
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
        # Same dotfiles, different route to halogen, because the two Coder servers
        # put their workspaces on different networks. See
        # home/hosts/coder-workspace-titan/userOptions.nix for why this cannot be
        # one attribute that decides at runtime. The titan template's startup_script
        # must name this attribute; the llm01 podman template keeps the one above.
        coder-workspace-titan = mkHomeConfig {
          hostname = "coder-workspace-titan";
          system = "x86_64-linux";
        };
        llm01 = mkHomeConfig {
          hostname = "llm01";
          system = "x86_64-linux";
        };
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

      nixosConfigurations.titan = nixpkgs.lib.nixosSystem {
        specialArgs = {
          inherit unstable home-manager nix-sweep;
        }
        // (mkExtraArgs "x86_64-linux");
        modules = [
          {
            nixpkgs.hostPlatform.system = "x86_64-linux";
          }
          ./hosts/titan
          disko.nixosModules.disko
          sops-nix.nixosModules.sops
          home-manager.nixosModules.home-manager
          comin.nixosModules.comin
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

      # The `home-manager` CLI that `hm-apply` runs (see
      # modules/home-manager/shell.nix). Taken from this flake's nixpkgs input and
      # deliberately NOT from the `home-manager` flake input: the upstream flake's
      # own package has no cache.nixos.org substitute, so the first `hm-apply` on a
      # fresh machine compiles it and drags the whole stdenv -- gcc, gmp, gettext,
      # groff, patchelf, coreutils -- into the closure. nixpkgs' copy is Hydra-built
      # and downloads in ~1 MiB. The CLI is only a driver: the modules it evaluates
      # come from the pinned `home-manager` input via `homeConfigurations`.
      #
      # Trade-off worth knowing: nixpkgs vendors an older home-manager than this
      # flake pins, so the driver is months older than the modules it runs. That is
      # fine -- the only contract between them is
      # `homeConfigurations.<name>.activationPackage`, stable for years -- but if a
      # future `hm-apply` fails in a way that smells like a CLI/module mismatch,
      # this is the first suspect. Escape hatch: `nix run nixpkgs#home-manager`
      # (unpinned, still cached).
      packages.x86_64-linux.hm-cli = nixpkgs.legacyPackages.x86_64-linux.home-manager;
      packages.aarch64-darwin.hm-cli = nixpkgs.legacyPackages.aarch64-darwin.home-manager;

      # The same ./pkgs/rec the macbookpro home config installs through the
      # overlay, called directly here rather than through a second nixpkgs
      # instance, so it can also be run ad hoc (`nix run .#rec`) without a
      # switch. aarch64-darwin only: upstream ships no other asset, so there is
      # deliberately no packages.x86_64-linux."rec" to fail on.
      # Quoted because `rec` is a reserved word in Nix; the attribute is still
      # reached as `nix run .#rec`.
      packages.aarch64-darwin."rec" = nixpkgs.legacyPackages.aarch64-darwin.callPackage ./pkgs/rec { };

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
