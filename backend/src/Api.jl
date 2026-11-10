# Endpoints HTTP/REST (Interface do Usuário e Interface ERP).

# shortcut: uma conexão e um lock global serializam as requisições; trocar por pool se houver carga concorrente.
const DB = Ref{LibPQ.Connection}()
const DB_LOCK = ReentrantLock()

json(x; status=200) = HTTP.Response(status, ["Content-Type" => "application/json"], JSON3.write(x))
json(x::Union{RegraNegocio,LimitePreco}) = json(NamedTuple{fieldnames(typeof(x))}(getfield.(Ref(x), fieldnames(typeof(x)))))
corpo(req) = try
    JSON3.read(String(copy(req.body)))  # HTTP.jl 2 embrulha o corpo em BytesBody
catch
    throw(ErroCliente(400, "JSON inválido"))
end
param(req, k) = HTTP.getparams(req)[k]

# ?pagina=1&por_pagina=20 (máximo 100); valor não numérico vira 400 via ArgumentError
function paginacao(req)
    q = HTTP.queryparams(HTTP.URI(req.target))
    (max(1, parse(Int, get(q, "pagina", "1"))), clamp(parse(Int, get(q, "por_pagina", "20")), 1, 100))
end

function rota(f)
    function (req)
        try
            lock(() -> f(req), DB_LOCK)
        catch e
            e isa ErroCliente && return json((erro=e.msg,); status=e.status)
            e isa Union{ArgumentError,LibPQ.Errors.PQResultError} && return json((erro=sprint(showerror, e),); status=400)
            @error "erro interno" exception = (e, catch_backtrace())
            json((erro="erro interno",); status=500)
        end
    end
end

function grafico_svg(df::DataFrame, titulo::AbstractString)
    plt = bar(df.data, df.quantidade; label="Vendas (un.)", color=:steelblue, alpha=0.6, linecolor=:match,
              ylabel="Unidades", legend=:topleft, title=titulo, size=(900, 380), titlefontsize=11)
    plot!(twinx(), df.data, df.preco; label="Preço (R\$)", color=:darkorange, lw=2, ylabel="R\$", legend=:topright)
    sprint(show, MIME("image/svg+xml"), plt)
end

function registrar_rotas()
    r = HTTP.Router()
    reg(metodo, caminho, f) = HTTP.register!(r, metodo, caminho, rota(f))

    # --- Painel Gerencial ---
    reg("GET", "/api/produtos", _ -> json(linhas(consulta(DB[], """
        SELECT p.*, l.preco_minimo, l.preco_maximo, l.margem_desejada,
               EXISTS (SELECT 1 FROM ajustes_preco a WHERE a.produto_id = p.id AND a.estado = 'NotificadoGerente') AS pendente
        FROM produtos p LEFT JOIN limites_preco l ON l.produto_id = p.id ORDER BY p.id"""))))

    reg("PUT", "/api/produtos/{id}/limites", req -> begin
        b = corpo(req)
        json(definir_limites(DB[], param(req, "id"),
             LimitePreco(campo(b, :preco_minimo, Float64), campo(b, :preco_maximo, Float64), campo(b, :margem_desejada, Float64))))
    end)

    reg("GET", "/api/produtos/{id}/grafico.svg", req -> begin
        id = param(req, "id")
        df = consulta(DB[], "SELECT data, quantidade, preco FROM vendas WHERE produto_id = \$1 ORDER BY data", [id])
        isempty(df) && throw(ErroCliente(404, "sem vendas para $id"))
        HTTP.Response(200, ["Content-Type" => "image/svg+xml"], grafico_svg(df, "Histórico de $id"))
    end)

    reg("GET", "/api/sugestoes-alertas", req -> json(ver_sugestoes_e_alertas(DB[], paginacao(req)...)))
    reg("GET", "/api/ajustes", req -> json(listar_ajustes(DB[], paginacao(req)...)))

    reg("POST", "/api/ajustes/{id}/aprovar", req -> json(revisar_ajustes(DB[], parse(Int, param(req, "id")), :aprovar)))
    reg("POST", "/api/ajustes/{id}/reverter", req -> json(revisar_ajustes(DB[], parse(Int, param(req, "id")), :reverter)))

    # --- Painel Administrativo ---
    reg("GET", "/api/regras", _ -> json(carregar_regra(DB[])))
    reg("PUT", "/api/regras", req -> begin
        b = corpo(req)
        regra = RegraNegocio(campo(b, :limite_estoque_minimo, Int64), campo(b, :limite_dias_inatividade, Int64),
                             campo(b, :taxa_ajuste_alto, Float64), campo(b, :taxa_ajuste_baixo, Float64))
        json(atualizar_regras(DB[], regra))
    end)
    reg("POST", "/api/motor/executar", _ -> json(executar_motor(DB[])))

    # --- Interface ERP ---
    reg("POST", "/api/erp/vendas-estoque", req -> begin
        recebido = receber_vendas_e_estoque(DB[], corpo(req))
        json((recebido=recebido, ciclo=executar_motor(DB[])))  # ciclo autônomo a cada carga do ERP
    end)
    reg("GET", "/api/erp/precos-ajustados", req -> begin
        q = HTTP.queryparams(HTTP.URI(req.target))
        desde = haskey(q, "desde") ? DateTime(q["desde"]) : DateTime(1970)
        json(listar_precos_ajustados(DB[], desde))
    end)
    r
end

function iniciar(; host="127.0.0.1", porta=parse(Int, get(ENV, "PORT", "8080")))
    DB[] = conectar()
    @info "JulyPrice API em http://$host:$porta"
    HTTP.serve(registrar_rotas(), host, porta)
end
