<script setup>
import { ref, onMounted } from 'vue'
import { api, qs, pct, paraPct, dataHora } from '../api.js'
import Paginacao from './Paginacao.vue'

// Frações exibidas em %, gravadas como fração
const FRACOES = ['taxa_ajuste_alto', 'taxa_ajuste_baixo', 'variacao_cooldown', 'teto_padrao', 'variacao_max_janela']
const CAMPOS_REGRA = ['limite_estoque_minimo', 'limite_dias_inatividade', 'taxa_ajuste_alto', 'taxa_ajuste_baixo']
const paraTela = (o, campos) => Object.fromEntries(campos.map((k) => [k, FRACOES.includes(k) ? paraPct(o[k]) : o[k]]))
const paraApi = (o) => Object.fromEntries(Object.entries(o).map(([k, v]) => [k, FRACOES.includes(k) ? v / 100 : v]))

const form = ref(null)
const msg = ref('')
const erro = ref('')
const ciclo = ref(null)
const simulacao = ref(null)
const ocupado = ref(false)
const categorias = ref([])
const regrasCat = ref([])
const formCat = ref({ categoria: '', limite_estoque_minimo: 10, limite_dias_inatividade: 30, taxa_ajuste_alto: 5, taxa_ajuste_baixo: 10 })
const execucoes = ref({ itens: [], total: 0, pagina: 1, por_pagina: 10 })

async function acao(f) {
  msg.value = erro.value = ''
  ocupado.value = true
  try { await f() } catch (e) { erro.value = e.message } finally { ocupado.value = false }
}

async function carregar() {
  const r = await api.get('/api/regras')
  form.value = paraTela(r, [...CAMPOS_REGRA, 'dias_cooldown', 'variacao_cooldown', 'teto_padrao',
    'variacao_max_janela', 'dias_janela_variacao', 'intervalo_motor_horas'])
  regrasCat.value = await api.get('/api/regras/categorias')
  categorias.value = await api.get('/api/categorias')
}

const salvar = () => acao(async () => {
  form.value = paraTela(await api.put('/api/regras', paraApi(form.value)), Object.keys(form.value))
  simulacao.value = null
  msg.value = 'Regras atualizadas.'
})
const simular = () => acao(async () => { simulacao.value = await api.post('/api/motor/simular', paraApi(form.value)) })
const executar = () => acao(async () => {
  ciclo.value = await api.post('/api/motor/executar')
  await irExecucoes(1)
})

const editarCat = (r) => { formCat.value = { categoria: r.categoria, ...paraTela(r, CAMPOS_REGRA) } }
const salvarCat = () => acao(async () => {
  const { categoria, ...regra } = formCat.value
  await api.put(`/api/regras/categorias/${encodeURIComponent(categoria)}`, paraApi(regra))
  regrasCat.value = await api.get('/api/regras/categorias')
  msg.value = `Regra de ${categoria} salva.`
})
const removerCat = (c) => acao(async () => {
  await api.del(`/api/regras/categorias/${encodeURIComponent(c)}`)
  regrasCat.value = await api.get('/api/regras/categorias')
  msg.value = `${c} volta a usar a regra global.`
})

async function irExecucoes(pagina) {
  try { execucoes.value = await api.get(`/api/execucoes${qs({ pagina, por_pagina: 10 })}`) } catch (e) { erro.value = e.message }
}

onMounted(() => Promise.all([carregar(), irExecucoes(1)]).catch((e) => (erro.value = e.message)))
</script>

