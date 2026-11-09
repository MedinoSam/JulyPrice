# Simula o Motor de Precificação sobre os CSVs do gerar_dataset.jl (sem banco).
# Uso: julia --project=backend backend/scripts/simulacao.jl [data]

using CSV, DataFrames, Statistics
using CoreSistemaInteligente

dir = get(ARGS, 1, "data")
produtos = CSV.read(joinpath(dir, "produtos.csv"), DataFrame; types=Dict(:id => String))
vendas = CSV.read(joinpath(dir, "vendas.csv"), DataFrame; types=Dict(:produto_id => String))
limites = Dict(r.produto_id => LimitePreco(r.preco_minimo, r.preco_maximo, r.margem_desejada)
               for r in eachrow(CSV.read(joinpath(dir, "limites_preco.csv"), DataFrame; types=Dict(:produto_id => String))))

regra = RegraNegocio(10, 30, 0.05, 0.10)
res = executar_ciclo(produtos, vendas, regra, limites)
res = leftjoin(res, select(produtos, :id => :produto_id, :cenario, :elasticidade_real), on=:produto_id)
res.variacao = res.preco_novo ./ res.preco_anterior .- 1

println("Resumo por risco detectado:")
println(combine(groupby(res, [:risco, :estado_final]), nrow => :produtos,
                :variacao => (v -> round(100mean(v); digits=2)) => :variacao_media_pct))
println("\nAcerto do risco vs cenário gerado: ", round(100mean(string.(res.risco) .== res.cenario); digits=1), "%")
println("Erro médio absoluto da elasticidade estimada (JuMP): ",
        round(mean(abs.(res.elasticidade .- res.elasticidade_real)); digits=3))
println("Produtos limitados pelo clamp: ", count(res.preco_novo .!= round.(res.preco_calculado; digits=2)))
