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
    nixos-generators.url = "github:nix-community/nixos-generators";
    nixos-generators.inputs.nixpkgs.follows = "nixpkgs";
    # Pull llama-cpp directly from its source
    llama-cpp = {
      url = "github:ggerganov/llama.cpp";
      inputs.nixpkgs.follows = "unstable";
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
      nixos-generators,
      llama-cpp,
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
          inherit
            unstable
            home-manager
            llama-cpp
            comfyui-nix
            ;
        }
        // (mkExtraArgs "x86_64-linux");
        modules = [
          {
            nixpkgs.overlays = [
              llama-cpp.overlays.default
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

      nixosConfigurations.k8s-node03 = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        specialArgs = {
          inherit unstable home-manager;
        }
        // (mkExtraArgs "x86_64-linux");
        modules = [
          ./hosts/k8s-node03
          sops-nix.nixosModules.sops
          home-manager.nixosModules.home-manager
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

      packages.x86_64-linux.sd-image-k8s-pi01 = nixos-generators.nixosGenerate {
        system = "aarch64-linux";
        modules = [
          ./hosts/k8s-pi01
          sops-nix.nixosModules.sops
          home-manager.nixosModules.home-manager
          comin.nixosModules.comin
        ];
        format = "sd-aarch64";
      };

      packages.x86_64-linux.sd-image-k8s-pi01-minimal = nixos-generators.nixosGenerate {
        system = "aarch64-linux";
        modules = [
          ./hosts/k8s-pi01/minimal-image.nix
          comin.nixosModules.comin
        ];
        format = "sd-aarch64";
      };

      packages.aarch64-darwin.sd-image-k8s-pi01 = nixos-generators.nixosGenerate {
        system = "aarch64-linux";
        modules = [
          ./hosts/k8s-pi01
          sops-nix.nixosModules.sops
          home-manager.nixosModules.home-manager
          comin.nixosModules.comin
        ];
        format = "sd-aarch64";
      };

      packages.aarch64-darwin.sd-image-k8s-pi01-minimal = nixos-generators.nixosGenerate {
        system = "aarch64-linux";
        modules = [
          ./hosts/k8s-pi01/minimal-image.nix
          comin.nixosModules.comin
        ];
        format = "sd-aarch64";
      };
    };
}
