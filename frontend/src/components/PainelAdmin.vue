<script setup>
import { ref, onMounted } from 'vue'
import { api } from '../api.js'

// Taxas exibidas em %, gravadas como fração
const form = ref(null)
const msg = ref('')
const erro = ref('')
const ciclo = ref(null)

async function carregar() {
  const r = await api.get('/api/regras')
  form.value = { ...r, taxa_ajuste_alto: r.taxa_ajuste_alto * 100, taxa_ajuste_baixo: r.taxa_ajuste_baixo * 100 }
}

async function salvar() {
  msg.value = erro.value = ''
  try {
    await api.put('/api/regras', {
      ...form.value,
      taxa_ajuste_alto: form.value.taxa_ajuste_alto / 100,
      taxa_ajuste_baixo: form.value.taxa_ajuste_baixo / 100,
    })
    msg.value = 'Regras atualizadas.'
  } catch (e) { erro.value = e.message }
}

async function executar() {
  msg.value = erro.value = ''
  try { ciclo.value = await api.post('/api/motor/executar') } catch (e) { erro.value = e.message }
}

onMounted(() => carregar().catch((e) => (erro.value = e.message)))
</script>

<template>
  <section class="card" v-if="form">
    <h2>Regras de negócio</h2>
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
      <div class="acoes"><button class="primario">Salvar regras</button></div>
    </form>
  </section>

  <section class="card">
    <h2>Motor de precificação</h2>
    <p>O ciclo roda sozinho a cada carga do ERP. Use o botão para rodar agora com as regras atuais.</p>
    <button class="primario" @click="executar">Executar ciclo</button>
    <p v-if="ciclo" class="resumo">
      Ruptura: <b>{{ ciclo.ruptura }}</b> · Encalhe: <b>{{ ciclo.encalhe }}</b> ·
      Normal: <b>{{ ciclo.normal }}</b> · Ajustes registrados: <b>{{ ciclo.ajustes }}</b>
    </p>
  </section>

  <p v-if="msg" class="ok" role="status">{{ msg }}</p>
  <p v-if="erro" class="erro" role="alert">{{ erro }}</p>
</template>
