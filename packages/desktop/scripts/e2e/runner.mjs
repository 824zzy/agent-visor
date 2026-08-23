await import(process.argv.includes("--chat")
  ? "../test-chat-accessibility.mjs"
  : "../test-sessions-accessibility.mjs");
