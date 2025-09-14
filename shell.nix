with import <nixpkgs> {};

mkShell {
  # These are the packages that will be available in your shell
  buildInputs = [
    podman
  ];
}
