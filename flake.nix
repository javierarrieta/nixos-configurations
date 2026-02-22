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
      ...
    }:
    let
      mkExtraArgs = system: {
        unstablepkgs = import unstable {
          system = system;
          config.allowUnfree = true;
        };
        pkgsunfree = import nixpkgs {
          system = system;
          config.allowUnfree = true;
        };
        unstablepkgsunfree = import unstable {
          system = system;
          config.allowUnfree = true;
        };
        unstablePkgs = import unstable {
          system = system;
          config.allowUnfree = false;
        };
        pkgsUnfree = import nixpkgs {
          system = system;
          config.allowUnfree = true;
        };
        unstablePkgsUnfree = import unstable {
          system = system;
          config.allowUnfree = true;
        };
      };
    in
    {
      nixosConfigurations.llm01 = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        specialArgs = {
          inherit unstable home-manager;
        }
        // (mkExtraArgs "x86_64-linux");
        modules = [
          ./hosts/llm01
          disko.nixosModules.disko
          sops-nix.nixosModules.sops
          home-manager.nixosModules.home-manager
          comin.nixosModules.comin
        ];
      };

      nixosConfigurations.newhost = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        specialArgs = {
          inherit unstable home-manager;
        }
        // (mkExtraArgs "x86_64-linux");
        modules = [
          ./hosts/newhost
          sops-nix.nixosModules.sops
          home-manager.nixosModules.home-manager
        ];
      };

      nixosConfigurations.ryzen7 = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        specialArgs = {
          inherit unstable home-manager nix-sweep;
        }
        // (mkExtraArgs "x86_64-linux");
        modules = [
          ./hosts/ryzen7
          disko.nixosModules.disko
          sops-nix.nixosModules.sops
          home-manager.nixosModules.home-manager
          nix-sweep.nixosModules.default
        ];
      };
    };
}
