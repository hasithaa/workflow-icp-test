// Does a runtime status change reach a client connected to the OTHER node?
//
// This documents a known gap rather than hunting a new one. `runtimeBroadcaster` is an
// in-process singleton, so a node publishes only to the sockets it is holding. With the console
// behind a round-robin balancer, two browsers land on two nodes and only one of them can hear
// any given event — silently, because the page looks fine and simply never updates.
//
// It is not workflow-specific and not introduced by the tunnel work; it blocks running the ICP
// two-up in general. Exits 0 either way: the point is the measurement, not a gate.
//
// Usage: node scripts/ws-fanout.mjs
import { readFileSync, existsSync } from 'node:fs';
import { createRequire } from 'node:module';
import { execSync } from 'node:child_process';

const require_ = createRequire(import.meta.url);
function loadPlaywright() {
  const candidates = [
    process.env.PLAYWRIGHT_DIR,
    new URL('../node_modules/playwright', import.meta.url).pathname,
    ...(() => {
      try {
        return execSync('ls -d ~/.npm/_npx/*/node_modules/playwright 2>/dev/null', { shell: '/bin/bash' })
          .toString().trim().split('\n').filter(Boolean);
      } catch { return []; }
    })(),
  ].filter(Boolean);
  for (const dir of candidates) {
    try { if (existsSync(dir)) return require_(dir); } catch { /* next */ }
  }
  console.error('playwright not found; see scripts/browser-check.mjs');
  process.exit(2);
}
const { chromium } = loadPlaywright();

const env = Object.fromEntries(
  readFileSync(new URL('../.env', import.meta.url), 'utf8')
    .split('\n').filter((l) => l && !l.startsWith('#') && l.includes('='))
    .map((l) => [l.slice(0, l.indexOf('=')), l.slice(l.indexOf('=') + 1)]),
);
const BASE = `https://localhost:${env.CONSOLE_PORT || '9446'}`;
const USER = env.ICP_ADMIN_USER || 'admin';
const PASS = env.ICP_ADMIN_PASSWORD || 'admin';
const sh = (cmd) => execSync(cmd, { shell: '/bin/bash' }).toString().trim();

const browser = await chromium.launch({ channel: 'chrome', headless: true });
const clients = [];

async function openClient(label) {
  const context = await browser.newContext({ ignoreHTTPSErrors: true });
  const page = await context.newPage();
  const client = { label, frames: [], sockets: 0 };
  page.on('websocket', (ws) => {
    client.sockets++;
    client.url = ws.url();
    ws.on('framereceived', (f) => {
      const payload = typeof f.payload === 'string' ? f.payload : f.payload?.toString?.() ?? '';
      if (payload) client.frames.push(payload.slice(0, 200));
    });
  });
  await page.goto(`${BASE}/login`, { waitUntil: 'domcontentloaded', timeout: 60000 });
  const u = page.locator('input[name="username"], input[type="text"]').first();
  await u.waitFor({ state: 'visible', timeout: 30000 });
  await u.fill(USER);
  await page.locator('input[name="password"], input[type="password"]').first().fill(PASS);
  await page.locator('button[type="submit"]').first().click();
  await page.waitForURL((x) => !x.pathname.includes('/login'), { timeout: 60000 });
  // The subscription lives in the app layout, so any authenticated page holds a socket.
  await page.waitForTimeout(4000);
  client.page = page;
  clients.push(client);
  console.log(`  ${label}: signed in, ${client.sockets} socket(s)`);
  return client;
}

try {
  console.log('\n=== Two consoles, balanced independently');
  await openClient('client-A');
  await openClient('client-B');

  // Which node is holding each socket, from the edge's own log.
  const upgrades = sh(`docker compose logs --tail=400 edge 2>/dev/null | grep -o 'runtime-status[^"]*" 101 upstream=[0-9.:]*' | tail -4 || true`);
  if (upgrades) {
    console.log('        socket upgrades, per the edge:');
    for (const line of upgrades.split('\n')) console.log(`          ${line}`);
  }

  console.log('\n=== Take one runtime offline');
  const victim = sh(`docker compose ps --format '{{.Name}}' | grep expense | tail -1`);
  console.log(`        stopping ${victim}`);
  sh(`docker stop ${victim} >/dev/null`);

  // heartbeatTimeoutSeconds is 30 and the offline sweep runs on schedulerIntervalSeconds (60),
  // so the transition can take a minute and a half to be published.
  const deadline = Date.now() + 150000;
  while (Date.now() < deadline) {
    const offline = sh(`docker compose exec -T postgres psql -qtAX -U ${env.POSTGRES_SUPERUSER || 'postgres'} -d ${env.ICP_DB_NAME || 'icp_db'} -c "SELECT count(*) FROM runtimes WHERE status = 'OFFLINE'" 2>/dev/null | tr -d ' '`);
    if (Number(offline) > 0 && clients.some((c) => c.frames.length > 0)) break;
    await clients[0].page.waitForTimeout(5000);
  }

  console.log('\n=== What each client heard');
  for (const c of clients) {
    const statusFrames = c.frames.filter((f) => /status|OFFLINE|runtime/i.test(f));
    console.log(`  ${c.label}: ${c.frames.length} frame(s), ${statusFrames.length} about runtime status`);
    for (const f of statusFrames.slice(0, 2)) console.log(`        ${f.slice(0, 120)}`);
  }

  const heard = clients.filter((c) => c.frames.some((f) => /status|OFFLINE|runtime/i.test(f))).length;
  console.log('');
  if (heard === clients.length) {
    console.log(`  ok    both clients heard it — fan-out reaches every node`);
  } else if (heard === 0) {
    console.log(`  note  neither client heard it: the event may not have been published in the window,`);
    console.log(`        or both sockets landed on the node that did not publish. Inconclusive.`);
  } else {
    console.log(`  GAP   ${heard} of ${clients.length} clients heard it — CONFIRMS the per-node broadcaster`);
    console.log(`        (analysis/05 §8a, PLAN R26). A client on the other node is never told, and`);
    console.log(`        nothing on the page says so. Pre-existing and not workflow-specific.`);
  }

  sh(`docker start ${victim} >/dev/null`);
  console.log(`\n        ${victim} restarted`);
} catch (e) {
  console.log(`  error: ${String(e.message).split('\n')[0]}`);
} finally {
  await browser.close();
}
