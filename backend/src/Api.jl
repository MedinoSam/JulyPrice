# Endpoints HTTP/REST (Interface do Usuário e Interface ERP).

# shortcut: uma conexão e um lock global serializam as requisições; trocar por pool se houver carga concorrente.
const DB = Ref{LibPQ.Connection}()
const DB_LOCK = ReentrantLock()

json(x; status=200, headers=Pair{String,String}[]) =
    HTTP.Response(status, ["Content-Type" => "application/json"; headers], JSON3.write(x))
json(x::Union{RegraNegocio,LimitePreco}) = json(NamedTuple{fieldnames(typeof(x))}(getfield.(Ref(x), fieldnames(typeof(x)))))

# Corpo JSON; vazio vira `nothing` (rotas em que o corpo é opcional).
function corpo(req; opcional::Bool=false)
    s = String(copy(req.body))  # HTTP.jl 2 embrulha o corpo em BytesBody
    opcional && isempty(strip(s)) && return nothing
    try
        JSON3.read(s)
    catch
        throw(ErroCliente(400, "JSON inválido"))
    end
end
param(req, k) = HTTP.URIs.unescapeuri(HTTP.getparams(req)[k])  # o Router não decodifica variáveis de caminho
consulta_url(req) = HTTP.queryparams(HTTP.URI(req.target))
# Parâmetro de query opcional: ausente ou vazio vira `nothing`; `conv` valida (erro vira 400 via ArgumentError).
function filtro(q, k, conv=identity)
    v = get(q, k, "")
    isempty(v) ? nothing : conv(v)
end
usuario(req) = req.context[:usuario]

function comentario(b)
    c = b === nothing ? nothing : campo(b, :comentario, String, nothing)
    c === nothing || isempty(strip(c)) ? nothing : String(first(strip(c), 1000))
end

# ?pagina=1&por_pagina=20 (máximo 100); valor não numérico vira 400 via ArgumentError
function paginacao(req)
    q = consulta_url(req)
    (max(1, parse(Int, get(q, "pagina", "1"))), clamp(parse(Int, get(q, "por_pagina", "20")), 1, 100))
end

"""
Controle de acesso de cada rota:
- `:publico` — sem login;
- `:erp` — header `X-ERP-Token` igual a `JULYPRICE_ERP_TOKEN` (sem a variável, as rotas do ERP ficam fechadas);
- `:gerente` — qualquer usuário logado (o admin pode tudo o que o gerente pode);
- `:admin` — só perfil admin.
O usuário logado fica em `req.context[:usuario]`.
"""
function autorizar!(req, acesso::Symbol)
    acesso == :publico && return
    if acesso == :erp
        esperado = get(ENV, "JULYPRICE_ERP_TOKEN", "")
        isempty(esperado) && throw(ErroCliente(503, "JULYPRICE_ERP_TOKEN não configurado na API"))
        iguais_tempo_constante(HTTP.header(req, "X-ERP-Token", ""), esperado) || throw(ErroCliente(401, "token do ERP inválido"))
        return
    end
    token = token_do_cookie(req)
    u = token === nothing ? nothing : usuario_da_sessao(DB[], token)
    u === nothing && throw(ErroCliente(401, "sessão expirada ou ausente; faça login"))
    acesso == :admin && u.perfil != "admin" && throw(ErroCliente(403, "acesso restrito ao perfil admin"))
    req.context[:usuario] = u
    nothing
end

garantir_conexao() = LibPQ.status(DB[]) == LibPQ.libpq_c.CONNECTION_OK || LibPQ.reset!(DB[]; throw_error=false)

function rota(f, acesso::Symbol)
    function (req)
        try
            lock(DB_LOCK) do
                garantir_conexao()  # conexão caiu (ex.: Postgres reiniciou): tenta reconectar antes de atender
                autorizar!(req, acesso)
                f(req)
            end
        catch e
            e isa ErroCliente && return json((erro=e.msg,); status=e.status)
            LibPQ.status(DB[]) == LibPQ.libpq_c.CONNECTION_OK || return json((erro="banco de dados indisponível",); status=503)
            e isa Union{ArgumentError,LibPQ.Errors.PQResultError} && return json((erro=sprint(showerror, e),); status=400)
            @error "erro interno" exception = (e, catch_backtrace())
            json((erro="erro interno",); status=500)
        end
    end
end

svg(plt) = HTTP.Response(200, ["Content-Type" => "image/svg+xml"], sprint(show, MIME("image/svg+xml"), plt))

