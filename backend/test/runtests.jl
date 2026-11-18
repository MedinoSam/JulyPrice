using Test, Random, DataFrames, Dates
using CoreSistemaInteligente

const R = RegraNegocio(10, 30, 0.05, 0.10)
mk(; estoque=50, dias=0, preco=100.0, custo=50.0) = Produto("P1", "Teste", custo, preco, estoque, dias, -1.5)

@testset "máquina de estados" begin
    r = calcularNovoPreco(mk(estoque=5), R)
    @test r.risco == :ruptura
    @test r.estados == [EmAnalise, AvaliadoRuptura, ValidadoClamp, NotificadoGerente]
    @test r.preco_novo ≈ 105.0
    @test r.alerta.tipo == "RUPTURA"

    r = calcularNovoPreco(mk(dias=45), R)
    @test r.estados == [EmAnalise, AvaliadoEncalhe, ValidadoClamp, NotificadoGerente]
    @test r.preco_novo ≈ 90.0

    r = calcularNovoPreco(mk(), R)
    @test r.estados == [EmAnalise, AvaliadoNormal, ValidadoClamp, Finalizado]
    @test r.preco_novo == 100.0 && r.alerta === nothing

    @test avaliar_risco(mk(estoque=5, dias=45), R) == :ruptura  # ruptura tem prioridade
    @test avaliar_risco(mk(dias=30), R) == :normal               # limite é estrito (>)
end

@testset "clamp" begin
    l = LimitePreco(95.0, 102.0, 0.0)
    @test calcularNovoPreco(mk(estoque=5), R, l).preco_novo == 102.0  # teto
    @test calcularNovoPreco(mk(dias=45), R, l).preco_novo == 95.0     # piso
    # margem sobre o custo vira piso: 85 * 1.2 = 102
    @test calcularNovoPreco(mk(dias=45, custo=85.0), R, LimitePreco(1.0, 500.0, 0.2)).preco_novo == 102.0
    # piso acima do teto: vale o teto
    @test aplicar_clamp(50.0, mk(custo=100.0), LimitePreco(1.0, 110.0, 0.5)) == 110.0
end

@testset "otimização de preço (JuMP + Ipopt)" begin
    # Regra de Lerner: com e < -1 o lucro máximo fica em custo·e/(1+e); com e ≥ -1 o lucro cresce com o preço
    lerner(c, e, lo, hi) = e < -1 ? clamp(c * e / (1 + e), lo, hi) : hi
    for (c, e, lo, hi) in [(50.0, -3.0, 60.0, 120.0), (50.0, -0.5, 100.0, 105.0), (40.0, -2.0, 70.0, 75.0), (10.0, -1.2, 20.0, 90.0)]
        @test isapprox(otimizar_preco(100.0, c, e, lo, hi), lerner(c, e, lo, hi); atol=0.01)
    end
    @test otimizar_preco(100.0, 0.0, -1.0, 90.0, 100.0; padrao=90.0) == 90.0  # receita plana: vale o padrão

    elastico = Produto("E", "e", 50.0, 100.0, 5, 0, -3.0)    # ótimo 75 < 100: subir derrubaria o lucro
    @test calcularNovoPreco(elastico, R).preco_novo == 100.0
    inelastico = Produto("I", "i", 50.0, 100.0, 50, 45, -0.5)  # encalhe inelástico: baixar não aumenta a receita
    r = calcularNovoPreco(inelastico, R)
    @test r.preco_novo == 100.0 && occursin("não melhora", r.alerta.mensagem)
end

@testset "elasticidade (JuMP)" begin
    rng = MersenneTwister(1)
    precos = 100 .* (1 .+ 0.2 .* (rand(rng, 200) .- 0.5))
    qtds = round.(Int, 50 .* (precos ./ 100) .^ -1.8 .* exp.(0.05 .* randn(rng, 200)))
    @test isapprox(estimar_elasticidade(precos, qtds), -1.8; atol=0.15)
    @test estimar_elasticidade(fill(10.0, 20), fill(3, 20); padrao=-0.7) == -0.7  # sem variação de preço
    @test isapprox(estimar_elasticidade(precos, precos .* 0.5), 0.0; atol=1e-6)  # restrição b <= 0
end

@testset "ciclo com DataFrames" begin
    produtos = DataFrame(id=["A", "B", "C"], nome=["a", "b", "c"], custo=[5.0, 5.0, 5.0], preco=[10.0, 10.0, 10.0],
                         estoque=[3, 100, 100], dias_parado=[0, 60, 2], elasticidade=[-1.0, -1.0, -1.0])
    res = executar_ciclo(produtos, DataFrame(produto_id=String[], data=Date[], quantidade=Int[], preco=Float64[]), R)
    @test res.risco == [:ruptura, :encalhe, :normal]
    @test res.preco_novo == [10.5, 9.0, 10.0]
    @test isempty(executar_ciclo(produtos[1:0, :], DataFrame(produto_id=String[]), R))
end

@testset "elasticidade com histórico esparso" begin
    # determinístico: o fluxo do MersenneTwister muda entre versões do Julia
    datas = Date(2026, 1, 1) .+ Day.(0:179)
    precos = repeat([70.0, 85.0, 100.0, 115.0, 130.0, 90.0]; inner=7, outer=5)[1:180]
    # Preço alto tem mais dias sem venda; o 1º dia de cada preço sempre vende (o preço dele fica conhecido)
    sem_venda(i, p) = (i - 1) % 7 != 0 && (i % 3 == 0 || (p >= 115 && i % 3 == 1))
    qtds = [sem_venda(i, p) ? 0 : round(Int, 20 * (p / 100)^-1.5) for (i, p) in enumerate(precos)]
    qtds[end-19:end] .= 0  # 20 dias parado no fim
    denso = DataFrame(data=datas, quantidade=qtds, preco=precos)
    p = Produto("S", "s", 50.0, 100.0, 50, 180 - findlast(>(0), qtds), -1.0)  # dias desde a última venda
    e = avaliar_elasticidade(p, denso)
    @test e < -1.5  # os dias sem venda contam na média: mais elástico que a curva dos dias com venda
    # ERP que omite os dias sem venda: mesma estimativa do histórico completo
    @test avaliar_elasticidade(p, denso[denso.quantidade .> 0, :]) ≈ e
    @test avaliar_elasticidade(p, denso[1:0, :]) == -1.0  # sem nenhuma venda: mantém a elasticidade
