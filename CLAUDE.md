# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

JulyPrice: plataforma de precificação dinâmica. O core é em Julia (pacote `CoreSistemaInteligente` em `backend/`), o banco é PostgreSQL e o frontend é Vue 3 + Vite (`frontend/`). Código, comentários, mensagens de erro e documentação ficam em português.

## Comandos

Rode tudo a partir da raiz do repositório. O projeto Julia é `backend/`, então todo comando Julia leva `--project=backend`.

```bash
docker compose up -d                                   # PostgreSQL 16 na porta 5433 (aplica db/schema.sql na 1ª subida)
julia --project=backend -e 'using Pkg; Pkg.instantiate()'
JULYPRICE_ERP_TOKEN=... julia --project=backend backend/server.jl   # API na 8080 (PORT muda a porta)
julia --project=backend backend/scripts/criar_usuario.jl <login> <admin|gerente> "<nome>"  # senha no terminal ou em JULYPRICE_SENHA
julia --project=backend -e 'using Pkg; Pkg.test()'     # backend/test/runtests.jl
julia --project=backend backend/scripts/gerar_dataset.jl --n 200 --dias 90 --seed 42 --saida data [--db]
julia --project=backend backend/scripts/simulacao.jl data   # roda o motor sobre os CSVs, sem banco
cd frontend && npm install && npm run dev              # http://localhost:5173
cd frontend && npm run build
```

- Não há filtro por teste: `Pkg.test()` roda todos os `@testset`. Os testes cobrem a lógica pura do motor e o PBKDF2, sem banco. A API foi validada por scripts que chamam `registrar_rotas()` direto contra um banco `julyprice_teste` descartável (crie com `CREATE DATABASE`; a API aplica o schema).
- `gerar_dataset.jl --db` faz `TRUNCATE ... RESTART IDENTITY` em produtos, limites, vendas, ajustes e alertas. Não toca usuários, sessões, regras por categoria nem execuções. Sem `--db`, só grava CSVs.
- `db/schema.sql` é idempotente e a API o reaplica a cada subida (`aplicar_schema`). Mudança de schema entra no fim, na seção de evoluções, com `ADD COLUMN IF NOT EXISTS`, `CREATE ... IF NOT EXISTS` ou `DROP CONSTRAINT IF EXISTS` + `ADD CONSTRAINT`. Nada destrutivo ali.
- Sem usuário no banco não há como entrar no painel: crie um com `criar_usuario.jl` (depois de subir a API uma vez, para o schema existir).
- A primeira requisição depois de subir a API leva de 5 a 10 segundos (compilação do Julia).

## Ambiente

- `JULYPRICE_ERP_TOKEN`: segredo que o ERP manda no header `X-ERP-Token`. Sem ele, as rotas `/api/erp/*` respondem 503.
- O banco vem de `JULYPRICE_DATABASE_URL` (padrão `postgresql://julyprice:julyprice@localhost:5433/julyprice`). Não use `DATABASE_URL`: no shell do usuário ela aponta para um MySQL de outro projeto.
- O frontend chama `/api` pelo proxy do Vite. O destino é `API_URL`, padrão `http://localhost:8080` (`frontend/vite.config.js`).
- Há dois manifests: `backend/Manifest.toml` (Julia 1.10, a versão da especificação) e `backend/Manifest-v1.13.toml` (Julia 1.13, o padrão do juliaup do usuário). Ao adicionar ou atualizar pacotes, faça nas duas versões (`julia +1.10 ...` e `julia ...`). Se um manifest ficar desatualizado, o 1.13 quebra no `StyledStrings`, que é pacote no 1.10 e stdlib a partir do 1.11.

## Arquitetura

Camadas no backend, incluídas em ordem por `backend/src/CoreSistemaInteligente.jl`:

1. **`Modelos.jl` + `MotorPrecificacao.jl`: lógica pura, sem banco.** Recebem structs e DataFrames, devolvem resultados. É aqui que os testes e a simulação atuam.
2. **`Repositorio.jl`: banco e casos de uso.** Usa LibPQ e transações. Traz as funções do diagrama de classes: `receber_vendas_e_estoque`, `enviar_precos_ajustados`, `atualizar_regras`, `definir_limites`, `ver_sugestoes_e_alertas`, `revisar_ajustes`. `preparar_ciclo` carrega tudo em DataFrames e chama `executar_ciclo` sem gravar; `executar_motor` grava ajustes, alertas e a execução, e `simular_motor` só devolve as contagens. Também traz alertas, indicadores (`indicadores`), CSV e os dados dos gráficos.
3. **`Autenticacao.jl`: usuários e sessões.** Senha com PBKDF2-HMAC-SHA256 (100 mil iterações, salt de 16 bytes, hex no banco). A sessão é um token aleatório no cookie `julyprice_sessao` (HttpOnly, SameSite=Strict, 12 h); o banco guarda só o SHA-256 do token.
4. **`Api.jl`: rotas HTTP.jl.** Cada rota é registrada com um nível de acesso: `:publico`, `:erp` (header `X-ERP-Token`), `:gerente` (qualquer logado) ou `:admin`. O admin pode tudo o que o gerente pode. `rota()` segura o lock global, reconecta ao Postgres se a conexão caiu, autoriza e converte erros: `ErroCliente` vira o status dele, conexão perdida vira 503, e `ArgumentError` ou erro do Postgres (`PQResultError`) viram 400. `GET /api/saude` testa o banco. `iniciar()` aplica o schema e sobe o agendador do motor (`agendador`, confere a cada minuto).

### Ciclo de preço (por produto, em `calcularNovoPreco`)

`EmAnalise → AvaliadoRuptura | AvaliadoEncalhe | AvaliadoNormal → ValidadoClamp → NotificadoGerente | Finalizado`

- Antes do ciclo, `avaliar_elasticidade` estima `e` com JuMP + HiGHS: regressão log-log ponderada por nível de preço, com `e ≤ 0`, ignorando os últimos `dias_parado` dias. O corte é por data e nunca passa da última venda, e dias ausentes no histórico entram como venda zero ao último preço (o ERP pode omitir dias sem venda).
- `avaliar_risco`: ruptura (`estoque < limite_estoque_minimo`) tem prioridade sobre encalhe (`dias_parado > limite_dias_inatividade`). Os dois limites são estritos.
- `calcular_preco`: a regra só define a **faixa**. Ruptura vai de `[p, p·(1+taxa_ajuste_alto)]` e encalhe de `[p·(1−taxa_ajuste_baixo), p]`. Dentro dela, `otimizar_preco` (JuMP + Ipopt) maximiza `(x − c)·(x/p)^e`, com `c = custo` na ruptura (lucro) e `c = 0` no encalhe (receita). Por isso um produto em risco pode manter o preço. O caso `c = 0, e = −1` é plano e devolve o passo da regra.
- `aplicar_clamp`: piso = `max(preco_minimo, custo·(1+margem_desejada))`, teto = `preco_maximo`. Se o piso passar do teto, vale o teto.
- O `LimitePreco` que chega ao clamp já vem ajustado: produto sem limites do gerente recebe `limite_padrao` (teto em `preco_base·(1+teto_padrao)`), e `limitar_variacao` estreita a faixa para `ref·(1 ± variacao_max_janela)`, com `ref` o preço no início da janela. As duas travas sempre incluem o preço atual: impedem o motor de ir além, nunca forçam o preço a voltar. `preco_base` é o primeiro preço do produto.
- A regra usada é a da categoria do produto (`regras_categoria`), se houver; senão, a global. Cooldown, teto, janela e agenda são só globais.
- Venda com `estoque = 0` no dia fica fora da elasticidade (demanda censurada). A coluna é opcional no ERP.
- Risco ≠ normal: o ajuste fica pendente (`NotificadoGerente`), um alerta é gravado e o preço **não** muda até o gerente aprovar. Normal com preço igual não gera registro. Normal com preço mudado pelo clamp vira `Finalizado` direto, com alerta `LIMITE`.

### Regras de persistência não óbvias

