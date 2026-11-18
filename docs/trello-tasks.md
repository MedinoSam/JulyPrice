# Tasks para o board do Trello — JulyPrice

Análise feita em 2026-11-11 sobre o commit `6ba0bc4`. Nada foi corrigido.

**Etiquetas sugeridas:** `bug`, `feature`, `tech-debt`, `backend`, `motor`, `frontend`, `api-erp`.
**Prioridade:** P1 (alta), P2 (média), P3 (baixa).
**Verificado** = reproduzido nesta análise. **Por leitura** = deduzido do código, sem reproduzir.

Dica: colar a lista de títulos abaixo no "Adicionar cartão" do Trello cria um cartão por linha.

```
[BUG][P1] Reverter ajuste antigo com sugestão pendente deixa preco_anterior defasado
[BUG][P1] Horários aparecem 3h adiantados no painel (UTC lido como hora local)
[BUG][P1] SKU com espaço, barra ou acento quebra limites e gráfico
[BUG][P2] Sugestão sem mudança de preço volta a cada ciclo e, aprovada, notifica o ERP à toa
[BUG][P2] Elasticidade corta linhas, não dias: ERP que omite dias sem venda distorce a estimativa
[BUG][P2] Campos em % com float (ex.: 7%) travam o envio do formulário
[BUG][P2] categoria nula ou não-texto no payload do ERP devolve 500
[BUG][P2] Cursor "desde" do ERP perde precisão e não tem fuso definido
[BUG][P2] API não reconecta ao Postgres depois de queda do banco
[BUG][P2] Produto sem limite pode subir de preço sem teto a cada ruptura
[BUG][P3] Reverter ajuste de clamp é inútil: o próximo ciclo reaplica
[BUG][P3] Duplo clique em Aprovar ou Executar ciclo dispara requisições repetidas
[BUG][P3] Gráfico quebrado para produto sem vendas e desatualizado após ciclo
[BUG][P3] campo() aceita true/false como número
[BUG][P3] Erros brutos do Postgres chegam ao usuário (ex.: limites de SKU inexistente)
[FEATURE][P1] Autenticação com perfis Administrador e Gerente, e token para o ERP
[FEATURE][P1] Cooldown para sugestões descartadas
[FEATURE][P1] Aprovar e descartar sugestões em lote, com filtros
[FEATURE][P1] Teto padrão e limite de variação acumulada de preço
[FEATURE][P2] Estado "Descartado", comentário do gerente e auditoria de quem revisou
[FEATURE][P2] Simulação "what-if" de regras antes de salvar
[FEATURE][P2] Regras de negócio por categoria
[FEATURE][P2] Central de alertas com não lidos
[FEATURE][P2] Agendamento do motor e histórico de execuções
[FEATURE][P2] Dashboard de KPIs da precificação
[FEATURE][P3] Gráfico do produto com marcação dos ajustes e curva de demanda
[FEATURE][P3] Ignorar dias de estoque zerado na estimativa de elasticidade
[FEATURE][P3] Exportar histórico de ajustes em CSV
[FEATURE][P3] Paginação e busca de produtos no servidor
[TECH][P1] Testes de integração do Repositorio e da API com Postgres
[TECH][P2] CI no GitHub Actions (Pkg.test e build do frontend)
[TECH][P2] Migrações versionadas do schema
[TECH][P2] Tirar o motor do lock global e carregar vendas de forma incremental
[TECH][P3] Docker Compose completo (API e frontend) e HOST configurável
```

---

## Bugs

### [BUG][P1] Reverter ajuste antigo com sugestão pendente deixa preco_anterior defasado
**Etiquetas:** bug, backend · **Por leitura**

`revisar_ajustes` (`backend/src/Repositorio.jl:100-104`) só bloqueia a reversão se houver ajuste **Finalizado** mais novo. Não olha os pendentes.

Cenário: ajuste A finalizado (100 → 105). Próximo ciclo cria B pendente (105 → 110). O gerente reverte A, e o preço volta a 100. Depois aprova B: o preço vai a 110, mas B guarda `preco_anterior = 105`. Reverter B leva a 105, um preço que nunca foi o anterior.

