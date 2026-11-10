# Integração Externa (ERP) + Gestão de Regras/Limites/Ajustes, persistidos no PostgreSQL.

struct ErroCliente <: Exception
    status::Int
    msg::String
end

const DATABASE_URL_PADRAO = "postgresql://julyprice:julyprice@localhost:5433/julyprice"
conectar() = LibPQ.Connection(get(ENV, "JULYPRICE_DATABASE_URL", DATABASE_URL_PADRAO))

consulta(conn, sql, params=[]) = DataFrame(execute(conn, sql, params))
linhas(df::DataFrame) = [NamedTuple(r) for r in eachrow(df)]

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

# Lê um campo de um objeto JSON validando o tipo; erro vira HTTP 400.
function campo(o, k::Symbol, ::Type{T}) where {T}
    v = o isa AbstractDict ? get(o, k, nothing) : nothing
    try
        T <: Real && v isa Real && return convert(T, v)
        T <: AbstractString && v isa AbstractString && return String(v)
    catch
    end
    throw(ErroCliente(400, "campo '$k' ausente ou inválido (esperado $T)"))
end

# ---------- Gestão de Regras (Administrador) ----------

function carregar_regra(conn)
    r = first(eachrow(consulta(conn, "SELECT * FROM regras_negocio WHERE id = 1")))
    RegraNegocio(r.limite_estoque_minimo, r.limite_dias_inatividade, r.taxa_ajuste_alto, r.taxa_ajuste_baixo)
end

function atualizar_regras(conn, r::RegraNegocio)
    execute(conn, """UPDATE regras_negocio SET limite_estoque_minimo=\$1, limite_dias_inatividade=\$2,
                     taxa_ajuste_alto=\$3, taxa_ajuste_baixo=\$4, atualizado_em=now() WHERE id = 1""",
            Any[r.limite_estoque_minimo, r.limite_dias_inatividade, r.taxa_ajuste_alto, r.taxa_ajuste_baixo])  # Any: evita promover Int para Float
    r
end

# ---------- Gerente Comercial ----------

function definir_limites(conn, produto_id::String, l::LimitePreco)
    l.preco_maximo >= l.preco_minimo > 0 || throw(ErroCliente(400, "exige 0 < preco_minimo <= preco_maximo"))
    l.margem_desejada >= 0 || throw(ErroCliente(400, "margem_desejada deve ser >= 0"))
    execute(conn, """INSERT INTO limites_preco VALUES (\$1,\$2,\$3,\$4)
                     ON CONFLICT (produto_id) DO UPDATE SET preco_minimo=EXCLUDED.preco_minimo,
                     preco_maximo=EXCLUDED.preco_maximo, margem_desejada=EXCLUDED.margem_desejada""",
            [produto_id, l.preco_minimo, l.preco_maximo, l.margem_desejada])
    l
end

# Página de `sql` (que já traz ORDER BY). `pagina` e `por_pagina` chegam validados como Int.
function paginar(conn, sql, pagina::Int, por_pagina::Int)
    total = only(consulta(conn, "SELECT count(*) AS n FROM ($sql) t").n)
    itens = linhas(consulta(conn, "$sql LIMIT $por_pagina OFFSET $((pagina - 1) * por_pagina)"))
    (itens=itens, total=total, pagina=pagina, por_pagina=por_pagina)
end

# Sugestões pendentes, cada uma com o alerta que a gerou.
ver_sugestoes_e_alertas(conn, pagina::Int, por_pagina::Int) = paginar(conn, """
    SELECT a.*, p.nome, al.tipo AS alerta_tipo, al.mensagem AS alerta_mensagem
    FROM ajustes_preco a JOIN produtos p ON p.id = a.produto_id
    LEFT JOIN alertas al ON al.ajuste_id = a.id
    WHERE a.estado = 'NotificadoGerente' ORDER BY a.criado_em DESC, a.id DESC""", pagina, por_pagina)

# `revertivel`: só o ajuste finalizado mais recente de cada produto pode ser revertido.
listar_ajustes(conn, pagina::Int, por_pagina::Int) = paginar(conn, """
    SELECT a.*, p.nome,
           (a.estado = 'Finalizado' AND NOT EXISTS (SELECT 1 FROM ajustes_preco b WHERE b.produto_id = a.produto_id
                                                    AND b.id > a.id AND b.estado = 'Finalizado')) AS revertivel
    FROM ajustes_preco a JOIN produtos p ON p.id = a.produto_id
    ORDER BY a.criado_em DESC, a.id DESC""", pagina, por_pagina)

