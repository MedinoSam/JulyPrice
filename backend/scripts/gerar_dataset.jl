# Gera um dataset sintético (produtos, limites de preço e histórico diário de vendas).
#
# Uso:
#   julia --project=backend backend/scripts/gerar_dataset.jl [--n 200] [--dias 90] [--seed 42] [--saida data] [--db]
#
# Sempre grava CSVs em --saida. Com --db, também APAGA e recarrega as tabelas de dados no
# PostgreSQL de JULYPRICE_DATABASE_URL (produtos, limites_preco, vendas, ajustes_preco, alertas).
#
# Demanda: q_t ~ Poisson(base · (p_t / p0)^e), com elasticidade real `e` por produto, para que o
# motor (JuMP) tenha o que estimar. Cenários: ~20% ruptura, ~25% encalhe, resto normal.

using CSV, DataFrames, Dates, LibPQ, Printf, Random

function argumentos(args)
    o = Dict("n" => "200", "dias" => "90", "seed" => "42", "saida" => "data", "db" => "false")
    i = 1
    while i <= length(args)
        k = lstrip(args[i], '-')
        haskey(o, k) || error("argumento desconhecido: $(args[i])")
        if k == "db"
            o[k] = "true"; i += 1
        else
            i < length(args) || error("faltou valor para $(args[i])")
            o[k] = args[i+1]; i += 2
        end
    end
    o
end

# Knuth: suficiente para λ moderado (λ aqui fica < ~400)
function poisson(rng, λ)
    L, k, p = exp(-λ), 0, 1.0
    while true
        p *= rand(rng)
        p <= L && return k
        k += 1
    end
end

const CATALOGO = Dict(
    "Eletrônicos" => ["Fone Bluetooth", "Carregador USB-C", "Mouse Sem Fio", "Teclado Mecânico", "Smartwatch", "Caixa de Som"],
    "Moda"        => ["Camiseta Básica", "Calça Jeans", "Tênis Casual", "Jaqueta Corta-Vento", "Boné", "Meia Esportiva"],
    "Casa"        => ["Jogo de Panelas", "Luminária LED", "Toalha de Banho", "Organizador", "Garrafa Térmica", "Cafeteira"],
    "Esporte"     => ["Bola de Futebol", "Halter 5kg", "Tapete de Yoga", "Squeeze", "Corda de Pular", "Luva de Treino"],
    "Beleza"      => ["Shampoo", "Protetor Solar", "Perfume", "Hidratante", "Sabonete Líquido", "Kit Maquiagem"],
    "Livros"      => ["Romance", "Biografia", "Livro Técnico", "HQ", "Livro Infantil", "Guia de Viagem"],
)
const MARCAS = ["Aurora", "Vértice", "Nexo", "Prisma", "Lume", "Orion", "Brisa", "Atlas"]

