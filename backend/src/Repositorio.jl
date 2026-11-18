# Integração Externa (ERP) + Gestão de Regras/Limites/Ajustes, persistidos no PostgreSQL.

struct ErroCliente <: Exception
    status::Int
    msg::String
end

const DATABASE_URL_PADRAO = "postgresql://julyprice:julyprice@localhost:5433/julyprice"
conectar() = LibPQ.Connection(get(ENV, "JULYPRICE_DATABASE_URL", DATABASE_URL_PADRAO))

consulta(conn, sql, params=[]) = DataFrame(execute(conn, sql, params))
# TIMESTAMP do banco está em UTC (sessão do LibPQ): sai com `Z` para o cliente não ler como hora local.
linhas(df::DataFrame) = [map(v -> v isa DateTime ? string(v, "Z") : v, NamedTuple(r)) for r in eachrow(df)]

function transacao(f, conn)
    execute(conn, "BEGIN")
    try
        x = f()
        execute(conn, "COMMIT")
        x
    catch
        execute(conn, "ROLLBACK")
        rethrow()
    end
end

# db/schema.sql é idempotente: reaplicado a cada subida, leva bancos antigos ao schema atual.
function aplicar_schema(conn)
    execute(conn, "SET client_min_messages TO warning")
    transacao(() -> execute(conn, read(joinpath(@__DIR__, "..", "..", "db", "schema.sql"), String)), conn)
end

# Lê um campo de um objeto JSON validando o tipo; erro vira HTTP 400.
function campo(o, k::Symbol, ::Type{T}) where {T}
    v = o isa AbstractDict ? get(o, k, nothing) : nothing
    try
        T <: Real && v isa Real && !(v isa Bool) && return convert(T, v)  # Bool <: Real no Julia
        T <: AbstractString && v isa AbstractString && return String(v)
    catch
    end
    throw(ErroCliente(400, "campo '$k' ausente ou inválido (esperado $T)"))
end

# Campo opcional: ausente ou null vira `padrao`.
campo(o, k::Symbol, T::Type, padrao) = o isa AbstractDict && get(o, k, nothing) === nothing ? padrao : campo(o, k, T)

# ---------- Gestão de Regras (Administrador) ----------

const CAMPOS_CONFIG = (:dias_cooldown, :variacao_cooldown, :teto_padrao, :variacao_max_janela,
                       :dias_janela_variacao, :intervalo_motor_horas)
const TIPOS_CONFIG = (Int64, Float64, Float64, Float64, Int64, Int64)

carregar_config(conn) = NamedTuple(first(eachrow(consulta(conn, "SELECT * FROM regras_negocio WHERE id = 1"))))

regra_de(r) = RegraNegocio(r.limite_estoque_minimo, r.limite_dias_inatividade, r.taxa_ajuste_alto, r.taxa_ajuste_baixo)
carregar_regra(conn) = regra_de(carregar_config(conn))

function validar_regra(r::RegraNegocio)
    r.limite_estoque_minimo >= 0 && r.limite_dias_inatividade >= 0 ||
        throw(ErroCliente(400, "estoque mínimo e dias de inatividade devem ser >= 0"))
    r.taxa_ajuste_alto >= 0 || throw(ErroCliente(400, "taxa_ajuste_alto deve ser >= 0"))
    0 <= r.taxa_ajuste_baixo < 1 || throw(ErroCliente(400, "taxa_ajuste_baixo deve estar em [0, 1)"))
    r
end

# Regra + parâmetros globais de um corpo JSON. Parâmetro ausente mantém o valor de `atual`.
function config_do_corpo(b, atual)
    regra = RegraNegocio(campo(b, :limite_estoque_minimo, Int64), campo(b, :limite_dias_inatividade, Int64),
                         campo(b, :taxa_ajuste_alto, Float64), campo(b, :taxa_ajuste_baixo, Float64))
    cfg = NamedTuple{CAMPOS_CONFIG}(Tuple(campo(b, k, T, getproperty(atual, k)) for (k, T) in zip(CAMPOS_CONFIG, TIPOS_CONFIG)))
    all(v -> v >= 0, cfg) || throw(ErroCliente(400, "os parâmetros de cooldown, teto, janela e agenda devem ser >= 0"))
    cfg.dias_janela_variacao >= 1 || throw(ErroCliente(400, "dias_janela_variacao deve ser >= 1"))
    validar_regra(regra), cfg
