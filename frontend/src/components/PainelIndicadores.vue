<script setup>
import { ref, computed, watch, onMounted } from 'vue'
import { api, brl, pct } from '../api.js'

const dias = ref(30)
const k = ref(null)
const erro = ref('')
const hover = ref(null)

async function carregar() {
  try { k.value = await api.get(`/api/indicadores?dias=${dias.value}`) } catch (e) { erro.value = e.message }
}
watch(dias, carregar)
onMounted(carregar)

const variacao = (antes, depois) => (antes ? depois / antes - 1 : null)

// Um ponto por dia do período (dias sem sugestão entram com zero)
const serie = computed(() => {
  if (!k.value) return []
  const n = new Map()
  for (const r of k.value.por_dia) n.set(`${r.dia}|${r.risco}`, r.n)
  const hoje = new Date()
  return Array.from({ length: k.value.dias }, (_, i) => {
    const d = new Date(Date.UTC(hoje.getUTCFullYear(), hoje.getUTCMonth(), hoje.getUTCDate() - (k.value.dias - 1 - i)))
    const dia = d.toISOString().slice(0, 10)
    return { dia, ruptura: n.get(`${dia}|ruptura`) ?? 0, encalhe: n.get(`${dia}|encalhe`) ?? 0 }
  })
})
const totais = computed(() => serie.value.reduce((t, d) => ({ ruptura: t.ruptura + d.ruptura, encalhe: t.encalhe + d.encalhe }), { ruptura: 0, encalhe: 0 }))

// Geometria do gráfico de barras empilhadas (viewBox fixo; o SVG escala com a largura)
const W = 720, H = 220, M = { top: 8, right: 8, bottom: 24, left: 36 }
const larguraPlot = W - M.left - M.right, alturaPlot = H - M.top - M.bottom
const maximo = computed(() => {
  const m = Math.max(1, ...serie.value.map((d) => d.ruptura + d.encalhe))
  const passo = m <= 5 ? 1 : m <= 10 ? 2 : m <= 25 ? 5 : m <= 50 ? 10 : Math.ceil(m / 40) * 10
  return Math.ceil(m / passo) * passo
})
const ticks = computed(() => [0, 0.25, 0.5, 0.75, 1].map((f) => Math.round(f * maximo.value)).filter((v, i, a) => a.indexOf(v) === i))
const y = (v) => M.top + alturaPlot * (1 - v / maximo.value)
const faixa = computed(() => larguraPlot / Math.max(1, serie.value.length))
const larguraBarra = computed(() => Math.max(2, Math.min(18, faixa.value - 2)))  // >= 2px de vão entre barras
const x = (i) => M.left + i * faixa.value + (faixa.value - larguraBarra.value) / 2

// Retângulo com só os cantos de cima arredondados (ponta de dado; a base fica reta no eixo)
function topoArredondado(x0, y0, w, h, r) {
  r = Math.min(r, w / 2, h)
  return `M${x0},${y0 + h}V${y0 + r}Q${x0},${y0} ${x0 + r},${y0}H${x0 + w - r}Q${x0 + w},${y0} ${x0 + w},${y0 + r}V${y0 + h}Z`
}
const GAP = 2
const barras = computed(() => serie.value.map((d, i) => {
  const segs = []
  let base = 0
  for (const risco of ['ruptura', 'encalhe']) {
    const v = d[risco]
    if (!v) continue
    const y1 = y(base), y0 = y(base + v)
    const altura = Math.max(1, y1 - y0 - (base > 0 ? GAP : 0))  // vão de 2px entre segmentos empilhados
    segs.push({ risco, y0, altura })
    base += v
  }
  return { ...d, i, segs }
}))
const rotulosX = computed(() => {
  const passo = Math.ceil(serie.value.length / 6)
  return serie.value.map((d, i) => ({ i, txt: d.dia.slice(8, 10) + '/' + d.dia.slice(5, 7) })).filter(({ i }) => i % passo === 0)
})
const dica = computed(() => (hover.value == null ? null : barras.value[hover.value]))
</script>

