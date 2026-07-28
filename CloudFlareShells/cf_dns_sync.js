// Cloudflare IPv6 DNS Updater Worker
// 设置全局变量CF_ZONE_NAME，CF_API_TOKEN
const BESTV6_URL = 'https://www.wetest.vip/page/cloudflare/address_v6.html';
const BESTV4_URL = 'https://www.wetest.vip/page/cloudflare/address_v4.html';
const ZONE_NAME = CF_ZONE_NAME;
const MAPPING = { 移动: '139', 联通: '155', 电信: '189' };
const CARRIERS = ['移动', '联通', '电信'];

addEventListener('fetch', event => {
  event.respondWith(handleRequest(event.request));
});

async function handleRequest(request) {
  try {
    const apiToken = CF_API_TOKEN;
    if (!apiToken) {
      return new Response('CF_API_TOKEN is not configured', { status: 500 });
    }

    const v6Html = await fetchText(BESTV6_URL);
    const v6Best = parsePreferredAddresses(v6Html);
    const v4Html = await fetchText(BESTV4_URL);
    const v4Best = parsePreferredAddresses(v4Html);
    const zoneId = await getZoneId(apiToken);
    const results = [];

    for (const carrier of CARRIERS) {
      const recordName = `${MAPPING[carrier]}.${ZONE_NAME}`;
      const v6Addr = v6Best[carrier]?.addr;
      const v4Addr = v4Best[carrier]?.addr;

      if (v6Addr) {
        const v6Result = await syncDnsRecord(apiToken, zoneId, recordName, v6Addr, 'AAAA', `${carrier} IPv6`);
        results.push(v6Result);
      } else {
        results.push(`${carrier}: no IPv6 address found, skipped`);
      }

      if (v4Addr) {
        const v4Result = await syncDnsRecord(apiToken, zoneId, recordName, v4Addr, 'A', `${carrier} IPv4`);
        results.push(v4Result);
      } else {
        results.push(`${carrier}: no IPv4 address found, skipped`);
      }
    }

    return new Response(results.join('\n'), { status: 200 });
  } catch (error) {
    return new Response(`Error: ${error.message || error}`, { status: 500 });
  }
}

async function fetchText(url) {
  const response = await fetch(url);
  if (!response.ok) {
    throw new Error(`Failed to fetch ${url}: ${response.status} ${response.statusText}`);
  }
  return await response.text();
}

function parsePreferredAddresses(html) {
  const pattern = /<tr>.*?<td[^>]*data-label="线路名称">([^<]+)<\/td>.*?<td[^>]*data-label="优选地址">([^<]+)<\/td>.*?<td[^>]*data-label="往返延迟">\s*([0-9]+)\s*毫秒<\/td>/gs;
  const best = {
    移动: { latency: Number.POSITIVE_INFINITY, addr: '' },
    联通: { latency: Number.POSITIVE_INFINITY, addr: '' },
    电信: { latency: Number.POSITIVE_INFINITY, addr: '' },
  };

  let match;
  while ((match = pattern.exec(html)) !== null) {
    const carrier = match[1].trim();
    const addr = match[2].trim();
    const latency = Number(match[3]);
    if (carrier in best && latency < best[carrier].latency) {
      best[carrier] = { latency, addr };
    }
  }

  return best;
}

async function cfApi(apiToken, path, method = 'GET', body = null, params = {}) {
  const url = new URL(`https://api.cloudflare.com/client/v4${path}`);
  Object.entries(params).forEach(([key, value]) => url.searchParams.append(key, String(value)));

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

async function getZoneId(apiToken) {
  const data = await cfApi(apiToken, '/zones', 'GET', null, { name: ZONE_NAME, status: 'active' });
  if (!Array.isArray(data.result) || data.result.length === 0) {
    throw new Error(`Zone ${ZONE_NAME} not found`);
  }
  return data.result[0].id;
}

async function syncDnsRecord(apiToken, zoneId, name, content, type, label) {
  const existing = await getDnsRecord(apiToken, zoneId, name, type);
  if (existing) {
    if (existing.content === content) {
      return `${label}: ${name} already set to ${content}`;
    }
    await updateDnsRecord(apiToken, zoneId, existing.id, name, content, type);
    return `${label}: ${name} updated to ${content}`;
  }

  await createDnsRecord(apiToken, zoneId, name, content, type);
  return `${label}: ${name} created with ${content}`;
}

async function getDnsRecord(apiToken, zoneId, name, type = 'AAAA') {
  const data = await cfApi(apiToken, `/zones/${zoneId}/dns_records`, 'GET', null, { type, name });
  return Array.isArray(data.result) && data.result.length > 0 ? data.result[0] : null;
}

async function updateDnsRecord(apiToken, zoneId, recordId, name, content, type = 'AAAA') {
  await cfApi(apiToken, `/zones/${zoneId}/dns_records/${recordId}`, 'PUT', {
    type,
    name,
    content,
    ttl: 1,
    proxied: false,
  });
}

async function createDnsRecord(apiToken, zoneId, name, content, type = 'AAAA') {
  await cfApi(apiToken, `/zones/${zoneId}/dns_records`, 'POST', {
    type,
    name,
    content,
    ttl: 1,
    proxied: false,
  });
}
