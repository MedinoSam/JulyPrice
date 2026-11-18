# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

JulyPrice: plataforma de precificação dinâmica. O core é em Julia (pacote `CoreSistemaInteligente` em `backend/`), o banco é PostgreSQL e o frontend é Vue 3 + Vite (`frontend/`). Código, comentários, mensagens de erro e documentação ficam em português.

## Comandos

Rode tudo a partir da raiz do repositório. O projeto Julia é `backend/`, então todo comando Julia leva `--project=backend`.

```bash
docker compose up -d                                   # PostgreSQL 16 na porta 5433 (aplica db/schema.sql na 1ª subida)
julia --project=backend -e 'using Pkg; Pkg.instantiate()'
julia --project=backend backend/server.jl              # API na 8080 (PORT muda a porta)
julia --project=backend -e 'using Pkg; Pkg.test()'     # backend/test/runtests.jl
julia --project=backend backend/scripts/gerar_dataset.jl --n 200 --dias 90 --seed 42 --saida data [--db]
julia --project=backend backend/scripts/simulacao.jl data   # roda o motor sobre os CSVs, sem banco
cd frontend && npm install && npm run dev              # http://localhost:5173
cd frontend && npm run build
```

- Não há filtro por teste: `Pkg.test()` roda todos os `@testset`. Os testes cobrem só a lógica pura do motor, sem banco. A API foi validada à mão com curl.
- `gerar_dataset.jl --db` faz `TRUNCATE ... RESTART IDENTITY` em produtos, limites, vendas, ajustes e alertas. Sem `--db`, só grava CSVs.
- O schema só é aplicado quando o volume `pgdata` é criado. Mudou `db/schema.sql`? Recrie o volume (`docker compose down -v`) ou aplique a mudança à mão.
- A primeira requisição depois de subir a API leva de 5 a 10 segundos (compilação do Julia).

## Ambiente

- O banco vem de `JULYPRICE_DATABASE_URL` (padrão `postgresql://julyprice:julyprice@localhost:5433/julyprice`). Não use `DATABASE_URL`: no shell do usuário ela aponta para um MySQL de outro projeto.
- O frontend chama `/api` pelo proxy do Vite. O destino é `API_URL`, padrão `http://localhost:8080` (`frontend/vite.config.js`).
- Há dois manifests: `backend/Manifest.toml` (Julia 1.10, a versão da especificação) e `backend/Manifest-v1.13.toml` (Julia 1.13, o padrão do juliaup do usuário). Ao adicionar ou atualizar pacotes, faça nas duas versões (`julia +1.10 ...` e `julia ...`). Se um manifest ficar desatualizado, o 1.13 quebra no `StyledStrings`, que é pacote no 1.10 e stdlib a partir do 1.11.

## Arquitetura

Três camadas no backend, incluídas em ordem por `backend/src/CoreSistemaInteligente.jl`:

1. **`Modelos.jl` + `MotorPrecificacao.jl`: lógica pura, sem banco.** Recebem structs e DataFrames, devolvem resultados. É aqui que os testes e a simulação atuam.
2. **`Repositorio.jl`: banco e casos de uso.** Usa LibPQ e transações. Traz as funções do diagrama de classes: `receber_vendas_e_estoque`, `enviar_precos_ajustados`, `atualizar_regras`, `definir_limites`, `ver_sugestoes_e_alertas`, `revisar_ajustes`. Também traz `executar_motor`, que carrega tudo em DataFrames, chama `executar_ciclo` e grava ajustes e alertas.
3. **`Api.jl`: rotas HTTP.jl.** Cada rota passa por `rota()`, que segura o lock global, reconecta ao Postgres se a conexão caiu e converte erros: `ErroCliente` vira o status dele, conexão perdida vira 503, e `ArgumentError` ou erro do Postgres (`PQResultError`) viram 400. `GET /api/saude` testa o banco.

### Ciclo de preço (por produto, em `calcularNovoPreco`)

`EmAnalise → AvaliadoRuptura | AvaliadoEncalhe | AvaliadoNormal → ValidadoClamp → NotificadoGerente | Finalizado`