A aprovação também não confere se `produtos.preco` ainda é igual a `preco_anterior` do ajuste.

**Critério de aceite**
- Reverter um finalizado com pendente do mesmo produto devolve 409. Outra opção: descartar o pendente junto.
- Aprovar um ajuste cujo `preco_anterior` difere do preço atual devolve 409.
- Teste cobrindo o cenário acima.

### [BUG][P1] Horários aparecem 3h adiantados no painel (UTC lido como hora local)
**Etiquetas:** bug, frontend, backend · **Verificado**

O Postgres do container roda em `TimeZone = UTC`. As colunas são `TIMESTAMP` sem fuso, e a API devolve `"2026-11-11T13:34:40.770"` sem `Z`. `dataHora` (`frontend/src/api.js:20`) usa `new Date(s)`, que lê a string como hora local (-03). Às 10:34 locais, o painel mostra 13:34.

**Critério de aceite**
- `criado_em` e `revisado_em` aparecem na hora local correta.
- Fuso definido de ponta a ponta: `TIMESTAMPTZ` no schema, ou API sempre em UTC com `Z`.

### [BUG][P1] SKU com espaço, barra ou acento quebra limites e gráfico
**Etiquetas:** bug, backend, api-erp · **Verificado**

O frontend usa `encodeURIComponent(id)`. O `HTTP.getparams` não decodifica: `/x/SKU%20A%2FB` chega como `"SKU%20A%2FB"`. Resultado: `PUT /api/produtos/{id}/limites` falha na FK com 400, e `grafico.svg` devolve 404. O SKU vem do ERP, então não há como garantir que seja só ASCII.

**Critério de aceite**
- `param()` em `Api.jl` decodifica (`HTTP.unescapeuri`).
- Limites e gráfico funcionam para um SKU como `"CAM 01/AZ"`.

### [BUG][P2] Sugestão sem mudança de preço volta a cada ciclo e, aprovada, notifica o ERP à toa
**Etiquetas:** bug, motor, backend · **Por leitura**

Um produto em risco pode ter ótimo igual ao preço atual (mensagem "Mudar o preço não melhora..."). Mesmo assim gera um ajuste `NotificadoGerente`. Se o gerente descarta, a próxima carga do ERP cria a mesma sugestão de novo. Se aprova, `enviar_precos_ajustados` mexe em `preco_alterado_em`, e o ERP recebe um "novo" preço idêntico.

**Critério de aceite**
- Uma escolha definida e documentada no CLAUDE.md: gravar só o alerta, sem ajuste pendente, ou manter o pendente sem tocar `preco_alterado_em` na aprovação.
- Depende do cartão "Cooldown para sugestões descartadas".

### [BUG][P2] Elasticidade corta linhas, não dias: ERP que omite dias sem venda distorce a estimativa
**Etiquetas:** bug, motor · **Por leitura**

`avaliar_elasticidade` (`MotorPrecificacao.jl:34-37`) descarta as últimas `dias_parado` **linhas**, supondo uma linha por dia. `estimar_elasticidade` também supõe que os dias com zero venda estão presentes ("contando dias sem venda"). Se o ERP mandar só os dias com venda:
- o corte remove vendas reais;
- a média por nível de preço fica inflada, porque os zeros somem.

O dataset sintético sempre manda todos os dias, por isso os testes passam.

**Critério de aceite**
- Corte feito por data (`data <= última_data - dias_parado`).
- Dias ausentes tratados como zero, ou exigência documentada no contrato do ERP.
- Teste com histórico esparso.

### [BUG][P2] Campos em % com float (ex.: 7%) travam o envio do formulário
**Etiquetas:** bug, frontend · **Float verificado; bloqueio do navegador por leitura**

No JavaScript, `0.07 * 100 = 7.000000000000001`. O input tem `step="0.1"` (taxas, `PainelAdmin.vue:13`) ou `step="0.5"` (margem, `PainelGerencial.vue:56`). O navegador marca o valor como inválido e o `@submit` não roda. Basta uma taxa de 7%, 14% ou 29% salva uma vez para o formulário travar até o usuário apagar o campo.