end

function atualizar_regras(conn, r::RegraNegocio, cfg::NamedTuple)
    execute(conn, """UPDATE regras_negocio SET limite_estoque_minimo=\$1, limite_dias_inatividade=\$2,
                     taxa_ajuste_alto=\$3, taxa_ajuste_baixo=\$4, dias_cooldown=\$5, variacao_cooldown=\$6,
                     teto_padrao=\$7, variacao_max_janela=\$8, dias_janela_variacao=\$9, intervalo_motor_horas=\$10,
                     atualizado_em=now() WHERE id = 1""",
            Any[r.limite_estoque_minimo, r.limite_dias_inatividade, r.taxa_ajuste_alto, r.taxa_ajuste_baixo,
                cfg...])  # Any: evita promover Int para Float
    carregar_config(conn)
end

listar_regras_categoria(conn) = linhas(consulta(conn, "SELECT * FROM regras_categoria ORDER BY categoria"))

carregar_regras_categoria(conn) =
    Dict{String,RegraNegocio}(r.categoria => regra_de(r) for r in eachrow(consulta(conn, "SELECT * FROM regras_categoria")))

function definir_regra_categoria(conn, categoria::String, r::RegraNegocio)
    isempty(strip(categoria)) && throw(ErroCliente(400, "categoria vazia"))
    validar_regra(r)
    execute(conn, """INSERT INTO regras_categoria VALUES (\$1,\$2,\$3,\$4,\$5) ON CONFLICT (categoria) DO UPDATE SET
                     limite_estoque_minimo=EXCLUDED.limite_estoque_minimo, limite_dias_inatividade=EXCLUDED.limite_dias_inatividade,
                     taxa_ajuste_alto=EXCLUDED.taxa_ajuste_alto, taxa_ajuste_baixo=EXCLUDED.taxa_ajuste_baixo""",
            Any[categoria, r.limite_estoque_minimo, r.limite_dias_inatividade, r.taxa_ajuste_alto, r.taxa_ajuste_baixo])
    (categoria=categoria, limite_estoque_minimo=r.limite_estoque_minimo, limite_dias_inatividade=r.limite_dias_inatividade,
     taxa_ajuste_alto=r.taxa_ajuste_alto, taxa_ajuste_baixo=r.taxa_ajuste_baixo)
end

function remover_regra_categoria(conn, categoria::String)
    isempty(consulta(conn, "DELETE FROM regras_categoria WHERE categoria = \$1 RETURNING 1", [categoria])) &&
        throw(ErroCliente(404, "categoria $categoria sem regra própria"))
    (categoria=categoria, removida=true)
end

listar_categorias(conn) = consulta(conn, "SELECT DISTINCT categoria FROM produtos WHERE categoria <> '' ORDER BY 1").categoria

# ---------- Gerente Comercial ----------

function definir_limites(conn, produto_id::String, l::LimitePreco)
    l.preco_maximo >= l.preco_minimo > 0 || throw(ErroCliente(400, "exige 0 < preco_minimo <= preco_maximo"))
    l.margem_desejada >= 0 || throw(ErroCliente(400, "margem_desejada deve ser >= 0"))
    isempty(consulta(conn, "SELECT 1 FROM produtos WHERE id = \$1", [produto_id])) &&
        throw(ErroCliente(404, "produto $produto_id não encontrado"))
    execute(conn, """INSERT INTO limites_preco VALUES (\$1,\$2,\$3,\$4)
                     ON CONFLICT (produto_id) DO UPDATE SET preco_minimo=EXCLUDED.preco_minimo,
                     preco_maximo=EXCLUDED.preco_maximo, margem_desejada=EXCLUDED.margem_desejada""",
            [produto_id, l.preco_minimo, l.preco_maximo, l.margem_desejada])
    l
end

