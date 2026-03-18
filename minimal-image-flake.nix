{
  description = "Minimal k8s-pi01 image for SD card";
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";
    sops-nix.url = "github:Mic92/sops-nix";
    home-manager.url = "github:nix-community/home-manager/release-25.11";
  };

  outputs = { self, nixpkgs, sops-nix, home-manager }: {
    nixosConfigurations.k8s-pi01 = nixpkgs.lib.nixosSystem {
      system = "aarch64-linux";
      modules = [
        ./hosts/k8s-pi01/minimal-image.nix
        sops-nix.nixosModules.sops
        home-manager.nixosModules.home-manager
      ];
    };
  };
}
