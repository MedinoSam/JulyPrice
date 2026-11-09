async function req(method, url, body) {
  const r = await fetch(url, {
    method,
    headers: body ? { 'Content-Type': 'application/json' } : {},
    body: body ? JSON.stringify(body) : undefined,
  })
  const data = await r.json().catch(() => ({}))
  if (!r.ok) throw new Error(data.erro || `${r.status} ${r.statusText}`)
  return data
}

export const api = {
  get: (u) => req('GET', u),
  put: (u, b) => req('PUT', u, b),
  post: (u, b) => req('POST', u, b),
}

export const brl = (v) => (v == null ? '—' : v.toLocaleString('pt-BR', { style: 'currency', currency: 'BRL' }))
export const pct = (v) => (v == null ? '—' : `${v > 0 ? '+' : ''}${(v * 100).toFixed(1)}%`)
export const dataHora = (s) => (s ? new Date(s).toLocaleString('pt-BR') : '—')