# Histórico de vendas e preço, com uma linha vertical em cada ajuste aprovado (verde) ou revertido (cinza).
function grafico_svg(d, titulo::AbstractString)
    df = d.vendas
    plt = bar(df.data, df.quantidade; label="Vendas (un.)", color=:steelblue, alpha=0.6, linecolor=:match,
              ylabel="Unidades", legend=:topleft, title=titulo, size=(900, 380), titlefontsize=11,
              left_margin=4Plots.mm, right_margin=4Plots.mm, bottom_margin=3Plots.mm)
    rotulos = Dict("Finalizado" => "Ajuste aprovado", "Revertido" => "Ajuste revertido")
    for a in eachrow(d.ajustes)
        vline!(plt, [a.data]; color=a.estado == "Finalizado" ? :seagreen : :gray, ls=:dash, lw=1.5,
               label=pop!(rotulos, a.estado, ""))
    end
    plot!(twinx(), df.data, df.preco; label="Preço (R\$)", color=:darkorange, lw=2, ylabel="R\$", legend=:topright)
    plt
end

# Curva de demanda q(x) = q₀·(x/p)^e, com q₀ a média diária dos últimos 30 dias de histórico.
function curva_svg(d)
    p, e = d.preco, d.elasticidade
    q0 = mean(last(d.vendas.quantidade, 30))
    q(x) = q0 * (x / p)^e
    lo, hi = 0.6p, 1.4p
    d.sugerido === nothing || (lo = min(lo, 0.9d.sugerido); hi = max(hi, 1.1d.sugerido))
    xs = range(lo, hi; length=120)
    plt = plot(xs, q.(xs); label=@sprintf("Demanda estimada (elasticidade %.2f)", e), color=:steelblue, lw=2,
               xlabel="Preço (R\$)", ylabel="Unidades/dia", size=(900, 320), legend=:topright,
               title="Curva de demanda", titlefontsize=11, left_margin=4Plots.mm, bottom_margin=5Plots.mm)
    scatter!(plt, [p], [q0]; label=@sprintf("Atual R\$ %.2f", p), color=:darkorange, ms=7)
    d.sugerido === nothing ||
        scatter!(plt, [d.sugerido], [q(d.sugerido)]; label=@sprintf("Sugerido R\$ %.2f", d.sugerido), color=:seagreen, ms=7)
    plt
end

