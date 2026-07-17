#!/bin/zsh

set -euo pipefail

resolve_codex_binary() {
  local candidate
  for candidate in \
    "/Applications/Codex.app/Contents/Resources/codex" \
    "/Applications/ChatGPT.app/Contents/Resources/codex"
  do
    if [[ -x "$candidate" ]]; then
      print -r -- "$candidate"
      return
    fi
  done
  command -v codex
}

CODEX_BINARY="${CODEX_BINARY:-$(resolve_codex_binary)}"
TMP_HOME="$(mktemp -d /tmp/agent-visor-codex-runtime.XXXXXX)"
SOCKET_PATH="$TMP_HOME/app-server-control/app-server-control.sock"
SERVER_PID=""

cleanup() {
  if [[ -n "$SERVER_PID" ]] && kill -0 "$SERVER_PID" 2>/dev/null; then
    kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
  fi
  rm -rf -- "$TMP_HOME"
}
trap cleanup EXIT INT TERM

CODEX_HOME="$TMP_HOME" "$CODEX_BINARY" \
  -c features.code_mode_host=true \
  app-server --listen unix:// \
  --analytics-default-enabled \
  >"$TMP_HOME/server.log" 2>&1 &
SERVER_PID=$!

for _ in {1..100}; do
  [[ -S "$SOCKET_PATH" ]] && break
  if ! kill -0 "$SERVER_PID" 2>/dev/null; then
    print -u2 "Codex app-server exited before creating its Unix socket."
    tail -40 "$TMP_HOME/server.log" >&2
    exit 1
  fi
  sleep 0.1
done

if [[ ! -S "$SOCKET_PATH" ]]; then
  print -u2 "Codex app-server did not create $SOCKET_PATH."
  tail -40 "$TMP_HOME/server.log" >&2
  exit 1
fi

CANONICAL_SOCKET_PATH="$(cd "${SOCKET_PATH:h}" && pwd -P)/${SOCKET_PATH:t}"
DAEMON_VERSION="$(CODEX_HOME="$TMP_HOME" "$CODEX_BINARY" app-server daemon version)"
print -r -- "$DAEMON_VERSION" | jq -e \
  --arg socket "$CANONICAL_SOCKET_PATH" \
  '.status == "running" and .socketPath == $socket and .appServerVersion == .cliVersion' \
  >/dev/null

CODEX_BINARY="$CODEX_BINARY" SOCKET_PATH="$SOCKET_PATH" node <<'NODE'
const { spawn } = require('node:child_process');
const { createHash, randomBytes } = require('node:crypto');

const binary = process.env.CODEX_BINARY;
const socket = process.env.SOCKET_PATH;

class ProxyClient {
  constructor(name) {
    this.name = name;
    this.nextId = 1;
    this.pending = new Map();
    this.buffer = Buffer.alloc(0);
    this.upgraded = false;
  }

  async connect() {
    this.process = spawn(binary, ['app-server', 'proxy', '--sock', socket], {
      stdio: ['pipe', 'pipe', 'pipe']
    });
    this.process.stdout.on('data', chunk => this.receive(chunk));
    this.process.stderr.setEncoding('utf8');
    this.process.stderr.on('data', chunk => process.stderr.write(`${this.name}: ${chunk}`));
    this.process.on('exit', code => this.fail(new Error(`${this.name} proxy exited ${code}`)));
    this.key = randomBytes(16).toString('base64');
    const upgraded = new Promise((resolve, reject) => {
      this.upgrade = { resolve, reject };
    });
    this.process.stdin.write(
      `GET /rpc HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\n` +
      `Connection: Upgrade\r\nSec-WebSocket-Key: ${this.key}\r\n` +
      `Sec-WebSocket-Version: 13\r\n\r\n`
    );
    await upgraded;
    const initialized = await this.request('initialize', {
      clientInfo: { name: this.name, version: '0.1.0' },
      capabilities: { experimentalApi: true }
    });
    if (!initialized.userAgent) throw new Error(`${this.name} initialize omitted userAgent`);
    this.send({ method: 'initialized' });
  }

  request(method, params) {
    const id = this.nextId++;
    const result = new Promise((resolve, reject) => this.pending.set(id, { resolve, reject }));
    this.send({ id, method, params });
    return result;
  }

  send(message) {
    this.sendFrame(0x1, Buffer.from(JSON.stringify(message)));
  }

