{
  config,
  pkgs,
  lib,
  userOptions,
  ...
}:
{
  home.packages = with pkgs; [
    starship
    zoxide
    fishPlugins.tide
    fishPlugins.fzf
  ];

  home.sessionVariables = {
    EDITOR = "nvim";
  };

  home.sessionPath = [
    "${userOptions.userHome}/.cargo/bin"
  ];

  programs.fish = {
    enable = true;
    interactiveShellInit = ''
      set fish_greeting
      fish_vi_key_bindings

      # Activate virtual environment if it exists
      test -e ~/.venv/default/bin/activate.fish || venv ~/.venv/default
      source ~/.venv/default/bin/activate.fish

      starship init fish | source
    '';
    plugins = [
      {
        name = "bass";
        src = pkgs.fishPlugins.bass;
      }
      {
        name = "tide";
        src = pkgs.fishPlugins.tide;
      }
    ];
    shellAbbrs = {
      "cd" = "z";
      "ga" = {
        position = "command";
        expansion = "git add";
      };
      "gita" = "git add";
      "gch" = "git checkout";
      "gitcm" = {
        position = "command";
        setCursor = true;
        expansion = "git commit -m \"%\"";
      };
      "gcm" = {
        position = "command";
        setCursor = true;
        expansion = "git commit -m \"%\"";
      };
      "gl" = "git log";
      "gr" = "git rebase";
      "gs" = "git status";
      "gss" = "git status --short";
      "G" = {
        position = "anywhere";
        setCursor = true;
        expansion = "| grep '%'";
      };
    };
    shellAliases = {
      "ls" = "lsd";
      "lsa" = "lsd -a";
      "ll" = "lsd -l";
      "lla" = "lsd -la";
      "lt" = "ls --tree";
      "l." = "lsd -d .* --color=auto";
      "z" = "zoxide";
      "k" = "kubectl";
      "kx" = "kubectx";
      "venv" = "python3 -m venv";
      "rebase-pr" = "git fetch && git merge origin/${userOptions.gitDefaultBranch} && git push";
      "autocomplete-server" =
        "hf download sweepai/sweep-next-edit-1.5B sweep-next-edit-1.5b.q8_0.v2.gguf --local-dir $HOME/llm/models && \
         llama-server -m $HOME/llm/models/sweep-next-edit-1.5b.q8_0.v2.gguf --offline --jinja -ngl 99 --threads -1 --ctx-size 8192 --port 8081";
    };
  };

  programs.starship = {
    enable = true;
    enableFishIntegration = true;
    settings = {
      add_newline = false;
      hostname.style = "bold green";
      username.style_user = "bold blue";
      format = lib.concatStrings [
        "$all"
        "$line_break"
        "$package"
        "$line_break"
        "$character"
      ];
      scan_timeout = 2000;
      character = {
        success_symbol = "➜";
        error_symbol = "➜";
      };
      directory = {
        truncate_to_repo = false;
        truncation_symbol = "…/";
        fish_style_pwd_dir_length = 1;
        style = "main_color";
        format = "[$path]($style)[$lock_symbol]($lock_style) ";
      };
      sudo = {
        disabled = false;
        symbol = "🪄  ";
      };
      kubernetes = {
        format = "on [⛵ ($namespace in )$context \($namespace\)](dimmed green) ";
        disabled = false;
      };
      battery = {
        full_symbol = "🔋";
        charging_symbol = "🔌";
        discharging_symbol = "⚡";
        display = [
          {
            threshold = 30;
            style = "bold red";
          }
        ];
        disabled = false;
      };
      python = {
        format = "[$symbol$pyenv_prefix($version )(($virtualenv) )]($style)";
        python_binary = [
          "python"
          "python3"
          "python2"
        ];
        pyenv_prefix = "pyenv ";
        pyenv_version_name = true;
        style = "yellow bold";
        symbol = "🐍 ";
        version_format = "v$raw";
        disabled = false;
        detect_extensions = [ "py" ];
        detect_files = [
          "requirements.txt"
          ".python-version"
          "pyproject.toml"
          "Pipfile"
          "tox.ini"
          "setup.py"
          "__init__.py"
        ];
        detect_folders = [ ];
      };
    };
    enableTransience = true;
  };

  programs.fzf = {
    enable = true;
    enableFishIntegration = true;
    enableZshIntegration = true;
    colors = {
      bg = "#eff1f5";
      "bg+" = "#ccd0da";
      spinner = "#dc8a78";
      hl = "#d20f39";
      fg = "#4c4f69";
      header = "#d20f39";
      info = "#8839ef";
      pointer = "#dc8a78";
      marker = "#dc8a78";
      "fg+" = "#4c4f69";
      prompt = "#8839ef";
      "hl+" = "#d20f39";
    };
  };

  programs.zoxide = {
    enable = true;
    enableFishIntegration = true;
    enableZshIntegration = true;
  };

  programs.zsh = {
    enable = true;
    enableCompletion = true;
    autosuggestion.enable = true;
    syntaxHighlighting.enable = true;
    initContent = ''
      export PATH=$HOME/.nix-profile/bin:$PATH
      export PATH=/nix/var/nix/profiles/default/bin:$PATH

      #THIS MUST BE AT THE END OF THE FILE FOR SDKMAN TO WORK!!!
      export SDKMAN_DIR="$HOME/.sdkman"
      [[ -s "$HOME/.sdkman/bin/sdkman-init.sh" ]] && source "$HOME/.sdkman/bin/sdkman-init.sh"

      eval "$(zoxide init --cmd cd zsh)"

      if [[ $(ps -o command= -p "$PPID" | awk '{print $1}') != 'fish' ]]
      then
          exec fish -l
      fi
    '';
    shellAliases = {
      gl = "git log";
      gs = "git status";
      gits = "git status";
      gitf = "git fetch";
      gita = "git add";
      gitcm = "git commit -m";
      gcm = "git commit -m";
      gch = "git checkout";
      cat = "bat";
      du = "dust";
      el = "erd -H -L 1";
      ela = "erd -H -L 1 -.";
      ls = "lsd";
      lsa = "lsd -a";
      ll = "lsd -l";
      lla = "ls -la";
      lt = "ls --tree";
      python = "python3";
      pip = "pip3";
      pym = "python3 -m";
      k = "kubectl";
      kx = "kubectx";
    };
  };

  programs.git = {
    enable = true;
    settings = {
      user = {
        email = "${userOptions.gitEmail}";
        name = "${userOptions.gitName}";
      };
      alias = {
        ss = "status --short";
        pf = "pull --ff-only";
        ci = "commit";
        co = "checkout";
        lg1 = "log --graph --abbrev-commit --decorate --format=format:'%C(bold blue)%h%C(reset) - %C(bold green)(%ar)%C(reset) %C(white)%s%C(reset) %C(dim white)- %an%C(reset)%C(auto)%d%C(reset)' --all";
        lg2 = "log --graph --abbrev-commit --decorate --format=format:'%C(bold blue)%h%C(reset) - %C(bold cyan)%aD%C(reset) %C(bold green)(%ar)%C(reset)%C(auto)%d%C(reset)%n''          %C(white)%s%C(reset) %C(dim white)- %an%C(reset)'";
        lg = "lg1";
        sw = "switch";
      };
      pull.rebase = "false";
      credential.helper = "osxkeychain";
      init.defaultBranch = "${userOptions.gitDefaultBranch}";
      github.user = "${userOptions.githubUser}";
    };
  };


  programs.tmux = {
    enable = true;
    # Enable focus events so tmux knows when you switch panes
    focusEvents = true; 

    extraConfig = ''
      # 1. Highlight Pane Borders
      set -g pane-border-style "fg=#3b4252"
      set -g pane-active-border-style "fg=#81a1c1"

      # 2. Dim Inactive Panes (Visual Differentiator)
      set -g window-style "fg=#616e88,bg=#2e3440"
      set -g window-active-style "fg=#d8dee9,bg=#2e3440"

      # 3. Add Border Indicators (requires tmux 3.2+)
      set -g pane-border-indicators both
      set -g pane-border-lines heavy
    '';
  };
}
