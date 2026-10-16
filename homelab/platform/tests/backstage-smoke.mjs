// Backstage smoke test in a real headless Chromium, over plain http.
// Run via ./backstage-smoke.sh (pinned Playwright image + package).
// Env: BASE (default http://backstage.192.168.1.153.nip.io), OUT (screenshot dir, default /out).
import { chromium } from 'playwright';
import fs from 'node:fs';

const BASE = process.env.BASE || 'http://backstage.192.168.1.153.nip.io';
const OUT = process.env.OUT || '/out';
fs.mkdirSync(OUT, { recursive: true });

const results = [];
const note = (step, ok, detail = '') => {
  results.push({ step, ok, detail });
  console.log(`${ok ? 'PASS' : 'FAIL'}  ${step}${detail ? '  -- ' + detail : ''}`);
};

const browser = await chromium.launch();
const ctx = await browser.newContext({ viewport: { width: 1440, height: 900 } });
const page = await ctx.newPage();

let where = 'root';
const consoleErrors = [];
const failed = [];
page.on('console', (m) => {
  if (m.type() === 'error' || (m.type() === 'warning' && !/icons were registered as IconComponent/.test(m.text())))
    consoleErrors.push(`[${where}] ${m.type()}: ${m.text().slice(0, 300)}`);
});
page.on('pageerror', (e) => consoleErrors.push(`[${where}] pageerror: ${String(e.message).slice(0, 300)} @ ${String(e.stack || '').split('\n').slice(1, 4).map((l) => l.trim().replace(BASE, '')).join(' < ').slice(0, 400)}`));
page.on('requestfailed', (r) => r.failure()?.errorText !== 'net::ERR_ABORTED' && failed.push(`[${where}] ${r.method()} ${r.url()} ${r.failure()?.errorText}`));
page.on('response', (r) => {
  if (r.status() >= 400) failed.push(`[${where}] HTTP ${r.status()} ${r.request().method()} ${r.url()}`);
});

const shot = (n) => page.screenshot({ path: `${OUT}/${n}.png`, fullPage: true });
const settle = async () => { await page.waitForLoadState('networkidle').catch(() => {}); await page.waitForTimeout(1500); };

// 0. secure context check (explains the disabled features)
// 1. root
where = 'root';
const resp = await page.goto(BASE + '/', { waitUntil: 'load' });
await settle();
note('root loads', resp.status() === 200, `HTTP ${resp.status()}, title "${await page.title()}", url ${page.url()}`);
const sec = await page.evaluate(() => ({ secure: window.isSecureContext, uuid: typeof crypto.randomUUID }));
note('plain-http context (expected: not secure, no randomUUID)', !sec.secure && sec.uuid === 'undefined', JSON.stringify(sec));
await shot('01-root');

// 2. guest sign-in
where = 'signin';
const enter = page.getByRole('button', { name: /^enter$/i });
if (await enter.count()) {
  await enter.first().click();
  await settle();
  note('guest sign-in', !(await page.getByRole('button', { name: /^enter$/i }).count()), `url ${page.url()}`);
} else {
  note('guest sign-in', true, 'no Enter button shown (already signed in or no sign-in page)');
}
await shot('02-after-signin');

