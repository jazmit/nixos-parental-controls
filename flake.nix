{
  description = "Per-user parental controls for NixOS using blocky DNS proxy";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";
    black-hosts = {
      url = "github:StevenBlack/hosts";
      flake = false;
    };
  };

  outputs = { self, nixpkgs, black-hosts }: {
    # Export the NixOS module
    nixosModules.default = {
      imports = [ ./nixos-parental-controls.nix ];
      _module.args = { inherit black-hosts; };
    };

    # Convenience alias
    nixosModules.parental-controls = self.nixosModules.default;
  };
}