end

@testset "clamp em produto normal gera alerta informativo" begin
    r = calcularNovoPreco(mk(), R, LimitePreco(110.0, 200.0, 0.0))
    @test r.preco_novo == 110.0 && r.estados[end] == Finalizado
    @test r.alerta.tipo == "LIMITE"
end

@testset "validação de campos JSON" begin
    campo, ErroCliente = CoreSistemaInteligente.campo, CoreSistemaInteligente.ErroCliente
    @test_throws ErroCliente campo(Dict(:x => true), :x, Float64)  # Bool não é número
    @test campo(Dict(:x => 2), :x, Float64) === 2.0
    @test campo(Dict(:c => nothing), :c, String, "") == ""
    @test campo(Dict{Symbol,Any}(), :c, String, "") == ""
    @test_throws ErroCliente campo(Dict(:c => 3), :c, String, "")
end

@testset "teto padrão e variação acumulada" begin
    l = LimitePreco(50.0, 200.0, 0.0)
    # janela de ±15% sobre 100: faixa [85, 115] dentro dos limites do gerente
    v = limitar_variacao(l, 100.0, 100.0, 0.15)
    @test v.preco_minimo ≈ 85.0 && v.preco_maximo ≈ 115.0
    @test limitar_variacao(l, 100.0, 100.0, 0.0) === l                       # 0 desliga
    @test limitar_variacao(l, 100.0, 130.0, 0.15).preco_maximo == 130.0      # não força a queda do preço atual
    @test limitar_variacao(LimitePreco(90.0, 110.0, 0.0), 100.0, 100.0, 0.5).preco_maximo == 110.0  # gerente manda
    @test limite_padrao(100.0, 100.0, 0.3).preco_maximo ≈ 130.0
    @test limite_padrao(100.0, 150.0, 0.3).preco_maximo == 150.0
    @test limite_padrao(100.0, 100.0, 0.0) === SEM_LIMITE
    # rupturas seguidas: com a trava, o preço para em ref·1,15 em vez de subir 5% a cada ciclo
    p, ref = 100.0, 100.0
    for _ in 1:10
        p = calcularNovoPreco(mk(estoque=5, preco=p), R, limitar_variacao(SEM_LIMITE, ref, p, 0.15)).preco_novo
    end
    @test p ≈ 115.0
end

@testset "cooldown de descarte" begin
    @test em_cooldown(105.0, 105.0, 0.05)
    @test em_cooldown(108.0, 105.0, 0.05)
    @test !em_cooldown(112.0, 105.0, 0.05)
end

@testset "regras por categoria" begin
    produtos = DataFrame(id=["A", "B"], nome=["a", "b"], categoria=["Livros", "Moda"], custo=[5.0, 5.0],
                         preco=[10.0, 10.0], estoque=[15, 15], dias_parado=[0, 0], elasticidade=[-1.0, -1.0])
    vazio = DataFrame(produto_id=String[], data=Date[], quantidade=Int[], preco=Float64[])
    cats = Dict("Livros" => RegraNegocio(20, 30, 0.05, 0.10))  # Livros: ruptura abaixo de 20 un.
    res = executar_ciclo(produtos, vazio, R; regras_categoria=cats)
    @test res.risco == [:ruptura, :normal]
end

@testset "elasticidade ignora dias esgotados" begin
    datas = Date(2026, 1, 1) .+ Day.(0:59)
    precos = repeat([80.0, 100.0, 120.0]; inner=5, outer=4)
    qtds = round.(Int, 20 .* (precos ./ 100) .^ -1.2)
    estoque = fill(50, 60)
    zerar = findall(precos .== 80.0)[1:2:end]  # metade dos dias baratos sem estoque (venda zero censurada)
    qtds[zerar] .= 0
    estoque[zerar] .= 0
    h = DataFrame(data=datas, quantidade=qtds, preco=precos, estoque=estoque)
    p = Produto("Z", "z", 50.0, 100.0, 50, 0, -1.0)
    @test isapprox(avaliar_elasticidade(p, h), -1.2; atol=0.05)
    @test avaliar_elasticidade(p, select(h, Not(:estoque))) > -1.0  # sem a coluna, os zeros puxam a estimativa
end

@testset "PBKDF2-HMAC-SHA256 (RFC 7914)" begin
    pbkdf2 = CoreSistemaInteligente.pbkdf2
    @test bytes2hex(pbkdf2("password", Vector{UInt8}("salt"); iter=1)) ==
          "120fb6cffcf8b32c43e7225256c4f837a86548c92ccc35480805987cb70be17b"
    @test bytes2hex(pbkdf2("password", Vector{UInt8}("salt"); iter=2)) ==
          "ae4d0c95af6b46d32d0adff928f06dd02a303f8ef3c251dfd6e2d85a95474c43"
    @test CoreSistemaInteligente.iguais_tempo_constante("abc", "abc")
    @test !CoreSistemaInteligente.iguais_tempo_constante("abc", "abd")
end