- No banco, `ajustes_preco.estado` só assume `NotificadoGerente`, `Finalizado`, `Descartado` (pendente recusado; o preço nunca mudou) ou `Revertido` (finalizado desfeito). Os outros estados existem só em memória. Descartes anteriores a este estado foram gravados como `Revertido`.
- Toda revisão grava `revisado_por` (login) e `comentario` opcional. `revisar_ajuste!` não abre transação: `revisar_ajustes` abre uma, e `revisar_lote` abre uma com um `SAVEPOINT` por item, de modo que um `ErroCliente` recusa só aquele item.
- Cooldown: sugestão de risco cujo preço fica a até `variacao_cooldown` da última descartada do mesmo produto e risco, há menos de `dias_cooldown` dias, não é gravada (conta em `suprimidas`).
- Toda execução do motor (origem `erp`, `manual` ou `agenda`) vira uma linha em `execucoes_motor`, com erro se falhou. A agenda roda quando `intervalo_motor_horas > 0` e não houve execução de nenhuma origem dentro do intervalo.
- Produto com ajuste pendente fica fora de `executar_motor`.
- A plataforma é dona do preço: o upsert do ERP só grava `preco` em produto novo. `preco_alterado_em` só muda quando a plataforma altera o preço, e é isso que `GET /api/erp/precos-ajustados?desde=` lê.
- Reverter um ajuste finalizado só é permitido no mais recente do produto, sem sugestão pendente e com risco ≠ normal (senão 409; ajuste de clamp se desfaz mudando os limites). Ele restaura `preco_anterior`. Aprovar exige que o preço atual ainda seja o `preco_anterior` do ajuste (senão 409).
- `enviar_precos_ajustados` não faz nada se o preço não muda, então `preco_alterado_em` não avança e o ERP não recebe preço repetido.
- Timestamps são `TIMESTAMP` em UTC (o LibPQ abre a sessão em UTC). `linhas()` devolve `DateTime` com `Z`; o `desde` do ERP é UTC, aceita `Z`, e a comparação trunca o banco para milissegundos, a precisão do `DateTime`.
- Listagens paginadas (`/api/produtos`, `/api/sugestoes-alertas`, `/api/ajustes`, `/api/alertas`, `/api/execucoes`) respondem `{itens, total, pagina, por_pagina}`, com `por_pagina` de 1 a 100. `/api/ajustes` traz `revertivel`, calculado no SQL.

### Armadilhas já encontradas

- Parâmetros do LibPQ: um vetor `[Int, Int, Float64, ...]` é promovido a `Float64`, e o Postgres recusa `10.0` em coluna `BIGINT`. Use `Any[...]`.
- Corpo da requisição no HTTP.jl atual é um `BytesBody`: leia com `JSON3.read(String(copy(req.body)))` (função `corpo`).
- JSON3 não serializa structs próprias: `json()` em `Api.jl` tem um método que converte `RegraNegocio` e `LimitePreco` para NamedTuple. Para outra struct, faça o mesmo.
- O Plots precisa de `ENV["GKSwstype"] = "100"` antes de carregar (definido em `backend/server.jl`) para rodar sem display.
- `campo()` em `Repositorio.jl` é a validação de entrada dos JSON (tipo e presença; recusa `Bool` como número). Use-a em todo campo novo vindo do cliente. Para campo opcional, `campo(o, k, T, padrao)`.
- O `HTTP.Router` não decodifica variáveis de caminho (`%20` chega cru): leia-as com `param()`, que decodifica.
- `Dict(k => v for ...)` sobre resultado vazio vira `Dict{Any,Any}`, que `executar_ciclo` recusa. Tipe o `Dict`.
- A API usa uma conexão e um `ReentrantLock` global: as requisições são atendidas uma de cada vez. O agendador também pega o lock.
- Filtros de listagem montam o `WHERE` com `onde()`, que renumera os `\$` e só inclui os filtros não `nothing`.
- Cookies não distinguem porta: a sessão vale para `localhost:5173` e `localhost:8080` ao mesmo tempo.

## Frontend

`App.vue` mostra `Login.vue` sem sessão (confere com `GET /api/eu`) e, logado, alterna entre `PainelGerencial.vue`, `PainelAlertas.vue`, `PainelIndicadores.vue` e, só para admin, `PainelAdmin.vue`. Não há router. As chamadas passam por `src/api.js` (`api.get/put/post/del`, que lançam `Error` com o `erro` da API; um 401 dispara o evento `julyprice:sessao-expirada`, que volta ao login), pelo `qs()` (query string sem filtros vazios) e pelos formatadores `brl`, `pct` e `dataHora`. O selo de alertas não lidos é recontado a cada minuto, na troca de aba e quando um painel emite `mudou`. O gráfico de barras de `PainelIndicadores.vue` é SVG feito à mão (sem biblioteca). Taxas e margem aparecem em % na tela e trafegam como fração na API; converta com `paraPct` (sem ele, `0.07 * 100` vira `7.000000000000001` e o `step` do input trava o envio). A paginação usa `components/Paginacao.vue`.
