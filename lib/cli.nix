# Four CLI tools, idempotent-by-contract. Add them to your PATH and call
# them from any orchestration language (bash, python, nushell, …).
#
#   nixify <name> <flake> <host> <ssh-key-file> [extras-dir]
#     Ensure <host> runs NixOS configured per <flake>#<name>.
#     No-op if already NixOS. Kexec-installs via nixos-anywhere otherwise.
#     <extras-dir>: optional dir whose contents are dropped into / on the
#     fresh install (e.g. age key + sops blob + authorized_keys).
#
#   probe-nixos <host> <ssh-key-file>
#     Exit 0 iff <host> is real NixOS (not Ubuntu, not the kexec installer).
#
#   deploy-with-rollback <flake> <name> <host> <ssh-key-file>
#     Push the closure for <flake>#<name> to <host> with magic-rollback:
#     auto-revert if SSH heartbeat dies after activation.
#
#   reboot-if-boot-critical <host> <ssh-key-file>
#     Reboot <host> iff its booted kernel/initrd/modules differ from current.

{ pkgs, system, nixos-anywhere, deploy-rs }:

let
  shellChecks = [ "SC2155" "SC2046" "SC2086" "SC2016" ];
in {

  probe-nixos = pkgs.writeShellApplication {
    name = "probe-nixos";
    excludeShellChecks = shellChecks;
    runtimeInputs = [ pkgs.openssh ];
    text = ''
      ssh -i "$2" -o BatchMode=yes -o ConnectTimeout=10 \
          -o StrictHostKeyChecking=accept-new \
          "root@$1" '[ -e /etc/NIXOS ] && [ "$(stat -f -c %T /)" != "tmpfs" ]'
    '';
  };

  nixify = pkgs.writeShellApplication {
    name = "nixify";
    excludeShellChecks = shellChecks;
    runtimeInputs = [
      pkgs.openssh
      nixos-anywhere.packages.${system}.default
    ];
    text = ''
      name="$1"
      flake="$2"
      host="$3"
      ssh_key="$4"
      extras="''${5:-}"

      if ssh -i "$ssh_key" -o BatchMode=yes -o ConnectTimeout=10 \
           -o StrictHostKeyChecking=accept-new \
           "root@$host" '[ -e /etc/NIXOS ] && [ "$(stat -f -c %T /)" != "tmpfs" ]' \
           2>/dev/null; then
        echo "==> $name: already NixOS"
        exit 0
      fi

      args=(--flake "$flake#$name" -i "$ssh_key")
      [ -n "$extras" ] && args+=(--extra-files "$extras")
      exec nixos-anywhere "''${args[@]}" "root@$host"
    '';
  };

  deploy-with-rollback = pkgs.writeShellApplication {
    name = "deploy-with-rollback";
    excludeShellChecks = shellChecks;
    runtimeInputs = [
      deploy-rs.packages.${system}.default
      pkgs.openssh
    ];
    text = ''
      flake="$1"
      name="$2"
      host="$3"
      ssh_key="$4"
      # `--skip-checks`: don't pre-flight-check the entire flake (deploy-rs
       # default runs `nix flake check`, which fails on unrelated outputs).
      exec deploy "$flake#$name" \
        --hostname "$host" \
        --ssh-opts "-i $ssh_key -o StrictHostKeyChecking=accept-new" \
        --skip-checks
    '';
  };

  reboot-if-boot-critical = pkgs.writeShellApplication {
    name = "reboot-if-boot-critical";
    excludeShellChecks = shellChecks;
    runtimeInputs = [ pkgs.openssh ];
    text = ''
      ssh -i "$2" -o BatchMode=yes -o ConnectTimeout=10 \
          -o StrictHostKeyChecking=accept-new "root@$1" '
        booted=$(readlink -f /run/booted-system/{kernel,initrd,kernel-modules})
        current=$(readlink -f /run/current-system/{kernel,initrd,kernel-modules})
        if [ "$booted" != "$current" ]; then
          echo "[reboot] boot-critical paths changed; rebooting"
          systemctl reboot
        fi
      '
    '';
  };
}
