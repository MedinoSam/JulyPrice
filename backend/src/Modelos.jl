# Entidades do diagrama de classes.
# `custo` foi adicionado ao Produto: sem ele a `margem_desejada` do LimitePreco não tem base de cálculo.

mutable struct Produto
    id::String
    nome::String
    custo::Float64
    preco::Float64
    estoque::Int64
    dias_parado::Int64
    elasticidade::Float64
end

struct RegraNegocio
    limite_estoque_minimo::Int64
    limite_dias_inatividade::Int64
    taxa_ajuste_alto::Float64   # reajuste em ruptura (ex.: 0.05 = +5%)
    taxa_ajuste_baixo::Float64  # reajuste em encalhe (ex.: 0.10 = -10%)
end

struct LimitePreco
    preco_minimo::Float64
    preco_maximo::Float64
    margem_desejada::Float64    # sobre o custo (ex.: 0.20 = custo + 20%)
end

const SEM_LIMITE = LimitePreco(0.01, Inf, 0.0)

struct Alerta
    tipo::String
    mensagem::String
    data_criacao::DateTime
end

# Máquina de estados do ciclo de análise de um produto
@enum Estado EmAnalise AvaliadoRuptura AvaliadoEncalhe AvaliadoNormal ValidadoClamp NotificadoGerente Finalizado

struct ResultadoAnalise
    produto_id::String
    risco::Symbol                 # :normal | :ruptura | :encalhe
    estados::Vector{Estado}       # trilha percorrida, ex.: [EmAnalise, AvaliadoRuptura, ValidadoClamp, NotificadoGerente]
    preco_anterior::Float64
    preco_calculado::Float64      # antes do clamp
    preco_novo::Float64           # depois do clamp
    alerta::Union{Alerta,Nothing}
end
