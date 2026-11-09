<script setup>
import { ref, computed, onMounted } from 'vue'
import { api, brl, pct, dataHora } from '../api.js'

const produtos = ref([])
const sugestoes = ref([])
const alertas = ref([])
const ajustes = ref([])
const filtro = ref('')
const selecionado = ref(null)
const limites = ref(null)
const erro = ref('')
const msg = ref('')

const alertaPorAjuste = computed(() => Object.fromEntries(alertas.value.map((a) => [a.ajuste_id, a])))
const produtosFiltrados = computed(() => {
  const f = filtro.value.toLowerCase()
  return produtos.value.filter((p) => !f || `${p.id} ${p.nome} ${p.categoria}`.toLowerCase().includes(f))
})

async function carregar() {
  erro.value = ''
  try {
    const [p, sa, aj] = await Promise.all([api.get('/api/produtos'), api.get('/api/sugestoes-alertas'), api.get('/api/ajustes')])
    produtos.value = p
    sugestoes.value = sa.sugestoes
    alertas.value = sa.alertas
    ajustes.value = aj
  } catch (e) { erro.value = e.message }
}

async function revisar(id, acao) {
  msg.value = erro.value = ''
  try {
    const r = await api.post(`/api/ajustes/${id}/${acao}`)
    msg.value = `Ajuste #${r.id}: ${r.estado}`
    await carregar()
  } catch (e) { erro.value = e.message }
}

function abrir(p) {
  selecionado.value = p
  // margem exibida em %
  limites.value = {
    preco_minimo: p.preco_minimo ?? Math.max(0.01, +(p.custo * 1.05).toFixed(2)),
    preco_maximo: p.preco_maximo ?? +(p.preco * 1.5).toFixed(2),
    margem_desejada: (p.margem_desejada ?? 0) * 100,
  }
}

async function salvarLimites() {
  msg.value = erro.value = ''
  try {
    await api.put(`/api/produtos/${encodeURIComponent(selecionado.value.id)}/limites`, {
      ...limites.value, margem_desejada: limites.value.margem_desejada / 100,
    })
    msg.value = `Limites de ${selecionado.value.id} salvos.`
    await carregar()
  } catch (e) { erro.value = e.message }
}

const ultimoFinalizado = computed(() => {
  // só o ajuste finalizado mais recente de cada produto pode ser revertido
  const m = {}
  for (const a of ajustes.value) if (a.estado === 'Finalizado' && !(a.produto_id in m)) m[a.produto_id] = a.id
  return new Set(Object.values(m))
})

onMounted(carregar)
</script>

