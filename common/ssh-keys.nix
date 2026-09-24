# Single source of truth for javier's SSH authorized keys on every host.
#
# Consumed by:
#   - common/users.nix                    (full NixOS systems, all 13 hosts)
#   - modules/nixos/minimal-image.nix     (k8s-piXX-minimal bootstrap images)
#
# Add keys here only. A second copy elsewhere is how the bootstrap images silently
# fall behind the fleet (the WSL key lived only in users.nix for months).
[
  "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJAxtDTZvN/YqOQC1nOGahb/qLp35iYnBTPaGld6/N6k javier@Javiers-MacBook-Air.local"
  "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIONAB+iq2juyVF0+JA8/gfHpZOnFEn0kITChNNQXddgI javier@Javiers-MacBook-Pro.local"
  "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQC7hbsmE8Ve4mfIsUrTTHRTq2pdO5ZjOLJsEdjhR4lakDpbe4NH1L5iFHGlIMQGnvHQuBZKqIhaIcVR1uriXWqouQTlfRS884jfvLOeYXo6jPzrFJaXLaHl35vyEE9SLZKTvm4F7B7ZyUGI5sBvXRBIw7VvYdEcLSdIawyTtIaHbZuUfnfqiqgeSR7zxrzNpG7gXAgpumy1xBNGRCIQRJs/IdYljL3Yx4uaFQB6CDHSUzpID+hFUafhPtPoTAlHZJEyIyD8bDd5UMt3jUWcEg5lPxNmPYTsB8uiF0pImfKZfYVyrb9hYJklHpmpTihhqsDvni6lnR0wX6xcvxI96XYipo1qJyI4eshIGjjRU93Si+wzhVP9CoKVQeuhpKSkX2t+BFVewPKUb8SqvIyd0WfxX7cZGbWYWxamvN1/LaHT68IfPgfvattviL+PL7zpQA3C8orTbGiqJRtlglw07sdCyz5Wgy0TW6Lmetx4TRkSPLbrakgYvaogbpaev0FTd4c= javier@Franciscos-MBP"
  "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOHYYT+i+mHzpO2+LObL1bOmb7Ry0c3Ju/7T4/01aybf jaarriet@jaarriet-mac"
  "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAICTCPPiQVMBxqQdAyUgUvM7FL+Fi8FErDOIxhdz/WlLu javier@kvm"
  "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKhwR+SbHJQR8mSFe5UvBVNlcuG6vpXLU6K+4Rh3z25N javier@DESKTOP-9N12DRJ"
  "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIC+5Q6F5SqhlkN/3Bb1aM9WDxOcZOFdg803ON3vZnhZa nixos@WSL-PC-Javier"
]