  receive(chunk) {
    this.buffer = Buffer.concat([this.buffer, chunk]);
    if (!this.upgraded) {
      const delimiter = this.buffer.indexOf('\r\n\r\n');
      if (delimiter < 0) return;
      const header = this.buffer.subarray(0, delimiter + 4).toString('utf8');
      this.buffer = this.buffer.subarray(delimiter + 4);
      const expected = createHash('sha1')
        .update(this.key + '258EAFA5-E914-47DA-95CA-C5AB0DC85B11')
        .digest('base64');
      if (!header.startsWith('HTTP/1.1 101 ') || !header.toLowerCase().includes(`sec-websocket-accept: ${expected}`.toLowerCase())) {
        this.upgrade.reject(new Error(`${this.name} invalid upgrade: ${header}`));
        return;
      }
      this.upgraded = true;
      this.upgrade.resolve();
    }
    for (;;) {
      if (this.buffer.length < 2) return;
      const first = this.buffer[0];
      const opcode = first & 0x0f;
      let length = this.buffer[1] & 0x7f;
      let cursor = 2;
      if (length === 126) {
        if (this.buffer.length < 4) return;
        length = this.buffer.readUInt16BE(2);
        cursor = 4;
      } else if (length === 127) {
        if (this.buffer.length < 10) return;
        const wide = this.buffer.readBigUInt64BE(2);
        if (wide > BigInt(Number.MAX_SAFE_INTEGER)) throw new Error('oversized websocket frame');
        length = Number(wide);
        cursor = 10;
      }
      if (this.buffer.length < cursor + length) return;
      const payload = this.buffer.subarray(cursor, cursor + length);
      this.buffer = this.buffer.subarray(cursor + length);
      if (opcode === 0x9) {
        this.sendFrame(0xA, payload);
        continue;
      }
      if (opcode === 0x8) {
        this.fail(new Error(`${this.name} websocket closed`));
        return;
      }
      if (opcode !== 0x1 && opcode !== 0x2) continue;
      const message = JSON.parse(payload.toString('utf8'));
      const pending = this.pending.get(message.id);
      if (!pending) continue;
      this.pending.delete(message.id);
      if (message.error) pending.reject(new Error(JSON.stringify(message.error)));
      else pending.resolve(message.result);
    }
  }

  sendFrame(opcode, payload) {
    const mask = randomBytes(4);
    let header;
    if (payload.length <= 125) {
      header = Buffer.from([0x80 | opcode, 0x80 | payload.length]);
    } else if (payload.length <= 0xffff) {
      header = Buffer.alloc(4);
      header[0] = 0x80 | opcode;
      header[1] = 0x80 | 126;
      header.writeUInt16BE(payload.length, 2);
    } else {
      header = Buffer.alloc(10);
      header[0] = 0x80 | opcode;
      header[1] = 0x80 | 127;
      header.writeBigUInt64BE(BigInt(payload.length), 2);
    }
    const masked = Buffer.alloc(payload.length);
    for (let index = 0; index < payload.length; index++) {
      masked[index] = payload[index] ^ mask[index % 4];
    }
    this.process.stdin.write(Buffer.concat([header, mask, masked]));
  }

  fail(error) {
    if (this.upgrade) this.upgrade.reject(error);
    for (const pending of this.pending.values()) pending.reject(error);
    this.pending.clear();
  }

  close() {
    this.process.stdin.end();
    this.process.kill('SIGTERM');
  }
}

const timeout = setTimeout(() => {
  process.stderr.write('Timed out waiting for Codex Unix proxy clients.\n');
  process.exit(1);
}, 15000);

(async () => {
  const first = new ProxyClient('agent-visor-unix-a');
  const second = new ProxyClient('agent-visor-unix-b');
  try {
    await Promise.all([first.connect(), second.connect()]);
    const [firstThreads, secondThreads] = await Promise.all([
      first.request('thread/list', { limit: 1 }),
      second.request('thread/list', { limit: 1 })
    ]);
    if (!Array.isArray(firstThreads.data) || !Array.isArray(secondThreads.data)) {
      throw new Error('thread/list response did not contain data arrays');
    }
    process.stdout.write('Codex Unix runtime PASS: two proxy clients share one broker.\n');
  } finally {
    clearTimeout(timeout);
    first.close();
    second.close();
  }
})().catch(error => {
  clearTimeout(timeout);
  process.stderr.write(`${error.stack || error}\n`);
  process.exitCode = 1;
});
NODE
