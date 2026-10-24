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
  # Why the agent config is written by an activation step rather than
  # `home.file`: the two files it owns have opposite requirements, and treating
  # them alike is what broke pi on the titan workspaces.
  #
  #   settings.json  pi writes this itself -- /model, `pi install`, the
  #                  compaction and retry toggles all end in a writeFileSync --
  #                  so it has to stay writable. It is merged: declared keys
  #                  win, pi's own keys survive.
  #   models.json    pi only reads this one (/model reloads it, docs/models.md).
  #                  Nothing writes it, so it is a plain symlink into the store
  #                  and therefore read-only.
  #
  # The rule both follow: nothing gets rewritten without saying so. The merge
  # names the keys it overwrote and keeps the copy it replaced; the link refuses
  # an edit at the moment it is attempted instead of silently at the next switch.
  # A writable file that activation overwrites quietly is the worst of both --
  # that is how a hand-edited models.json looked fixed for hours and then
  # reverted, with no error anywhere.
  #
  # Deliberately NOT declared:
  #   * lastChangelogVersion -- pi's own runtime bookkeeping.
  #   * ~/.pi/agent/auth.json -- holds the real openrouter/google API keys.
  #     Never render it from Nix and never commit it; keep using `pi login`
  #     (or wire sops-nix's homeManagerModules if it must be declarative).
  #   * trust.json -- per-checkout project trust, resolved at runtime.
  #
  # Extensions are declared, and linked like models.json: pi reads them and never
  # writes them, so a hand-edit of ~/.pi/agent/extensions/*.ts was drift a switch
  # would not mention. See `piExtensionNames` below.
  jsonFormat = pkgs.formats.json { };

  # Per-host overrides live in that host's userOptions.nix under `pi`.
  piCfg = userOptions.pi or { };

  # Opt a host out of pi entirely with `pi.enable = false` in its
  # userOptions.nix. Why the flag exists: upstream's flake publishes no
  # binary cache, so every host compiles the npm workspace from source, and
  # that build fetches its npm tarballs at build time. On a network that will
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

  # Machine-local providers a host declares under `pi.extraProviders` in its
  # userOptions.nix, merged into `piModels.providers` below (a same-named key
  # replaces the declared provider wholesale).
  #
  # Why the hook exists: models.json is a *read-only symlink* into the store (see
  # `_link_pi_json` below), so an endpoint that only exists on one box -- an omlx
  # server on 127.0.0.1 on the laptop -- has no other place to live. Before the
  # link it was a hand-edit of ~/.pi/agent/models.json, and the link change
  # silently dropped those edits (they survive only as models.json.pre-link).
  # Anything machine-local now has to be declared here to be seen by pi.
  piExtraProviders = piCfg.extraProviders or { };

  piModels = {
    providers = {
      llm01-halogen = {
        # Default is llm01's LAN address. The halogen API runs with
        # `--network=host` and binds 0.0.0.0 on the published port, so any
        # host on the LAN (or VPN) reaches it here. Override per machine via
        # `pi.baseUrl` in that host's userOptions.nix.
        #
        # Two hosts override it, and they are the two coder workspace attributes:
        # `coder-workspace` (llm01 podman) points at `host.containers.internal`,
        # the podman gateway, which is cheaper than hairpinning out to the LAN
        # address from inside the container. The titan workspaces reach this same
        # address over the mesh, so they could take the default, but they name it
        # explicitly instead to keep the mesh route next to the thing that depends
        # on it; see home/hosts/coder-workspace-titan/userOptions.nix.
        #
        # No runtime autodetection on purpose. This file is merged over
        # ~/.pi/agent/models.json with the declared value winning, so whatever
        # baseUrl Nix chose at eval time is authoritative on every switch. A value
        # picked at activation time would either be overwritten on the next switch
        # or overwrite nothing, and both fail silently into a pi that cannot reach
        # its model.
        baseUrl = piCfg.baseUrl or "http://192.168.0.29:8731/v1";
        api = "openai-completions";
        # The LAN endpoint is unauthenticated; pi requires the field to be present.
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
            # The endpoint serves a reasoning model, but pi only exposes
            # thinking levels when this flag is set: getSupportedThinkingLevels()
            # returns ["off"] for a model without `reasoning`, so /thinking showed
            # nothing else. `compat.supportsReasoningEffort` above only controls
            # whether a reasoning_effort is sent at all -- it does not make the
            # levels selectable.
            reasoning = true;
            # The map does two jobs, both verified against the live server
            # (`curl http://192.168.0.29:8731/health`):
            #   * `off -> "none"` -- the server's own value for no reasoning.
            #     Its `reasoning_effort_default` is "xhigh", and with no map pi
            #     sends no reasoning_effort when the level is off, so the server
            #     default would win and "off" would still think hard. Measured
            #     against the running server: reasoning_effort=none -> 0
            #     reasoning tokens; every other level -> nonzero (the count
            #     tracks the prompt and the server's answer-room cap).
            #   * `xhigh`/`max` -- pi lists these two only when the map defines
            #     them, and the server accepts both in its
            #     `reasoning_effort_values` (["high","low","max","medium",
            #     "minimal","none","xhigh"]). The other levels pass through
            #     unmapped: pi's level names are already the server's names.
            thinkingLevelMap = {
              off = "none";
              xhigh = "xhigh";
              max = "max";
            };
            # llm01's halogen runs with HALOGEN_VISION_TOWER=1 (vision sidecar),
            # so /v1 accepts image content parts. Without this pi treats the
            # model as text-only and never attaches images.
            input = [
              "text"
              "image"
            ];
          }
        ];
      };
    }
    # Opt-in second route to the same endpoint, for a machine that is neither on llm01's LAN nor on
    # the WireGuard mesh -- the two MacBooks. Declared by setting `pi.publicApiKey` in that host's
    # userOptions.nix; a host that does not set it gets no public provider at all, which is right for
    # the coder workspaces and llm01 itself, where the LAN or mesh route is always available and a
    # second one is just another way to leave the network.
    #
    # There is no automatic failover anywhere here: pi does not try a second provider when one is
    # unreachable, so the away-and-still-on-the-LAN-provider symptom is a request that hangs until it
    # times out, not a clean error. The user picks it with /model, deliberately.
    #
    # The key is never in this repo and never in Nix: the repo is public and the store is
    # world-readable and keeps every copy forever. A host passes pi's `!command` form, which reads it
    # from the macOS login keychain at request time and is not cached. Provisioning is one manual
    # step outside git, which is the point -- a Nix activation cannot create it:
    #   security add-generic-password -a javier -s llm-titan -U -w
    #
    # Derived from the provider above rather than copied. `id` is what pi sends as the request's model
    # name, so the two routes cannot declare different ids, and compat, thinkingLevelMap and the vision
    # `input` all have to match the LAN route exactly -- a copy would be a second thing to keep in
    # sync, and the two MacBooks are already two hosts to keep in sync. The self-reference is safe
    # because `//` forces only the keys of its right-hand attrset: `llm01-halogen`'s value is reached
    # without forcing this branch's value, so nothing here is circular.
    #
    # `/v1` is load-bearing. pi appends /chat/completions to baseUrl, so a bare host asks halogen for
    # /chat/completions and gets `404 not_found_error` from uvicorn -- an auth-shaped symptom from a
    # path-shaped mistake, because the forwardAuth answers `401` first and a `404` therefore means the
    # credential was already accepted and the route is wrong.
    // lib.optionalAttrs (piCfg.publicApiKey or "" != "") {
      llm01-halogen-public = piModels.providers.llm01-halogen // {
        baseUrl = "https://llm.titan.arrieta.eu/v1";
        apiKey = piCfg.publicApiKey;
        # Only the display name differs. pi's /model list shows `name`, so two identical names for
        # two routes would be a guessing game; `id` stays identical because it is what goes on the
        # wire.
        models = map (
          m:
          m
          // {
            name = m.name + " (via titan)";
          }
        ) piModels.providers.llm01-halogen.models;
      };
    }
    // piExtraProviders;
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
  # 2026-10-05 and must stay removed -- the activation pruner below deletes any
  # copy of these names that reappears there and reports the ones it does not
  # recognise. Re-run `ls ~/.agents/skills` if the warnings come back -- an old
  # `skills` CLI install on another host recreates them there.
  #
  # One layout rule for every entry: <input>/skills/<name>. For the flake inputs
  # `input` is the upstream repo root; for cocoindex it is a repo-root mirror
  # committed under vendor/, so the same rule applies and no per-entry override
  # is needed. `root = true` is the one escape hatch, for upstreams that put
  # SKILL.md at the repo root instead of under skills/<name>/.
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
      # Rewrites dense English into ASD-STE100 Simplified Technical English for
      # text a machine must parse without a human (tool descriptions, error
      # messages, inter-agent instructions). Ships a python linter alongside.
      input = agentSkills.asd-ste100;
      origin = "danyuchn/asd-ste100-skill";
      # Single-skill repo: SKILL.md, references/, scripts/ sit at the root.
      root = true;
      names = [ "asd-ste100" ];
    }
    {
      # Fish-shell-scripting guidance from porada/domfiles. The upstream repo is a
      # multi-skill monorepo (skills/<name>/ for all twelve), so the shared layout
      # rule applies and no per-entry override is needed. Its default branch is
      # `master`, so the flake input carries no ref.
      #
      # This one matters for hand-over commands: AGENTS.md records that every
      # command handed to the operator is pasted into fish, and bashisms fail in
      # ways that look like the task failing rather than the shell. The skill
      # makes that failure mode a routed concern instead of a remembered rule.
      input = agentSkills.domfiles;
      origin = "porada/domfiles";
      names = [ "fish-shell-scripting" ];
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

  # Skills that must be visible to more than pi, as symlinks in
  # ~/.agents/skills -- the cross-agent Agent Skills location pi scans as a user
  # skill root, and the one Codex reads as well.
  #
  # superpowers is deliberately *not* in piVendoredSkills: it ships as a pi
  # package, pinned in `piSettings.packages` above, and pi's package manager
  # checks it out under ~/.pi/agent/git/github.com/obra/superpowers. Pointing
  # ~/.agents/skills/superpowers at that checkout instead of keeping a second
  # clone is what makes it quiet. pi loads skills by canonical path and silently
  # skips a file it has already loaded through another path, so one file behind
  # two scan roots costs nothing; two *different* files with the same skill name
  # produce a collision warning per skill per start, and the copy pi happens to
  # scan first wins the routing table. That is what sat here until 2026-10-24: a
  # `skills`-CLI-era clone at ~/.codex/superpowers, symlinked into ~/.agents, at
  # v6.2.0, beating the v6.4.1 pin declared above. Every pin bump since August
  # was decorative and nothing on the machine said so.
  #
  # The target is derived from the pin rather than written out again: a pin that
  # moves to a mirror or another owner has to move the link with it, or the link
  # quietly keeps serving the old checkout and nothing between two switches
  # notices. pi keys its git checkouts by host/owner/repo, not by rev, so a rev
  # bump moves the contents and leaves the path alone.
  #
  # The target is a runtime directory pi creates on startup, not a store path, so
  # this cannot be a `home.file` entry -- that would copy the tree into the store
  # and freeze it against the pin. The activation step below makes the link.
  piSuperpowersPackage = lib.findFirst (
    p: lib.hasPrefix "git:github.com/obra/superpowers@" p
  ) null piSettings.packages;

  piSharedAgentSkillLinks = lib.optionals (piSuperpowersPackage != null) [
    {
      name = "superpowers";
      target =
        let
          # "git:github.com/obra/superpowers@<rev>" -> "github.com/obra/superpowers"
          repo = builtins.head (lib.splitString "@" (lib.removePrefix "git:" piSuperpowersPackage));
        in
        "${config.home.homeDirectory}/.pi/agent/git/${repo}/skills";
    }
  ];
  piSharedAgentSkillNames = map (l: l.name) piSharedAgentSkillLinks;

  # Links into *other* agents' own skill dirs, by absolute path.
  #
  # Different from the shared links above in one way that matters: pi's module
  # does not get to create another agent's home. `require-parent` below skips
  # these silently when the agent's directory is absent, so a host without Codex
  # does not grow a ~/.codex because of a pi change. Nothing here prunes those
  # dirs -- Codex's own skill-installer writes there, and this repo cannot tell
  # its installs from drift.
  #
  # find-skills is here because it had been hand-made drift: the link pointed at
  # ~/.agents/skills/find-skills, which the 2026-10-05 legacy cleanup deleted, so
  # Codex had been silently missing the skill for weeks and no file in this repo
  # said anything about it. The target is now the store-backed vendored copy pi
  # uses -- same content, and it survives a switch.
  piForeignAgentSkillLinks = [
    {
      # Codex's personal skill dir. It also holds ~/.codex/skills/.system, which
      # is Codex's own and is never touched from here.
      path = "${config.home.homeDirectory}/.codex/skills/find-skills";
      target = "${config.home.homeDirectory}/.pi/agent/skills/find-skills";
    }
  ];

  # Shell for the activation entry below: one `_pi_skill_link` call per declared
  # link. Bound here rather than inlined because the activation string is an
  # indented literal and nested indentation inside it reads badly.
  piSkillLinkCommands =
    lib.concatMapStrings
      (l: ''
        _pi_skill_link "${l.path}" "${l.target}"${l.extra or ""}
      '')
      (
        map (l: {
          path = "${config.home.homeDirectory}/.agents/skills/${l.name}";
          inherit (l) target;
        }) piSharedAgentSkillLinks
        ++ map (l: {
          inherit (l) path target;
          extra = " require-parent";
        }) piForeignAgentSkillLinks
      );

  piSkillFiles = builtins.listToAttrs (
    lib.flatten (
      map (
        s:
        map (
          n:
          lib.nameValuePair ".pi/agent/skills/${n}" {
            source = if s.root or false then "${s.input}" else "${s.input}/skills/${n}";
            # force: these paths already exist as unmanaged symlinks left by the
            # `skills` CLI, which Home Manager would otherwise refuse to replace.
            force = true;
          }
        ) s.names
      ) piVendoredSkills
    )
  );
  # pi extensions this repo owns, linked read-only into ~/.pi/agent/extensions.
  # Unlike settings.json these are never written by pi, so a link is honest: the
  # edit fails where it is attempted instead of disappearing on the next switch.
  # A hand-written extension has to be listed here (and vendored under
  # ./pi/extensions/) to survive a switch; the activation step below names any it
  # does not declare.
  piExtensionNames = [ "compaction-inkling.ts" ];

  piExtensionFiles = builtins.listToAttrs (
    map (
      n:
      lib.nameValuePair ".pi/agent/extensions/${n}" {
        source = ./pi/extensions/${n};
        # The live ~/.pi/agent/extensions entries were hand-written regular files
        # before this was declared; Home Manager refuses to replace anything that
        # is not its own symlink without this.
        force = true;
      }
    ) piExtensionNames
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
    # pi comes from the `piPkg` special arg (upstream's own flake; see the `pi`
    # input) because nixos-26.05 freezes pi-coding-agent at an old release. It
    # stays gated with the rest of this module: on configOnly
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
  home.file = lib.mkIf piEnable (piSkillFiles // piExtensionFiles);

  # The agent config is rendered even on configOnly hosts: those hosts get the
  # pi binary from the workspace image, but settings and model definitions
  # still come from here. settings.json is merged, models.json is linked -- see
  # the note on `piSettings` above for why they differ. Wrapped as a set so
  # `piEnable = false` removes the activation entry outright instead of leaving
  # an empty one.
  home.activation = lib.mkIf piEnable {
    piAgentConfig =
      lib.hm.dag.entryAfter [ "writeBoundary" ] # bash
        ''
          _pi_agent_dir="${config.home.homeDirectory}/.pi/agent"
          _pi_jq="${lib.getExe pkgs.jq}"
          mkdir -p "$_pi_agent_dir"

          # settings.json -- merged, because pi writes this file itself. Loud by
          # construction: whenever the merge changes the file it names the keys it
          # overwrote and the local-only keys it preserved, and keeps the copy it
          # replaced at settings.json.pre-hm.
          _merge_pi_json() {
            _declared="$1"
            _target="$2"
            # A leftover home.file symlink would make the merge write into the store.
            if [ -L "$_target" ]; then
              rm -f "$_target"
            fi
            _tmp="$(mktemp "$_target.XXXXXX")"
            # -S on every write, not just on read: the change test below compares
            # bytes, so if the merged output were only as canonical as jq happened
            # to print it, a reflowed declared file would read as a change on
            # every single switch and the log would become noise. Canonicalising
            # on the way in makes the comparison about content, and a legacy
            # non-canonical file self-heals on the first switch instead of
            # reporting itself as changed forever after.
            if [ -f "$_target" ]; then
              if ! $_pi_jq -s -S '.[0] * .[1]' "$_target" "$_declared" > "$_tmp"; then
                rm -f "$_tmp"
                echo "piAgentConfig: failed to merge $_target, leaving it untouched" >&2
                return 0
              fi
            else
              if ! $_pi_jq -S . "$_declared" > "$_tmp"; then
                rm -f "$_tmp"
                echo "piAgentConfig: cannot read the declared $_declared, leaving it untouched" >&2
                return 0
              fi
            fi
            chmod 0644 "$_tmp"
            if cmp -s "$_tmp" "$_target" 2>/dev/null; then
              rm -f "$_tmp"
              return 0
            fi
            if [ -f "$_target" ]; then
              # `keys[] as $k` rather than `keys[] | select(... . ...)`: after the
              # pipe the dot is the key, so `$b | has(.)` silently reads as
              # `has($b)` and the filter passes everything. Binding $k keeps both
              # sides of the comparison explicit -- and the trailing `| $k` is not
              # decoration: `select` passes its *input* through, not the variable
              # it was given, so without it the array collects whole objects and
              # join() fails. No 2>/dev/null here either: a report that cannot be
              # computed should say so on stderr, not quietly print "none", which
              # is the silence this whole change exists to remove. The `|| _x=""`
              # only keeps set -e from aborting the switch over a cosmetic line.
              _over="$($_pi_jq -s -r '. as [$a, $b] | [ $b | keys[] as $k | select(($a | has($k)) and ($a[$k] != $b[$k])) | $k ] | join(" ")' "$_target" "$_declared")" || _over=""
              _kept="$($_pi_jq -s -r '. as [$a, $b] | [ $a | keys[] as $k | select(($b | has($k)) | not) | $k ] | join(" ")' "$_target" "$_declared")" || _kept=""
              if [ -z "$_over" ]; then _over=none; fi
              if [ -z "$_kept" ]; then _kept=none; fi
              cp -p "$_target" "$_target.pre-hm"
              echo "piAgentConfig: $_target updated -- declared over: $_over; local-only kept: $_kept; previous copy at $_target.pre-hm" >&2
            else
              echo "piAgentConfig: $_target created from the declared copy" >&2
            fi
            mv "$_tmp" "$_target"
          }

          # models.json -- linked, not merged. pi only reads this one, so merging
          # bought nothing and left a writable file that every switch overwrote
          # without a word. A symlink into the store is read-only: an edit now
          # fails where it is made, not silently on the next activation.
          #
          # The one thing this trades away, stated plainly: if pi ever starts
          # writing models.json -- a /model save, or the Radius gateway metadata
          # cache providers.md mentions -- it fails with EACCES instead of
          # quietly winning. Neither path is reachable from the providers declared
          # here, and a hard failure is the better default for a file this repo
          # already owns outright.
          _link_pi_json() {
            _declared="$1"
            _target="$2"
            if [ -L "$_target" ]; then
              if [ "$(readlink "$_target")" = "$_declared" ]; then
                return 0
              fi
              echo "piAgentConfig: relinking read-only $_target -> $_declared" >&2
              rm -f "$_target"
            elif [ -e "$_target" ]; then
              # Migration from the merged-regular-file layout. Worth a backup only
              # if there is local content in it to lose; byte comparison, so a
              # merely reflowed file still gets one rather than vanishing.
              if ! cmp -s "$_target" "$_declared"; then
                cp -p "$_target" "$_target.pre-link"
                echo "piAgentConfig: $_target held content the flake does not declare; kept at $_target.pre-link" >&2
              fi
              echo "piAgentConfig: $_target is now a read-only link to the declared copy -- change the flake, not this file" >&2
              rm -f "$_target"
            fi
            ln -s "$_declared" "$_target"
          }

          _merge_pi_json "${piSettingsFile}" "$_pi_agent_dir/settings.json"
          _link_pi_json "${piModelsFile}" "$_pi_agent_dir/models.json"

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

          # Same rule for extensions, but reported instead of deleted: an
          # extension is code somebody wrote, and rm -rf on switch is the wrong
          # first move for something this repo only just started declaring. Add the
          # file to piExtensionNames (and vendor it under ./pi/extensions/) to
          # silence the line.
          _pi_extension_names=" ${lib.concatStringsSep " " piExtensionNames} "
          if [ -d "$_pi_agent_dir/extensions" ]; then
            (
              cd "$_pi_agent_dir/extensions" || exit 0
              for _n in *; do
                [ -e "$_n" ] || continue
                case "$_pi_extension_names" in *" $_n "*) continue ;; esac
                echo "piAgentConfig: undeclared pi extension $_pi_agent_dir/extensions/$_n -- vendor it under modules/home-manager/pi/extensions/ and add it to piExtensionNames" >&2
              done
            )
          fi

          # ~/.agents/skills: the cross-agent Agent Skills layout. pi scans it as
          # a user skill root and Codex reads it too, so this repo does not own the
          # directory outright -- an entry pi does not declare may belong to Codex.
          # The rule is therefore the narrow one, and matches the extensions rule
          # above: delete only what collides with a name pi vendors, report the
          # rest. Shared links are skipped here because the step below owns them.
          #
          # A copy of a vendored name is deleted for the same reason the
          # ~/.pi/agent/skills pruner deletes: it is a startup collision warning
          # and an unaccountable version of that skill in the routing table. On
          # 2026-10-24 that was the `skills`-CLI-era superpowers clone at
          # ~/.codex/superpowers, v6.2.0, beating the pin declared above.
          _pi_cross_agent_dir="${config.home.homeDirectory}/.agents"
          _pi_vendored_names=" ${lib.concatStringsSep " " piSkillNames} "
          _pi_shared_names=" ${lib.concatStringsSep " " piSharedAgentSkillNames} "
          if [ -d "$_pi_cross_agent_dir/skills" ]; then
            (
              cd "$_pi_cross_agent_dir/skills" || exit 0
              for _n in *; do
                # -L as well as -e: a dangling link is still a routing-table entry
                # that resolves to nothing, and `continue` on -e alone keeps it
                # forever because nothing else ever looks at it.
                [ -e "$_n" ] || [ -L "$_n" ] || continue
                case "$_pi_shared_names" in *" $_n "*) continue ;; esac
                case "$_pi_vendored_names" in
                  *" $_n "*)
                    echo "piAgentConfig: removing copy of pi-owned skill $_pi_cross_agent_dir/skills/$_n" >&2
                    rm -rf "$_n"
                    ;;
                  *)
                    echo "piAgentConfig: undeclared entry $_pi_cross_agent_dir/skills/$_n left alone -- declare it in piVendoredSkills or piSharedAgentSkillLinks, or remove it" >&2
                    ;;
                esac
              done
            )
          fi

          # A real directory where a declared link belongs is left alone and
          # named, and the switch keeps going: it is somebody's checkout, and
          # failing the whole activation over one skill would take the rest of the
          # home environment down with it. Same contract as the extensions report.
          #
          # $1 destination, $2 source, $3 optional "require-parent": with it, a
          # missing parent means that agent is not installed on this host, and its
          # home is not this module's to create.
          _pi_skill_link() {
            _dst="$1"
            _src="$2"
            # Two apostrophes before the dollar-brace are how an indented Nix
            # string spells a literal one. Left unescaped it parses as an
            # interpolation and emits its value into the script instead: the
            # guard below turns into dead code and no build error says so. A bare
            # $3, on the other hand, aborts the whole activation under `set -u`
            # on the first call with no third argument -- which is what this is.
            if [ "''${3:-}" = "require-parent" ] && [ ! -d "$(dirname "$_dst")" ]; then
              return 0
            fi
            if [ -e "$_dst" ] && [ ! -L "$_dst" ]; then
              echo "piAgentConfig: WARNING $_dst is a real directory, not the declared link to $_src -- replace it by hand" >&2
              return 0
            fi
            mkdir -p "$(dirname "$_dst")"
            ln -sfn "$_src" "$_dst"
            # Normal on the first switch on a new machine: pi clones the package on
            # its own startup, so the link resolves from the next start onward.
            [ -e "$_dst" ] || echo "piAgentConfig: $_dst points at $_src, which does not exist yet -- pi creates it on next start" >&2
          }
          ${piSkillLinkCommands}
          if [ -e "$_pi_cross_agent_dir/.skill-lock.json" ]; then
            echo "piAgentConfig: removing legacy $_pi_cross_agent_dir/.skill-lock.json" >&2
            rm -f "$_pi_cross_agent_dir/.skill-lock.json"
          fi
        '';
  };

  # One definition, because the module system rejects the same option twice in
  # one file. `lib.mkIf` per key would have been the shape if these could be
  # separate.
  #
  # JAVA_HOME: JVM tooling (gradle, maven, sbt, some IDE integrations) resolves
  # the JDK through JAVA_HOME rather than `java` on PATH, so point it at the same
  # derivation that provides the binaries. `pkgs.jdk21` is openjdk on Linux and
  # zulu-ca on aarch64-darwin; both are cached for these systems. Follows
  # `jdkEnable`: a host whose JDK comes from outside Nix must not have JAVA_HOME
  # pinned here, or it overrides that manager on every shell.
  #
  # PI_*: pi's upstream flake wrapper is thinner than the nixpkgs
  # `pi-coding-agent` that used to provide the binary -- it prefixes fd and
  # ripgrep onto PATH and stops there, so telemetry is on and every start asks
  # pi.dev whether a newer release exists. That check is meaningless here: the
  # version moves when `nix flake update pi` says so, not when upstream
  # publishes. Gated on `piEnable` rather than `!configOnly`, because configOnly
  # hosts (the coder workspaces) take the binary from the workspace image but run
  # the same agent, so they want these too.
  home.sessionVariables =
    (lib.optionalAttrs (!configOnly && jdkEnable) {
      JAVA_HOME = "${pkgs.jdk21}";
    })
    // (lib.optionalAttrs piEnable {
      PI_TELEMETRY = "0";
      PI_SKIP_VERSION_CHECK = "1";
    });

  programs.neovim = lib.mkIf (!configOnly) {
    enable = true;
    defaultEditor = true;
    viAlias = true;
    withPython3 = false;
    withRuby = false;
  };
}
