# Uso: julia --project=backend backend/server.jl
ENV["GKSwstype"] = "100"  # GR sem janela (servidor headless)
using CoreSistemaInteligente
iniciar()
