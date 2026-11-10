<script setup>
import { computed } from 'vue'

// `pagina`: { itens, total, pagina, por_pagina } vindo da API
const props = defineProps({ pagina: { type: Object, required: true } })
const emit = defineEmits(['ir'])
const ultima = computed(() => Math.max(1, Math.ceil(props.pagina.total / props.pagina.por_pagina)))
</script>

<template>
  <nav class="paginacao" aria-label="Paginação">
    <button :disabled="pagina.pagina <= 1" @click="emit('ir', 1)" aria-label="Primeira página">«</button>
    <button :disabled="pagina.pagina <= 1" @click="emit('ir', pagina.pagina - 1)">Anterior</button>
    <span>Página {{ pagina.pagina }} de {{ ultima }} · {{ pagina.total }} itens</span>
    <button :disabled="pagina.pagina >= ultima" @click="emit('ir', pagina.pagina + 1)">Próxima</button>
    <button :disabled="pagina.pagina >= ultima" @click="emit('ir', ultima)" aria-label="Última página">»</button>
  </nav>
</template>
