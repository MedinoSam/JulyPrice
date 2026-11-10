# Motor de Precificação + Análise de Elasticidade + Gestão de Alertas (lógica pura, sem banco).

detectar_inatividade(p::Produto, r::RegraNegocio) = p.dias_parado > r.limite_dias_inatividade

# Ruptura tem prioridade sobre encalhe (ordem da máquina de estados).
avaliar_risco(p::Produto, r::RegraNegocio) =
    p.estoque < r.limite_estoque_minimo ? :ruptura :
    detectar_inatividade(p, r) ? :encalhe : :normal

"""
Estima a elasticidade-preço pelo modelo log-log `log(q̄) = a + b·log(p)` via JuMP (mínimos quadrados
ponderados), com a restrição `b ≤ 0` (demanda não cresce com o preço). As vendas são agregadas por nível
de preço (média diária, contando dias sem venda; peso = nº de dias), o que evita o log de zero.
Com menos de 3 níveis de preço com venda, devolve `padrao`.
"""
function estimar_elasticidade(precos::AbstractVector, quantidades::AbstractVector; padrao::Float64=-1.0)
    niveis = combine(groupby(DataFrame(p=Float64.(precos), q=Float64.(quantidades)), :p),
                     :q => mean => :q, nrow => :n)
    filter!(r -> r.p > 0 && r.q > 0, niveis)
    nrow(niveis) < 3 && return padrao
    x = log.(niveis.p)
    x .-= mean(x)  # centraliza: melhora o condicionamento do QP
    y, w = log.(niveis.q), niveis.n
    m = Model(HiGHS.Optimizer)
    set_silent(m)
    @variable(m, a)
    @variable(m, b <= 0)
    @objective(m, Min, sum(w[i] * (y[i] - a - b * x[i])^2 for i in eachindex(x)))
    optimize!(m)
    is_solved_and_feasible(m) ? value(b) : padrao
end

# `historico`: data, quantidade, preco. Os últimos `dias_parado` dias (sem venda) refletem encalhe, não preço.
function avaliar_elasticidade(p::Produto, historico)
    h = sort(historico, :data)
    h = h[1:max(0, nrow(h) - p.dias_parado), :]
    estimar_elasticidade(h.preco, h.quantidade; padrao=p.elasticidade)
end

"""
Escolhe, via JuMP + Ipopt, o preço `x` em `[lo, hi]` que maximiza o resultado esperado
`(x - custo) · (x / p0)^e`, com a demanda prevista pela elasticidade `e` (a demanda atual é uma
constante e não muda o ponto ótimo). Com `custo = 0` o objetivo vira receita.
Sem solução, devolve `padrao`.
"""
function otimizar_preco(p0, custo, e, lo, hi; padrao=hi)
    lo >= hi && return lo
    # custo 0 e elasticidade -1: receita igual em toda a faixa; qualquer preço serve, vale o padrão
    iszero(custo) && e == -1 && return padrao
    m = Model(Ipopt.Optimizer)
    set_silent(m)
    @variable(m, lo <= x <= hi, start = padrao)
    @objective(m, Max, (x - custo) * (x / p0)^e)
    optimize!(m)
    is_solved_and_feasible(m) ? clamp(value(x), lo, hi) : padrao
end

"""
A regra define a direção e o passo máximo; a otimização escolhe o ponto dentro dessa faixa.
- Ruptura: faixa [preço, preço·(1 + taxa_ajuste_alto)], maximiza o lucro `(x - custo)·q(x)`.
- Encalhe: faixa [preço·(1 - taxa_ajuste_baixo), preço], maximiza a receita `x·q(x)`:
  o custo do estoque parado já foi pago, então só vale baixar se a demanda for elástica.
- Normal: mantém o preço.
"""
function calcular_preco(p::Produto, r::RegraNegocio, risco::Symbol=avaliar_risco(p, r))
    risco == :normal && return p.preco
    if risco == :ruptura
        lo, hi = p.preco, p.preco * (1 + r.taxa_ajuste_alto)
        return otimizar_preco(p.preco, p.custo, p.elasticidade, lo, hi; padrao=hi)
    end
    lo, hi = p.preco * (1 - r.taxa_ajuste_baixo), p.preco
    otimizar_preco(p.preco, 0.0, p.elasticidade, lo, hi; padrao=lo)
