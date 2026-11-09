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