- Antes do ciclo, `avaliar_elasticidade` estima `e` com JuMP + HiGHS: regressão log-log ponderada por nível de preço, com `e ≤ 0`, ignorando os últimos `dias_parado` dias. O corte é por data e nunca passa da última venda, e dias ausentes no histórico entram como venda zero ao último preço (o ERP pode omitir dias sem venda).
- `avaliar_risco`: ruptura (`estoque < limite_estoque_minimo`) tem prioridade sobre encalhe (`dias_parado > limite_dias_inatividade`). Os dois limites são estritos.
- `calcular_preco`: a regra só define a **faixa**. Ruptura vai de `[p, p·(1+taxa_ajuste_alto)]` e encalhe de `[p·(1−taxa_ajuste_baixo), p]`. Dentro dela, `otimizar_preco` (JuMP + Ipopt) maximiza `(x − c)·(x/p)^e`, com `c = custo` na ruptura (lucro) e `c = 0` no encalhe (receita). Por isso um produto em risco pode manter o preço. O caso `c = 0, e = −1` é plano e devolve o passo da regra.
- `aplicar_clamp`: piso = `max(preco_minimo, custo·(1+margem_desejada))`, teto = `preco_maximo`. Se o piso passar do teto, vale o teto.
- Risco ≠ normal: o ajuste fica pendente (`NotificadoGerente`), um alerta é gravado e o preço **não** muda até o gerente aprovar. Normal com preço igual não gera registro. Normal com preço mudado pelo clamp vira `Finalizado` direto, com alerta `LIMITE`.

### Regras de persistência não óbvias

- No banco, `ajustes_preco.estado` só assume `NotificadoGerente`, `Finalizado` ou `Revertido`. Os outros estados existem só em memória.
- Produto com ajuste pendente fica fora de `executar_motor`.
- A plataforma é dona do preço: o upsert do ERP só grava `preco` em produto novo. `preco_alterado_em` só muda quando a plataforma altera o preço, e é isso que `GET /api/erp/precos-ajustados?desde=` lê.
- Reverter um ajuste finalizado só é permitido no mais recente do produto, sem sugestão pendente e com risco ≠ normal (senão 409; ajuste de clamp se desfaz mudando os limites). Ele restaura `preco_anterior`. Aprovar exige que o preço atual ainda seja o `preco_anterior` do ajuste (senão 409).
- `enviar_precos_ajustados` não faz nada se o preço não muda, então `preco_alterado_em` não avança e o ERP não recebe preço repetido.
- Timestamps são `TIMESTAMP` em UTC (o LibPQ abre a sessão em UTC). `linhas()` devolve `DateTime` com `Z`; o `desde` do ERP é UTC, aceita `Z`, e a comparação trunca o banco para milissegundos, a precisão do `DateTime`.
- Listagens paginadas (`/api/sugestoes-alertas`, `/api/ajustes`) respondem `{itens, total, pagina, por_pagina}`, com `por_pagina` de 1 a 100. `/api/ajustes` traz `revertivel`, calculado no SQL.

### Armadilhas já encontradas

- Parâmetros do LibPQ: um vetor `[Int, Int, Float64, ...]` é promovido a `Float64`, e o Postgres recusa `10.0` em coluna `BIGINT`. Use `Any[...]`.
- Corpo da requisição no HTTP.jl atual é um `BytesBody`: leia com `JSON3.read(String(copy(req.body)))` (função `corpo`).
- JSON3 não serializa structs próprias: `json()` em `Api.jl` tem um método que converte `RegraNegocio` e `LimitePreco` para NamedTuple. Para outra struct, faça o mesmo.
- O Plots precisa de `ENV["GKSwstype"] = "100"` antes de carregar (definido em `backend/server.jl`) para rodar sem display.
- `campo()` em `Repositorio.jl` é a validação de entrada dos JSON (tipo e presença; recusa `Bool` como número). Use-a em todo campo novo vindo do cliente. Para campo opcional, `campo(o, k, T, padrao)`.
- O `HTTP.Router` não decodifica variáveis de caminho (`%20` chega cru): leia-as com `param()`, que decodifica.
- `Dict(k => v for ...)` sobre resultado vazio vira `Dict{Any,Any}`, que `executar_ciclo` recusa. Tipe o `Dict`.
- A API usa uma conexão e um `ReentrantLock` global: as requisições são atendidas uma de cada vez.

## Frontend

`App.vue` alterna entre `PainelGerencial.vue` e `PainelAdmin.vue`. Não há router nem login. As chamadas passam por `src/api.js` (`api.get/put/post`, que lançam `Error` com o `erro` da API) e pelos formatadores `brl`, `pct` e `dataHora`. Taxas e margem aparecem em % na tela e trafegam como fração na API; converta com `paraPct` (sem ele, `0.07 * 100` vira `7.000000000000001` e o `step` do input trava o envio). A paginação usa `components/Paginacao.vue`.
