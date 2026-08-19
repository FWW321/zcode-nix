{
  description = "ZCode (Zhipu GLM official ADE) — nix packaging + Home Manager module";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { self, nixpkgs }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      forAllSystems = nixpkgs.lib.genAttrs systems;
    in
    {
      packages = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in
        {
          zcode = pkgs.callPackage ./pkgs/zcode { };
          default = self.packages.${system}.zcode;
        }
      );

      overlays.default = final: _prev: {
        zcode = final.callPackage ./pkgs/zcode { };
      };

      homeManagerModules = {
        zcode = import ./modules/zcode.nix;
        default = self.homeManagerModules.zcode;
      };
    };
}
