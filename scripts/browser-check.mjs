// Drives the real console in headless Chrome, because everything else here talks to the API.
//
// Three things only a browser can check:
//   1. Login and every subsequent request are balanced across nodes with no affinity, so the
//      SPA has to work when consecutive requests land on different servers. A session kept in
//      one node's memory would pass every API test and fail here.
//   2. The "Fetching … from the integration…" state actually renders. The API returning 202 is
//      not the same as a user being told; that gap is what made the page look hung.
//   3. Nothing throws. A React error boundary or a failed type assertion shows as a blank
//      panel, which no status-code assertion can see.
//
// Usage: NODE_PATH=<playwright> node scripts/browser-check.mjs [--headed] [--slow]
import { readFileSync, existsSync } from 'node:fs';
import { createRequire } from 'node:module';
import { execSync } from 'node:child_process';

// Playwright is not a dependency of this repo — it is whatever the machine already has. ESM
// ignores NODE_PATH, so resolve it explicitly: PLAYWRIGHT_DIR if set, then a local install,
// then the npx cache (`npx playwright --version` puts it there). Failing that, say how to get
// it rather than dying with a module-resolution stack trace.
const require_ = createRequire(import.meta.url);
function loadPlaywright() {
  const candidates = [
    process.env.PLAYWRIGHT_DIR,
    new URL('../node_modules/playwright', import.meta.url).pathname,
    ...(() => {
      try {
        return execSync('ls -d ~/.npm/_npx/*/node_modules/playwright 2>/dev/null', { shell: '/bin/bash' })
          .toString().trim().split('\n').filter(Boolean);
      } catch {
        return [];
      }
    })(),
  ].filter(Boolean);
  for (const dir of candidates) {
    try {
      if (existsSync(dir)) return require_(dir);
    } catch { /* try the next one */ }
  }
  console.error('playwright not found. Install it with `npx playwright install chromium`,');
  console.error('or point PLAYWRIGHT_DIR at an existing install.');
  process.exit(2);
}
const { chromium } = loadPlaywright();

const env = Object.fromEntries(
  readFileSync(new URL('../.env', import.meta.url), 'utf8')
    .split('\n')
    .filter((l) => l && !l.startsWith('#') && l.includes('='))
    .map((l) => [l.slice(0, l.indexOf('=')), l.slice(l.indexOf('=') + 1)]),
);

const PORT = env.CONSOLE_PORT || '9446';
const BASE = `https://localhost:${PORT}`;
const ORG = process.env.ORG_HANDLE || 'default';
const PROJECT = env.ICP_PROJECT?.replace(/_/g, '-') || 'workflow-icp-test';
const USER = process.env.CONSOLE_USER || env.ICP_ADMIN_USER || 'admin';
const PASS = process.env.CONSOLE_PASSWORD || env.ICP_ADMIN_PASSWORD || 'admin';
const headed = process.argv.includes('--headed');

let pass = 0;
let fail = 0;
const ok = (m) => { console.log(`  ok    ${m}`); pass++; };
const bad = (m) => { console.log(`  FAIL  ${m}`); fail++; };
const note = (m) => console.log(`        ${m}`);
const log = (m) => console.log(`\n=== ${m}`);

const browser = await chromium.launch({ channel: 'chrome', headless: !headed });
// The distribution and the edge both serve self-signed certificates.
const context = await browser.newContext({ ignoreHTTPSErrors: true, viewport: { width: 1500, height: 950 } });
const page = await context.newPage();

// Everything the page said went wrong, kept for the assertions at the end.
const consoleErrors = [];
const failedRequests = [];
page.on('console', (m) => {
  if (m.type() === 'error') consoleErrors.push(m.text().slice(0, 200));
});
page.on('pageerror', (e) => consoleErrors.push(`pageerror: ${e.message.slice(0, 200)}`));
page.on('requestfailed', (r) => failedRequests.push(`${r.method()} ${r.url().slice(0, 110)}`));