function gerar(n, dias, rng; hoje=today())
    produtos = DataFrame(id=String[], nome=String[], categoria=String[], custo=Float64[], preco=Float64[],
                         estoque=Int64[], dias_parado=Int64[], elasticidade=Float64[],
                         elasticidade_real=Float64[], cenario=String[])
    limites = DataFrame(produto_id=String[], preco_minimo=Float64[], preco_maximo=Float64[], margem_desejada=Float64[])
    vendas = DataFrame(produto_id=String[], data=Date[], quantidade=Int64[], preco=Float64[])
    cats = sort(collect(keys(CATALOGO)))

    for i in 1:n
        id = @sprintf("SKU%04d", i)
        cat = rand(rng, cats)
        nome = "$(rand(rng, CATALOGO[cat])) $(rand(rng, MARCAS))"
        custo = round(exp(1.5 + 4rand(rng)); digits=2)        # ~R$ 4,50 a R$ 245
        p0 = round(custo * (1.3 + 0.9rand(rng)); digits=2)     # markup 30%–120%
        e = -(0.3 + 2.5rand(rng))                              # elasticidade real em [-2.8, -0.3]
        base = 3 + 27rand(rng)                                 # unidades/dia ao preço p0
        u = rand(rng)
        cenario = u < 0.20 ? "ruptura" : u < 0.45 ? "encalhe" : "normal"
        dias_parado = cenario == "encalhe" ? rand(rng, 31:min(75, dias)) : rand(rng, 0:5)

        # Preço muda toda semana, sorteado em ±30% de p0 (variação para o motor estimar a elasticidade)
        p = p0
        for d in 0:dias-1
            d % 7 == 0 && d > 0 && (p = round(p0 * (0.7 + 0.6rand(rng)); digits=2))
            data = hoje - Day(dias - d)
            q = d >= dias - dias_parado ? 0 : poisson(rng, base * (p / p0)^e)
            push!(vendas, (id, data, q, p))
        end

        estoque = cenario == "ruptura" ? rand(rng, 0:9) : cenario == "encalhe" ? rand(rng, 50:400) : rand(rng, 15:200)
        margem = rand(rng, [0.10, 0.15, 0.20, 0.25])
        pmin = round(custo * 1.05; digits=2)
        pmax = round(max(p * 1.4, pmin * 1.1); digits=2)
        push!(produtos, (id, nome, cat, custo, p, estoque, dias_parado, -1.0, round(e; digits=3), cenario))
        push!(limites, (id, pmin, pmax, margem))
    end
    produtos, limites, vendas
end

function carregar_db(produtos, limites, vendas)
    conn = LibPQ.Connection(get(ENV, "JULYPRICE_DATABASE_URL", "postgresql://julyprice:julyprice@localhost:5433/julyprice"))
    ex(sql) = execute(conn, sql)
    load!(df, sql) = LibPQ.load!(df, conn, sql)
    ex("BEGIN")
    try
        ex("TRUNCATE alertas, ajustes_preco, vendas, limites_preco, produtos RESTART IDENTITY")
        load!(select(produtos, Not([:elasticidade_real, :cenario])),
              "INSERT INTO produtos (id, nome, categoria, custo, preco, estoque, dias_parado, elasticidade) VALUES (\$1,\$2,\$3,\$4,\$5,\$6,\$7,\$8)")
        load!(limites, "INSERT INTO limites_preco VALUES (\$1,\$2,\$3,\$4)")
        load!(vendas, "INSERT INTO vendas VALUES (\$1,\$2,\$3,\$4)")
        ex("COMMIT")
    catch
        ex("ROLLBACK")
        rethrow()
    finally
        close(conn)
    end
end

function main(args)
    o = argumentos(args)
    n, dias = parse(Int, o["n"]), parse(Int, o["dias"])
    n > 0 && dias >= 31 || error("--n deve ser > 0 e --dias >= 31")
    produtos, limites, vendas = gerar(n, dias, MersenneTwister(parse(Int, o["seed"])))

    # Autoverificação do dataset
    @assert nrow(vendas) == n * dias
    @assert all(limites.preco_maximo .>= limites.preco_minimo .> 0)
    @assert all(produtos.preco .> 0) && all(vendas.quantidade .>= 0)
    for r in eachrow(produtos)  # dias parados batem com o fim do histórico
        r.dias_parado == 0 && continue
        @assert all(vendas.quantidade[(vendas.produto_id .== r.id) .& (vendas.data .> today() - Day(r.dias_parado + 1))] .== 0)
    end

    mkpath(o["saida"])
    CSV.write(joinpath(o["saida"], "produtos.csv"), produtos)
    CSV.write(joinpath(o["saida"], "limites_preco.csv"), limites)
    CSV.write(joinpath(o["saida"], "vendas.csv"), vendas)
    println("CSV gravados em $(o["saida"]): $(nrow(produtos)) produtos, $(nrow(vendas)) vendas")
    println(combine(groupby(produtos, :cenario), nrow => :produtos))

    if o["db"] == "true"
        carregar_db(produtos, limites, vendas)
        println("Banco recarregado.")
    end
end

main(ARGS)
