{
  config,
  lib,
  pkgs,
  ...
}:
{
  options = {
    cominDiscordAlert = {
      enable = lib.mkEnableOption "Comin Discord failure alerts";
      webhookUrl = lib.mkOption {
        type = lib.types.str;
        default = "YOUR_DISCORD_WEBHOOK_URL_HERE";
        description = "Discord webhook URL for Comin failure alerts";
      };
    };
  };

  config = lib.mkIf config.cominDiscordAlert.enable {
    cominDiscordAlert.script = pkgs.writeScript "comin-discord-alert" ''
      #!/bin/sh
      if [ "$COMIN_STATUS" != "done" ]; then
        WEBHOOK_URL="${config.cominDiscordAlert.webhookUrl}"

        if [ -f "$WEBHOOK_URL" ]; then
          WEBHOOK_URL=$(cat "$WEBHOOK_URL")
        fi

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
    '';
  };
}
