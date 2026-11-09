<script setup>
import { ref } from 'vue'
import PainelGerencial from './components/PainelGerencial.vue'
import PainelAdmin from './components/PainelAdmin.vue'

const aba = ref('gerencial')
</script>

<template>
  <header class="topo">
    <h1>JulyPrice <small>precificação dinâmica</small></h1>
    <nav>
      <button :class="{ ativo: aba === 'gerencial' }" @click="aba = 'gerencial'">Painel Gerencial</button>
      <button :class="{ ativo: aba === 'admin' }" @click="aba = 'admin'">Painel Administrativo</button>
    </nav>
  </header>
  <main>
    <PainelGerencial v-if="aba === 'gerencial'" />
    <PainelAdmin v-else />
  </main>
</template>
