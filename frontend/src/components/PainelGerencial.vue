<script setup>
import { ref, computed, onMounted, watch } from 'vue'
import { api, qs, brl, pct, paraPct, dataHora } from '../api.js'
import Paginacao from './Paginacao.vue'

const emit = defineEmits(['mudou'])  // revisão marca alertas como lidos: o App reconta
const vazia = { itens: [], total: 0, pagina: 1, por_pagina: 20 }
const produtos = ref(vazia)
const sugestoes = ref(vazia)
const ajustes = ref(vazia)
const categorias = ref([])
const busca = ref('')
const filtroSug = ref({ risco: '', categoria: '' })
const filtroAj = ref({ estado: '', de: '', ate: '' })
const marcados = ref(new Set())  // ids de sugestões selecionadas para o lote
const comentario = ref('')
const selecionado = ref(null)
const limites = ref(null)
const erro = ref('')
const msg = ref('')
const ocupado = ref(false)  // evita clique duplo em aprovar/descartar/salvar
const versao = ref(Date.now())  // muda a URL dos gráficos a cada recarga
const semGrafico = ref(false)

const csvUrl = computed(() => `/api/ajustes.csv${qs(filtroAj.value)}`)
const todosMarcados = computed(() => sugestoes.value.itens.length > 0 && sugestoes.value.itens.every((s) => marcados.value.has(s.id)))

// Busca uma página; se ela ficou vazia (ex.: último item aprovado), volta uma página.
async function buscarPagina(url, filtros, pagina) {
  const r = await api.get(`${url}${qs({ ...filtros, pagina })}`)
  return r.itens.length || pagina <= 1 ? r : buscarPagina(url, filtros, pagina - 1)
}

const tentar = (f) => async (...args) => { try { await f(...args) } catch (e) { erro.value = e.message } }
const irProdutos = tentar(async (p) => { produtos.value = await buscarPagina('/api/produtos', { q: busca.value }, p) })
const irSugestoes = tentar(async (p) => {
  sugestoes.value = await buscarPagina('/api/sugestoes-alertas', filtroSug.value, p)
  const visiveis = new Set(sugestoes.value.itens.map((s) => s.id))
  marcados.value = new Set([...marcados.value].filter((id) => visiveis.has(id)))
})
const irAjustes = tentar(async (p) => { ajustes.value = await buscarPagina('/api/ajustes', filtroAj.value, p) })

async function carregar() {
  erro.value = ''
  versao.value = Date.now()
  semGrafico.value = false
  await Promise.all([irProdutos(produtos.value.pagina), irSugestoes(sugestoes.value.pagina), irAjustes(ajustes.value.pagina)])
}

let espera
watch(busca, () => { clearTimeout(espera); espera = setTimeout(() => irProdutos(1), 300) })
watch(filtroSug, () => irSugestoes(1), { deep: true })
watch(filtroAj, () => irAjustes(1), { deep: true })

function alternar(id) {
  const s = new Set(marcados.value)
  s.has(id) ? s.delete(id) : s.add(id)
  marcados.value = s
}
function alternarPagina() {
  marcados.value = todosMarcados.value ? new Set() : new Set(sugestoes.value.itens.map((s) => s.id))
}

async function acao(f) {
  msg.value = erro.value = ''
  ocupado.value = true
  try {
    msg.value = await f()
    comentario.value = ''
    emit('mudou')
    await carregar()
  } catch (e) { erro.value = e.message } finally { ocupado.value = false }
}

const revisar = (id, tipo) => acao(async () => {
  const r = await api.post(`/api/ajustes/${id}/${tipo}`, comentario.value ? { comentario: comentario.value } : undefined)
  return `Ajuste #${r.id}: ${r.estado}`
})

