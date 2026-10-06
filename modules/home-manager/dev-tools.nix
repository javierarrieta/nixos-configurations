{
  config,
  pkgs,
  pkgsUnfree,
  lib,
  userOptions,
  herdrPkg,
  piPkg,
  agentSkills,
  ...
}:

let
  configOnly = userOptions.configOnly or false;

  # ---- JDK ------------------------------------------------------------
  # Per-host overrides live in that host's userOptions.nix under `jdk`.
  jdkCfg = userOptions.jdk or { };

  # Opt a host out of the Nix-provided JDK with `jdk.enable = false` in its
  # userOptions.nix, for a machine where a JDK manager outside Nix owns
  # Java. Why the flag exists: such a manager (SDKMAN on oracle) switches
  # versions by rewriting JAVA_HOME and PATH in the shell, but Home Manager
  # re-exports its own session variables into every new shell, so `sdk use
  # java ...` is undone by the next prompt. Package and JAVA_HOME therefore
  # move together -- a host that opts out must keep neither, or `java` on
  # PATH and $JAVA_HOME name two different JDKs and gradle, maven and sbt
  # silently build against the Nix one.
  jdkEnable = jdkCfg.enable or true;

  # ---- pi coding agent -------------------------------------------------
  # Extracted from this machine's ~/.pi/agent on 2026-09-25.
  #
  # Why an activation merge instead of `home.file`: pi rewrites
  # settings.json itself -- /model, `pi install`, the compaction and retry
  # toggles all end in a writeFileSync -- so a symlink into the read-only
  # store breaks those paths. The activation step below merges the declared
  # JSON over whatever pi left on disk, declared keys winning, so the repo
  # stays the source of truth without making the file unwritable.
  #
  # Deliberately NOT declared:
  #   * lastChangelogVersion -- pi's own runtime bookkeeping.
  #   * ~/.pi/agent/auth.json -- holds the real openrouter/google API keys.
  #     Never render it from Nix and never commit it; keep using `pi login`
  #     (or wire sops-nix's homeManagerModules if it must be declarative).
  #   * trust.json -- per-checkout project trust, resolved at runtime.
  jsonFormat = pkgs.formats.json { };

  # Per-host overrides live in that host's userOptions.nix under `pi`.
  piCfg = userOptions.pi or { };

  # Opt a host out of pi entirely with `pi.enable = false` in its
  # userOptions.nix. Why the flag exists: pi.cachix.org only carries
  # x86_64-linux NARs -- upstream's sole cache push is a ubuntu-latest
  # cron -- so every Mac compiles the bun2nix build from source, and that
  # build fetches its npm tarballs at build time. On a network that will
  # not serve registry.npmjs.org (oracle's returns 403 for
  # @anthropic-ai/sandbox-runtime) the whole home generation becomes
  # unbuildable. A host that will never run pi should opt out rather than
  # depend on a working npm egress; the flag drops the package, the
  # vendored skills and the agent config together, so nothing pi-shaped is
  # left behind. configOnly hosts are unaffected: they never took the
  # package, and they leave this flag alone.
  piEnable = piCfg.enable or true;

  piSettings = {
    theme = "dark";
    defaultProvider = "llm01-halogen";
    defaultModel = "halogen-qwen3.8-flash-next";
    compaction = {
      enabled = true;
      reserveTokens = 65536;
    };
    # Pinned to the versions this machine had installed. pi auto-installs these
    # into ~/.pi/agent/{npm,git} on startup; the array is replaced wholesale on
    # every switch, so a runtime `pi install` does not survive a rebuild -- add
    # it here instead.
    #
    # pi-web-access >= 0.36.0 and pi-subagents >= 0.76.0 are the first releases
    # that declare `typebox` under peerDependencies instead of dependencies.
    # The older pins (0.31.0 / 0.71.0) install a physical copy of typebox, which
    # pi rejects with an extension warning at every startup: a bundled copy can
    # bypass pi's extension module mapping and duplicate its runtime classes.
    # Do not downgrade past these.
    packages = [
      "npm:pi-web-access@0.36.0"
      "npm:pi-subagents@0.76.0"
      # Installed on the coder workspace with `pi install` and in use there; it
      # has to be declared because the wholesale array replacement above would
      # otherwise drop it on the next switch.
      "npm:@penumbral-labs/pi-copy-code@0.4.0"
      # superpowers v6.4.1
      "git:github.com/obra/superpowers@5bf4e78011075bcfc0dc295f0724994cd123ee71"
    ];
  };

  piModels = {
    providers = {
      llm01-halogen = {
        # Default is llm01's LAN address. The halogen API runs with
        # `--network=host` and binds 0.0.0.0 on the published port, so any
        # host on the LAN (or VPN) reaches it here. Override per machine via
        # `pi.baseUrl` in that host's userOptions.nix -- the coder workspaces
        # do, because `host.containers.internal` is the podman gateway and is
        # cheaper than hairpinning out to the LAN address from inside the
        # container.
        baseUrl = piCfg.baseUrl or "http://192.168.0.29:8731/v1";
        api = "openai-completions";
        # The endpoint is unauthenticated; pi requires the field to be present.
        apiKey = "dummy";
        compat = {
          supportsDeveloperRole = false;
          supportsReasoningEffort = true;
        };
        models = [
          {
            id = "halogen-qwen3.8-flash-next";
            name = "Qwen3.8-Flash-Next (halogen, llm01)";
            contextWindow = 262144;
            maxTokens = 65536;
          }
        ];
      };
    };
  };

  piSettingsFile = jsonFormat.generate "pi-settings.json" piSettings;
  piModelsFile = jsonFormat.generate "pi-models.json" piModels;

  # Skills vendored from their upstream repos into pi's personal skills dir.
  # These used to be installed imperatively with the `skills` CLI, which left
  # ~/.agents/skills plus a .skill-lock.json nothing in this repo could
  # reproduce. The name list is explicit rather than a directory glob so a skill
  # added upstream cannot silently join the agent's routing table on a flake
  # update.
  #
  # pi scans ~/.agents/skills as well as ~/.pi/agent/skills (Agent Skills
  # layout), and a name collision keeps the first hit and warns on every start.
  # The ~/.agents/skills copies were byte-identical to these except for
  # cocoindex, where they were an older upstream revision, so they were dead
  # weight that only produced 28 startup warnings; they were removed on
  # 2026-10-05 and must stay removed. Re-run `ls ~/.agents` if the warnings come
  # back -- an old `skills` CLI install on another host recreates them there.
  #
  # One layout rule for every entry: <input>/skills/<name>. For the flake inputs
  # `input` is the upstream repo root; for cocoindex it is a repo-root mirror
  # committed under vendor/, so the same rule applies and no per-entry override
  # is needed.
  piVendoredSkills = [
    {
      input = agentSkills.caveman;
      origin = "JuliusBrussee/caveman";
      names = [
        "cavecrew"
        "caveman"
        "caveman-commit"
        "caveman-compress"
        "caveman-discover"
        "caveman-evidence-review"
        "caveman-explore"
        "caveman-help"
        "caveman-learn"
        "caveman-manage"
        "caveman-optimize"
        "caveman-review"
        "caveman-setup"
        "caveman-stats"
        "investigate-first"
        "lean-build"
        "migration"
        "safe-refactor"
        "surgical-patch"
        "verify-and-stop"
      ];
    }
    {
      input = agentSkills.gitguardian;
      origin = "gitguardian/agent-skills";
      names = [
        "check-hmsl"
        "create-honeytokens"
        "install-hooks"
        "scan-machine"
        "scan-secrets"
        "triage-incidents"
      ];
    }
    {
      input = agentSkills.vercel;
      origin = "vercel-labs/skills";
      names = [ "find-skills" ];
    }
    {
      # Vendored in-repo rather than as a flake input: cocoindex-io/cocoindex is a
      # ~114MB framework repo, and a `flake = false` input would fetch all of it
      # on every `nix flake update` to reach one skill folder. vendor/cocoindex/
      # mirrors that repo's root so the shared <input>/skills/<name> rule holds.
      input = ../../vendor/cocoindex;
      origin = "cocoindex-io/cocoindex";
      names = [ "cocoindex" ];
    }
  ];

  # Every name pi owns. Used both to build home.file and by the activation
  # pruner below, which treats anything outside this list as drift.
  piSkillNames = lib.flatten (map (s: s.names) piVendoredSkills);

  piSkillFiles = builtins.listToAttrs (
    lib.flatten (
      map (
        s:
        map (
          n:
          lib.nameValuePair ".pi/agent/skills/${n}" {
            source = "${s.input}/skills/${n}";
            # force: these paths already exist as unmanaged symlinks left by the
            # `skills` CLI, which Home Manager would otherwise refuse to replace.
            force = true;
          }
        ) s.names
      ) piVendoredSkills
    )
  );
