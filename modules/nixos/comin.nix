{
  config,
  lib,
  pkgs,
  ...
}:
let
  cominAlertScript = pkgs.writeScript "comin-discord-alert" ''
    #!/bin/sh
    if [ "$COMIN_STATUS" != "done" ]; then
      WEBHOOK_URL_FILE="${config.cominGitOps.discordWebhookUrl}"
      
      if [ -f "$WEBHOOK_URL_FILE" ]; then
        WEBHOOK_URL=$(cat "$WEBHOOK_URL_FILE")
        
        if [ -n "$WEBHOOK_URL" ] && [ "$WEBHOOK_URL" != "YOUR_DISCORD_WEBHOOK_URL_HERE" ]; then
          curl -X POST "$WEBHOOK_URL" \
            -H "Content-Type: application/json" \
            -d "{
              \"embeds\": [{
                \"title\": \"❌ Comin Deployment Failed\",
                \"color\": 16711680,
                \"fields\": [
                  {\"name\": \"Host\", \"value\": \"$COMIN_HOSTNAME\", \"inline\": true},
                  {\"name\": \"Status\", \"value\": \"$COMIN_STATUS\", \"inline\": true},
                  {\"name\": \"Commit\", \"value\": \"$COMIN_GIT_SHA\", \"inline\": false},
                  {\"name\": \"Error\", \"value\": \"$COMIN_ERROR_MSG\", \"inline\": false}
                ],
                \"timestamp\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"
              }]
            }"
        fi
      fi
    fi
  '';
in
{
  options = {
    cominGitOps = {
      enable = lib.mkEnableOption "Comin GitOps deployment";
      repositoryUrl = lib.mkOption {
        type = lib.types.str;
        default = "https://github.com/javierarrieta/nixos-configurations.git";
        description = "Git repository URL for Comin";
      };
      pollInterval = lib.mkOption {
        type = lib.types.int;
        default = 300;
        description = "Poll interval in seconds";
      };
      discordWebhookUrl = lib.mkOption {
        type = lib.types.str;
        default = "YOUR_DISCORD_WEBHOOK_URL_HERE";
        description = "Discord webhook URL for Comin failure alerts";
      };
    };
  };

  config = lib.mkIf config.cominGitOps.enable {
    services.comin = {
      enable = true;
      remotes = [
        {
          name = "origin";
          url = config.cominGitOps.repositoryUrl;
          branches.main.name = "main";
          poller.period = config.cominGitOps.pollInterval;
        }
      ];
      postDeploymentCommand = cominAlertScript;
    };
  };
}
