// DOM contract fixtures only. No fixture backend is shipped by the application.
import { readFileSync } from 'node:fs';
import { strict as assert } from 'node:assert';
import { test } from 'node:test';
import vm from 'node:vm';

const html = readFileSync(new URL('../web/static/index.html', import.meta.url), 'utf8');
const i18n = readFileSync(new URL('../web/static/i18n.js', import.meta.url), 'utf8');
const app = readFileSync(new URL('../web/static/app.js', import.meta.url), 'utf8');
class Element {
  constructor() { this.textContent = ''; this.hidden = false; this.children = []; this.listeners = {}; this.dataset = {}; this.className = ''; this.value = ''; this.disabled = false; this.attributes = {}; this.classList = { toggle: () => {} }; }
  addEventListener(type, action) { this.listeners[type] = action; }
  setAttribute(key, value) { this.attributes[key] = value; }
  append(...values) { this.children.push(...values); }
  replaceChildren(...values) { this.children = [...values]; }
}
function view(result = null, connected = false) {
  const nodes = {}, translated = [], languageButtons = ['en-GB', 'tr'].map(lang => Object.assign(new Element(), { dataset: { lang } }));
  for (const match of html.matchAll(/<[^>]+\bid="([^"]+)"[^>]*>/g)) {
    const node = new Element(), tag = match[0];
    node.value = tag.match(/\bvalue="([^"]*)"/)?.[1] || '';
    node.hidden = /\bhidden\b/.test(tag); nodes[match[1]] = node;
  }
  for (const match of html.matchAll(/\bdata-i18n="([^"]+)"/g)) translated.push(Object.assign(new Element(), { dataset: { i18n: match[1] } }));
  const radios = [0, 1, 2].map(value => Object.assign(new Element(), { value: String(value) }));
  const events = {}, storage = new Map(), window = {};
  const document = { documentElement: { lang: 'en-GB' },
    getElementById: id => { assert.ok(nodes[id], `Missing HTML element ${id}`); return nodes[id]; },
    querySelectorAll: query => query === '[data-i18n]' ? translated : query === '[data-lang]' ? languageButtons : query === 'input[name=policy]' ? radios : [],
    querySelector: query => query === 'input[name=policy]:checked' ? radios[0] : null,
    createElement: () => new Element(), addEventListener: (type, action) => { events[type] = action; },
    dispatchEvent: event => events[event.type]?.(event),
  };
  const context = vm.createContext({ window, document, Intl, console,
    localStorage: { getItem: key => storage.get(key) || null, setItem: (key, value) => storage.set(key, value) },
    CustomEvent: class { constructor(type) { this.type = type; } },
    setTimeout: action => { action(); return 1; }, setInterval: () => 1,
    fetch: async (path, options) => {
      let data;
      if (path === '/api/session') data = { token: 'unit-test-only' };
      else if (path === '/api/device') data = { connected, ready: connected, reason_code: connected ? 'ready' : 'linux_required', device: connected ? { rows: 64, cols: 64 } : null };
      else if (path === '/api/jobs' && options.method === 'POST') data = { id: 'fixture-request' };
      else if (path === '/api/jobs/fixture-request') data = { id: 'fixture-request', state: 'done', result, events: [], record_saved: true };
      else throw new Error(`Unexpected test API ${path}`);
      return { ok: true, json: async () => data };
    },
  });
  vm.runInContext(i18n, context); vm.runInContext(app, context);
  return { nodes, translated, languageButtons, window, context, document };
}
const settle = () => new Promise(resolve => setImmediate(resolve));
function fixture(policy, observed = true) {
  const metadata = { job_id: 2, generation: 2, submit_ns: '1000000000000000000', timeout_ns: '1000000000020000000',
    handoff_ns: policy < 2 ? '1000000000020000100' : '1000000000500000001', rx_done_ns: '1000000000500000000',
    tx_done_ns: '1000000000000010000', release_ns: '1000000000500000200', timed_out: 1, changed_bytes: 256, guard_errors: 0, core_cycles: 8192 };
  return { request: { policy, a: { label: '<script>A</script>' }, b: { label: 'Part B' } },
    window_observed: observed, wrong_product_decision: observed && policy === 0, wrong_output: observed && policy === 0,
    delivered_b: observed ? { source: policy === 0 ? 'late_a_dma' : 'own_b_dma', score: policy === 0 ? 948 : 445, decision: policy === 0 ? 'accept' : 'reject' } : null,
    reference_b: { score: 445, decision: 'reject' }, device: { rows: 64, cols: 64 }, threshold: 700,
    capture_a: { metadata, dma_sha256: 'test-a-hash' }, control_b: { dma_sha256: 'test-b-hash' },
    actual_b: policy === 0 ? null : { metadata: { rx_done_ns: '1000000000500100000' } } };
}
test('English first load, all static translations and original offline behaviour', async () => {
  const v = view(); await settle();
  assert.equal(v.document.documentElement.lang, 'en-GB');
  assert.equal(v.nodes['connection-text'].textContent, 'Device offline');
  assert.equal(v.nodes['run-button'].disabled, true);
  assert.equal(v.nodes['result-content'].hidden, true);
  for (const node of v.translated) assert.notEqual(node.textContent, node.dataset.i18n, `Missing EN key ${node.dataset.i18n}`);
  v.languageButtons[1].listeners.click();
  assert.equal(v.document.documentElement.lang, 'tr');
  assert.equal(v.nodes['connection-text'].textContent, 'Kart bağlı değil');
  for (const node of v.translated) assert.notEqual(node.textContent, node.dataset.i18n, `Missing TR key ${node.dataset.i18n}`);
});
test('P0 renders the real-response contract and preserves full-width timestamps', async () => {
  const v = view(fixture(0), true); await settle();
  await v.nodes['request-form'].listeners.submit({ preventDefault() {} });
  assert.equal(v.nodes['expected-score'].textContent, '445');
  assert.equal(v.nodes['delivered-score'].textContent, '948');
  assert.equal(v.nodes['delivered-decision'].textContent, 'ACCEPT');
  assert.equal(v.nodes['impact-text'].textContent, 'A product that should be rejected was accepted.');
  assert.equal(v.nodes['evidence-content'].hidden, false);
  assert.match(v.nodes['outcome-description'].textContent, /<script>A<\/script>/); // textContent, never HTML.
  assert.match(v.nodes['raw-record'].textContent, /1000000000020000100/);
  assert.equal(v.nodes.timeline.children[2].children[1].textContent, '+20 ms');
});
test('protected result and missed window do not show a fabricated wrong reply', async () => {
  for (const [policy, observed] of [[2, true], [0, false]]) {
    const v = view(fixture(policy, observed), true); await settle();
    await v.nodes['request-form'].listeners.submit({ preventDefault() {} });
    assert.equal(v.nodes['delivered-score'].textContent, observed ? '445' : '—');
    assert.equal(v.nodes['delivered-decision'].textContent, observed ? 'REJECT' : 'NOT DELIVERED');
    v.languageButtons[1].listeners.click();
    assert.match(v.nodes['outcome-title'].textContent, observed ? /teslim edilmedi/ : /Yanlış çıktı/);
  }
});
