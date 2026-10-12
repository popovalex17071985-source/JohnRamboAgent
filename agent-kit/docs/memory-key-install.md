# Long-term memory: installing the owner's OpenAI key

The owner sends the key in chat (the ask comes from `bin/memory-key-ask.py`).
Steps, in order. Never echo the key.

1. Save it as a config file, not an env/secret path:
   `~/config/openai-creds.json` -> `{"api_key": "sk-..."}`, `chmod 600`.
2. Write `~/.openviking/ov.conf` (mode 600) with the key inlined:

```json
{
  "embedding": {
    "dense": {
      "api_base": "https://api.openai.com/v1",
      "api_key": "<key>",
      "provider": "openai",
      "dimension": 1536,
      "model": "text-embedding-3-small"
    }
  },
  "vlm": {
    "api_base": "https://api.openai.com/v1",
    "api_key": "<key>",
    "provider": "openai",
    "model": "gpt-4o-mini"
  },
  "server": { "host": "127.0.0.1" },
  "storage": { "workspace": "/app/data" }
}
```

   `storage.workspace` is mandatory: since OpenViking v0.4.21 the image runs in
   `/app/.openviking`, so the default `./data` misses the appdata volume and the
   server starts on an empty store. If an existing `ov.conf` is rewritten, keep
   its `storage.workspace` (`agent-kit/scripts/ov-conf-fix.py` pins it).

   `provider: openai` is what avoids the local-embedding crash
   (`EmbeddingConfigurationError: 'llama-cpp-python' is not installed`).
3. Start the container (host port 1933), mounts as on the coordinator:
   `~/.openviking -> /app/.openviking`, `~/.openviking/appdata -> /app/data`.
   Image: the one pinned in `scripts/install-agent.sh` (`OPENVIKING_IMAGE`, v0.5.0).
   Since v0.4.22 scores are `(cos + 1) / 2`: the recall hooks map their thresholds
   by the server version, the plugin's `scoreThreshold` is 0.625 (was 0.25).
4. Verify: `memory_health` must answer, then flush the hot log
   (`hooks/flush-to-openviking.sh`) and confirm the line count drops.
5. Report to the owner in ONE message: memory alive, how many lines were flushed.
   Delete nothing on failure -- report the exact error instead.