**Critério de aceite**
- Valores convertidos com arredondamento (ex.: `+(v * 100).toFixed(2)`).
- Salvar 7% e reabrir a tela permite salvar de novo.

### [BUG][P2] categoria nula ou não-texto no payload do ERP devolve 500
**Etiquetas:** bug, api-erp · **Verificado**

`String(get(p, :categoria, ""))` (`Repositorio.jl:132`) com `null` ou número dá `MethodError`. A rota transforma isso em 500 "erro interno", e a carga inteira é perdida. É o único campo que não passa por `campo()`.

**Critério de aceite**
- `categoria` validada (opcional; se vier, tem que ser string). Inválida devolve 400 com o nome do campo.

### [BUG][P2] Cursor "desde" do ERP perde precisão e não tem fuso definido
**Etiquetas:** bug, api-erp · **Verificado**

O Postgres grava microssegundos e o `DateTime` do Julia trunca para milissegundos (`10:00:00.123456` vira `10:00:00.123`). Um ERP que usa o último `preco_alterado_em` recebido como `desde` recebe o mesmo item de novo, porque o valor real é maior que o truncado. O contrato também não diz em que fuso está o `desde`.

**Critério de aceite**
- Cursor sem perda: `date_trunc('milliseconds', ...)` ao gravar, ou cursor por sequência/id.
- Fuso documentado no README.
- Duas leituras seguidas com o cursor devolvido não repetem itens.

### [BUG][P2] API não reconecta ao Postgres depois de queda do banco
**Etiquetas:** bug, backend · **Por leitura, a confirmar**

`DB[]` é uma conexão única criada em `iniciar()` (`Api.jl:95`). Se o Postgres reiniciar (ex.: `docker compose restart`), todas as requisições falham até a API ser reiniciada.

**Critério de aceite**
- A API detecta conexão morta e reconecta. Teste manual: reiniciar o container e a próxima requisição funcionar.
- `GET /api/saude` responde o estado do banco.

### [BUG][P2] Produto sem limite pode subir de preço sem teto a cada ruptura
**Etiquetas:** bug, motor · **Por leitura**

Sem linha em `limites_preco`, vale `SEM_LIMITE` com `preco_maximo = Inf`. Enquanto o estoque não é reposto, cada carga do ERP sugere mais `taxa_ajuste_alto`. Com o gerente aprovando no automático, o preço composto não tem limite. No encalhe, o piso é o custo, então esse lado está protegido.

**Critério de aceite**
- Resolvido pelo cartão "Teto padrão e limite de variação acumulada de preço".

### [BUG][P3] Reverter ajuste de clamp é inútil: o próximo ciclo reaplica
**Etiquetas:** bug, motor · **Por leitura**

Produto normal com preço fora dos limites é corrigido pelo clamp e vira `Finalizado` direto, sem alerta (há 6 casos no banco atual). Se o gerente reverte, o próximo ciclo aplica o clamp de novo. O botão "Reverter" aparece, mas não tem efeito duradouro.

**Critério de aceite**
- Ajuste de clamp gera um alerta informativo ("preço ajustado ao limite").
- Ajuste de clamp não é revertível, ou a reversão pede para editar os limites.

### [BUG][P3] Duplo clique em Aprovar ou Executar ciclo dispara requisições repetidas
**Etiquetas:** bug, frontend · **Por leitura**

Os botões não ficam desabilitados durante a requisição. Aprovar duas vezes mostra um erro 409 confuso. "Executar ciclo" leva segundos (compilação do Julia e um solver por produto) e não mostra que está rodando.

**Critério de aceite**
- Botão desabilitado e com indicador enquanto a requisição está em andamento.

### [BUG][P3] Gráfico quebrado para produto sem vendas e desatualizado após ciclo
**Etiquetas:** bug, frontend · **Por leitura**

Sem vendas, `grafico.svg` devolve 404 e a tela mostra uma imagem quebrada. A URL é sempre a mesma, então o navegador pode manter em cache a versão antiga depois de uma nova carga.