const revisarLote = (tipo) => acao(async () => {
  const r = await api.post('/api/ajustes/lote', { ids: [...marcados.value], acao: tipo, comentario: comentario.value || null })
  marcados.value = new Set()
  const recusados = r.filter((x) => !x.ok)
  return `${r.length - recusados.length} ajuste(s) ${tipo === 'aprovar' ? 'aprovado(s)' : 'descartado(s)'}` +
    (recusados.length ? `; recusados: ${recusados.map((x) => `#${x.id} (${x.erro})`).join(', ')}` : '.')
})

function abrir(p) {
  selecionado.value = p
  semGrafico.value = false
  // margem exibida em %
  limites.value = {
    preco_minimo: p.preco_minimo ?? Math.max(0.01, +(p.custo * 1.05).toFixed(2)),
    preco_maximo: p.preco_maximo ?? +(p.preco * 1.5).toFixed(2),
    margem_desejada: paraPct(p.margem_desejada ?? 0),
  }
}

const salvarLimites = () => acao(async () => {
  await api.put(`/api/produtos/${encodeURIComponent(selecionado.value.id)}/limites`, {
    ...limites.value, margem_desejada: limites.value.margem_desejada / 100,
  })
  return `Limites de ${selecionado.value.id} salvos.`
})

const grafico = (tipo) => `/api/produtos/${encodeURIComponent(selecionado.value.id)}/${tipo}.svg?v=${versao.value}`

onMounted(async () => {
  await carregar()
  try { categorias.value = await api.get('/api/categorias') } catch (e) { erro.value = e.message }
})
</script>

<template>
  <p v-if="msg" class="ok" role="status">{{ msg }}</p>
  <p v-if="erro" class="erro" role="alert">{{ erro }}</p>

  <section class="card">
    <div class="cab">
      <h2>Sugestões aguardando revisão <span class="contador">{{ sugestoes.total }}</span></h2>
      <div class="filtros">
        <select v-model="filtroSug.risco" aria-label="Filtrar por risco">
          <option value="">Todos os riscos</option><option value="ruptura">Ruptura</option><option value="encalhe">Encalhe</option>
        </select>
        <select v-model="filtroSug.categoria" aria-label="Filtrar por categoria">
          <option value="">Todas as categorias</option>
          <option v-for="c in categorias" :key="c" :value="c">{{ c }}</option>
        </select>
        <button @click="carregar">Atualizar</button>
      </div>
    </div>
    <p v-if="!sugestoes.total" class="vazio">Nenhum ajuste pendente{{ filtroSug.risco || filtroSug.categoria ? ' com esses filtros' : '' }}.</p>
    <template v-else>
      <div class="lote">
        <input v-model="comentario" maxlength="1000" placeholder="Comentário da revisão (opcional)" aria-label="Comentário da revisão" />
        <button class="primario" :disabled="ocupado || !marcados.size" @click="revisarLote('aprovar')">Aprovar selecionadas ({{ marcados.size }})</button>
        <button :disabled="ocupado || !marcados.size" @click="revisarLote('descartar')">Descartar selecionadas</button>
      </div>
      <div class="rolagem">
        <table>
          <thead><tr>
            <th><input type="checkbox" :checked="todosMarcados" @change="alternarPagina" aria-label="Selecionar a página" /></th>
            <th>Produto</th><th>Risco</th><th>Preço atual</th><th>Sugerido</th><th>Alerta</th><th></th>
          </tr></thead>
          <tbody>
            <tr v-for="s in sugestoes.itens" :key="s.id">
              <td><input type="checkbox" :checked="marcados.has(s.id)" @change="alternar(s.id)" :aria-label="`Selecionar ajuste ${s.id}`" /></td>
              <td><b>{{ s.produto_id }}</b><br /><small>{{ s.nome }} · {{ s.categoria }}</small></td>
              <td><span :class="['tag', s.risco]">{{ s.risco }}</span></td>
              <td>{{ brl(s.preco_anterior) }}</td>
              <td>{{ brl(s.preco_novo) }} <small>({{ pct(s.preco_novo / s.preco_anterior - 1) }})</small></td>
              <td class="mensagem">{{ s.alerta_mensagem }}</td>
              <td class="botoes">
                <button class="primario" :disabled="ocupado" @click="revisar(s.id, 'aprovar')">Aprovar</button>
                <button :disabled="ocupado" @click="revisar(s.id, 'descartar')">Descartar</button>
              </td>
            </tr>
          </tbody>
        </table>
        <Paginacao :pagina="sugestoes" @ir="irSugestoes" />
      </div>
    </template>
  </section>

  <section class="card">
    <div class="cab">
      <h2>Produtos <span class="contador">{{ produtos.total }}</span></h2>
      <input type="search" v-model="busca" placeholder="Buscar por SKU, nome ou categoria" aria-label="Buscar produtos" />
    </div>
    <div class="rolagem">
      <table>
        <thead>
          <tr><th>SKU</th><th>Nome</th><th>Custo</th><th>Preço</th><th>Estoque</th><th>Dias parado</th>
            <th>Elasticidade</th><th>Mín / Máx</th><th>Margem</th></tr>
        </thead>
        <tbody>
          <tr v-for="p in produtos.itens" :key="p.id" :class="{ sel: selecionado?.id === p.id }"
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
      <p v-if="!produtos.total" class="vazio">Nenhum produto encontrado.</p>
      <Paginacao v-else :pagina="produtos" @ir="irProdutos" />
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
      <div class="acoes"><button class="primario" :disabled="ocupado">Salvar limites</button></div>
    </form>
    <p v-if="semGrafico" class="vazio">Sem histórico de vendas para este produto.</p>
    <template v-else>
      <img class="grafico" :src="grafico('grafico')" :alt="`Histórico de vendas e preço de ${selecionado.id}, com os ajustes marcados`"
           @error="semGrafico = true" />
      <img class="grafico" :src="grafico('curva')" :alt="`Curva de demanda estimada de ${selecionado.id}`" @error="semGrafico = true" />
    </template>
  </section>

  <section class="card">
    <div class="cab">
      <h2>Histórico de ajustes <span class="contador">{{ ajustes.total }}</span></h2>
      <div class="filtros">
        <select v-model="filtroAj.estado" aria-label="Filtrar por estado">
          <option value="">Todos os estados</option>
          <option v-for="e in ['NotificadoGerente', 'Finalizado', 'Descartado', 'Revertido']" :key="e">{{ e }}</option>
        </select>
        <label class="inline">De <input type="date" v-model="filtroAj.de" /></label>
        <label class="inline">Até <input type="date" v-model="filtroAj.ate" /></label>
        <a class="botao" :href="csvUrl" download>Exportar CSV</a>
      </div>
    </div>
    <p v-if="!ajustes.total" class="vazio">Nenhum ajuste{{ filtroAj.estado || filtroAj.de || filtroAj.ate ? ' com esses filtros' : '. Rode o motor no Painel Administrativo' }}.</p>
    <div v-else class="rolagem">
      <table>
        <thead><tr><th>#</th><th>Data</th><th>Produto</th><th>Risco</th><th>De</th><th>Para</th><th>Estado</th><th>Revisão</th><th></th></tr></thead>
        <tbody>
          <tr v-for="a in ajustes.itens" :key="a.id">
            <td>{{ a.id }}</td>
            <td>{{ dataHora(a.criado_em) }}</td>
            <td>{{ a.produto_id }}</td>
            <td><span :class="['tag', a.risco]">{{ a.risco }}</span></td>
            <td>{{ brl(a.preco_anterior) }}</td>
            <td>{{ brl(a.preco_novo) }}</td>
            <td>{{ a.estado }}</td>
            <td><template v-if="a.revisado_por">{{ a.revisado_por }} <small>{{ dataHora(a.revisado_em) }}</small>
              <br v-if="a.comentario" /><small v-if="a.comentario">“{{ a.comentario }}”</small></template></td>
            <td><button v-if="a.revertivel" :disabled="ocupado" @click="revisar(a.id, 'reverter')">Reverter</button></td>
          </tr>
        </tbody>
      </table>
      <Paginacao :pagina="ajustes" @ir="irAjustes" />
    </div>
  </section>
</template>