end

# Clamp: piso = max(preço mínimo, custo + margem); teto = preço máximo.
# Se o piso passar do teto, vale o teto (limite explícito do gerente).
function aplicar_clamp(preco::Float64, p::Produto, l::LimitePreco)
    hi = l.preco_maximo
    lo = min(max(l.preco_minimo, p.custo * (1 + l.margem_desejada)), hi)
    round(clamp(preco, lo, hi); digits=2)
end

pct(x) = @sprintf("%+.1f%%", 100x)

function disparar_alerta(p::Produto, risco::Symbol, preco_novo::Float64)
    dp = preco_novo / p.preco - 1
    dq = (1 + dp)^p.elasticidade - 1  # variação de demanda esperada pela elasticidade
    motivo = risco == :ruptura ? "Estoque baixo ($(p.estoque) un.)" : "Sem vendas há $(p.dias_parado) dias"
    msg = @sprintf("%s. Preço sugerido R\$ %.2f → R\$ %.2f (%s); demanda estimada %s (elasticidade %.2f).",
                   motivo, p.preco, preco_novo, pct(dp), pct(dq), p.elasticidade)
    preco_novo == p.preco && (msg *= " Mudar o preço não melhora o resultado esperado.")
    Alerta(risco == :ruptura ? "RUPTURA" : "ENCALHE", msg, now())
end

"""
Executa a máquina de estados para um produto:
EmAnalise → AvaliadoRuptura | AvaliadoEncalhe | AvaliadoNormal → ValidadoClamp → NotificadoGerente | Finalizado
"""
function calcularNovoPreco(p::Produto, r::RegraNegocio, l::LimitePreco=SEM_LIMITE)
    estados = [EmAnalise]
    risco = avaliar_risco(p, r)
    push!(estados, risco == :ruptura ? AvaliadoRuptura : risco == :encalhe ? AvaliadoEncalhe : AvaliadoNormal)
    bruto = calcular_preco(p, r, risco)
    novo = aplicar_clamp(bruto, p, l)
    push!(estados, ValidadoClamp)
    alerta = risco == :normal ? nothing : disparar_alerta(p, risco, novo)
    push!(estados, alerta === nothing ? Finalizado : NotificadoGerente)
    ResultadoAnalise(p.id, risco, estados, p.preco, bruto, novo, alerta)
end

"""
Ciclo completo sobre DataFrames.
`produtos`: id, nome, custo, preco, estoque, dias_parado, elasticidade
`vendas`:   produto_id, data, quantidade, preco
Retorna um DataFrame com um resultado por produto.
"""
function executar_ciclo(produtos::DataFrame, vendas::DataFrame, regra::RegraNegocio,
                        limites::Dict{String,LimitePreco}=Dict{String,LimitePreco}())
    isempty(produtos) && return DataFrame()
    historico = Dict(String(k.produto_id) => g for (k, g) in pairs(groupby(vendas, :produto_id)))
    DataFrame(map(eachrow(produtos)) do r
        p = Produto(r.id, r.nome, r.custo, r.preco, r.estoque, r.dias_parado, r.elasticidade)
        h = get(historico, p.id, nothing)
        h === nothing || (p.elasticidade = avaliar_elasticidade(p, h))
        res = calcularNovoPreco(p, regra, get(limites, p.id, SEM_LIMITE))
        (produto_id=p.id, risco=res.risco, estado_final=res.estados[end],
         preco_anterior=res.preco_anterior, preco_calculado=res.preco_calculado,
         preco_novo=res.preco_novo, elasticidade=p.elasticidade,
         alerta_tipo=res.alerta === nothing ? missing : res.alerta.tipo,
         alerta_mensagem=res.alerta === nothing ? missing : res.alerta.mensagem)
    end)
end