# Cláusula WHERE. Texto puro entra sempre; um par (condição com `\$`, valor) só entra se o valor não for
# `nothing`. Os `\$` das condições são renumerados na ordem em que entram.
function onde(filtros...)
    conds, params = String[], Any[]
    for f in filtros
        f isa AbstractString && (push!(conds, f); continue)
        cond, v = f
        v === nothing && continue
        push!(params, v)
        push!(conds, replace(cond, "\$" => "\$$(length(params))"))
    end
    (isempty(conds) ? "" : "WHERE " * join(conds, " AND ")), params
end

# Página de `sql` (que já traz ORDER BY). `pagina` e `por_pagina` chegam validados como Int.
function paginar(conn, sql, params, pagina::Int, por_pagina::Int)
    total = only(consulta(conn, "SELECT count(*) AS n FROM ($sql) t", params).n)
    itens = linhas(consulta(conn, "$sql LIMIT $por_pagina OFFSET $((pagina - 1) * por_pagina)", params))
    (itens=itens, total=total, pagina=pagina, por_pagina=por_pagina)
end

function listar_produtos(conn, pagina::Int, por_pagina::Int; busca=nothing)
    w, params = onde(("position(lower(\$) in lower(p.id || ' ' || p.nome || ' ' || p.categoria)) > 0", busca))
    paginar(conn, """
        SELECT p.*, l.preco_minimo, l.preco_maximo, l.margem_desejada,
               EXISTS (SELECT 1 FROM ajustes_preco a WHERE a.produto_id = p.id AND a.estado = 'NotificadoGerente') AS pendente
        FROM produtos p LEFT JOIN limites_preco l ON l.produto_id = p.id $w ORDER BY p.id""", params, pagina, por_pagina)
end

# Sugestões pendentes, cada uma com o alerta que a gerou.
function ver_sugestoes_e_alertas(conn, pagina::Int, por_pagina::Int; risco=nothing, categoria=nothing)
    w, params = onde("a.estado = 'NotificadoGerente'", ("a.risco = \$", risco), ("p.categoria = \$", categoria))
    paginar(conn, """
        SELECT a.*, p.nome, p.categoria, al.tipo AS alerta_tipo, al.mensagem AS alerta_mensagem
        FROM ajustes_preco a JOIN produtos p ON p.id = a.produto_id
        LEFT JOIN alertas al ON al.ajuste_id = a.id
        $w ORDER BY a.criado_em DESC, a.id DESC""", params, pagina, por_pagina)
end

# `revertivel`: mesmas regras de `revisar_ajuste!` — finalizado mais recente do produto, sem pendente,
# e não feito pelo clamp de limites (risco normal), que o próximo ciclo reaplicaria.
function sql_ajustes(; estado=nothing, de=nothing, ate=nothing)
    w, params = onde(("a.estado = \$", estado), ("a.criado_em >= \$", de), ("a.criado_em < \$", ate))
    """SELECT a.id, a.criado_em, a.produto_id, p.nome, p.categoria, a.risco, a.estado, a.preco_anterior,
              a.preco_calculado, a.preco_novo, a.elasticidade, a.revisado_em, a.revisado_por, a.comentario,
              (a.estado = 'Finalizado' AND a.risco <> 'normal'
               AND NOT EXISTS (SELECT 1 FROM ajustes_preco b WHERE b.produto_id = a.produto_id
                               AND ((b.id > a.id AND b.estado = 'Finalizado') OR b.estado = 'NotificadoGerente'))) AS revertivel
       FROM ajustes_preco a JOIN produtos p ON p.id = a.produto_id
       $w ORDER BY a.criado_em DESC, a.id DESC""", params
end

listar_ajustes(conn, pagina::Int, por_pagina::Int; filtros...) = paginar(conn, sql_ajustes(; filtros...)..., pagina, por_pagina)

function ajustes_csv(conn; filtros...)
    sql, params = sql_ajustes(; filtros...)
    io = IOBuffer()
    CSV.write(io, select(consulta(conn, sql, params), Not(:revertivel)))
    String(take!(io))
end

const ACOES = Dict("aprovar" => :aprovar, "descartar" => :descartar, "reverter" => :reverter)

