// Test preload: cut the suite off from the live agent it may be running inside.
//
// `bun test` launched from an agent session inherits that session's channel env
// (TELEGRAM_STATE_DIR, webhook port/token, bot token, ...). Tests that spawn
// hooks with `...process.env` then wrote into the LIVE state: on 01.10.2026 a
// fixture chat id landed in state/telegram/fallback-reply/last-chat and the
// Stop fallback started forwarding the owner's turns to a stranger's id.
// CI has none of these vars, so stripping them makes a local run match CI.
const LIVE_ENV = /^(TELEGRAM_|MULTICHAT_|DASHI_|FALLBACK_REPLY_)/

for (const key of Object.keys(process.env)) {
  if (LIVE_ENV.test(key)) delete process.env[key]
}
