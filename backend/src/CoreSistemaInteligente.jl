module CoreSistemaInteligente

using Dates, Printf, Statistics
using DataFrames, JuMP, HiGHS, Ipopt, Plots
using HTTP, JSON3, LibPQ

include("Modelos.jl")
include("MotorPrecificacao.jl")
include("Repositorio.jl")
include("Api.jl")

export Produto, RegraNegocio, LimitePreco, Alerta, Estado, ResultadoAnalise, SEM_LIMITE,
       EmAnalise, AvaliadoRuptura, AvaliadoEncalhe, AvaliadoNormal, ValidadoClamp, NotificadoGerente, Finalizado,
       avaliar_risco, detectar_inatividade, estimar_elasticidade, avaliar_elasticidade, otimizar_preco, calcular_preco,
       aplicar_clamp, disparar_alerta, calcularNovoPreco, executar_ciclo, iniciar

end