function registrar_rotas()
    r = HTTP.Router()
    reg(metodo, caminho, acesso, f) = HTTP.register!(r, metodo, caminho, rota(f, acesso))

    # --- Sessão ---
    reg("GET", "/api/saude", :publico, _ -> (execute(DB[], "SELECT 1"); json((status="ok",))))
    reg("POST", "/api/login", :publico, req -> begin
        b = corpo(req)
        s = autenticar(DB[], campo(b, :login, String), campo(b, :senha, String))
        json(s.usuario; headers=["Set-Cookie" => cookie_sessao(s.token, HORAS_SESSAO * 3600)])
    end)
    reg("POST", "/api/logout", :publico, req -> begin
        t = token_do_cookie(req)
        t === nothing || encerrar_sessao(DB[], t)
        json((saiu=true,); headers=["Set-Cookie" => cookie_sessao("", 0)])
    end)
    reg("GET", "/api/eu", :gerente, req -> json(usuario(req)))

    # --- Painel Gerencial ---
    reg("GET", "/api/produtos", :gerente, req ->
        json(listar_produtos(DB[], paginacao(req)...; busca=filtro(consulta_url(req), "q"))))
    reg("GET", "/api/categorias", :gerente, _ -> json(listar_categorias(DB[])))

    reg("PUT", "/api/produtos/{id}/limites", :gerente, req -> begin
        b = corpo(req)
        json(definir_limites(DB[], param(req, "id"),
             LimitePreco(campo(b, :preco_minimo, Float64), campo(b, :preco_maximo, Float64), campo(b, :margem_desejada, Float64))))
    end)

    reg("GET", "/api/produtos/{id}/grafico.svg", :gerente, req -> begin
        id = param(req, "id")
        svg(grafico_svg(dados_grafico(DB[], id), "Histórico de $id"))
    end)
    reg("GET", "/api/produtos/{id}/curva.svg", :gerente, req -> svg(curva_svg(dados_grafico(DB[], param(req, "id")))))

    reg("GET", "/api/sugestoes-alertas", :gerente, req -> begin
        q = consulta_url(req)
        json(ver_sugestoes_e_alertas(DB[], paginacao(req)...; risco=filtro(q, "risco"), categoria=filtro(q, "categoria")))
    end)

    filtros_ajustes(req) = (q = consulta_url(req);
        (estado=filtro(q, "estado"), de=filtro(q, "de", Date), ate=filtro(q, "ate", s -> Date(s) + Day(1))))  # `ate` inclusivo
    reg("GET", "/api/ajustes", :gerente, req -> json(listar_ajustes(DB[], paginacao(req)...; filtros_ajustes(req)...)))
    reg("GET", "/api/ajustes.csv", :gerente, req -> HTTP.Response(200,
        ["Content-Type" => "text/csv; charset=utf-8", "Content-Disposition" => "attachment; filename=\"ajustes.csv\""],
        ajustes_csv(DB[]; filtros_ajustes(req)...)))

    reg("POST", "/api/ajustes/lote", :gerente, req -> begin
        b = corpo(req)
        ids = get(b, :ids, nothing)
        ids isa AbstractVector && all(i -> i isa Integer && !(i isa Bool), ids) ||
            throw(ErroCliente(400, "campo 'ids' deve ser uma lista de inteiros"))
        acao = get(ACOES, campo(b, :acao, String), nothing)
        acao === nothing && throw(ErroCliente(400, "acao deve ser aprovar ou descartar"))
        json(revisar_lote(DB[], Int.(ids), acao; usuario=usuario(req).login, comentario=comentario(b)))
    end)
    reg("POST", "/api/ajustes/{id}/{acao}", :gerente, req -> begin
        acao = get(ACOES, param(req, "acao"), nothing)
        acao === nothing && throw(ErroCliente(404, "ação desconhecida"))
        json(revisar_ajustes(DB[], parse(Int, param(req, "id")), acao;
                             usuario=usuario(req).login, comentario=comentario(corpo(req; opcional=true))))
    end)

    # --- Alertas e indicadores ---
    reg("GET", "/api/alertas", :gerente, req -> begin
        q = consulta_url(req)
        json(listar_alertas(DB[], paginacao(req)...; tipo=filtro(q, "tipo"), lido=filtro(q, "lido", s -> parse(Bool, s))))
    end)
    reg("GET", "/api/alertas/nao-lidos", :gerente, _ -> json((total=contar_alertas_nao_lidos(DB[]),)))
    reg("POST", "/api/alertas/lidos", :gerente, _ -> json(marcar_alertas_lidos(DB[])))
    reg("POST", "/api/alertas/{id}/lido", :gerente, req -> json(marcar_alertas_lidos(DB[], parse(Int, param(req, "id")))))
    reg("GET", "/api/indicadores", :gerente, req ->
        json(indicadores(DB[]; dias=clamp(something(filtro(consulta_url(req), "dias", s -> parse(Int, s)), 30), 1, 365))))

    # --- Painel Administrativo ---
    reg("GET", "/api/regras", :gerente, _ -> json(carregar_config(DB[])))
    reg("PUT", "/api/regras", :admin, req -> json(atualizar_regras(DB[], config_do_corpo(corpo(req), carregar_config(DB[]))...)))
    reg("GET", "/api/regras/categorias", :gerente, _ -> json(listar_regras_categoria(DB[])))
    reg("PUT", "/api/regras/categorias/{categoria}", :admin, req -> begin
        b = corpo(req)
        json(definir_regra_categoria(DB[], param(req, "categoria"),
             RegraNegocio(campo(b, :limite_estoque_minimo, Int64), campo(b, :limite_dias_inatividade, Int64),
                          campo(b, :taxa_ajuste_alto, Float64), campo(b, :taxa_ajuste_baixo, Float64))))
    end)
    reg("DELETE", "/api/regras/categorias/{categoria}", :admin, req -> json(remover_regra_categoria(DB[], param(req, "categoria"))))
    reg("POST", "/api/motor/executar", :admin, _ -> json(executar_motor(DB[]; origem="manual")))
    reg("POST", "/api/motor/simular", :admin, req -> json(simular_motor(DB[], corpo(req))))
    reg("GET", "/api/execucoes", :admin, req -> json(listar_execucoes(DB[], paginacao(req)...)))

    # --- Interface ERP ---
    reg("POST", "/api/erp/vendas-estoque", :erp, req -> begin
        recebido = receber_vendas_e_estoque(DB[], corpo(req))
        json((recebido=recebido, ciclo=executar_motor(DB[]; origem="erp")))  # ciclo autônomo a cada carga do ERP
    end)
    reg("GET", "/api/erp/precos-ajustados", :erp, req -> begin
        q = consulta_url(req)
        # `desde` em UTC (ISO 8601); aceita o `Z` que a própria API devolve
        desde = haskey(q, "desde") ? DateTime(chopsuffix(q["desde"], "Z")) : DateTime(1970)
        json(listar_precos_ajustados(DB[], desde))
    end)
    r
end

# Confere a cada minuto se a agenda do motor venceu (regras_negocio.intervalo_motor_horas; 0 desliga).
function agendador()
    while true
        sleep(60)
        try
            lock(DB_LOCK) do
                garantir_conexao()
                motor_agendado_vencido(DB[]) || return
                @info "motor agendado" executar_motor(DB[]; origem="agenda")
            end
        catch e
            @error "falha no motor agendado" exception = (e, catch_backtrace())
        end
    end
end

function iniciar(; host="127.0.0.1", porta=parse(Int, get(ENV, "PORT", "8080")))
    DB[] = conectar()
    aplicar_schema(DB[])
    haskey(ENV, "JULYPRICE_ERP_TOKEN") || @warn "JULYPRICE_ERP_TOKEN não definido: as rotas /api/erp ficam fechadas"
    errormonitor(@async agendador())
    @info "JulyPrice API em http://$host:$porta"
    HTTP.serve(registrar_rotas(), host, porta)
end