"""
Revisão de um ajuste, sem abrir transação (quem chama abre):
- `:aprovar` — pendente vira Finalizado e o preço é enviado ao ERP;
- `:descartar` — pendente vira Descartado (o preço nunca mudou);
- `:reverter` — finalizado volta ao preço anterior (só o mais recente do produto, sem pendente, e não de clamp).
`usuario` e `comentario` ficam gravados no ajuste.
"""
function revisar_ajuste!(conn, ajuste_id::Int, acao::Symbol, usuario::String, comentario::Union{String,Nothing})
    df = consulta(conn, "SELECT * FROM ajustes_preco WHERE id = \$1 FOR UPDATE", [ajuste_id])
    isempty(df) && throw(ErroCliente(404, "ajuste $ajuste_id não encontrado"))
    a = first(eachrow(df))
    if acao in (:aprovar, :descartar)
        a.estado == "NotificadoGerente" || throw(ErroCliente(409, "ajuste $ajuste_id não está pendente"))
        if acao == :aprovar
            atual = only(consulta(conn, "SELECT preco FROM produtos WHERE id = \$1 FOR UPDATE", [a.produto_id]).preco)
            atual == a.preco_anterior ||
                throw(ErroCliente(409, "o preço do produto mudou desde a sugestão; descarte-a e rode o motor de novo"))
            enviar_precos_ajustados(conn, a.produto_id, a.preco_novo)
        end
        novo_estado = acao == :aprovar ? "Finalizado" : "Descartado"
    else
        a.estado == "NotificadoGerente" && throw(ErroCliente(409, "ajuste pendente: use descartar"))
        a.estado == "Finalizado" || throw(ErroCliente(409, "só ajustes finalizados podem ser revertidos"))
        a.risco == "normal" &&
            throw(ErroCliente(409, "ajuste feito pelos limites do produto; altere os limites em vez de reverter"))
        pendente = consulta(conn, "SELECT 1 FROM ajustes_preco WHERE produto_id=\$1 AND estado = 'NotificadoGerente'",
                            [a.produto_id])
        isempty(pendente) || throw(ErroCliente(409, "há sugestão pendente para o produto; revise-a primeiro"))
        mais_novo = consulta(conn, """SELECT 1 FROM ajustes_preco WHERE produto_id=\$1 AND id > \$2
                                      AND estado = 'Finalizado'""", [a.produto_id, ajuste_id])
        isempty(mais_novo) || throw(ErroCliente(409, "existe ajuste mais recente; reverta-o primeiro"))
        enviar_precos_ajustados(conn, a.produto_id, a.preco_anterior)
        novo_estado = "Revertido"
    end
    execute(conn, "UPDATE ajustes_preco SET estado=\$1, revisado_em=now(), revisado_por=\$2, comentario=\$3 WHERE id=\$4",
            Any[novo_estado, usuario, something(comentario, missing), ajuste_id])
    execute(conn, "UPDATE alertas SET lido = true WHERE ajuste_id = \$1", [ajuste_id])
    (id=ajuste_id, estado=novo_estado)
end

revisar_ajustes(conn, ajuste_id::Int, acao::Symbol; usuario::String, comentario=nothing) =
    transacao(() -> revisar_ajuste!(conn, ajuste_id, acao, usuario, comentario), conn)

"""
Aprova ou descarta vários ajustes numa transação. Cada item roda num SAVEPOINT: um erro de regra
(ex.: preço mudou) recusa só aquele item e devolve o motivo; o resto segue.
"""
function revisar_lote(conn, ids::Vector{Int}, acao::Symbol; usuario::String, comentario=nothing)
    acao in (:aprovar, :descartar) || throw(ErroCliente(400, "lote aceita só aprovar ou descartar"))
    isempty(ids) && throw(ErroCliente(400, "nenhum ajuste selecionado"))
    length(ids) <= 500 || throw(ErroCliente(400, "no máximo 500 ajustes por lote"))
    transacao(conn) do
        map(unique(ids)) do id
            execute(conn, "SAVEPOINT item")
            try
                r = revisar_ajuste!(conn, id, acao, usuario, comentario)
                execute(conn, "RELEASE SAVEPOINT item")
                (id=id, ok=true, estado=r.estado, erro=nothing)
            catch e
                e isa ErroCliente || rethrow()
                execute(conn, "ROLLBACK TO SAVEPOINT item")
                (id=id, ok=false, estado=nothing, erro=e.msg)
            end
        end
    end
