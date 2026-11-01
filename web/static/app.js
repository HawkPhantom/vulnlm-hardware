'use strict';
(() => {
  const el = id => document.getElementById(id);
  const t = (key, parameters) => window.VulnLMI18n.t(key, parameters);
  let token = '', activeJob = null, lastJob = null, polling = false, currentDevice = null, currentPhase = 'starting';
  const features = ['surface', 'dimension', 'temperature', 'vibration'];
  const format = value => new Intl.NumberFormat(window.VulnLMI18n.language).format(value);
  const ms = value => `${new Intl.NumberFormat(window.VulnLMI18n.language, { maximumFractionDigits: 3 }).format(value)} ms`;
  const decision = value => t(value === 'accept' ? 'accept' : value === 'reject' ? 'reject' : 'notDelivered');
  function renderScenario() {
    const e2 = el('scenario').value === 'e2';
    el('scenario-tag').textContent = e2 ? 'E2 · AXI-Stream' : 'E1 · DMA';
    el('scenario-title').textContent = t(e2 ? 'e2Title' : 'scenarioTitle');
    el('scenario-description').textContent = t(e2 ? 'e2Description' : 'scenarioDescription');
  }
  async function api(path, options = {}) {
    const response = await fetch(path, { cache: 'no-store', ...options });
    const data = await response.json();
    if (!response.ok) { const error = new Error(data.error || t('apiError')); error.status = response.status; throw error; }
    return data;
  }
  function state(name) {
    for (const key of ['empty-state', 'running-state', 'error-state', 'result-content']) el(key).hidden = key !== name;
    el('evidence-content').hidden = name !== 'result-content';
    el('evidence-empty').hidden = name === 'result-content';
  }
  function lockForm(locked) { el('request-fields').disabled = locked; el('context-fields').disabled = locked; }
  function showError(message) { state('error-state'); el('error-message').textContent = message; el('result-tag').textContent = t('noOutput'); }
  function input(prefix) {
    const value = { label: el(`${prefix}-label`).value.trim() };
    for (const feature of features) value[feature] = Number(el(`${prefix}-${feature}`).value);
    return value;
  }
  function renderEvents(events) {
    el('live-events').replaceChildren();
    if (!events.length) { const li = document.createElement('li'); li.textContent = t('noRequest'); el('live-events').append(li); }
    const translations = { baseline: 'baselineMessage', capture: 'captureMessage', protected: 'protectedMessage', misdelivery: 'misdeliveryMessage' };
    for (const event of events) {
      const li = document.createElement('li');
      li.textContent = `${event.utc ? new Date(event.utc).toLocaleTimeString(window.VulnLMI18n.language) + '  ' : ''}${translations[event.phase] ? t(translations[event.phase]) : event.message}`;
      el('live-events').append(li);
    }
  }
  function renderDevice() {
    if (!currentDevice) return;
    const s = currentDevice;
    el('connection').className = `connection ${s.busy ? 'busy' : s.ready ? 'online' : ''}`;
    el('connection-text').textContent = t(s.busy ? 'deviceBusy' : s.ready ? 'deviceReady' : s.connected ? 'deviceNotReady' : 'offline');
    el('connection-note').textContent = s.reason_code ? t(s.reason_code) : s.reason;
    el('connection-note').className = `notice ${s.ready ? 'ready' : ''}`;
    el('core-shape').textContent = s.device ? `${s.device.rows}×${s.device.cols}` : '—';
    el('device-chip').textContent = s.device ? `KV260 · ${s.device.rows}×${s.device.cols}` : t('hardwareRequired');
    el('device-chip').className = `dot-label ${s.ready ? 'online' : ''}`;
    el('run-button').disabled = !s.ready || !!activeJob;
    lockForm(!!activeJob);
  }
  function renderRunning() {
    el('result-tag').textContent = t('processingTag');
    el('running-title').textContent = t(currentPhase === 'baseline' ? 'baselineTitle' : currentPhase === 'protected' ? 'protectedTitle' : 'captureTitle');
    const key = { baseline: 'baselineMessage', protected: 'protectedMessage', capture: 'captureMessage', misdelivery: 'misdeliveryMessage' }[currentPhase];
    el('running-message').textContent = t(key || 'starting');
  }
  function renderResult(job) {
    lastJob = job;
    const r = job.result, sent = r.delivered_b, reference = r.reference_b, crossed = sent?.source === 'late_a_dma';
    state('result-content'); renderEvents(job.events || []);
    el('result-tag').textContent = r.window_observed ? t('hardwareTag', { policy: r.request.policy }) : t('windowMiss');
    el('result-hero').className = `result-hero ${crossed ? 'danger' : r.window_observed ? 'safe' : ''}`;
    el('outcome-eyebrow').textContent = t(r.window_observed ? 'readHardware' : 'noWindow');
    el('outcome-title').textContent = t(!r.window_observed ? 'noWrongOutput' : r.wrong_product_decision ? 'wrongDecision' : crossed ? 'crossedReply' : 'protectedReply');
    el('outcome-description').textContent = t(!r.window_observed ? 'missedDescription' : crossed ? 'crossedDescription' : r.request.policy === 1 ? 'p1Description' : 'p2Description', { a: r.request.a.label, b: r.request.b.label });
    el('expected-score').textContent = format(reference.score); el('expected-decision').textContent = decision(reference.decision);
    el('delivered-score').textContent = sent ? format(sent.score) : '—'; el('delivered-decision').textContent = decision(sent?.decision);
    el('source-label').textContent = sent ? t(crossed ? 'sourceA' : 'sourceB', { label: crossed ? r.request.a.label : r.request.b.label }) : t('notDelivered');
    el('delivered-card').className = `score-card delivered ${crossed ? 'wrong' : ''}`;
    const impact = !r.window_observed ? 'impactNoReply' : r.wrong_product_decision ? reference.decision === 'reject' ? 'impactFalseAccept' : 'impactFalseReject' : r.wrong_output ? 'impactSameDecision' : crossed ? 'impactSameScore' : 'impactCorrect';
    el('impact-text').textContent = t(impact);
    el('impact-detail').textContent = !r.window_observed ? t('retryWindow') : t('scoreComparison', { expected: format(reference.score), delivered: sent ? format(sent.score) : '—', threshold: r.threshold });
    const m = r.capture_a.metadata, events = [];
    function add(key, value, critical = false) { if (BigInt(value) > 0n) events.push({ key, time: BigInt(value), critical }); }
    add('eventSubmit', m.submit_ns); add('eventTimeout', m.timeout_ns);
    if (r.window_observed) add(r.request.policy < 2 ? 'eventEarlyHandoff' : 'eventSafeHandoff', m.handoff_ns, r.request.policy < 2);
    add('eventDma', m.rx_done_ns); if (r.actual_b) add('eventB', r.actual_b.metadata.rx_done_ns);
    el('timeline').replaceChildren();
    for (const event of events.sort((a, b) => a.time < b.time ? -1 : a.time > b.time ? 1 : 0)) {
      const li = document.createElement('li'), label = document.createElement('span'), time = document.createElement('time');
      label.textContent = t(event.key); time.textContent = `+${ms(Number(event.time - BigInt(m.submit_ns)) / 1e6)}`;
      if (event.critical) li.className = 'critical'; li.append(label, time); el('timeline').append(li);
    }
    const data = [
      ['proofSource', '/dev/kv260-lab → DMA → FPGA'], ['proofRequest', job.id],
      ['proofShape', `${r.device.rows} × ${r.device.cols}`], ['proofIdentity', `${m.job_id} / ${m.generation}`],
      ['proofTimeout', t(m.timed_out ? 'yes' : 'no')], ['proofGuard', m.guard_errors],
      ['proofChanged', r.request.policy < 2 && r.window_observed ? m.changed_bytes : t('noEarlyOwner')],
      ['proofAHash', r.capture_a.dma_sha256], ['proofBHash', r.control_b.dma_sha256],
      ['proofCycles', format(m.core_cycles)], ['proofSaved', t(job.record_saved ? 'saved' : 'checkRecord')],
    ];
    el('evidence-list').replaceChildren();
    for (const [key, value] of data) { const dt = document.createElement('dt'), dd = document.createElement('dd'); dt.textContent = t(key); dd.textContent = String(value); el('evidence-list').append(dt, dd); }
    el('raw-record').textContent = JSON.stringify(job, null, 2);
  }
  async function checkDevice() {
    try {
      currentDevice = await api('/api/device');
      if (currentDevice.active_job && !activeJob) activeJob = currentDevice.active_job;
      renderDevice(); if (activeJob && !polling) watch();
    } catch (e) {
      el('connection').className = 'connection'; el('connection-text').textContent = t('serverOffline');
      el('connection-note').textContent = e.message; el('run-button').disabled = true;
    }
  }
  async function watch() {
    if (polling || !activeJob) return;
    polling = true; lockForm(true); state('running-state'); renderRunning();
    try {
      while (activeJob) {
        const job = await api(`/api/jobs/${encodeURIComponent(activeJob)}`);
        if (job.state === 'done') { renderResult(job); activeJob = null; break; }
        if (job.state === 'error') { showError(job.error); renderEvents(job.events || []); activeJob = null; break; }
        currentPhase = job.phase; renderRunning(); renderEvents(job.events); el('wait-note').hidden = !job.waiting_for_hardware;
        await new Promise(resolve => setTimeout(resolve, 350));
      }
    } catch (e) {
      if (e.status === 404) activeJob = null;
      showError(t('connectionLost', { error: e.message }));
    } finally { polling = false; lockForm(false); await checkDevice(); }
  }
  document.querySelectorAll('input[name=policy]').forEach(radio => radio.addEventListener('change', () => { el('active-policy').textContent = `P${radio.value}`; }));
  el('request-form').addEventListener('submit', async event => {
    event.preventDefault(); if (activeJob) return;
    const body = { a: input('a'), b: input('b'), scenario: el('scenario').value || 'e1', policy: Number(document.querySelector('input[name=policy]:checked').value), delay_cycles: Number(el('delay').value), timeout_ms: Number(el('timeout').value) };
    el('run-button').disabled = true;
    try {
      const job = await api('/api/jobs', { method: 'POST', headers: { 'Content-Type': 'application/json', 'X-KV260-Session': token }, body: JSON.stringify(body) });
      activeJob = job.id; currentPhase = 'starting'; await watch();
    } catch (e) { showError(e.message); await checkDevice(); }
  });
  el('download-button').addEventListener('click', () => {
    if (!lastJob) return;
    const url = URL.createObjectURL(new Blob([JSON.stringify(lastJob, null, 2)], { type: 'application/json' }));
    const a = document.createElement('a'); a.href = url; a.download = `vulnlm-hardware-${lastJob.id}.json`; a.click(); setTimeout(() => URL.revokeObjectURL(url), 1000);
  });
  el('scenario').addEventListener('change', renderScenario);
  document.addEventListener('vulnlm:language', () => { renderScenario(); renderDevice(); if (!el('result-content').hidden && lastJob) renderResult(lastJob); else if (polling) renderRunning(); });
  async function start() {
    try { token = (await api('/api/session')).token; } catch (e) { el('connection-note').textContent = e.message; }
    await checkDevice(); setInterval(checkDevice, 4000);
  }
  start();
})();
