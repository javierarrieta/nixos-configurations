To install llm01

Run disko:

```shell
sudo nix --experimental-features "nix-command flakes" run github:nix-community/disko/latest -- --mode destroy,format,mount nixos-configurations/hosts/llm01/disko.nix
```

Provide the password for both partitions encryption

Install the system:

```shell
ce $HOME/cd nixos-configurations && sudo nixos-install --flake .#llm01
```

