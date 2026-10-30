{
  pkgs,
  lib,
  root,
}:

# The Elephant-Goldfish Model mapping this repo owns: upstream ships manifests for
# Claude Code, Codex and Antigravity and none for pi, so everything here is the pi
# side of it. Consumed by ../dev-tools.nix, which wires the results into home.file,
# piVendoredSkills and the activation report. `root` is the vendored upstream tree
# (the `egm-skills` flake input).
#
# Imported as a plain function rather than a home-manager module because it declares
# no options of its own: it renders derivations, and the enable flag, the home.file
# merge and the activation entry all stay with dev-tools.nix, which owns pi.

let
  # ---- Elephant-Goldfish Model (EGM) --------------------------------------
  #
  # EGM drafts a design spec with a context-rich agent (the elephant) and then
  # stress-tests it with reviewers that get the document and nothing else (the
  # goldfish). Upstream ships manifests for Claude Code, Codex and Antigravity
  # and none for pi, so everything below is this repo's mapping -- and it
  # deliberately does not fork the skill text.
  #
  # Three things pi needs that the tarball does not provide by itself:
  #
  # 1. Path layout. Every skill resolves `agents/<persona>.md` and
  #    `resources/document_standards/<standard>.md` against the *repo root*, not
  #    its own folder, so the `<input>/skills/<name>` link every other vendored
  #    skill uses leaves both trees unreachable -- upstream's own
  #    docs/harnesses.md says a skills-only install breaks EGM. `skillDir`
  #    rebuilds each skill folder with those two trees merged into it, so the
  #    relative paths resolve from the directory pi reports to the model.
  #
  # 2. Harness notes. Each SKILL.md opens by telling the reader to read
  #    `../../docs/codex.md` (Codex) or `${CLAUDE_PLUGIN_ROOT}/docs/claude.md`
  #    (Claude) and names only those harnesses' subagent tools. Neither path
  #    exists here and pi is not named, so `piNotes` appends a pi section.
  #    Appended rather than substituted on purpose: an append cannot silently
  #    no-op when upstream rewords that paragraph, which a sed would.
  #
  # 3. Named subagents. The skills ask for subagents named `egm-zoom-out`,
  #    `egm-design`, ... "where your harness registers named subagents".
  #    `personaAgent` renders each upstream persona into a pi-subagents agent
  #    file, and that is where the Goldfish guarantee actually gets enforced --
  #    read-only tools and no inherited project or skill context. A reviewer that
  #    inherits the parent's context is not a Goldfish, and no amount of upstream
  #    prompt text can enforce that on pi.
  # Explicit rather than `builtins.readDir`, for the same reason the other name
  # lists are: an upstream addition cannot silently join the routing table on a
  # flake update.
  skillNames = [
    "egm-bootstrap"
    "egm-brainstorm"
    "egm-draft"
    "egm-drift-report"
    "egm-resolve"
    "egm-review"
    "egm-review-loop"
  ];

  # `name` is the runtime name pi-subagents uses, taken from each persona's own
  # frontmatter -- it does not always match the file name (design_critic.md
  # registers as `egm-design`).
  #
  # `extraTools` is the whole difference between a reviewer and a producer. The
  # seven reviewers get nothing beyond the read-only default: their own text
  # mandates it ("Strict Read-Only Protocol"), and on pi the tool list is the only
  # thing that enforces it -- a reviewer that can edit the document it is auditing
  # is not a Goldfish.
  #
  # The two producers are different animals, and were wrong until 2026-10-30: they
  # shipped with the reviewer default, which left `egm-synthesizer` unable to write
  # the report its own description promises and `egm-bootstrap-orchestrator` unable
  # to create a single contract file after scouting a whole tree. The orchestrator
  # also gets `bash` because the bootstrap workflow tells it to use the shell for
  # directory discovery and for the optional markdown formatter.
  #
  # `advertise` stays false: nine always-present descriptions in every pi system
  # prompt on every host, for a workflow that is opt-in by slash command, is the
  # wrong trade. The names are in context when they matter instead --
  # `piNotes` lists them inside each skill.
  personas = [
    {
      file = "bootstrap_orchestrator.md";
      name = "egm-bootstrap-orchestrator";
      extraTools = [
        "subagent"
        "write"
        "edit"
        "bash"
      ];
    }
    {
      file = "codebase_details.md";
      name = "egm-codebase-details";
    }
    {
      file = "comprehension.md";
      name = "egm-comprehension";
    }
    {
      file = "design_critic.md";
      name = "egm-design";
    }
    {
      file = "implementation_readiness.md";
      name = "egm-implementation-readiness";
    }
    {
      file = "structural.md";
      name = "egm-structural";
    }
    {
      file = "style.md";
      name = "egm-style";
    }
    {
      file = "synthesizer.md";
      name = "egm-synthesizer";
      extraTools = [
        "subagent"
        "write"
        "edit"
      ];
    }
    {
      file = "zoom_out.md";
      name = "egm-zoom-out";
    }
  ];

  # What the two harness lines at the top of each skill cannot say on pi, and
  # cannot be patched in place without a fragile match on upstream wording.
  piNotes =
    pkgs.writeText "egm-pi-notes" # markdown
      ''


        ---

        ## pi harness notes

        Added by nixos-configurations; not upstream text. This is pi, not Codex,
        ChatGPT Work, Claude Code or Cowork: ignore the two lines near the top that
        point at `docs/codex.md` or `''${CLAUDE_PLUGIN_ROOT}/docs/claude.md`, and use
        this instead.

        * Subagent tool: `subagent` (pi-subagents). Pass the persona as the agent
          and the review prompt as the task.
        * Registered personas: egm-zoom-out, egm-design, egm-structural, egm-style,
          egm-comprehension, egm-codebase-details, egm-implementation-readiness,
          egm-synthesizer, egm-bootstrap-orchestrator. They are registered
          unadvertised, so name them explicitly; they are not in the parent's system
          prompt.
        * Goldfish isolation is enforced by those agent definitions (fresh context,
          no inherited project or skill context). The seven reviewers are read-only;
          only `egm-synthesizer` and `egm-bootstrap-orchestrator` write, and only
          their own artifacts. Do not substitute a forked-context or
          general-purpose subagent -- that is not a Goldfish review, and the skill is
          right to refuse it.
        * `agents/<file>.md` and `resources/document_standards/<file>.md` resolve
          inside this skill directory; both are merged into it here.
        * Prefer direct dispatch: spawn each reviewer from this session. Nested
          spawning is capped by pi-subagents `maxSubagentDepth` (default 2), so a
          synthesizer that fans out reviewers itself may hit the cap; if it does,
          use the flat swarm the skill documents as the fallback.
      '';

  # One skill folder, self-contained: upstream contents, plus the repo-root
  # `agents/` and `resources/` trees its text resolves relative to itself, plus
  # the pi notes appended.
  #
  # Copied, not symlinked, and that is not laziness: every upstream skill folder
  # already ships its own `agents/` (a Codex `openai.yaml`), so `ln -s
  # <root>/agents $out/agents` lands *inside* it as `agents/agents` and the
  # persona files stay unreachable. Measured on the first build of this, which is
  # the only reason it is known.
  # Text patches to upstream EGM skill bodies, keyed by skill name.
  #
  # `.nix` is not in EGM's recognized source-extension list, so the bootstrap's
  # bottom-up pruning pass drops every directory holding only `.nix` files. On
  # this repo that is 135 files across `common/`, `home/`, `hosts/`, `modules/`
  # and `secrets/` -- the whole point of the tree -- and what survives to be
  # documented is five shell scripts, one `.ts` extension and a python helper.
  # Measured 2026-10-30, not guessed: `find` over the tree reported 135 `.nix`
  # against 5 `.sh`, and the list appears exactly once in the entire plugin.
  #
  # Unlike the harness paragraph, this one is substituted rather than appended,
  # because it is a filter the model applies mid-workflow rather than an
  # instruction it can weigh, and because the anchor is a single unique line
  # rather than prose upstream rewords between releases.
  #
  # Guarded for the same reason either way: `substituteInPlace` no-ops silently
  # when the anchor moves, and a silently unpatched list is a bootstrap that
  # quietly documents nothing and reports success. Here the build fails and says
  # what to update -- which it did, first catching that an anchor starting with
  # `- ` is read as a grep option. Hence the shorter anchor and the `--`.
  skillPatches.egm-bootstrap = {
    anchor = "Declarative Code: `.tf`, `.hcl`, `.cue`";
    replacement = "Declarative Code: `.tf`, `.hcl`, `.cue`, `.nix`";
  };

  skillPatchScript =
    name:
    let
      p = skillPatches.${name} or null;
    in
    if p == null then
      ""
    else
      # bash
      ''
        if ! grep -qF -- ${lib.escapeShellArg p.anchor} $out/SKILL.md; then
          echo "skillDir: ${name}: the anchor for the .nix patch is gone -- upstream reworded its source-extension list; update skillPatches" >&2
          exit 1
        fi
        substituteInPlace $out/SKILL.md --replace ${lib.escapeShellArg p.anchor} ${lib.escapeShellArg p.replacement}
      '';

  skillDir =
    name:
    pkgs.runCommand "egm-${name}" { } # bash
      ''
        mkdir -p $out
        cp -r ${root}/skills/${name}/. $out/
        # cp preserves the store's read-only mode; SKILL.md has to stay writable
        # for the patch and the append below. Nix restores read-only perms on the
        # output path.
        chmod -R u+w $out
        mkdir -p $out/agents $out/resources
        cp ${root}/agents/*.md $out/agents/
        cp -r ${root}/resources/. $out/resources/
        ${skillPatchScript name}
        cat $out/SKILL.md ${piNotes} > $out/SKILL.md.tmp
        mv $out/SKILL.md.tmp $out/SKILL.md
      '';

  # Upstream persona -> pi-subagents agent file. The persona's own frontmatter
  # is dropped and replaced: pi needs its own fields, and a second frontmatter
  # block in the middle of the file would render as prompt text.
  #
  # `description` is read out of the persona rather than copied into Nix, so a
  # reworded upstream persona cannot drift from what the parent sees. The guard
  # is there because an awk that silently returns nothing would otherwise produce
  # an agent file pi refuses to load, with the cause three directories away.
  personaAgent =
    p:
    let
      extraToolsSuffix = if p ? extraTools then ", " + lib.concatStringsSep ", " p.extraTools else "";
    in
    pkgs.runCommand "pi-agent-${p.name}" { } # bash
      ''
        src=${root}/agents/${p.file}
        desc=$(awk '/^description: /{ sub(/^description: /, ""); gsub(/"/, ""); print; exit }' "$src")
        if [ -z "$desc" ]; then
          echo "personaAgent: no description line in ${p.file}" >&2
          exit 1
        fi
        {
          printf -- '---\nname: ${p.name}\n'
          printf 'description: %s\n' "$desc"
          printf 'advertise: false\n'
          printf 'tools: read, grep, find, ls${extraToolsSuffix}\n'
          printf 'inheritProjectContext: false\n'
          printf 'inheritGlobalContext: false\n'
          printf 'inheritSkills: false\n'
          printf -- '---\n\n'
          # Body after the closing '---' of the upstream frontmatter.
          awk 'c >= 2 { print } /^---$/ { c++ }' "$src"
        } > $out
      '';

  agentFiles = builtins.listToAttrs (
    map (
      p:
      lib.nameValuePair ".pi/agent/agents/${p.name}.md" {
        source = personaAgent p;
        # A hand-made ~/.pi/agent/agents/<name>.md is what this collides with,
        # and Home Manager refuses to replace one without this.
        force = true;
      }
    ) personas
  );

in
{
  inherit
    skillDir
    skillNames
    personas
    agentFiles
    ;
}