end

# ---------- Alertas ----------

function listar_alertas(conn, pagina::Int, por_pagina::Int; tipo=nothing, lido=nothing)
    w, params = onde(("al.tipo = \$", tipo), ("al.lido = \$", lido))
    paginar(conn, """SELECT al.*, p.nome FROM alertas al JOIN produtos p ON p.id = al.produto_id
                     $w ORDER BY al.data_criacao DESC, al.id DESC""", params, pagina, por_pagina)
end

contar_alertas_nao_lidos(conn) = only(consulta(conn, "SELECT count(*) AS n FROM alertas WHERE NOT lido").n)

function marcar_alertas_lidos(conn, id::Union{Int,Nothing}=nothing)
    n = id === nothing ? nrow(consulta(conn, "UPDATE alertas SET lido = true WHERE NOT lido RETURNING id")) :
                         nrow(consulta(conn, "UPDATE alertas SET lido = true WHERE id = \$1 RETURNING id", [id]))
    id !== nothing && n == 0 && throw(ErroCliente(404, "alerta $id não encontrado"))
    (marcados=n,)
end

# ---------- Interface ERP ----------

"""
Recebe produtos (estoque, dias parado, custo, preço) e histórico de vendas do ERP.
Cada venda pode trazer `estoque` do dia (opcional), usado para ignorar dias esgotados na elasticidade.
shortcut: o preço do ERP só é aceito para produto novo — depois a plataforma é dona do preço;
se o ERP também alterar preços, trocar por reconciliação com `preco_alterado_em`.
"""
function receber_vendas_e_estoque(conn, payload)
    payload isa AbstractDict || throw(ErroCliente(400, "corpo deve ser um objeto JSON"))
    produtos = get(payload, :produtos, [])
    vendas = get(payload, :vendas, [])
    produtos isa AbstractVector && vendas isa AbstractVector || throw(ErroCliente(400, "'produtos' e 'vendas' devem ser listas"))
    transacao(conn) do
        for p in produtos
            execute(conn, """INSERT INTO produtos (id, nome, categoria, custo, preco, estoque, dias_parado, preco_base)
                             VALUES (\$1,\$2,\$3,\$4,\$5,\$6,\$7,\$5)
                             ON CONFLICT (id) DO UPDATE SET nome=EXCLUDED.nome, categoria=EXCLUDED.categoria,
                             custo=EXCLUDED.custo, estoque=EXCLUDED.estoque, dias_parado=EXCLUDED.dias_parado""",
                    [campo(p, :id, String), campo(p, :nome, String), campo(p, :categoria, String, ""),
                     campo(p, :custo, Float64), campo(p, :preco, Float64),
                     campo(p, :estoque, Int64), campo(p, :dias_parado, Int64)])
        end
        for v in vendas
            execute(conn, """INSERT INTO vendas (produto_id, data, quantidade, preco, estoque) VALUES (\$1,\$2,\$3,\$4,\$5)
                             ON CONFLICT (produto_id, data)
                             DO UPDATE SET quantidade=EXCLUDED.quantidade, preco=EXCLUDED.preco, estoque=EXCLUDED.estoque""",
                    Any[campo(v, :produto_id, String), Date(campo(v, :data, String)),
                        campo(v, :quantidade, Int64), campo(v, :preco, Float64), campo(v, :estoque, Int64, missing)])
        end
    end
    (produtos=length(produtos), vendas=length(vendas))
end

# Grava o preço final; o ERP o recebe pelo GET /api/erp/precos-ajustados. Preço igual não conta como alteração.
enviar_precos_ajustados(conn, produto_id::String, novo_preco::Float64) =
    execute(conn, "UPDATE produtos SET preco=\$1, preco_alterado_em=now() WHERE id=\$2 AND preco <> \$1",
            [novo_preco, produto_id])