// 3. catalog
where = 'catalog';
await page.goto(BASE + '/', { waitUntil: 'load' });
await settle();
await shot('03-catalog');
const kindBefore = await page.locator('main').innerText().catch(() => '');
const rows = async () => page.locator('table tbody tr').count();
const tableText = async () => page.locator('table').first().innerText().catch(() => '');
// default filter is Kind=Component, owned/all toggle
const compRows = await rows();
note('catalog (served at /, not /catalog) table renders', compRows > 0, `${compRows} Component rows (default filter)`);
const names = (await page.locator('table tbody tr td a').allInnerTexts()).filter(Boolean);
console.log('   component names:', [...new Set(names)].join(', '));
// every kind via the API from the browser session (the token is in the page's own requests)
const counts = await page.evaluate(async (base) => {
  const out = {};
  try {
    const t = await (await fetch(base + '/api/auth/guest/refresh', { credentials: 'include' })).json().catch(() => null);
    const token = t?.backstageIdentity?.token;
    const r = await fetch(base + '/api/catalog/entities', { headers: token ? { Authorization: `Bearer ${token}` } : {} });
    const list = await r.json();
    out.total = list.length;
    out.byKind = {};
    for (const e of list) out.byKind[e.kind] = (out.byKind[e.kind] || 0) + 1;
    out.status = r.status;
  } catch (e) { out.error = String(e); }
  return out;
}, BASE);
note('catalog API from the browser session', !!counts.total, JSON.stringify(counts));

// demo-api
where = 'demo-api';
await page.goto(BASE + '/catalog/default/component/demo-api', { waitUntil: 'load' });
await settle();
await shot('04-demo-api-overview');
const body = await page.locator('main').innerText().catch(() => '');
note('demo-api overview renders', /demo-api/.test(body), `owner shown: ${/app-team/.test(body)}, system: ${/demo-product/.test(body)}, lifecycle: ${/experimental/.test(body)}`);
note('demo-api owner = app-team', /app-team/.test(body));

// API tab: click the entity page's own "APIs" tab (the route is /api in 1.55? find it by clicking)
where = 'api-tab';
await page.goto(BASE + '/catalog/default/component/demo-api', { waitUntil: 'load' });
await settle();
await page.getByRole('link', { name: /^apis$/i }).last().click();
await settle();
const apiTabUrl = page.url().replace(BASE, '');
await shot('05-demo-api-api-tab');
let t = await page.locator('main').innerText().catch(() => '');
note('API tab lists the demo-api API', /demo-api/.test(t) && /openapi/i.test(t), `${apiTabUrl} :: ${t.replace(/\s+/g, ' ').slice(t.search(/Provided|APIs/), 400).slice(0, 220)}`);
// open the API entity's definition (swagger-ui renders the OpenAPI spec)
where = 'api-definition';
await page.goto(BASE + '/catalog/default/api/demo-api/definition', { waitUntil: 'load' });
await settle();
await page.waitForTimeout(2500);
await shot('06-api-definition');
const ops = await page.locator('.swagger-ui .opblock').count();
const opText = (await page.locator('.swagger-ui .opblock-summary').allInnerTexts()).map((x) => x.replace(/\s+/g, ' ')).join(' ; ');
note('OpenAPI definition renders (swagger-ui, operations listed)', ops > 0, `${ops} operations: ${opText.slice(0, 200)}`);

// 4. dependencies / graph (this image's entity page has no Dependencies tab: use the graph page and the overview's relations card)
where = 'dependencies';
await page.goto(BASE + '/catalog/default/component/demo-api', { waitUntil: 'load' });
await settle();
console.log('   demo-api tabs:', (await page.getByRole('link').allInnerTexts()).join(' | ').slice(0, 300));
const hasDepTab = (await page.getByRole('link', { name: /dependenc/i }).count()) > 0;
console.log(`INFO  Dependencies tab on the entity page: ${hasDepTab ? 'present' : 'absent in this image (tabs are Overview/TechDocs/APIs/Kubernetes); the catalog graph covers it'}`);
where = 'catalog-graph';
await page.goto(BASE + '/catalog-graph?rootEntityRefs%5B%5D=component%3Adefault%2Fdemo-api', { waitUntil: 'load' });
await settle();
await page.waitForTimeout(3500);
await shot('08-catalog-graph');
const gNodes = await page.locator('svg g[data-testid="node"], svg g[class*="node"]').count();
const gText = (await page.locator('svg text').allInnerTexts()).join(', ');
note('Catalog graph page renders nodes', gNodes > 0, `${gNodes} nodes; labels: ${gText.slice(0, 200)}`);
where = 'visualizer';
await page.getByRole('link', { name: /^Visualizer$/ }).first().click();
await settle();
await page.waitForTimeout(3000);
await shot('08b-visualizer');
note('Visualizer (sidebar) renders', (await page.locator('svg').count()) > 1, page.url().replace(BASE, ''));

