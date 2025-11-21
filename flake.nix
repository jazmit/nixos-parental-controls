{
  description = "Per-user parental controls for NixOS using blocky DNS proxy";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs = { self, nixpkgs }: {
    # Export the NixOS module
    nixosModules.default = import ./nixos-parental-controls.nix;

    # Convenience alias
    nixosModules.parental-controls = self.nixosModules.default;
  };
}
