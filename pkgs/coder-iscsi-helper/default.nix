{ pkgs }:
pkgs.stdenvNoCC.mkDerivation {
  pname = "coder-iscsi-helper";
  version = "0.1.0";
  src = ./.;
  nativeBuildInputs = [ pkgs.makeWrapper ];
  installPhase = ''
    install -Dm755 helper.py $out/libexec/coder-iscsi-helper.py
    makeWrapper ${pkgs.python3}/bin/python3 $out/bin/coder-iscsi-helper \
      --add-flags "$out/libexec/coder-iscsi-helper.py"
  '';
}