**Critério de aceite**
- Mensagem "sem histórico de vendas" no lugar da imagem.
- URL com parâmetro de versão, ou `Cache-Control: no-cache`.

### [BUG][P3] campo() aceita true/false como número
**Etiquetas:** bug, backend · **Verificado**

`Bool <: Real` no Julia. Então `{"preco": true}` passa como `1.0`, e `{"estoque": false}` como `0`.

**Critério de aceite**
- `campo` recusa `Bool` quando o tipo esperado é numérico, com teste.

### [BUG][P3] Erros brutos do Postgres chegam ao usuário (ex.: limites de SKU inexistente)
**Etiquetas:** bug, backend · **Por leitura**

`PQResultError` vira 400 com a mensagem do Postgres (`Api.jl:28`). Limites para SKU inexistente devolvem um erro de FK em inglês, quando o certo seria 404. Regras fora da faixa devolvem o nome do `CHECK`.

**Critério de aceite**
- `definir_limites` devolve 404 para produto inexistente.
- `atualizar_regras` valida as faixas no Julia, com mensagem em português.

---

## Features

### [FEATURE][P1] Autenticação com perfis Administrador e Gerente, e token para o ERP
**Etiquetas:** feature, backend, frontend

Hoje qualquer um que acesse a API pode mudar regras, aprovar preços e enviar dados como se fosse o ERP.
- Login com dois perfis: Administrador (regras, motor) e Gerente (limites, aprovação).
- Rotas `/api/erp/*` protegidas por token próprio (header).
- Abas do frontend conforme o perfil.

### [FEATURE][P1] Cooldown para sugestões descartadas
**Etiquetas:** feature, motor, backend

Sugestão descartada não volta para o mesmo produto e o mesmo risco por N dias (configurável nas regras), a não ser que o preço sugerido mude mais que X%. Isso acaba com o loop de alertas repetidos a cada carga do ERP.

### [FEATURE][P1] Aprovar e descartar sugestões em lote, com filtros
**Etiquetas:** feature, frontend, backend

Com 200 produtos, o primeiro ciclo gerou 79 pendências, e hoje cada uma exige um clique.
- Checkbox por linha e "Aprovar selecionadas" / "Descartar selecionadas".
- Filtro por risco e categoria na lista de sugestões.
- Endpoint de lote que processa tudo numa transação e devolve o resultado por item.

### [FEATURE][P1] Teto padrão e limite de variação acumulada de preço
**Etiquetas:** feature, motor

- Teto global nas regras (ex.: no máximo +30% sobre o preço de referência) para produto sem `limites_preco`.
- Limite de variação acumulada numa janela (ex.: no máximo +15% em 30 dias), aplicado no clamp.
- Resolve o bug "Produto sem limite pode subir de preço sem teto".

### [FEATURE][P2] Estado "Descartado", comentário do gerente e auditoria de quem revisou
**Etiquetas:** feature, backend, frontend · **Depende de:** migrações versionadas, autenticação

Hoje descartar um pendente e reverter um finalizado gravam o mesmo estado, `Revertido`.
- Novo estado `Descartado`.
- Campos `revisado_por` e `comentario` em `ajustes_preco`.
- Histórico mostra quem fez o quê.

### [FEATURE][P2] Simulação "what-if" de regras antes de salvar
**Etiquetas:** feature, motor, frontend

No Painel Administrativo, botão "Simular" que roda `executar_ciclo` com as regras do formulário, sem gravar nada. Mostra quantos produtos cairiam em ruptura e encalhe e a variação média de preço. O motor já é puro (sem banco), então dá para reaproveitar quase tudo.

### [FEATURE][P2] Regras de negócio por categoria
**Etiquetas:** feature, motor, backend · **Depende de:** migrações versionadas

`regras_negocio` tem uma linha só. Eletrônicos e Livros têm giro e estoque mínimo muito diferentes. A ideia: regra opcional por categoria, com a global como padrão.

### [FEATURE][P2] Central de alertas com não lidos
**Etiquetas:** feature, frontend, backend

