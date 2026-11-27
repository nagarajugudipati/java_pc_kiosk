import {browserRules, domainOf, isBlocked} from './policy.mjs';

const base = 'http://127.0.0.1:48731/kiosk/';
let refresh;
async function bridge(path, body) {
  const {pairingToken} = await chrome.storage.local.get('pairingToken');
  if (!pairingToken) throw new Error('Browser is not paired');
  return fetch(base + path, {
    method: body ? 'POST' : 'GET',
    headers: {Authorization: 'Bearer ' + pairingToken},
    body: body ? JSON.stringify(body) : undefined,
    signal: AbortSignal.timeout(3000),
    cache: 'no-store',
  });
}

async function apply(policy) {
  const previous = await chrome.declarativeNetRequest.getSessionRules();
  await chrome.declarativeNetRequest.updateSessionRules({
    removeRuleIds: previous.map((rule) => rule.id),
    addRules: browserRules(policy?.rules ?? []),
  });
  await chrome.storage.session.set({policy});
  await chrome.alarms.clear('policy-expiry');
  if (policy) await chrome.alarms.create('policy-expiry', {when: policy.expires});
}

function sync() {
  if (refresh) return refresh;
  refresh = (async () => {
    try {
      const response = await bridge('policy');
      if (!response.ok) throw new Error('Browser policy unavailable');
      const policy = await response.json();
      await apply(policy.leaseMs > 0
        ? {...policy, expires: Date.now() + Math.min(120000, policy.leaseMs)} : null);
    } catch {
      const {policy} = await chrome.storage.session.get('policy');
      if (!policy || Date.now() >= policy.expires) await apply(null);
    }
  })().finally(() => { refresh = undefined; });
  return refresh;
}

async function start() {
  if (!await chrome.alarms.get('policy-sync')) {
    await chrome.alarms.create('policy-sync', {periodInMinutes: 0.5});
  }
  await sync();
}

chrome.runtime.onInstalled.addListener(start);
chrome.runtime.onStartup.addListener(start);
chrome.alarms.onAlarm.addListener(sync);
chrome.storage.onChanged.addListener((_changes, area) => { if (area === 'local') void start(); });

async function visit(details, action) {
  if (details.frameId !== 0 || details.tabId < 0) return;
  const domain = domainOf(details.url);
  if (!domain) return;
  const {policy} = await chrome.storage.session.get('policy');
  if (!policy || Date.now() >= policy.expires) return;
  if (isBlocked(domain, policy.rules) !== (action === 'BLOCKED')) return;
  try { await bridge('event', {domain, action, session: policy.session}); } catch { /* bridge unavailable */ }
}

chrome.webNavigation.onBeforeNavigate.addListener((details) => visit(details, 'BLOCKED'));
chrome.webNavigation.onCommitted.addListener((details) => visit(details, 'OPENED'));
