// Cloudflare Worker: fetch IPv4 from a remote page and update Cloudflare DNS records
// Bindings expected in Workers:
// - CF_ZONE_NAME: your zone name, e.g. example.com
// - CF_API_TOKEN: Cloudflare API token with Zone:DNS:Edit permission
// - CF_RECORD_NAMES (optional): comma-separated record names, e.g. "@,www"
// - CF_RECORD_TYPE (optional): DNS record type, default A

const TARGET_URL = 'https://ip.164746.xyz/ipTop.html';

addEventListener('fetch', (event) => {
  event.respondWith(handleRequest(event.request));
});

async function handleRequest(request) {
  try {
    const apiToken = CF_API_TOKEN;
    const zoneName = CF_ZONE_NAME;
    if (!apiToken || !zoneName) {
      return new Response('CF_API_TOKEN and CF_ZONE_NAME are required', {
        status: 500,
        headers: { 'content-type': 'text/plain;charset=UTF-8' },
      });
    }

    const recordNames = parseRecordNames(CF_RECORD_NAMES || CF_RECORD_NAME || '@');
    const recordType = (CF_RECORD_TYPE || 'A').toUpperCase();
    const html = await fetchText(TARGET_URL);
    const ips = extractIpv4Addresses(html);
    if (ips.length === 0) {
      return new Response(`No IPv4 addresses found in ${TARGET_URL}`, {
        status: 500,
        headers: { 'content-type': 'text/plain;charset=UTF-8' },
      });
    }

    const zoneId = await getZoneId(apiToken, zoneName);
    const results = [];
    const selectedIps = ips.slice(0, Math.max(1, recordNames.length));

    for (let index = 0; index < recordNames.length; index += 1) {
      const recordName = normalizeRecordName(recordNames[index], zoneName);
      const content = selectedIps[index] || ips[0];
      results.push(await syncDnsRecord(apiToken, zoneId, recordName, content, recordType));
    }

    return new Response(results.join('\n'), {
      status: 200,
      headers: { 'content-type': 'text/plain;charset=UTF-8' },
    });
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    return new Response(`Error: ${message}`, {
      status: 500,
      headers: { 'content-type': 'text/plain;charset=UTF-8' },
    });
  }
}

async function fetchText(url) {
  const response = await fetch(url, {
    headers: { 'User-Agent': 'Mozilla/5.0' },
  });
  if (!response.ok) {
    throw new Error(`Failed to fetch ${url}: ${response.status} ${response.statusText}`);
  }
  return response.text();
}

function parseRecordNames(value) {
  if (!value) {
    return ['@'];
  }
  const names = value
    .split(',')
    .map((name) => name.trim())
    .filter(Boolean);
  return names.length > 0 ? names : ['@'];
}

function normalizeRecordName(recordName, zoneName) {
  const trimmed = recordName.trim().replace(/\.$/, '');
  if (!trimmed || trimmed === '@') {
    return zoneName;
  }
  if (trimmed === zoneName || trimmed.endsWith(`.${zoneName}`)) {
    return trimmed;
  }
  return `${trimmed}.${zoneName}`;
}

function extractIpv4Addresses(text) {
  const results = [];
  const regex = /\b(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)(?:\.(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)){3}\b/g;
  for (const match of text.matchAll(regex)) {
    results.push(match[0]);
  }
  return [...new Set(results)];
}

async function cfApi(apiToken, path, method = 'GET', body = null, params = {}) {
  const url = new URL(`https://api.cloudflare.com/client/v4${path}`);
  Object.entries(params).forEach(([key, value]) => {
    if (value !== undefined && value !== null) {
      url.searchParams.append(key, String(value));
    }
  });

  const init = {
    method,
    headers: {
      Authorization: `Bearer ${apiToken}`,
      'Content-Type': 'application/json',
      Accept: 'application/json',
    },
  };

  if (body !== null) {
    init.body = JSON.stringify(body);
  }

  const response = await fetch(url.toString(), init);
  const data = await response.json();
  if (!response.ok || !data.success) {
    throw new Error(`Cloudflare API error ${response.status}: ${JSON.stringify(data)}`);
  }
  return data;
}

async function getZoneId(apiToken, zoneName) {
  const data = await cfApi(apiToken, '/zones', 'GET', null, { name: zoneName, status: 'active' });
  if (!Array.isArray(data.result) || data.result.length === 0) {
    throw new Error(`Zone ${zoneName} not found`);
  }
  return data.result[0].id;
}

async function syncDnsRecord(apiToken, zoneId, name, content, type = 'A') {
  const existing = await getDnsRecord(apiToken, zoneId, name, type);
  if (existing) {
    if (existing.content === content) {
      return `${name}: already set to ${content}`;
    }
    await updateDnsRecord(apiToken, zoneId, existing.id, name, content, type);
    return `${name}: updated to ${content}`;
  }

  await createDnsRecord(apiToken, zoneId, name, content, type);
  return `${name}: created with ${content}`;
}

async function getDnsRecord(apiToken, zoneId, name, type = 'A') {
  const data = await cfApi(apiToken, `/zones/${zoneId}/dns_records`, 'GET', null, { type, name });
  return Array.isArray(data.result) && data.result.length > 0 ? data.result[0] : null;
}

async function updateDnsRecord(apiToken, zoneId, recordId, name, content, type = 'A') {
  await cfApi(apiToken, `/zones/${zoneId}/dns_records/${recordId}`, 'PUT', {
    type,
    name,
    content,
    ttl: 1,
    proxied: false,
  });
}

async function createDnsRecord(apiToken, zoneId, name, content, type = 'A') {
  await cfApi(apiToken, `/zones/${zoneId}/dns_records`, 'POST', {
    type,
    name,
    content,
    ttl: 1,
    proxied: false,
  });
}