A coluna `alertas.lido` existe, mas nenhuma tela usa.
- Contador de não lidos no topo.
- Lista de alertas com filtro por tipo.
- Marcar como lido.
- Opcional: e-mail ou webhook para alertas de ruptura.

### [FEATURE][P2] Agendamento do motor e histórico de execuções
**Etiquetas:** feature, backend · **Depende de:** migrações versionadas

O motor hoje só roda em carga do ERP ou no clique do botão.
- Execução agendada (ex.: diária) configurável.
- Tabela `execucoes_motor` com início, duração, origem (ERP, manual, agenda) e contagens.
- Última execução mostrada no Painel Administrativo.

### [FEATURE][P2] Dashboard de KPIs da precificação
**Etiquetas:** feature, frontend, backend

Indicadores:
- ajustes por risco ao longo do tempo;
- taxa de aprovação;
- tempo médio até a revisão;
- receita e margem estimadas antes e depois dos ajustes aprovados;
- produtos atualmente em risco.

### [FEATURE][P3] Gráfico do produto com marcação dos ajustes e curva de demanda
**Etiquetas:** feature, frontend, motor

No gráfico do produto:
- linhas verticais nas datas de ajustes aprovados ou revertidos;
- painel com a curva de demanda estimada `q(p) ∝ p^e` e o preço atual e o sugerido marcados.

### [FEATURE][P3] Ignorar dias de estoque zerado na estimativa de elasticidade
**Etiquetas:** feature, motor

Dia com estoque zero tem venda zero por falta de produto, não por causa do preço (demanda censurada). Isso puxa a elasticidade para baixo. Precisa do estoque diário no payload de vendas do ERP.

### [FEATURE][P3] Exportar histórico de ajustes em CSV
**Etiquetas:** feature, backend, frontend

`GET /api/ajustes.csv` com filtros de período e estado, e um botão no histórico.

### [FEATURE][P3] Paginação e busca de produtos no servidor
**Etiquetas:** feature, backend, frontend

`GET /api/produtos` devolve o catálogo inteiro e o filtro roda no navegador. Usar o mesmo formato `{itens, total, pagina, por_pagina}` das outras listagens, com `?q=`.

---

## Dívida técnica

### [TECH][P1] Testes de integração do Repositorio e da API com Postgres
**Etiquetas:** tech-debt, backend

Hoje os testes cobrem só o motor, e a API foi validada à mão. Faltam testes, com um banco de teste, para:
- aprovar, descartar e reverter (incluindo o bug do pendente);
- carga do ERP com payload inválido;
- paginação;
- `precos-ajustados?desde=`.

### [TECH][P2] CI no GitHub Actions (Pkg.test e build do frontend)
**Etiquetas:** tech-debt

Pipeline por PR:
- `Pkg.test()` no Julia 1.10 e 1.13 (pega manifest desatualizado);
- `npm run build`;
- testes de integração com o serviço Postgres.

### [TECH][P2] Migrações versionadas do schema
**Etiquetas:** tech-debt, backend

Hoje, mudar `db/schema.sql` exige `docker compose down -v`, o que apaga os dados. Adotar migrações numeradas (`db/migrations/001_*.sql`) com uma tabela de controle. Vários cartões acima dependem disso.

### [TECH][P2] Tirar o motor do lock global e carregar vendas de forma incremental
**Etiquetas:** tech-debt, backend, motor

`executar_motor` lê a tabela `vendas` inteira a cada carga do ERP e segura o `DB_LOCK` durante todos os solves. Nesse tempo, o painel fica travado. Propostas:
- janela de histórico (ex.: últimos 180 dias);
- rodar o cálculo fora do lock e só gravar dentro dele;
- pool de conexões.

### [TECH][P3] Docker Compose completo (API e frontend) e HOST configurável
**Etiquetas:** tech-debt

`iniciar()` fixa `host="127.0.0.1"`, o que impede rodar a API em container. Adicionar `HOST` por variável de ambiente e serviços `api` e `frontend` no compose para subir tudo com um comando.