<template>
  <p v-if="msg" class="ok" role="status">{{ msg }}</p>
  <p v-if="erro" class="erro" role="alert">{{ erro }}</p>

  <section class="card" v-if="form">
    <h2>Regras de negócio (globais)</h2>
    <form class="grade" @submit.prevent="salvar">
      <label>Estoque mínimo (un.)
        <input type="number" min="0" step="1" required v-model.number="form.limite_estoque_minimo" />
        <span class="ajuda">Abaixo disso: ruptura</span>
      </label>
      <label>Dias de inatividade
        <input type="number" min="0" step="1" required v-model.number="form.limite_dias_inatividade" />
        <span class="ajuda">Acima disso: encalhe</span>
      </label>
      <label>Reajuste em ruptura (%)
        <input type="number" min="0" step="0.1" required v-model.number="form.taxa_ajuste_alto" />
      </label>
      <label>Redução em encalhe (%)
        <input type="number" min="0" max="99" step="0.1" required v-model.number="form.taxa_ajuste_baixo" />
      </label>
      <label>Cooldown de descarte (dias)
        <input type="number" min="0" step="1" required v-model.number="form.dias_cooldown" />
        <span class="ajuda">Sugestão descartada não volta nesse prazo. 0 desliga</span>
      </label>
      <label>Diferença que fura o cooldown (%)
        <input type="number" min="0" step="0.1" required v-model.number="form.variacao_cooldown" />
        <span class="ajuda">Nova sugestão mais distante que isso volta antes</span>
      </label>
      <label>Teto sem limites (%)
        <input type="number" min="0" step="0.1" required v-model.number="form.teto_padrao" />
        <span class="ajuda">Máximo sobre o preço inicial de produto sem limites. 0 desliga</span>
      </label>
      <label>Variação máxima na janela (%)
        <input type="number" min="0" step="0.1" required v-model.number="form.variacao_max_janela" />
        <span class="ajuda">Para cima ou para baixo. 0 desliga</span>
      </label>
      <label>Janela de variação (dias)
        <input type="number" min="1" step="1" required v-model.number="form.dias_janela_variacao" />
      </label>
      <label>Motor agendado (horas)
        <input type="number" min="0" step="1" required v-model.number="form.intervalo_motor_horas" />
        <span class="ajuda">Roda sozinho nesse intervalo. 0 desliga</span>
      </label>
      <div class="acoes">
        <button class="primario" :disabled="ocupado">Salvar regras</button>
        <button type="button" :disabled="ocupado" @click="simular">{{ ocupado ? 'Calculando…' : 'Simular' }}</button>
      </div>
    </form>
    <div v-if="simulacao" class="resumo simulacao" role="status">
      <b>Se estas regras fossem salvas e o motor rodasse agora</b> (sem gravar nada):
      ruptura <b>{{ simulacao.ruptura }}</b> · encalhe <b>{{ simulacao.encalhe }}</b> · normal <b>{{ simulacao.normal }}</b> ·
      ajustes <b>{{ simulacao.ajustes }}</b> · suprimidos pelo cooldown <b>{{ simulacao.suprimidas }}</b> ·
      variação média dos ajustes <b>{{ pct(simulacao.variacao_media) }}</b>.
      <small>Produtos com sugestão pendente ficam de fora, como no motor.</small>
    </div>
  </section>

  <section class="card">
    <h2>Regras por categoria</h2>
    <p class="ajuda">Categoria sem regra própria usa a global. Cooldown, teto e janela são sempre globais.</p>
    <table v-if="regrasCat.length">
      <thead><tr><th>Categoria</th><th>Estoque mín.</th><th>Dias inatividade</th><th>Ruptura</th><th>Encalhe</th><th></th></tr></thead>
      <tbody>
        <tr v-for="r in regrasCat" :key="r.categoria" tabindex="0" @click="editarCat(r)" @keydown.enter="editarCat(r)">
          <td><b>{{ r.categoria }}</b></td>
          <td>{{ r.limite_estoque_minimo }}</td>
          <td>{{ r.limite_dias_inatividade }}</td>
          <td>{{ pct(r.taxa_ajuste_alto) }}</td>
          <td>{{ pct(-r.taxa_ajuste_baixo) }}</td>
          <td><button :disabled="ocupado" @click.stop="removerCat(r.categoria)">Remover</button></td>
        </tr>
      </tbody>
    </table>
    <form class="grade" @submit.prevent="salvarCat">
      <label>Categoria
        <select v-model="formCat.categoria" required>
          <option value="" disabled>Escolha</option>
          <option v-for="c in categorias" :key="c" :value="c">{{ c }}</option>
        </select>
      </label>
      <label>Estoque mínimo (un.) <input type="number" min="0" step="1" required v-model.number="formCat.limite_estoque_minimo" /></label>
      <label>Dias de inatividade <input type="number" min="0" step="1" required v-model.number="formCat.limite_dias_inatividade" /></label>
      <label>Reajuste em ruptura (%) <input type="number" min="0" step="0.1" required v-model.number="formCat.taxa_ajuste_alto" /></label>
      <label>Redução em encalhe (%) <input type="number" min="0" max="99" step="0.1" required v-model.number="formCat.taxa_ajuste_baixo" /></label>
      <div class="acoes"><button class="primario" :disabled="ocupado">Salvar regra da categoria</button></div>
    </form>
  </section>

  <section class="card">
    <div class="cab">
      <h2>Motor de precificação</h2>
      <button class="primario" :disabled="ocupado" @click="executar">{{ ocupado ? 'Executando…' : 'Executar ciclo' }}</button>
    </div>
    <p>O ciclo roda a cada carga do ERP e, se ligado, na agenda acima.</p>
    <p v-if="ciclo" class="resumo">
      Ruptura: <b>{{ ciclo.ruptura }}</b> · Encalhe: <b>{{ ciclo.encalhe }}</b> · Normal: <b>{{ ciclo.normal }}</b> ·
      Ajustes registrados: <b>{{ ciclo.ajustes }}</b> · Suprimidos pelo cooldown: <b>{{ ciclo.suprimidas }}</b>
    </p>
    <h3>Execuções <span class="contador">{{ execucoes.total }}</span></h3>
    <div v-if="execucoes.total" class="rolagem">
      <table>
        <thead><tr><th>Início</th><th>Origem</th><th>Duração</th><th>Ruptura</th><th>Encalhe</th><th>Normal</th><th>Ajustes</th><th>Suprimidos</th></tr></thead>
        <tbody>
          <tr v-for="e in execucoes.itens" :key="e.id">
            <td>{{ dataHora(e.inicio) }}</td>
            <td>{{ e.origem }}</td>
            <td>{{ e.duracao_ms == null ? '—' : `${(e.duracao_ms / 1000).toFixed(1)} s` }}</td>
            <template v-if="e.erro"><td colspan="5" class="mensagem">Falhou: {{ e.erro }}</td></template>
            <template v-else>
              <td>{{ e.ruptura }}</td><td>{{ e.encalhe }}</td><td>{{ e.normal }}</td><td>{{ e.ajustes }}</td><td>{{ e.suprimidas }}</td>
            </template>
          </tr>
        </tbody>
      </table>
      <Paginacao :pagina="execucoes" @ir="irExecucoes" />
    </div>
    <p v-else class="vazio">Nenhuma execução registrada.</p>
  </section>
</template>
