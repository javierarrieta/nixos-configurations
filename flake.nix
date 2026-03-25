{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";
    unstable.url = "github:NixOS/nixpkgs/nixos-unstable";
    sops-nix.url = "github:Mic92/sops-nix";
    home-manager = {
      url = "github:nix-community/home-manager/release-25.11";
    };
    disko.url = "github:nix-community/disko";
    disko.inputs.nixpkgs.follows = "nixpkgs";
    comin = {
      url = "github:nlewo/comin";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    nix-sweep.url = "github:jzbor/nix-sweep";
    comfyui-nix.url = "github:utensils/comfyui-nix";
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
      };
    in
    {
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

      nixosConfigurations.k8s-pi01 = nixpkgs.lib.nixosSystem {
        system = "aarch64-linux";
        specialArgs = {
          inherit unstable home-manager;
        }
        // (mkExtraArgs "aarch64-linux");
        modules = [
          ./hosts/k8s-pi01
          sops-nix.nixosModules.sops
          home-manager.nixosModules.home-manager
          comin.nixosModules.comin
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
          inherit unstable home-manager;
        }
        // (mkExtraArgs "aarch64-linux");
        modules = [
          ./hosts/k8s-pi02
          sops-nix.nixosModules.sops
          home-manager.nixosModules.home-manager
          comin.nixosModules.comin
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
          inherit unstable home-manager;
        }
        // (mkExtraArgs "aarch64-linux");
        modules = [
          ./hosts/k8s-pi03
          sops-nix.nixosModules.sops
          home-manager.nixosModules.home-manager
          comin.nixosModules.comin
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
              image.fileName = "nixos-sd-image-k8s-pi01.img.zst";
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
              image.fileName = "nixos-sd-image-k8s-pi01.img.zst";
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
              image.fileName = "nixos-sd-image-k8s-pi02.img.zst";
            }

            "${nixpkgs}/nixos/modules/installer/sd-card/sd-image-aarch64.nix"

          ];

        }).config.system.build.sdImage;

      packages.aarch64-darwin.sd-image-k8s-pi02-minimal =
        (self.nixosConfigurations.k8s-pi02-minimal.extendModules {

          modules = [

            {
              networking.hostName = "k8s-pi02";
              image.fileName = "nixos-sd-image-k8s-pi02.img.zst";
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
              image.fileName = "nixos-sd-image-k8s-pi03.img.zst";
            }

            "${nixpkgs}/nixos/modules/installer/sd-card/sd-image-aarch64.nix"

          ];

        }).config.system.build.sdImage;

      packages.aarch64-darwin.sd-image-k8s-pi03 =
        (self.nixosConfigurations.k8s-pi03.extendModules {

          modules = [

            {
              networking.hostName = "k8s-pi03";
              image.fileName = "nixos-sd-image-k8s-pi03.img.zst";
            }

            "${nixpkgs}/nixos/modules/installer/sd-card/sd-image-aarch64.nix"

          ];

        }).config.system.build.sdImage;

      packages.aarch64-darwin.sd-image-k8s-pi03-minimal =
        (self.nixosConfigurations.k8s-pi03-minimal.extendModules {

          modules = [

            {
              networking.hostName = "k8s-pi03";
              image.fileName = "nixos-sd-image-k8s-pi03.img.zst";
            }

            "${nixpkgs}/nixos/modules/installer/sd-card/sd-image-aarch64.nix"

          ];

        }).config.system.build.sdImage;
    };
}