# O banco guarda microssegundos e o DateTime do Julia, milissegundos: sem truncar, o cursor `desde` repetiria itens.
listar_precos_ajustados(conn, desde::DateTime) =
    linhas(consulta(conn, """SELECT id AS produto_id, preco, preco_alterado_em FROM produtos
                             WHERE date_trunc('milliseconds', preco_alterado_em) > \$1 ORDER BY preco_alterado_em""", [desde]))

# ---------- Ciclo do Motor ----------

"""
Carrega tudo o que o motor precisa e roda `executar_ciclo` sobre os produtos sem revisão pendente, sem gravar.
Aplica as regras por categoria, o teto padrão (produto sem limites) e a trava de variação acumulada.
Devolve o resultado e os descartes recentes (para o cooldown).
"""
function preparar_ciclo(conn, regra::RegraNegocio, cfg)
    execute(conn, "UPDATE produtos SET preco_base = preco WHERE preco_base IS NULL")  # produto carregado por fora da API
    produtos = consulta(conn, """SELECT id, nome, categoria, custo, preco, preco_base, estoque, dias_parado, elasticidade
                                 FROM produtos p WHERE NOT EXISTS (SELECT 1 FROM ajustes_preco a
                                                   WHERE a.produto_id = p.id AND a.estado = 'NotificadoGerente')""")
    vendas = consulta(conn, "SELECT produto_id, data, quantidade, preco, estoque FROM vendas")
    # tipado: com a tabela vazia, o gerador daria Dict{Any,Any} e executar_ciclo recusaria
    limites = Dict{String,LimitePreco}(r.produto_id => LimitePreco(r.preco_minimo, r.preco_maximo, r.margem_desejada)
                   for r in eachrow(consulta(conn, "SELECT * FROM limites_preco")))
    for p in eachrow(produtos)
        haskey(limites, p.id) || (limites[p.id] = limite_padrao(p.preco_base, p.preco, cfg.teto_padrao))
    end
    # Preço no início da janela: o anterior do primeiro ajuste finalizado dentro dela (sem ajuste, o atual)
    referencias = Dict{String,Float64}(r.produto_id => r.ref for r in eachrow(consulta(conn, """
        SELECT DISTINCT ON (produto_id) produto_id, preco_anterior AS ref FROM ajustes_preco
        WHERE estado = 'Finalizado' AND COALESCE(revisado_em, criado_em) >= now() - make_interval(days => \$1::int)
        ORDER BY produto_id, id""", Any[cfg.dias_janela_variacao])))
    descartes = cfg.dias_cooldown == 0 ? Dict{Tuple{String,String},Float64}() :
        Dict{Tuple{String,String},Float64}((r.produto_id, r.risco) => r.preco_novo for r in eachrow(consulta(conn, """
            SELECT DISTINCT ON (produto_id, risco) produto_id, risco, preco_novo FROM ajustes_preco
            WHERE estado = 'Descartado' AND revisado_em >= now() - make_interval(days => \$1::int)
            ORDER BY produto_id, risco, id DESC""", Any[cfg.dias_cooldown])))
    res = executar_ciclo(produtos, vendas, regra, limites; regras_categoria=carregar_regras_categoria(conn),
                         referencias=referencias, variacao_janela=cfg.variacao_max_janela)
    res, descartes
end

# Sugestão de risco parecida com uma descartada dentro do cooldown não volta ao gerente.
suprimida(r, descartes, cfg) = r.risco != :normal && haskey(descartes, (r.produto_id, string(r.risco))) &&
    em_cooldown(r.preco_novo, descartes[(r.produto_id, string(r.risco))], cfg.variacao_cooldown)

gera_ajuste(r) = !(r.risco == :normal && r.preco_novo == r.preco_anterior)  # normal sem mudança não gera registro

