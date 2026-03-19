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
        ];
      };

      nixosConfigurations.newhost = nixpkgs.lib.nixosSystem {
        specialArgs = {
          inherit unstable home-manager;
        }
        // (mkExtraArgs "x86_64-linux");
        modules = [
          {
            nixpkgs.hostPlatform.system = "x86_64-linux";
          }
          ./hosts/newhost
          sops-nix.nixosModules.sops
          home-manager.nixosModules.home-manager
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

      nixosConfigurations.k8s-node03 = nixpkgs.lib.nixosSystem {
        specialArgs = {
          inherit unstable home-manager;
        }
        // (mkExtraArgs "x86_64-linux");
        modules = [
          {
            nixpkgs.hostPlatform.system = "x86_64-linux";
          }
          ./hosts/k8s-node03
          sops-nix.nixosModules.sops
          home-manager.nixosModules.home-manager
        ];
      };
    };
}
