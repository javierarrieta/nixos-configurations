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
      };

      mkHomeConfig =
        {
          hostname,
          system ? "aarch64-darwin",
        }:
        home-manager.lib.homeManagerConfiguration {
          pkgs = import nixpkgs {
            inherit system;
            config.allowUnfree = false;
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
        vps = mkHomeConfig {
          hostname = "vps";
          system = "x86_64-linux";
        };
        coder-workspace = mkHomeConfig {
          hostname = "coder-workspace";
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
          ./hosts/k8s-pi03/minimal-image.nix
          comin.nixosModules.comin
        ];
      };

      packages.x86_64-linux.sd-image-k8s-pi01 =
        (self.nixosConfigurations.k8s-pi01.extendModules {

          modules = [

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
