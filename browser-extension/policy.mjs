export function domainOf(value) {
  try {
    const url = new URL(value);
    const host = url.hostname.toLowerCase().replace(/\.$/, '');
    return ['https:', 'http:'].includes(url.protocol) && host.length <= 240
      && /^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$/.test(host) ? host : null;
  } catch {
    return null;
  }
}

export function isBlocked(domain, rules) {
  return rules.filter((rule) => domain === rule.domain || domain.endsWith('.' + rule.domain))
    .sort((a, b) => b.domain.length - a.domain.length)[0]?.blocked === true;
}

export function browserRules(rules) {
  return rules.map(({domain, blocked}, index) => ({
    id: index + 1,
    priority: domain.length,
    action: {type: blocked ? 'block' : 'allow'},
    condition: {requestDomains: [domain], resourceTypes: ['main_frame']},
  }));
}