// 5. kubernetes
where = 'kubernetes';
await page.goto(BASE + '/catalog/default/component/demo-api', { waitUntil: 'load' });
await settle();
await page.getByRole('link', { name: /^kubernetes$/i }).last().click();
await settle();
await page.waitForTimeout(4000);
const warn = page.getByText(/problem retrieving Kubernetes objects/i);
let warnDetail = '';
if (await warn.count()) { await warn.first().click().catch(() => {}); await page.waitForTimeout(800); }
await page.getByText(/^rke2$/).first().click().catch(() => {});
await page.waitForTimeout(1500);
await shot('09-kubernetes');
t = (await page.locator('main').innerText().catch(() => '')).replace(/\s+/g, ' ');
const hasPods = /Cluster 2 pods/.test(t) && /namespace: demo-ci/.test(t);
note('Kubernetes tab: no warning banner', !/problem retrieving Kubernetes objects/.test(t), (t.match(/Errors: .{0,200}/) || ['none'])[0]);
note('Kubernetes tab shows demo-ci pods', hasPods, t.slice(t.indexOf('Your Clusters'), t.indexOf('Your Clusters') + 300));

// 6. other pages. expect404: features switched off on purpose in values/backstage.yaml (no secure context over http)
const pages = [
  ['api-docs index', '/api-docs', /API Explorer/],
  ['create (scaffolder), template listed', '/create', /(new-service|Python service|golden path)/i],
  ['docs (TechDocs) index', '/docs', /Docs/],
  ['settings (guest)', '/settings', /user:development\/guest/],
  ['jenkins component page', '/catalog/default/component/jenkins', /ci-platform/],
  ['search (switched off on purpose)', '/search', /PAGE NOT FOUND/, true],
  ['notifications (switched off on purpose)', '/notifications', /PAGE NOT FOUND/, true],
];
for (const [name, path, want, expect404] of pages) {
  where = name;
  try {
    await page.goto(BASE + path, { waitUntil: 'load' });
    await settle();
    const tx = (await page.locator('body').innerText().catch(() => '')).replace(/\s+/g, ' ');
    note(name, want.test(tx), tx.replace(/^.*?Settings /, '').slice(0, 160));
    await shot('10-' + name.replace(/[^a-z0-9]+/gi, '-').toLowerCase());
  } catch (e) { note(name, false, String(e).slice(0, 200)); }
}
// the backstage component's own Kubernetes tab (label-selector annotation, namespace backstage)
where = 'backstage k8s';
await page.goto(BASE + '/catalog/default/component/backstage/kubernetes', { waitUntil: 'load' });
await settle();
await page.waitForTimeout(4000);
await shot('11-backstage-kubernetes');
t = (await page.locator('main').innerText().catch(() => '')).replace(/\s+/g, ' ');
note('backstage component Kubernetes tab shows its pod', /1 pod/.test(t) || /backstage-[a-z0-9]+-[a-z0-9]{5}/.test(t), t.slice(t.indexOf('Component'), 500));

await browser.close();
const uniq = (a) => [...new Set(a)];
console.log('\n--- console errors/warnings (deduped) ---');
uniq(consoleErrors).forEach((l) => console.log(l));
console.log('\n--- failed requests / HTTP >= 400 (deduped) ---');
uniq(failed).forEach((l) => console.log(l));
fs.writeFileSync(`${OUT}/results.json`, JSON.stringify({ results, consoleErrors: uniq(consoleErrors), failed: uniq(failed) }, null, 2));
process.exit(results.every((r) => r.ok) ? 0 : 1);
