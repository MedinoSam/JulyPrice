# JulyPrice

Plataforma de precificação dinâmica e gestão reativa de catálogo.
Core em Julia 1.10 (DataFrames.jl, JuMP.jl + HiGHS + Ipopt, Plots.jl, HTTP.jl), banco PostgreSQL e frontend Vue 3.

## Estrutura

```
db/schema.sql                      esquema PostgreSQL (carregado pelo docker-compose)
docker-compose.yml                 PostgreSQL 16 na porta 5433
backend/                           pacote Julia CoreSistemaInteligente
  src/Modelos.jl                   Produto, RegraNegocio, LimitePreco, Alerta, Estado, ResultadoAnalise
  src/MotorPrecificacao.jl         avaliar_risco, detectar_inatividade, avaliar_elasticidade (JuMP),
                                   otimizar_preco (JuMP + Ipopt),
                                   calcular_preco, aplicar_clamp, disparar_alerta, calcularNovoPreco, executar_ciclo
  src/Repositorio.jl               Interface ERP, gestão de regras/limites/ajustes (LibPQ)
  src/Api.jl                       endpoints HTTP/REST + gráfico (Plots.jl)
  server.jl                        sobe a API
  scripts/gerar_dataset.jl         dataset sintético (CSV e/ou carga no banco)
  scripts/simulacao.jl             simulação do motor com DataFrames sobre os CSVs
  test/runtests.jl                 testes do motor
frontend/                          Vue 3 + Vite (Painel Gerencial e Painel Administrativo)
```

## Como rodar

Execute os comandos a partir da raiz do repositório, nesta ordem.

1. Banco:

```bash
docker compose up -d
```

2. Dependências Julia (uma vez). Sem Julia instalado, use o juliaup (`curl -fsSL https://install.julialang.org | sh`, depois `juliaup add 1.10`).

```bash
julia --project=backend -e 'using Pkg; Pkg.instantiate()'
```

3. Dataset sintético. **Atenção:** `--db` apaga e recarrega produtos, limites, vendas, ajustes e alertas.

```bash
julia --project=backend backend/scripts/gerar_dataset.jl --n 200 --dias 90 --seed 42 --saida data --db
```

4. API (porta 8080):

```bash
julia --project=backend backend/server.jl
```