"""
`acao = :aprovar` — ajuste pendente vira Finalizado e o preço é enviado ao ERP.
`acao = :reverter` — pendente é descartado; finalizado volta ao preço anterior (só o ajuste mais recente do produto).
"""
function revisar_ajustes(conn, ajuste_id::Int, acao::Symbol)
    transacao(conn) do
        df = consulta(conn, "SELECT * FROM ajustes_preco WHERE id = \$1 FOR UPDATE", [ajuste_id])
        isempty(df) && throw(ErroCliente(404, "ajuste $ajuste_id não encontrado"))
        a = first(eachrow(df))
        if acao == :aprovar
            a.estado == "NotificadoGerente" || throw(ErroCliente(409, "só ajustes pendentes podem ser aprovados"))
            enviar_precos_ajustados(conn, a.produto_id, a.preco_novo)
            novo_estado = "Finalizado"
        else
            a.estado == "Revertido" && throw(ErroCliente(409, "ajuste já revertido"))
            if a.estado == "Finalizado"
                mais_novo = consulta(conn, """SELECT 1 FROM ajustes_preco WHERE produto_id=\$1 AND id > \$2
                                              AND estado = 'Finalizado'""", [a.produto_id, ajuste_id])
                isempty(mais_novo) || throw(ErroCliente(409, "existe ajuste mais recente; reverta-o primeiro"))
                enviar_precos_ajustados(conn, a.produto_id, a.preco_anterior)
            end
            novo_estado = "Revertido"
        end
        execute(conn, "UPDATE ajustes_preco SET estado=\$1, revisado_em=now() WHERE id=\$2", [novo_estado, ajuste_id])
        execute(conn, "UPDATE alertas SET lido = true WHERE ajuste_id = \$1", [ajuste_id])
        (id=ajuste_id, estado=novo_estado)
    end
end

# ---------- Interface ERP ----------

"""
Recebe produtos (estoque, dias parado, custo, preço) e histórico de vendas do ERP.
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
            execute(conn, """INSERT INTO produtos (id, nome, categoria, custo, preco, estoque, dias_parado)
                             VALUES (\$1,\$2,\$3,\$4,\$5,\$6,\$7)
                             ON CONFLICT (id) DO UPDATE SET nome=EXCLUDED.nome, categoria=EXCLUDED.categoria,
                             custo=EXCLUDED.custo, estoque=EXCLUDED.estoque, dias_parado=EXCLUDED.dias_parado""",
                    [campo(p, :id, String), campo(p, :nome, String), String(get(p, :categoria, "")),
                     campo(p, :custo, Float64), campo(p, :preco, Float64),
                     campo(p, :estoque, Int64), campo(p, :dias_parado, Int64)])
        end
        for v in vendas
            execute(conn, """INSERT INTO vendas VALUES (\$1,\$2,\$3,\$4) ON CONFLICT (produto_id, data)
                             DO UPDATE SET quantidade=EXCLUDED.quantidade, preco=EXCLUDED.preco""",
                    [campo(v, :produto_id, String), Date(campo(v, :data, String)),
                     campo(v, :quantidade, Int64), campo(v, :preco, Float64)])
        end
    end
    (produtos=length(produtos), vendas=length(vendas))
end

# Grava o preço final; o ERP o recebe pelo GET /api/erp/precos-ajustados.
enviar_precos_ajustados(conn, produto_id::String, novo_preco::Float64) =
    execute(conn, "UPDATE produtos SET preco=\$1, preco_alterado_em=now() WHERE id=\$2", [novo_preco, produto_id])

listar_precos_ajustados(conn, desde::DateTime) =
    linhas(consulta(conn, """SELECT id AS produto_id, preco, preco_alterado_em FROM produtos
                             WHERE preco_alterado_em > \$1 ORDER BY preco_alterado_em""", [desde]))

# ---------- Ciclo do Motor ----------

"Roda o motor sobre todos os produtos sem revisão pendente e persiste ajustes/alertas."
function executar_motor(conn)
    regra = carregar_regra(conn)
    produtos = consulta(conn, """SELECT id, nome, custo, preco, estoque, dias_parado, elasticidade FROM produtos p
                                 WHERE NOT EXISTS (SELECT 1 FROM ajustes_preco a
                                                   WHERE a.produto_id = p.id AND a.estado = 'NotificadoGerente')""")
    vendas = consulta(conn, "SELECT produto_id, data, quantidade, preco FROM vendas")
    limites = Dict(r.produto_id => LimitePreco(r.preco_minimo, r.preco_maximo, r.margem_desejada)
                   for r in eachrow(consulta(conn, "SELECT * FROM limites_preco")))
    res = executar_ciclo(produtos, vendas, regra, limites)
    contagem = Dict("normal" => 0, "ruptura" => 0, "encalhe" => 0, "ajustes" => 0)
    transacao(conn) do
        for r in eachrow(res)
            contagem[string(r.risco)] += 1
            execute(conn, "UPDATE produtos SET elasticidade=\$1 WHERE id=\$2", [r.elasticidade, r.produto_id])
            # Produto normal sem mudança de preço não gera registro
            r.risco == :normal && r.preco_novo == r.preco_anterior && continue
            contagem["ajustes"] += 1
            id = only(consulta(conn, """INSERT INTO ajustes_preco (produto_id, risco, estado, preco_anterior,
                                        preco_calculado, preco_novo, elasticidade) VALUES (\$1,\$2,\$3,\$4,\$5,\$6,\$7)
                                        RETURNING id""",
                               [r.produto_id, string(r.risco), string(r.estado_final), r.preco_anterior,
                                r.preco_calculado, r.preco_novo, r.elasticidade]).id)
            if r.estado_final == Finalizado
                enviar_precos_ajustados(conn, r.produto_id, r.preco_novo)
            else
                execute(conn, "INSERT INTO alertas (produto_id, ajuste_id, tipo, mensagem) VALUES (\$1,\$2,\$3,\$4)",
                        [r.produto_id, id, r.alerta_tipo, r.alerta_mensagem])
            end
        end
    end
    contagem
end