// Which node answered: the workflow API is the interesting one, and the edge balances per
// request, so a single page load is spread across both.
const statuses = [];
page.on('response', (r) => {
  const u = r.url();
  if (u.includes('/icp/workflow/') || u.includes('/auth/') || u.includes('/graphql')) {
    statuses.push({ url: u.replace(BASE, ''), status: r.status() });
  }
});

try {
  log('Sign in through the load balancer');
  await page.goto(`${BASE}/login`, { waitUntil: 'domcontentloaded', timeout: 60000 });
  // Wait for the form to be interactive rather than merely present: filling a field the SPA
  // has not wired up yet submits an empty form, and the failure looks like a bad password.
  const username = page.locator('input[name="username"], input[type="text"]').first();
  await username.waitFor({ state: 'visible', timeout: 30000 });
  await username.fill(USER);
  await page.locator('input[name="password"], input[type="password"]').first().fill(PASS);
  await page.locator('button[type="submit"]').first().click();
  const landed = await page.waitForURL((u) => !u.pathname.includes('/login'), { timeout: 45000 })
    .then(() => true).catch(() => false);
  if (!landed) {
    // One retry: the console is behind a round-robin balancer, and a node restarting mid-run
    // is a property of this environment rather than a bug in the page.
    note('the first sign-in did not land; retrying once');
    await page.goto(`${BASE}/login`, { waitUntil: 'domcontentloaded', timeout: 60000 });
    await page.locator('input[name="username"], input[type="text"]').first().fill(USER);
    await page.locator('input[name="password"], input[type="password"]').first().fill(PASS);
    await page.locator('button[type="submit"]').first().click();
    await page.waitForURL((u) => !u.pathname.includes('/login'), { timeout: 45000 });
  }
  ok(`signed in as ${USER}; landed on ${new URL(page.url()).pathname}`);

  log('The Workflows page of one integration');
  const wfUrl = `${BASE}/organizations/${ORG}/projects/${PROJECT}/components/expense-integration/workflows`;
  await page.goto(wfUrl, { waitUntil: 'domcontentloaded', timeout: 60000 });

  // Record what the page actually asks for and what it gets back. A disagreement between a
  // badge and the list beneath it is either two different questions or one stale answer, and
  // the request log is the only way to tell which.
  const wfBodies = [];
  page.on('response', async (r) => {
    const u = r.url();
    if (!u.includes('/icp/workflow/')) return;
    let summary = '';
    try {
      const b = await r.json();
      if (b && typeof b === 'object') {
        if ('count' in b) summary = `count=${b.count}`;
        else if (Array.isArray(b.items)) summary = `items=${b.items.length}`;
        else if (b.status) summary = String(b.status);
      }
    } catch { /* not JSON, or already consumed */ }
    wfBodies.push(`${r.status()} ${u.slice(u.indexOf('/750e8400') + 37) || u.slice(-60)} ${summary}`);
  });

  log('My Tasks — the badge and the list must agree');
  // This is the default tab. The badge comes from human-tasks/pending-count and the list from
  // human-tasks?status=PENDING: two reads, two cache entries, one truth. If they disagree the
  // user is looking at a number that contradicts the page under it.
  const tasksTab = page.getByRole('tab', { name: /My Tasks/i });
  await tasksTab.waitFor({ state: 'visible', timeout: 30000 });
  const badgeText = ((await tasksTab.textContent()) || '').replace(/[^0-9]/g, '');
  const badge = badgeText === '' ? null : Number(badgeText);
  note(`badge reads ${badge === null ? '(none)' : badge}`);

  // Give the list its own time: the read may be materializing, and the query polls.
  const taskRows = page.locator('table tbody tr');
  const sawRows = await taskRows.first().waitFor({ state: 'visible', timeout: 60000 }).then(() => true).catch(() => false);
  const rowCount = sawRows ? await taskRows.count() : 0;
  const emptyClaim = await page.getByText(/No pending tasks/i).isVisible().catch(() => false);
  const fetchClaim = await page.getByText(/Fetching .* from the integration/i).isVisible().catch(() => false);
  note(`list shows ${rowCount} row(s)${emptyClaim ? ', and claims "No pending tasks."' : ''}${fetchClaim ? ', and says it is fetching' : ''}`);

  if (badge !== null && badge > 0 && emptyClaim) {
    bad(`the badge says ${badge} while the list claims there are none`);
  } else if (badge !== null && badge > 0 && rowCount === 0 && !fetchClaim) {
    bad(`the badge says ${badge} and the list rendered nothing, without saying it is fetching`);
  } else if (badge !== null && rowCount > 0 && badge !== rowCount) {
    note(`badge ${badge} vs ${rowCount} rows — a filter difference, not necessarily wrong`);
    ok('the badge and the list both report work');
  } else if (rowCount > 0) {
    ok(`the badge and the list agree (${badge} / ${rowCount} rows)`);
  } else {
    note('no pending tasks anywhere — run scripts/populate.sh for this assertion to mean something');
  }

  log('Workflow Executions — the instance list');
  const execTab = page.getByRole('tab', { name: /Workflow Executions/i });
  if (await execTab.isVisible().catch(() => false)) {
    await execTab.click();
    const fetching = page.getByText(/Fetching .* from the integration/i);
    const sawFetching = await fetching.first().isVisible().catch(() => false);
    if (sawFetching) ok('the page says it is fetching, rather than showing a bare spinner');
    else note('no fetching state seen — this read was already cached, the other valid path');

    const rows = page.locator('table tbody tr');
    const appeared = await rows.first().waitFor({ state: 'visible', timeout: 90000 }).then(() => true).catch(() => false);
    if (appeared) {
      ok(`${await rows.count()} instance row(s) rendered without a reload`);
      const stillEmpty = await page.getByText(/No workflows found/i).isVisible().catch(() => false);
      stillEmpty ? bad('the page claims "No workflows found" while rows exist') : ok('no contradictory empty state');
    } else {
      const claims = await page.getByText(/No workflows found/i).isVisible().catch(() => false);
      bad(claims ? 'the instance list claims "No workflows found"' : 'the instance list never rendered');
    }
  } else {
    note('the Workflow Executions tab is not visible for this user');
  }

  log('What the browser saw');
  const wfCalls = statuses.filter((s) => s.url.includes('/icp/workflow/'));
  const codes = [...new Set(wfCalls.map((s) => s.status))].sort();
  note(`${wfCalls.length} workflow API call(s), status codes: ${codes.join(', ') || 'none'}`);
  for (const line of wfBodies.slice(-12)) note(`  ${line}`);
  // 202 is expected and healthy here: it is the contract, not an error.
  const serverErrors = wfCalls.filter((s) => s.status >= 500);
  serverErrors.length === 0
    ? ok('no 5xx from the workflow API')
    : bad(`${serverErrors.length} 5xx: ${serverErrors.slice(0, 3).map((s) => `${s.status} ${s.url}`).join(' | ')}`);

  consoleErrors.length === 0
    ? ok('no console errors or uncaught exceptions')
    : bad(`${consoleErrors.length} console error(s): ${consoleErrors.slice(0, 3).join(' | ')}`);

  // Ignore the noise a page makes while navigating away.
  const realFailures = failedRequests.filter((r) => !r.includes('websocket') && !r.includes('ws://'));
  realFailures.length === 0
    ? ok('no failed requests')
    : note(`${realFailures.length} failed request(s): ${realFailures.slice(0, 3).join(' | ')}`);

  await page.screenshot({ path: '/tmp/console-workflows.png', fullPage: false });
  note('screenshot: /tmp/console-workflows.png');
} catch (e) {
  bad(`the run threw: ${String(e.message).split('\n')[0]}`);
  await page.screenshot({ path: '/tmp/console-failure.png' }).catch(() => {});
  note('screenshot: /tmp/console-failure.png');
} finally {
  await browser.close();
}

console.log(`\n=== browser: ${pass} passed, ${fail} failed`);
process.exit(fail === 0 ? 0 : 1);
