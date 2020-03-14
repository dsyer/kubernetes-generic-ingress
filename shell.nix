with import <nixpkgs> {};
pkgs.mkShell {
  name = "env";
  buildInputs = [
    (import ./default.nix { inherit pkgs; })
    figlet
  ];
  shellHook = ''
    figlet ":smile:"
    kind-setup
    kubectl get all
'';
} 