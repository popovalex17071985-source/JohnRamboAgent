#!/usr/bin/env python3
"""UserPromptSubmit hook: clean the prompt, search OpenViking, inject only hits
above the relevance threshold. Replaces the plugin's auto-recall.mjs (which
searched with the raw Telegram wrapper and injected 3 hits no matter the score).
Always exits 0 — memory is a convenience, never a blocker."""
import json
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from ov_memory import (  # noqa: E402
    OVClient, RECALL_LIMIT, clean_text, is_noise, log, rank, render, threshold_for,
)

# Only this agent's own scope: «default» is the shared bucket every agent
# used to land in, and reading it handed one agent another's memory.
SCOPES = ("viking://user/__AGENT__/memories",)


def recall(prompt: str, client: OVClient | None = None,
           threshold: float | None = None, limit: int = RECALL_LIMIT) -> list[dict]:
    query = clean_text(prompt)
    if is_noise(query):
        log("recall_skip", reason="noise", query=query[:80])
        return []
    client = client or OVClient()
    if threshold is None:  # the server's score scale changed in OpenViking 0.4.22
        version = client.server_version() if hasattr(client, "server_version") else ""
        threshold = threshold_for(version)
    cands = []
    for scope in SCOPES:
        try:
            cands += client.find(query[:1000], scope, limit=limit * 3)
        except Exception as exc:  # noqa: BLE001 — a dead server must not block the turn
            log("recall_error", scope=scope, error=str(exc)[:120])
    picked = rank(cands, threshold=threshold, limit=limit, query=query)
    log("recall", query=query[:120], candidates=len(cands), threshold=threshold,
        top=[round(float(c.get("score") or 0), 3) for c in
             sorted(cands, key=lambda c: float(c.get("score") or 0), reverse=True)[:4]],
        picked=[(m["uri"].rsplit("/", 1)[-1], round(m["score"], 3)) for m in picked])
    return picked


def main() -> None:
    t0 = time.time()
    try:
        data = json.load(sys.stdin)
    except json.JSONDecodeError:
        return
    picked = recall(data.get("prompt") or "")
    if picked:
        print(json.dumps({"hookSpecificOutput": {
            "hookEventName": "UserPromptSubmit", "additionalContext": render(picked)}},
            ensure_ascii=False))
    log("recall_done", ms=int((time.time() - t0) * 1000), n=len(picked))


if __name__ == "__main__":
    main()
