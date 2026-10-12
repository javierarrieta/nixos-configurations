{
  username = "javier";
  userHome = "/Users/javier";
  gitName = "Javier Arrieta";
  gitEmail = "javier@techdelivery.es";
  gitDefaultBranch = "main";
  githubUser = "javierarrieta";
  pythonVersion = "3.12";
  homeManagerConfigDir = "/Users/javier/code/nixos-configurations";

  pi = {
    # This laptop runs omlx locally (127.0.0.1:8000, OpenAI-compatible).
    #
    # Declared here rather than in ~/.pi/agent/models.json because that file is a
    # read-only symlink into the store since 605839a -- pi reads it, nothing
    # writes it, and an edit there is impossible instead of merely temporary.
    # The provider lived only in the hand-edited file until then, so the switch
    # that added the link dropped it (kept at models.json.pre-link) and the local
    # model disappeared from /model.
    extraProviders.local-omlx = {
      baseUrl = "http://127.0.0.1:8000/v1";
      api = "openai-completions";
      # omlx ignores the key; pi requires the field to be present.
      apiKey = "dummy";
      compat = {
        supportsDeveloperRole = true;
        supportsReasoningEffort = true;
        supportsUsageInStreaming = true;
      };
      models = [
        {
          id = "Qwen3.8-27B-oQ4e-mtp";
          name = "Qwen3.8-27B-oQ4e-mtp (local omlx)";
          reasoning = true;
          input = [ "text" ];
          contextWindow = 262144;
          maxTokens = 65536;
        }
        # Second model the same omlx server serves. Its numbers come from the
        # server itself (`curl localhost:8000/v1/models` -> max_model_len
        # 65000) rather than from a hand-edit, so maxTokens stays well under the
        # context: it is the output cap, and the prompt has to fit in what is
        # left.
        #
        # `reasoning` is left off because it is unverified here. If Ornith answers
        # with reasoning_content, add `reasoning = true;` -- pi only offers the
        # thinking levels a model declares.
        {
          id = "Ornith-1.5-35B-A3B-MLX-6bit";
          name = "Ornith-1.5-35B-A3B-MLX-6bit (local omlx)";
          input = [ "text" ];
          contextWindow = 65000;
          maxTokens = 32768;
        }
      ];
    };
  };
}