<template>
  <p v-if="msg" class="ok" role="status">{{ msg }}</p>
  <p v-if="erro" class="erro" role="alert">{{ erro }}</p>

  <section class="card">
    <div class="cab">
      <h2>Sugestões aguardando revisão <span class="contador">{{ sugestoes.length }}</span></h2>
      <button @click="carregar">Atualizar</button>
    </div>
    <p v-if="!sugestoes.length" class="vazio">Nenhum ajuste pendente.</p>
    <div v-else class="rolagem">
      <table>
        <thead><tr><th>Produto</th><th>Risco</th><th>Preço atual</th><th>Sugerido</th><th>Alerta</th><th></th></tr></thead>
        <tbody>
          <tr v-for="s in sugestoes" :key="s.id">
            <td><b>{{ s.produto_id }}</b><br /><small>{{ s.nome }}</small></td>
            <td><span :class="['tag', s.risco]">{{ s.risco }}</span></td>
            <td>{{ brl(s.preco_anterior) }}</td>
            <td>{{ brl(s.preco_novo) }} <small>({{ pct(s.preco_novo / s.preco_anterior - 1) }})</small></td>
            <td class="mensagem">{{ alertaPorAjuste[s.id]?.mensagem }}</td>
            <td class="botoes">
              <button class="primario" @click="revisar(s.id, 'aprovar')">Aprovar</button>
              <button @click="revisar(s.id, 'reverter')">Descartar</button>
            </td>
          </tr>
        </tbody>
      </table>
    </div>
  </section>

  <section class="card">
    <div class="cab">
      <h2>Produtos <span class="contador">{{ produtos.length }}</span></h2>
      <input type="search" v-model="filtro" placeholder="Filtrar por SKU, nome ou categoria" aria-label="Filtrar produtos" />
    </div>
    <div class="rolagem alta">
      <table>
        <thead>
          <tr><th>SKU</th><th>Nome</th><th>Custo</th><th>Preço</th><th>Estoque</th><th>Dias parado</th>
            <th>Elasticidade</th><th>Mín / Máx</th><th>Margem</th></tr>
        </thead>
        <tbody>
          <tr v-for="p in produtosFiltrados" :key="p.id" :class="{ sel: selecionado?.id === p.id }"
              tabindex="0" @click="abrir(p)" @keydown.enter="abrir(p)">
            <td><b>{{ p.id }}</b> <span v-if="p.pendente" class="tag ruptura" title="revisão pendente">!</span></td>
            <td>{{ p.nome }}<br /><small>{{ p.categoria }}</small></td>
            <td>{{ brl(p.custo) }}</td>
            <td><b>{{ brl(p.preco) }}</b></td>
            <td>{{ p.estoque }}</td>
            <td>{{ p.dias_parado }}</td>
            <td>{{ p.elasticidade.toFixed(2) }}</td>
            <td>{{ brl(p.preco_minimo) }} / {{ brl(p.preco_maximo) }}</td>
            <td>{{ p.margem_desejada == null ? '—' : pct(p.margem_desejada) }}</td>
          </tr>
        </tbody>
      </table>
    </div>
  </section>

  <section class="card" v-if="selecionado">
    <div class="cab">
      <h2>{{ selecionado.id }} — {{ selecionado.nome }}</h2>
      <button @click="selecionado = null">Fechar</button>
    </div>
    <form class="grade" @submit.prevent="salvarLimites">
      <label>Preço mínimo (R$) <input type="number" min="0.01" step="0.01" required v-model.number="limites.preco_minimo" /></label>
      <label>Preço máximo (R$) <input type="number" min="0.01" step="0.01" required v-model.number="limites.preco_maximo" /></label>
      <label>Margem desejada sobre custo (%) <input type="number" min="0" step="0.5" required v-model.number="limites.margem_desejada" /></label>
      <div class="acoes"><button class="primario">Salvar limites</button></div>
    </form>
    <img class="grafico" :src="`/api/produtos/${encodeURIComponent(selecionado.id)}/grafico.svg`"
         :alt="`Histórico de vendas e preço de ${selecionado.id}`" />
  </section>

  <section class="card">
    <h2>Histórico de ajustes</h2>
    <p v-if="!ajustes.length" class="vazio">Nenhum ajuste ainda. Rode o motor no Painel Administrativo.</p>
    <div v-else class="rolagem">
      <table>
        <thead><tr><th>#</th><th>Data</th><th>Produto</th><th>Risco</th><th>De</th><th>Para</th><th>Estado</th><th></th></tr></thead>
        <tbody>
          <tr v-for="a in ajustes" :key="a.id">
            <td>{{ a.id }}</td>
            <td>{{ dataHora(a.criado_em) }}</td>
            <td>{{ a.produto_id }}</td>
            <td><span :class="['tag', a.risco]">{{ a.risco }}</span></td>
            <td>{{ brl(a.preco_anterior) }}</td>
            <td>{{ brl(a.preco_novo) }}</td>
            <td>{{ a.estado }}</td>
            <td><button v-if="ultimoFinalizado.has(a.id)" @click="revisar(a.id, 'reverter')">Reverter</button></td>
          </tr>
        </tbody>
      </table>
    </div>
  </section>
</template>
