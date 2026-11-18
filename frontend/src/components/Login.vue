<script setup>
import { ref } from 'vue'
import { api } from '../api.js'

const emit = defineEmits(['entrou'])
const login = ref('')
const senha = ref('')
const erro = ref('')
const ocupado = ref(false)

async function entrar() {
  erro.value = ''
  ocupado.value = true
  try {
    emit('entrou', await api.post('/api/login', { login: login.value, senha: senha.value }))
  } catch (e) { erro.value = e.message } finally { ocupado.value = false; senha.value = '' }
}
</script>

<template>
  <section class="card login">
    <h2>Entrar</h2>
    <form @submit.prevent="entrar">
      <label>Login <input v-model.trim="login" autocomplete="username" required autofocus /></label>
      <label>Senha <input v-model="senha" type="password" autocomplete="current-password" required /></label>
      <button class="primario" :disabled="ocupado">{{ ocupado ? 'Entrando…' : 'Entrar' }}</button>
    </form>
    <p v-if="erro" class="erro" role="alert">{{ erro }}</p>
  </section>
</template>
