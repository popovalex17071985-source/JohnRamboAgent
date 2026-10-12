# Long-term memory without asking the owner for a key

Tried on gorbot (144.124.224.216, 2 cores / 3.9 GB) 19.09.2026. No OpenAI key,
no card, no owner action. Two containers, both bound to loopback.

1. Embeddings -- `scripts/embed-server.py` from this kit: fastembed behind
   uvicorn, serving `POST /v1/embeddings` on 127.0.0.1:1934, model
   `sentence-transformers/paraphrase-multilingual-MiniLM-L12-v2` (384 dim).
   systemd unit `dashi-embed`, `MemoryMax=1200M`, `OMP_NUM_THREADS=1`.

   Why not HuggingFace TEI (`text-embeddings-inference:cpu`): it works, but its
   ONNX arenas peak at ~1.9 GB, which left 73 MB free on a 4 GB box, and any cap
   below that kills it with exit 137 in a restart loop.
   fastembed rejects `intfloat/multilingual-e5-small` -- check
   `TextEmbedding.list_supported_models()` before picking a model, and set
   `dimension` in ov.conf to what `/v1/embeddings` actually returns.

2. Summaries -- any OpenAI-compatible chat API the box ALREADY holds a key for
   (gorbot: Groq, `openai/gpt-oss-20b`). Never copy a key between servers.

3. `~/.openviking/ov.conf` (mode 600): `embedding.dense` -> the local endpoint,
   `provider: openai`, `dimension` = what `/v1/embeddings` actually returns
   (384 for e5-small); `vlm` -> the Groq base + model; `server.host: 127.0.0.1`;
   `storage.workspace: /app/data` (since v0.4.21 the default `./data` misses the
   appdata volume and memory «disappears»).

4. Run OpenViking with `--network host` AND `-e OPENVIKING_SERVER_HOST=127.0.0.1`
   -- without the env it binds 0.0.0.0 and dev auth mode refuses to start.

5. The kit's `flush-to-openviking.sh` delegates to
   `~/.claude-lab/<agent>/scripts/ov-session-sync.sh` -- on a copied kit both the
   path and `AGENT_NAME` still said `jarvis`, so the flush silently did nothing
   even with the service up. Check both before declaring memory alive.

Ask the owner for a key (`bin/memory-key-ask.py`) only when neither a local
embedder nor an existing provider key can be used -- see [memory-key-install.md].
