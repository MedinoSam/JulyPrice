<script setup>
import { ref, computed, onMounted, onUnmounted, watch } from 'vue'
import { api } from './api.js'
import Login from './components/Login.vue'
import PainelGerencial from './components/PainelGerencial.vue'
import PainelAdmin from './components/PainelAdmin.vue'
import PainelAlertas from './components/PainelAlertas.vue'
import PainelIndicadores from './components/PainelIndicadores.vue'

const usuario = ref(null)
const verificando = ref(true)
const aba = ref('gerencial')
const naoLidos = ref(0)

const abas = computed(() => [
  { id: 'gerencial', nome: 'Painel Gerencial' },
  { id: 'alertas', nome: 'Alertas' },
  { id: 'indicadores', nome: 'Indicadores' },
  ...(usuario.value?.perfil === 'admin' ? [{ id: 'admin', nome: 'Painel Administrativo' }] : []),
])

async function contarAlertas() {
  if (!usuario.value) return
  try { naoLidos.value = (await api.get('/api/alertas/nao-lidos')).total } catch { /* 401 já tratado */ }
}

function expirou() { usuario.value = null }
async function sair() {
  await api.post('/api/logout').catch(() => {})
  usuario.value = null
}

let timer
onMounted(async () => {
  window.addEventListener('julyprice:sessao-expirada', expirou)
  try { usuario.value = await api.get('/api/eu') } catch { /* sem sessão */ } finally { verificando.value = false }
  timer = setInterval(contarAlertas, 60000)
})
onUnmounted(() => { window.removeEventListener('julyprice:sessao-expirada', expirou); clearInterval(timer) })
watch([usuario, aba], () => {
  if (!abas.value.some((a) => a.id === aba.value)) aba.value = 'gerencial'
  contarAlertas()
})
</script>

<template>
  <header class="topo">
    <h1>JulyPrice <small>precificação dinâmica</small></h1>
    <nav v-if="usuario">
      <button v-for="a in abas" :key="a.id" :class="{ ativo: aba === a.id }" @click="aba = a.id">
        {{ a.nome }}
        <span v-if="a.id === 'alertas' && naoLidos" class="selo" :aria-label="`${naoLidos} não lidos`">{{ naoLidos }}</span>
      </button>
    </nav>
    <div v-if="usuario" class="quem">
      <span>{{ usuario.nome }} <small>{{ usuario.perfil }}</small></span>
      <button @click="sair">Sair</button>
    </div>
  </header>
  <main>
    <Login v-if="!usuario && !verificando" @entrou="(u) => (usuario = u)" />
    <template v-else-if="usuario">
      <PainelGerencial v-if="aba === 'gerencial'" @mudou="contarAlertas" />
      <PainelAlertas v-else-if="aba === 'alertas'" @mudou="contarAlertas" />
      <PainelIndicadores v-else-if="aba === 'indicadores'" />
      <PainelAdmin v-else />
    </template>
  </main>
</template>