"Roda o motor sobre todos os produtos sem revisão pendente, persiste ajustes/alertas e registra a execução."
function executar_motor(conn; origem::String="manual")
    inicio = time()
    try
        cfg = carregar_config(conn)
        res, descartes = preparar_ciclo(conn, regra_de(cfg), cfg)
        contagem = Dict("normal" => 0, "ruptura" => 0, "encalhe" => 0, "ajustes" => 0, "suprimidas" => 0)
        transacao(conn) do
            for r in eachrow(res)
                contagem[string(r.risco)] += 1
                execute(conn, "UPDATE produtos SET elasticidade=\$1 WHERE id=\$2", [r.elasticidade, r.produto_id])
                gera_ajuste(r) || continue
                suprimida(r, descartes, cfg) && (contagem["suprimidas"] += 1; continue)
                contagem["ajustes"] += 1
                id = only(consulta(conn, """INSERT INTO ajustes_preco (produto_id, risco, estado, preco_anterior,
                                            preco_calculado, preco_novo, elasticidade) VALUES (\$1,\$2,\$3,\$4,\$5,\$6,\$7)
                                            RETURNING id""",
                                   [r.produto_id, string(r.risco), string(r.estado_final), r.preco_anterior,
                                    r.preco_calculado, r.preco_novo, r.elasticidade]).id)
                r.estado_final == Finalizado && enviar_precos_ajustados(conn, r.produto_id, r.preco_novo)
                ismissing(r.alerta_tipo) ||
                    execute(conn, "INSERT INTO alertas (produto_id, ajuste_id, tipo, mensagem) VALUES (\$1,\$2,\$3,\$4)",
                            [r.produto_id, id, r.alerta_tipo, r.alerta_mensagem])
            end
            execute(conn, """INSERT INTO execucoes_motor (origem, inicio, duracao_ms, normal, ruptura, encalhe, ajustes, suprimidas)
                             VALUES (\$1, now() - make_interval(secs => \$2), \$3, \$4, \$5, \$6, \$7, \$8)""",
                    Any[origem, time() - inicio, round(Int, 1000(time() - inicio)), contagem["normal"],
                        contagem["ruptura"], contagem["encalhe"], contagem["ajustes"], contagem["suprimidas"]])
        end
        contagem
    catch e
        try  # registra a falha; se o banco caiu, o registro também falha e o erro original prevalece
            execute(conn, "INSERT INTO execucoes_motor (origem, duracao_ms, erro) VALUES (\$1, \$2, \$3)",
                    Any[origem, round(Int, 1000(time() - inicio)), first(sprint(showerror, e), 500)])
        catch
        end
        rethrow()
    end
end

"Roda o ciclo com as regras de `b` (corpo do PUT /api/regras) sem gravar nada: o que mudaria se fossem salvas."
function simular_motor(conn, b)
    regra, cfg = config_do_corpo(b, carregar_config(conn))
    res, descartes = preparar_ciclo(conn, regra, cfg)
    isempty(res) && return (normal=0, ruptura=0, encalhe=0, ajustes=0, suprimidas=0, variacao_media=0.0)
    ajustes = filter(r -> gera_ajuste(r) && !suprimida(r, descartes, cfg), res)
    variacao = isempty(ajustes) ? 0.0 : mean(ajustes.preco_novo ./ ajustes.preco_anterior .- 1)
    (normal=count(==(:normal), res.risco), ruptura=count(==(:ruptura), res.risco), encalhe=count(==(:encalhe), res.risco),
     ajustes=nrow(ajustes), suprimidas=count(r -> gera_ajuste(r) && suprimida(r, descartes, cfg), eachrow(res)),
     variacao_media=variacao)
end

listar_execucoes(conn, pagina::Int, por_pagina::Int) =
    paginar(conn, "SELECT * FROM execucoes_motor ORDER BY inicio DESC, id DESC", [], pagina, por_pagina)

"Hora de rodar pela agenda: intervalo ligado e nenhuma execução (de qualquer origem) dentro dele."
function motor_agendado_vencido(conn)
    h = carregar_config(conn).intervalo_motor_horas
    h > 0 && isempty(consulta(conn, """SELECT 1 FROM execucoes_motor
                                      WHERE inicio > now() - make_interval(hours => \$1::int)""", Any[h]))
end

# ---------- Indicadores ----------