<template>
  <p v-if="erro" class="erro" role="alert">{{ erro }}</p>
  <section class="card">
    <div class="cab">
      <h2>Indicadores</h2>
      <select v-model.number="dias" aria-label="Período">
        <option :value="7">Últimos 7 dias</option><option :value="30">Últimos 30 dias</option><option :value="90">Últimos 90 dias</option>
      </select>
    </div>
    <div v-if="k" class="kpis">
      <div class="kpi">
        <span>Pendentes agora</span>
        <b>{{ k.pendentes.ruptura + k.pendentes.encalhe }}</b>
        <small>{{ k.pendentes.ruptura }} ruptura · {{ k.pendentes.encalhe }} encalhe</small>
      </div>
      <div class="kpi">
        <span>Taxa de aprovação</span>
        <b>{{ k.taxa_aprovacao == null ? '—' : `${(k.taxa_aprovacao * 100).toFixed(0)}%` }}</b>
        <small>{{ k.aprovados }} aprovadas · {{ k.descartados }} descartadas</small>
      </div>
      <div class="kpi">
        <span>Tempo até a revisão</span>
        <b>{{ k.horas_ate_revisao == null ? '—' : k.horas_ate_revisao < 1 ? `${Math.round(k.horas_ate_revisao * 60)} min` : `${k.horas_ate_revisao.toFixed(1)} h` }}</b>
        <small>média das sugestões revisadas</small>
      </div>
      <div class="kpi">
        <span>Receita diária estimada</span>
        <b>{{ brl(k.impacto.receita_depois) }}</b>
        <small>antes {{ brl(k.impacto.receita_antes) }} ({{ pct(variacao(k.impacto.receita_antes, k.impacto.receita_depois)) }})</small>
      </div>
      <div class="kpi">
        <span>Margem diária estimada</span>
        <b>{{ brl(k.impacto.margem_depois) }}</b>
        <small>antes {{ brl(k.impacto.margem_antes) }} ({{ pct(variacao(k.impacto.margem_antes, k.impacto.margem_depois)) }})</small>
      </div>
    </div>
    <p v-if="k" class="ajuda">
      Receita e margem: {{ k.impacto.ajustes }} ajuste(s) aprovado(s) no período, com a demanda prevista pela elasticidade
      sobre a média diária de vendas dos últimos 30 dias de cada produto. É uma estimativa do modelo, não venda realizada.
    </p>
  </section>

  <section class="card" v-if="k">
    <h2>Sugestões de risco por dia</h2>
    <div class="legenda">
      <span><i class="amostra ruptura"></i>Ruptura <b>{{ totais.ruptura }}</b></span>
      <span><i class="amostra encalhe"></i>Encalhe <b>{{ totais.encalhe }}</b></span>
    </div>
    <div class="grafico-barras" @mouseleave="hover = null">
      <svg :viewBox="`0 0 ${W} ${H}`" role="img" :aria-label="`Sugestões por dia nos últimos ${k.dias} dias: ${totais.ruptura} de ruptura e ${totais.encalhe} de encalhe`">
        <g class="eixo">
          <template v-for="t in ticks" :key="t">
            <line :x1="M.left" :x2="W - M.right" :y1="y(t)" :y2="y(t)" />
            <text :x="M.left - 6" :y="y(t) + 4" text-anchor="end">{{ t }}</text>
          </template>
          <text v-for="r in rotulosX" :key="r.i" :x="x(r.i) + larguraBarra / 2" :y="H - 6" text-anchor="middle">{{ r.txt }}</text>
        </g>
        <g v-for="b in barras" :key="b.dia" :class="{ apagada: hover != null && hover !== b.i }">
          <template v-for="(s, j) in b.segs" :key="s.risco">
            <path v-if="j === b.segs.length - 1" :class="['seg', s.risco]" :d="topoArredondado(x(b.i), s.y0, larguraBarra, s.altura, 4)" />
            <rect v-else :class="['seg', s.risco]" :x="x(b.i)" :y="s.y0" :width="larguraBarra" :height="s.altura" />
          </template>
          <rect class="alvo" :x="M.left + b.i * faixa" :y="M.top" :width="faixa" :height="alturaPlot" @mouseenter="hover = b.i" />
        </g>
      </svg>
      <div v-if="dica" class="dica" :style="{ left: `${((x(dica.i) + larguraBarra / 2) / W) * 100}%` }">
        <b>{{ new Date(dica.dia + 'T12:00:00').toLocaleDateString('pt-BR') }}</b>
        <span><i class="amostra ruptura"></i>Ruptura {{ dica.ruptura }}</span>
        <span><i class="amostra encalhe"></i>Encalhe {{ dica.encalhe }}</span>
      </div>
    </div>
    <details>
      <summary>Ver em tabela</summary>
      <table>
        <thead><tr><th>Dia</th><th>Ruptura</th><th>Encalhe</th></tr></thead>
        <tbody>
          <tr v-for="d in serie.filter((d) => d.ruptura || d.encalhe)" :key="d.dia">
            <td>{{ new Date(d.dia + 'T12:00:00').toLocaleDateString('pt-BR') }}</td><td>{{ d.ruptura }}</td><td>{{ d.encalhe }}</td>
          </tr>
        </tbody>
      </table>
    </details>
  </section>
</template>