5. Frontend (http://localhost:5173, faz proxy de `/api` para a 8080):

```bash
cd frontend && npm install && npm run dev
```

No Painel Administrativo, clique em **Executar ciclo** para a primeira rodada do motor.

Outros comandos:

```bash
julia --project=backend backend/scripts/simulacao.jl data
```

```bash
julia --project=backend -e 'using Pkg; Pkg.test()'
```

Variáveis: `JULYPRICE_DATABASE_URL` (padrão `postgresql://julyprice:julyprice@localhost:5433/julyprice`), `PORT` (padrão 8080).

## Problemas comuns

### `MethodError: no method matching StyledStrings...AnnotatedChar` no Julia 1.11+

O `Manifest.toml` foi resolvido no Julia 1.10, em que `StyledStrings` é um pacote comum. A partir do 1.11 ele
faz parte do próprio Julia, e a versão antiga do pacote quebra o `REPL` ao carregar. O projeto traz um
`backend/Manifest-v1.13.toml`, que o Julia 1.13 usa no lugar do `Manifest.toml`. Em outra versão (1.11, 1.12),
crie o manifest dela uma vez, trocando `1.12` pela sua versão:

```bash
cd backend && rm -f Manifest-v1.12.toml && mv Manifest.toml Manifest.toml.bak && julia --project=. -e 'using Pkg; Pkg.instantiate()' && mv Manifest.toml Manifest-v1.12.toml && mv Manifest.toml.bak Manifest.toml
```

Ou rode com o Julia 1.10: `julia +1.10 --project=backend backend/server.jl`.

### `missing "=" after "jdbc:mysql://..." in connection info string`

```
[error | LibPQ]: missing "=" after "jdbc:mysql://localhost:3306/db" in connection info string
```

O LibPQ recebeu uma URL que não é do PostgreSQL. Versões antigas deste projeto liam a variável genérica
`DATABASE_URL`, que costuma estar definida no shell por outros projetos (aqui, uma URL JDBC de MySQL).
O projeto agora lê só `JULYPRICE_DATABASE_URL`. Se o erro aparecer:

1. Confira o código: `backend/src/Repositorio.jl` e `backend/scripts/gerar_dataset.jl` devem usar
   `JULYPRICE_DATABASE_URL`. Se ainda usarem `DATABASE_URL`, atualize o repositório.
2. Veja se `JULYPRICE_DATABASE_URL` tem uma URL que não é PostgreSQL:

```bash
echo "$JULYPRICE_DATABASE_URL"
```

3. Remova a variável só desta sessão do terminal (o projeto volta ao padrão `localhost:5433`):

```bash
unset JULYPRICE_DATABASE_URL
```

   Ou aponte para o Postgres certo. A URL precisa começar com `postgresql://`, sem o prefixo `jdbc:`:

```bash
export JULYPRICE_DATABASE_URL=postgresql://julyprice:julyprice@localhost:5433/julyprice
```

4. Se a variável foi definida em `~/.bashrc` ou `~/.profile`, corrija-a lá para o erro não voltar.
5. Garanta que o banco do projeto está no ar com `docker compose up -d`.

## Máquina de estados (`calcularNovoPreco`)

```
EmAnalise ─┬─ estoque < limite_estoque_minimo          → AvaliadoRuptura (sobe até taxa_ajuste_alto, 5%)
           ├─ dias_parado > limite_dias_inatividade    → AvaliadoEncalhe (desce até taxa_ajuste_baixo, 10%)
           └─ normal                                   → AvaliadoNormal (mantém)
        → ValidadoClamp: preço ∈ [max(preco_minimo, custo·(1+margem)), preco_maximo]
        → risco ≠ normal: NotificadoGerente (alerta; aguarda aprovar/descartar)
          risco = normal: Finalizado (preço vai ao ERP)
```

Ruptura tem prioridade sobre encalhe. Se o piso de margem passar do teto, vale o teto.
Elasticidade: regressão log-log `log q = a + b·log p` resolvida com JuMP/HiGHS, restrita a `b ≤ 0`.
Produto com revisão pendente não é reavaliado.

Preço (`otimizar_preco`, JuMP + Ipopt): a regra define a direção e o passo máximo; a otimização escolhe
o ponto da faixa com a demanda prevista pela elasticidade `e`, `q(x) = q0·(x/p0)^e`.

- Ruptura: `x ∈ [p, p·(1+taxa_ajuste_alto)]`, maximiza o lucro `(x − custo)·q(x)`. Demanda elástica com
  markup alto pode manter o preço (pela regra de Lerner o ótimo é `custo·e/(1+e)`).
- Encalhe: `x ∈ [p·(1−taxa_ajuste_baixo), p]`, maximiza a receita `x·q(x)`, porque o custo do estoque parado
  já foi pago. Só baixa se a demanda for elástica (`e < −1`); inelástica mantém o preço e o alerta avisa.

## Endpoints

| Método | Rota | Uso |
|---|---|---|
| POST | `/api/erp/vendas-estoque` | ERP envia produtos e vendas (`receber_vendas_e_estoque`); dispara o ciclo |
| GET | `/api/erp/precos-ajustados?desde=2026-11-09T00:00:00` | ERP lê preços alterados (`enviar_precos_ajustados`) |
| GET | `/api/produtos` | catálogo com limites e flag de pendência |
| PUT | `/api/produtos/{id}/limites` | gerente define `preco_minimo`, `preco_maximo`, `margem_desejada` |
| GET | `/api/produtos/{id}/grafico.svg` | histórico vendas × preço (Plots.jl) |
| GET | `/api/sugestoes-alertas?pagina=1&por_pagina=20` | ajustes pendentes com o alerta de cada um (paginado) |
| GET | `/api/ajustes?pagina=1&por_pagina=20` | histórico de ajustes (paginado; `revertivel` indica o que pode ser revertido) |
| POST | `/api/ajustes/{id}/aprovar` | aprova sugestão pendente |
| POST | `/api/ajustes/{id}/reverter` | descarta pendente ou reverte o último finalizado do produto |
| GET/PUT | `/api/regras` | administrador lê/atualiza regras globais |
| POST | `/api/motor/executar` | roda o ciclo agora |

Listagens paginadas respondem `{"itens": [...], "total": N, "pagina": P, "por_pagina": K}`; `por_pagina` vai de 1 a 100 (padrão 20).

Exemplo de carga do ERP:

```json
{
  "produtos": [{"id": "SKU9001", "nome": "Fone", "categoria": "Eletrônicos",
                "custo": 40.0, "preco": 79.9, "estoque": 4, "dias_parado": 0}],
  "vendas": [{"produto_id": "SKU9001", "data": "2026-11-08", "quantidade": 3, "preco": 79.9}]
}
```

## Decisões

- `custo` foi adicionado ao Produto: a margem desejada e o lucro da otimização precisam de uma base.
- Administrador e Gerente Comercial são os dois painéis do frontend; não há login.
- O preço vindo do ERP só vale para produto novo; depois a plataforma é dona do preço.