"""
KPIs dos últimos `dias`: sugestões de risco por dia, taxa de aprovação, tempo até a revisão, pendências por risco
e o impacto estimado dos ajustes aprovados na receita e na margem diárias. O impacto usa a média diária de vendas
dos últimos 30 dias de histórico do produto e a elasticidade gravada no ajuste: q₁ = q₀·(p₁/p₀)^e.
"""
function indicadores(conn; dias::Int=30)
    p = Any[dias]
    por_dia = linhas(consulta(conn, """
        SELECT criado_em::date AS dia, risco, count(*) AS n FROM ajustes_preco
        WHERE risco <> 'normal' AND criado_em >= now() - make_interval(days => \$1::int)
        GROUP BY 1, 2 ORDER BY 1, 2""", p))
    rev = first(eachrow(consulta(conn, """
        SELECT count(*) FILTER (WHERE estado IN ('Finalizado', 'Revertido')) AS aprovados,
               count(*) FILTER (WHERE estado = 'Descartado') AS descartados,
               (avg(extract(epoch FROM revisado_em - criado_em)) / 3600)::float8 AS horas_ate_revisao
        FROM ajustes_preco WHERE risco <> 'normal' AND revisado_em IS NOT NULL
          AND criado_em >= now() - make_interval(days => \$1::int)""", p)))
    pendentes = Dict(r.risco => r.n for r in eachrow(consulta(conn,
        "SELECT risco, count(*) AS n FROM ajustes_preco WHERE estado = 'NotificadoGerente' GROUP BY risco")))
    imp = consulta(conn, """
        SELECT a.preco_anterior AS p0, a.preco_novo AS p1, a.elasticidade AS e, p.custo,
               (SELECT avg(v.quantidade)::float8 FROM vendas v WHERE v.produto_id = a.produto_id
                  AND v.data > (SELECT max(w.data) FROM vendas w WHERE w.produto_id = a.produto_id) - 30) AS q0
        FROM ajustes_preco a JOIN produtos p ON p.id = a.produto_id
        WHERE a.estado = 'Finalizado' AND a.risco <> 'normal' AND a.criado_em >= now() - make_interval(days => \$1::int)""", p)
    imp = dropmissing(imp, :q0)
    q1 = imp.q0 .* (imp.p1 ./ imp.p0) .^ imp.e
    revisados = rev.aprovados + rev.descartados
    (dias=dias, por_dia=por_dia, aprovados=rev.aprovados, descartados=rev.descartados,
     taxa_aprovacao=revisados == 0 ? nothing : rev.aprovados / revisados,
     horas_ate_revisao=coalesce(rev.horas_ate_revisao, nothing),
     pendentes=(ruptura=get(pendentes, "ruptura", 0), encalhe=get(pendentes, "encalhe", 0)),
     impacto=(ajustes=nrow(imp),
              receita_antes=sum(imp.p0 .* imp.q0; init=0.0), receita_depois=sum(imp.p1 .* q1; init=0.0),
              margem_antes=sum((imp.p0 .- imp.custo) .* imp.q0; init=0.0),
              margem_depois=sum((imp.p1 .- imp.custo) .* q1; init=0.0)))
end

# ---------- Gráficos ----------

"Histórico do produto, ajustes revisados (datas) e o ajuste pendente, para os gráficos."
function dados_grafico(conn, id::String)
    vendas = consulta(conn, "SELECT data, quantidade, preco FROM vendas WHERE produto_id = \$1 ORDER BY data", [id])
    isempty(vendas) && throw(ErroCliente(404, "sem vendas para $id"))
    prod = first(eachrow(consulta(conn, "SELECT preco, elasticidade FROM produtos WHERE id = \$1", [id])))
    ajustes = consulta(conn, """SELECT COALESCE(revisado_em, criado_em)::date AS data, estado FROM ajustes_preco
                                WHERE produto_id = \$1 AND estado IN ('Finalizado', 'Revertido') ORDER BY 1""", [id])
    pendente = consulta(conn, "SELECT preco_novo FROM ajustes_preco WHERE produto_id = \$1 AND estado = 'NotificadoGerente'", [id])
    (vendas=vendas, ajustes=ajustes, preco=prod.preco, elasticidade=prod.elasticidade,
     sugerido=isempty(pendente) ? nothing : only(pendente.preco_novo))
end
