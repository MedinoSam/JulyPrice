// Sessão por cookie HttpOnly: o navegador manda sozinho. 401 avisa o App para voltar ao login.
async function req(method, url, body) {
  const r = await fetch(url, {
    method,
    headers: body ? { 'Content-Type': 'application/json' } : {},
    body: body ? JSON.stringify(body) : undefined,
  })
  const data = await r.json().catch(() => ({}))
  if (r.status === 401 && url !== '/api/login') window.dispatchEvent(new Event('julyprice:sessao-expirada'))
  if (!r.ok) throw new Error(data.erro || `${r.status} ${r.statusText}`)
  return data
}

export const api = {
  get: (u) => req('GET', u),
  put: (u, b) => req('PUT', u, b),
  post: (u, b) => req('POST', u, b),
  del: (u) => req('DELETE', u),
}

// Query string sem os filtros vazios: qs({ risco: '', pagina: 2 }) === '?pagina=2'
export function qs(params) {
  const p = new URLSearchParams()
  for (const [k, v] of Object.entries(params)) if (v !== '' && v != null) p.set(k, v)
  const s = p.toString()
  return s ? `?${s}` : ''
}

export const brl = (v) => (v == null ? '—' : v.toLocaleString('pt-BR', { style: 'currency', currency: 'BRL' }))
// fração → % sem lixo de ponto flutuante (0.07 * 100 = 7.000000000000001 quebra o `step` dos inputs)
export const paraPct = (v) => +(v * 100).toFixed(2)
export const pct = (v) => (v == null ? '—' : `${v > 0 ? '+' : ''}${(v * 100).toFixed(1)}%`)
export const dataHora = (s) => (s ? new Date(s).toLocaleString('pt-BR') : '—')