in
{
  # Development toolchains and editor config. The everyday CLI niceties
  # (curl, tmux, ripgrep, fzf, bat, eza, difftastic, dyff, gh, fastfetch)
  # live in ./cli-tools.nix instead, because they are installed on every
  # host while this module is skipped on the k8s fleet.
  home.packages = lib.mkIf (!configOnly) (
    with pkgs;
    [
      htop
      git
      wget
      btop
      yq
      jq
      rustup
      bash
      zsh
      age
      sops
      nixfmt
      nixfmt-tree
      kubernetes-helm
      scala-cli
      pstree
      lsof
      binutils
      nodejs_24
      bun

      # Terminal-native runtime for AI coding agents. Comes from the
      # `herdrPkg` special arg (prebuilt release binary via the herdr-nix
      # flake) rather than `pkgs`, so no Rust/Zig build lands on any host.
      herdrPkg

      pkgsUnfree.coder
    ]
    # pi comes from the `piPkg` special arg (bun2nix build of upstream
    # earendil-works/pi) because `pi-coding-agent` is absent from
    # nixos-26.05. It stays gated with the rest of this module: on configOnly
    # hosts (the coder workspaces) pi is installed by hand, because its
    # closure pulls dns-root-data -- a root-owned, DB-unregistered leftover
    # of the workspace image's /nix/store that Nix cannot replace as uid
    # 1000. The agent *config* and the vendored skills below stay ungated
    # for exactly that reason, and follow `piEnable` instead.
    ++ lib.optionals piEnable [ piPkg ]
    # The JDK is gated separately because a host may manage Java outside
    # Nix -- see `jdkEnable` above.
    ++ lib.optionals jdkEnable [ jdk21 ]
  );

  # Vendored skills -- see `piVendoredSkills` above. They route to pi, so
  # they go when pi does; Home Manager unlinks the ones it managed.
  home.file = lib.mkIf piEnable piSkillFiles;

  # The agent config is rendered even on configOnly hosts: those hosts get the
  # pi binary from the workspace image, but settings and model definitions
  # still come from here. Merged over the on-disk JSON rather than symlinked --
  # see the note on `piSettings` above. Wrapped as a set so `piEnable = false`
  # removes the activation entry outright instead of leaving an empty one.
  home.activation = lib.mkIf piEnable {
    piAgentConfig =
      lib.hm.dag.entryAfter [ "writeBoundary" ] # bash
        ''
          _pi_agent_dir="${config.home.homeDirectory}/.pi/agent"
          _pi_jq="${lib.getExe pkgs.jq}"
          mkdir -p "$_pi_agent_dir"

          _merge_pi_json() {
            _declared="$1"
            _target="$2"
            # A leftover home.file symlink would make the merge write into the store.
            if [ -L "$_target" ]; then
              rm -f "$_target"
            fi
            _tmp="$(mktemp "$_target.XXXXXX")"
            if [ -f "$_target" ]; then
              if ! $_pi_jq -s '.[0] * .[1]' "$_target" "$_declared" > "$_tmp"; then
                rm -f "$_tmp"
                echo "piAgentConfig: failed to merge $_target, leaving it untouched" >&2
                return 0
              fi
            else
              cp "$_declared" "$_tmp"
            fi
            chmod 0644 "$_tmp"
            if cmp -s "$_tmp" "$_target" 2>/dev/null; then
              rm -f "$_tmp"
            else
              mv "$_tmp" "$_target"
            fi
          }

          _merge_pi_json "${piSettingsFile}" "$_pi_agent_dir/settings.json"
          _merge_pi_json "${piModelsFile}" "$_pi_agent_dir/models.json"

          # Unmanaged skills must not be present. A SKILL.md backed by no flake
          # input joins the model's routing table silently, and cannot be
          # reproduced or reviewed from this repo -- that is how 21 supipowers
          # copies and 2 frontmatter-less ones ended up in ~/.pi/agent/skills,
          # the latter failing every start with "description is required".
          # Prune the dir down to the declared set; a hand-written skill has to
          # go into piVendoredSkills to survive a switch.
          #
          # Runs in a subshell with cd so the glob yields bare names: a Nix
          # indented string interpolates dollar-brace, so the usual bash
          # parameter expansion to strip a directory prefix is not available.
          _pi_skill_names=" ${lib.concatStringsSep " " piSkillNames} "
          if [ -d "$_pi_agent_dir/skills" ]; then
            (
              cd "$_pi_agent_dir/skills" || exit 0
              for _n in *; do
                [ -e "$_n" ] || continue
                case "$_pi_skill_names" in *" $_n "*) continue ;; esac
                echo "piAgentConfig: removing unmanaged skill $_pi_agent_dir/skills/$_n" >&2
                rm -rf "$_n"
              done
            )
          fi

          # Same for the legacy `skills` CLI layout: pi scans ~/.agents/skills
          # too, so any copy of a name we own there is a collision warning on
          # every start and dead weight besides -- pi keeps the ~/.pi copy.
          _pi_legacy="${config.home.homeDirectory}/.agents"
          if [ -d "$_pi_legacy/skills" ]; then
            (
              cd "$_pi_legacy/skills" || exit 0
              for _n in *; do
                [ -e "$_n" ] || continue
                case "$_pi_skill_names" in
                  *" $_n "*)
                    echo "piAgentConfig: removing legacy copy $_pi_legacy/skills/$_n" >&2
                    rm -rf "$_n"
                    ;;
                esac
              done
            )
          fi
          if [ -e "$_pi_legacy/.skill-lock.json" ]; then
            echo "piAgentConfig: removing legacy $_pi_legacy/.skill-lock.json" >&2
            rm -f "$_pi_legacy/.skill-lock.json"
          fi
        '';
  };

  # JVM tooling (gradle, maven, sbt, some IDE integrations) resolves the JDK
  # through JAVA_HOME rather than `java` on PATH, so point it at the same
  # derivation that provides the binaries. `pkgs.jdk21` is openjdk on Linux
  # and zulu-ca on aarch64-darwin; both are cached for these systems.
  # Follows `jdkEnable`: a host whose JDK comes from outside Nix must not
  # have JAVA_HOME pinned here, or it overrides that manager on every shell.
  home.sessionVariables = lib.mkIf (!configOnly && jdkEnable) {
    JAVA_HOME = "${pkgs.jdk21}";
  };

  programs.neovim = lib.mkIf (!configOnly) {
    enable = true;
    defaultEditor = true;
    viAlias = true;
    withPython3 = false;
    withRuby = false;
  };
}
