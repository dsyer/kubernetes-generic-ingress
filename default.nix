{ pkgs ? import <nixpkgs> {} }:

with pkgs;

let

  kindSetup = pkgs.writeShellScriptBin "kind-setup" "./kind-setup.sh";

in buildEnv {
  name = "env";
  paths = [
    kind
    kubectl
    kustomize
    skaffold
    kindSetup
  ];
}