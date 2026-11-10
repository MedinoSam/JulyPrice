<script setup>
import { ref, computed, onMounted } from 'vue'
import { api, brl, pct, dataHora } from '../api.js'
import Paginacao from './Paginacao.vue'

const produtos = ref([])
const vazia = { itens: [], total: 0, pagina: 1, por_pagina: 20 }
const sugestoes = ref(vazia)
const ajustes = ref(vazia)
const filtro = ref('')
const selecionado = ref(null)
const limites = ref(null)
const erro = ref('')
const msg = ref('')

const produtosFiltrados = computed(() => {
  const f = filtro.value.toLowerCase()
  return produtos.value.filter((p) => !f || `${p.id} ${p.nome} ${p.categoria}`.toLowerCase().includes(f))
})

// Busca uma página; se ela ficou vazia (ex.: último item aprovado), volta uma página.
async function buscarPagina(url, pagina) {
  const r = await api.get(`${url}?pagina=${pagina}`)
  return r.itens.length || pagina <= 1 ? r : buscarPagina(url, pagina - 1)
}

async function irSugestoes(pagina) {
  try { sugestoes.value = await buscarPagina('/api/sugestoes-alertas', pagina) } catch (e) { erro.value = e.message }
}

async function irAjustes(pagina) {
  try { ajustes.value = await buscarPagina('/api/ajustes', pagina) } catch (e) { erro.value = e.message }
}

async function carregar() {
  erro.value = ''
  try { produtos.value = await api.get('/api/produtos') } catch (e) { erro.value = e.message }
  await Promise.all([irSugestoes(sugestoes.value.pagina), irAjustes(ajustes.value.pagina)])
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

onMounted(carregar)
</script>

<template>
  <p v-if="msg" class="ok" role="status">{{ msg }}</p>
  <p v-if="erro" class="erro" role="alert">{{ erro }}</p>

  <section class="card">
    <div class="cab">
      <h2>Sugestões aguardando revisão <span class="contador">{{ sugestoes.total }}</span></h2>
      <button @click="carregar">Atualizar</button>
    </div>
    <p v-if="!sugestoes.total" class="vazio">Nenhum ajuste pendente.</p>
    <div v-else class="rolagem">
      <table>
        <thead><tr><th>Produto</th><th>Risco</th><th>Preço atual</th><th>Sugerido</th><th>Alerta</th><th></th></tr></thead>
        <tbody>
          <tr v-for="s in sugestoes.itens" :key="s.id">
            <td><b>{{ s.produto_id }}</b><br /><small>{{ s.nome }}</small></td>
            <td><span :class="['tag', s.risco]">{{ s.risco }}</span></td>
            <td>{{ brl(s.preco_anterior) }}</td>
            <td>{{ brl(s.preco_novo) }} <small>({{ pct(s.preco_novo / s.preco_anterior - 1) }})</small></td>
            <td class="mensagem">{{ s.alerta_mensagem }}</td>
            <td class="botoes">
              <button class="primario" @click="revisar(s.id, 'aprovar')">Aprovar</button>
              <button @click="revisar(s.id, 'reverter')">Descartar</button>
            </td>
          </tr>
        </tbody>
      </table>
      <Paginacao :pagina="sugestoes" @ir="irSugestoes" />
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
    <h2>Histórico de ajustes <span class="contador">{{ ajustes.total }}</span></h2>
    <p v-if="!ajustes.total" class="vazio">Nenhum ajuste ainda. Rode o motor no Painel Administrativo.</p>
    <div v-else class="rolagem">
      <table>
        <thead><tr><th>#</th><th>Data</th><th>Produto</th><th>Risco</th><th>De</th><th>Para</th><th>Estado</th><th></th></tr></thead>
        <tbody>
          <tr v-for="a in ajustes.itens" :key="a.id">
            <td>{{ a.id }}</td>
            <td>{{ dataHora(a.criado_em) }}</td>
            <td>{{ a.produto_id }}</td>
            <td><span :class="['tag', a.risco]">{{ a.risco }}</span></td>
            <td>{{ brl(a.preco_anterior) }}</td>
            <td>{{ brl(a.preco_novo) }}</td>
            <td>{{ a.estado }}</td>
            <td><button v-if="a.revertivel" @click="revisar(a.id, 'reverter')">Reverter</button></td>
          </tr>
        </tbody>
      </table>
      <Paginacao :pagina="ajustes" @ir="irAjustes" />
    </div>
  </section>
</template>
