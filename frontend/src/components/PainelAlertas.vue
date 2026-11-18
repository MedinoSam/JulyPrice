<script setup>
import { ref, watch, onMounted } from 'vue'
import { api, qs, dataHora } from '../api.js'
import Paginacao from './Paginacao.vue'

const emit = defineEmits(['mudou'])  // avisa o App para recontar os não lidos
const alertas = ref({ itens: [], total: 0, pagina: 1, por_pagina: 20 })
const filtro = ref({ tipo: '', lido: 'false' })
const erro = ref('')
const ocupado = ref(false)

async function ir(pagina) {
  try { alertas.value = await api.get(`/api/alertas${qs({ ...filtro.value, pagina })}`) } catch (e) { erro.value = e.message }
}

async function marcar(url) {
  erro.value = ''
  ocupado.value = true
  try {
    await api.post(url)
    emit('mudou')
    await ir(alertas.value.pagina)
    if (!alertas.value.itens.length && alertas.value.pagina > 1) await ir(alertas.value.pagina - 1)
  } catch (e) { erro.value = e.message } finally { ocupado.value = false }
}

watch(filtro, () => ir(1), { deep: true })
onMounted(() => ir(1))
</script>

<template>
  <p v-if="erro" class="erro" role="alert">{{ erro }}</p>
  <section class="card">
    <div class="cab">
      <h2>Central de alertas <span class="contador">{{ alertas.total }}</span></h2>
      <div class="filtros">
        <select v-model="filtro.tipo" aria-label="Filtrar por tipo">
          <option value="">Todos os tipos</option>
          <option value="RUPTURA">Ruptura</option><option value="ENCALHE">Encalhe</option><option value="LIMITE">Limite</option>
        </select>
        <select v-model="filtro.lido" aria-label="Filtrar por leitura">
          <option value="false">Não lidos</option><option value="true">Lidos</option><option value="">Todos</option>
        </select>
        <button :disabled="ocupado" @click="marcar('/api/alertas/lidos')">Marcar todos como lidos</button>
      </div>
    </div>
    <p class="ajuda">Alertas de ruptura e encalhe ficam lidos quando a sugestão é revisada. LIMITE avisa preço corrigido pelos limites do produto.</p>
    <p v-if="!alertas.total" class="vazio">Nenhum alerta.</p>
    <div v-else class="rolagem">
      <table>
        <thead><tr><th>Data</th><th>Tipo</th><th>Produto</th><th>Mensagem</th><th></th></tr></thead>
        <tbody>
          <tr v-for="a in alertas.itens" :key="a.id" :class="{ naolido: !a.lido }">
            <td>{{ dataHora(a.data_criacao) }}</td>
            <td><span :class="['tag', a.tipo.toLowerCase()]">{{ a.tipo }}</span></td>
            <td><b>{{ a.produto_id }}</b><br /><small>{{ a.nome }}</small></td>
            <td class="mensagem">{{ a.mensagem }}</td>
            <td><button v-if="!a.lido" :disabled="ocupado" @click="marcar(`/api/alertas/${a.id}/lido`)">Marcar lido</button></td>
          </tr>
        </tbody>
      </table>
      <Paginacao :pagina="alertas" @ir="ir" />
    </div>
  </section>
</template>
