# Estimativa de elasticidade

Implementação: `avaliar_elasticidade` e `estimar_elasticidade` em `backend/src/MotorPrecificacao.jl` (JuMP + HiGHS).

```gherkin
# language: pt
Funcionalidade: Estimativa da elasticidade-preço da demanda
  Como sistema inteligente
  Quero medir como a demanda de cada produto reage ao preço
  Para escolher o preço com base no comportamento real do cliente

  Cenário: Histórico com variação de preço
    Dado um produto vendido em pelo menos 3 níveis de preço diferentes
    E a venda cai quando o preço sobe
    Quando o motor estima a elasticidade
    Então a elasticidade é negativa
    E ela vem da regressão log q = a + b · log p, ponderada pelo número de dias em cada preço

  Cenário: A demanda nunca cresce com o preço
    Dado um histórico em que, por ruído, a venda sobe junto com o preço
    Quando o motor estima a elasticidade
    Então a elasticidade é 0, porque a regressão é restrita a b ≤ 0

  Cenário: Pouca variação de preço
    Dado um produto com elasticidade atual de -1
    E um histórico com vendas em só 2 níveis de preço
    Quando o motor estima a elasticidade
    Então a elasticidade continua -1

  Cenário: Produto que nunca vendeu
    Dado um produto com elasticidade atual de -1,4
    E um histórico sem nenhuma venda
    Quando o motor estima a elasticidade
    Então a elasticidade continua -1,4

  Cenário: ERP omite os dias sem venda
    Dado um histórico que só traz os dias em que houve venda
    Quando o motor monta a série diária
    Então cada dia ausente entra com venda zero ao último preço conhecido

  Cenário: Dias de encalhe não contam como efeito de preço
    Dado um produto parado há 20 dias
    Quando o motor monta a série diária
    Então os últimos 20 dias ficam fora da regressão
    Mas o corte nunca exclui o dia da última venda

  Cenário: Estoque zerado é demanda censurada
    Dado um histórico com a coluna de estoque
    E um dia com estoque zero e venda zero
    Quando o motor estima a elasticidade
    Então esse dia fica fora da regressão

  Cenário: Coluna de estoque ausente
    Dado um histórico sem a coluna de estoque
    Quando o motor estima a elasticidade
    Então nenhum dia é excluído por falta de estoque
```
