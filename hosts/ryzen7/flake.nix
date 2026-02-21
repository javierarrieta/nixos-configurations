{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";
    nix-sweep.url = "github:jzbor/nix-sweep";
  };
  outputs = { self, nixpkgs , nix-sweep }: {
    nixosConfigurations.ai-server = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        ./configuration.nix
	nix-sweep.nixosModules.default
      ];
    };
  };
}
