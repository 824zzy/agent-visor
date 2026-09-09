await import(process.argv.includes("--freshness")
  ? "../test-session-freshness.mjs"
  : process.argv.includes("--chat")
  ? "../test-chat-accessibility.mjs"
  : "../test-sessions-accessibility.mjs");
