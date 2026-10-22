{
  config,
  pkgs,
  lib,
  userOptions,
  ...
}:

let
  cfg = config.kubeSegregation;
  home = userOptions.userHome;
  # Quoted for fish, not for the Nix string: the module writes fish source, and
  # a context name with a space or glob would otherwise split or expand.
  expectedFishList = lib.concatMapStringsSep " " (c: "'${c}'") cfg.expectedContexts;
  firstExpected = "'${lib.head cfg.expectedContexts}'";
in
{
  options.kubeSegregation = {
    enable = lib.mkEnableOption ''
      read-only-by-default kubeconfig segregation with a fail-closed agent launcher.
      Enable per-host only where the kubeconfig has actually been split into a
      read-only file and a separate admin file.
    '';

    readOnlyKubeconfig = lib.mkOption {
      type = lib.types.str;
      default = "${home}/.kube/config";
      description = ''
        Kubeconfig that becomes the DEFAULT for every shell, script and agent.
        Must contain read-only credentials only.
      '';
    };

    adminKubeconfig = lib.mkOption {
      type = lib.types.str;
      default = "${home}/.kube/admin.yaml";
      description = ''
        Kubeconfig holding privileged contexts. Never the default; reached only
        via `kadm`.
      '';
    };

    expectedAgentIdentity = lib.mkOption {
      type = lib.types.str;
      default = "system:serviceaccount:k8s-reader:k8s-reader";
      description = ''
        The exact identity agent-env must resolve to, or it refuses to launch.
        Per-host override if the read-only ServiceAccount differs.
      '';
    };

    expectedContexts = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [
        "casa"
        "titan"
        "vps"
      ];
      apply = lib.unique;
      description = ''
        The context names every kubeconfig on this host must contain, and nothing
        else. Both the read-only and the admin kubeconfig are checked against
        this list; a file that does not exist is skipped rather than reported.

        The schema is context == cluster == user, named after the cluster, and
        it is shared with the ssh jumpbox kubeconfig in k8s-casa so the same
        name means the same cluster everywhere. `vps` is the techdelivery
        cluster: it is what the jumpbox calls it, and both entries share CA
        fingerprint e55d3b92f6c09a0a.

        The first entry is what a bare `kadm` selects.
      '';
    };

    checkContextsOnStartup = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Validate context names from every interactive shell startup.";
    };

    installAgentEnv = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Manage ~/.local/bin/agent-env declaratively.";
    };

    installFishFunctions = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Install kadm / kro / kctx fish functions.";
    };
  };

  config = lib.mkIf cfg.enable (
    lib.mkMerge [
      {
        # -------------------------------------------------------------------------
        # The fallback is read-only. Anything that does not deliberately choose
        # otherwise lands on a read-only identity — the opposite of "default is root".
        # -------------------------------------------------------------------------
        home.sessionVariables.KUBECONFIG = cfg.readOnlyKubeconfig;

        home.sessionPath = [
          "${home}/.local/bin"
        ];
      }

      # -------------------------------------------------------------------------
      # agent-env: FAIL-CLOSED launcher.
      #
      # The old setup failed *open*: a broken read-only context made kubectl fall
      # back to the default (admin) context. This asserts the identity and refuses
      # to launch, so a broken credential is a hard stop, not an escalation.
      # -------------------------------------------------------------------------
      (lib.mkIf cfg.installAgentEnv {
        home.file.".local/bin/agent-env" = {
          executable = true;
          text = ''
            #!/usr/bin/env bash
            # agent-env — launch a command with a FAIL-CLOSED read-only cluster identity.
            #
            # Usage:  agent-env <command> [args...]
            #         agent-env --print-env
            set -euo pipefail

            RO_KUBECONFIG="''${RO_KUBECONFIG:-${cfg.readOnlyKubeconfig}}"
            EXPECTED_IDENTITY="${cfg.expectedAgentIdentity}"

            if [ ! -f "$RO_KUBECONFIG" ]; then
              echo "agent-env: ABORT — read-only kubeconfig not found at $RO_KUBECONFIG" >&2
              exit 1
            fi

            export KUBECONFIG="$RO_KUBECONFIG"
            unset KUBECTL_CONTEXT KUBECTL_CLUSTER KUBECTL_USER 2>/dev/null || true

            if [ "''${1:-}" = "--print-env" ]; then
              echo "KUBECONFIG=$KUBECONFIG"
              exit 0
            fi

            # --- fail closed: verify identity before handing over a cluster handle ---
            actual="$(kubectl auth whoami -o jsonpath='{.status.userInfo.username}' 2>/dev/null || true)"
            if [ "$actual" != "$EXPECTED_IDENTITY" ]; then
              echo "agent-env: ABORT — cluster identity is ''${actual:-<unreachable>}" >&2
              echo "           expected '$EXPECTED_IDENTITY'. Refusing to launch." >&2
              exit 1
            fi

            # Belt and braces. NOTE: `kubectl auth can-i` prints "no" to stdout AND
            # exits 1 on denial, so the exit code must be swallowed, not OR-ed in.
            can_delete="$(kubectl auth can-i delete pods 2>/dev/null || true)"
            if [ "$can_delete" != "no" ]; then
              echo "agent-env: ABORT — identity can delete pods (got ''${can_delete:-<empty>})." >&2
              exit 1
            fi

            exec "$@"
          '';
        };
      })

      (lib.mkIf cfg.installFishFunctions {
        programs.fish.functions = {
          kadm = {
            description = "Switch this shell to the ADMIN kubeconfig (privileged)";
            body = ''
              # Bare `kadm` used to select the context `default`. That name is gone:
              # the schema names every context after its cluster, so `default` was a
              # silent dead default -- `use-context` failed, the function reverted to
              # read-only, and it looked like the admin kubeconfig was broken rather
              # than like the name was stale. Now it takes the first entry of
              # kubeSegregation.expectedContexts.
              set -l ctx ${firstExpected}
              if test (count $argv) -ge 1
                  set ctx $argv[1]
              end
              if not test -f ${cfg.adminKubeconfig}
                  echo "kadm: ${cfg.adminKubeconfig} not found" >&2
                  return 1
              end
              set -gx KUBECONFIG ${cfg.adminKubeconfig}
              if not kubectl config use-context $ctx >/dev/null 2>&1
                  echo "kadm: context '$ctx' invalid — reverting to read-only" >&2
                  set -gx KUBECONFIG ${cfg.readOnlyKubeconfig}
                  return 1
              end
              echo "⚠️   ADMIN CONTEXT: "(kubectl config current-context)" (privileged)"
              echo "    back to read-only with: kro"
            '';
          };

          kro = {
            description = "Switch this shell back to the read-only kubeconfig";
            body = ''
              set -gx KUBECONFIG ${cfg.readOnlyKubeconfig}
              echo "read-only: "(kubectl config current-context 2>/dev/null)" -> "(kubectl auth whoami -o jsonpath='{.status.userInfo.username}' 2>/dev/null)
            '';
          };

          "kube-context-check" = {
            description = "Check kubeconfig context names against kubeSegregation.expectedContexts";
            body = ''
              set -l expected ${expectedFishList}
              set -l labels read-only admin
              set -l files '${cfg.readOnlyKubeconfig}' '${cfg.adminKubeconfig}'
              set -l rc 0
              set -l i 1

              for f in $files
                  set -l label $labels[$i]
                  set i (math $i + 1)

                  # A host may legitimately carry only the read-only file; agent-env
                  # is what makes that case safe. Absent is not a finding.
                  if not test -f $f
                      continue
                  end

                  # Local file parse only -- no cluster contact, so this is safe on a
                  # plane with no VPN up.
                  set -l have (kubectl config get-contexts -o name --kubeconfig $f 2>/dev/null)

                  set -l missing
                  for e in $expected
                      contains -- $e $have
                      or set -a missing $e
                  end
                  set -l extra
                  for h in $have
                      contains -- $h $expected
                      or set -a extra $h
                  end

                  if test (count $missing) -gt 0; or test (count $extra) -gt 0
                      set rc 1
                      echo "kube-context-check: $label kubeconfig $f" >&2
                      if test (count $missing) -gt 0
                          echo "    missing:    "(string join ', ' $missing) >&2
                      end
                      if test (count $extra) -gt 0
                          echo "    unexpected: "(string join ', ' $extra) >&2
                      end
                  end
              end

              return $rc
            '';
          };

          kctx = {
            description = "Show current cluster identity (🔴 admin / 🟢 read-only)";
            body = ''
              set -l who (kubectl auth whoami -o jsonpath='{.status.userInfo.username}' 2>/dev/null)
              set -l cctx (kubectl config current-context 2>/dev/null)
              if test -z "$who"
                  echo "⚪ no reachable cluster context" >&2
                  return 1
              end
              switch $who
                  case system:admin
                      echo "🔴 $cctx = ADMIN ($who)"
                  case '*'
                      echo "🟢 $cctx = $who"
              end
            '';
          };
        };
      })

      # -------------------------------------------------------------------------
      # Startup validation. Runs once per interactive shell, from the same
      # interactiveShellInit home-manager already guards with `status
      # is-interactive`, so ssh/scp sessions stay silent. Quiet unless something is
      # misaligned -- a name that drifted is the only output.
      # -------------------------------------------------------------------------
      (lib.mkIf cfg.checkContextsOnStartup {
        programs.fish.interactiveShellInit = ''
          # Guard: the check shells out to kubectl twice. On a host where the k8s
          # CLI is not installed (see base.nix skipK8sTools) that would print an
          # error on every prompt instead of checking nothing.
          #
          # `or true` is load-bearing. home-manager emits this inside
          # `status is-interactive; and begin ... end`, so a non-zero return here
          # becomes $status for the first prompt and starship would draw a failed
          # exit for a shell that did nothing wrong. The warning above is the whole
          # point at startup; the exit code is for interactive use.
          if type -q kubectl
              kube-context-check
              or true
          end
        '';
      })

      # Guard against enabling this on a host that has not had its kubeconfig
      # split. It has to live inside the mkIf *content*: `mkIf c X // { ... }`
      # merges the update into the { _type = "if"; condition; content; } wrapper
      # rather than into X, so the module system never collects it (verified:
      # config.warnings stayed [ ] with the `//` form).
      {
        warnings = [
          ''
            kubeSegregation is enabled. This assumes ${cfg.readOnlyKubeconfig} contains
            READ-ONLY credentials and ${cfg.adminKubeconfig} holds the privileged ones.
            If that split has not been done on this host, the default is not actually
            read-only — agent-env will still fail closed, but the fallback is not safe.
          ''
        ];
      }
    ]
  );
}
