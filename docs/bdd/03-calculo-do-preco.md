# Cálculo do preço

Implementação: `calcular_preco` e `otimizar_preco` em `backend/src/MotorPrecificacao.jl` (JuMP + Ipopt).

A regra define a faixa; dentro dela o motor maximiza `(x − c) · (x/p)^e`, com `c = custo` na ruptura (lucro) e `c = 0` no encalhe (receita).

```gherkin
# language: pt
Funcionalidade: Cálculo do preço ótimo dentro da faixa da regra
  Como sistema inteligente
  Quero escolher o melhor preço dentro da faixa permitida pela regra
  Para ganhar margem na ruptura e girar o estoque no encalhe

  Contexto:
    Dado a regra com reajuste de até 5% na ruptura e redução de até 10% no encalhe
    E um produto com preço de R$ 100,00 e custo de R$ 60,00
    E sem limites que restrinjam a faixa

  Esquema do Cenário: Mesmo risco, decisões diferentes conforme a elasticidade
    Dado que o produto está em <risco>
    E a elasticidade estimada é <elasticidade>
    Quando o motor calcula o novo preço
    Então o preço sugerido é R$ <novo_preco>

    Exemplos:
      | risco   | elasticidade | novo_preco |
      | ruptura | -1,5         | 105,00     |
      | ruptura | -3,0         | 100,00     |
      | encalhe | -2,0         | 90,00      |
      | encalhe | -0,8         | 100,00     |

  Cenário: Ruptura maximiza o lucro
    Dado que o produto está em ruptura
    Quando o motor calcula o novo preço
    Então ele procura x entre R$ 100,00 e R$ 105,00 que maximiza (x − 60) · (x/100)^e

  Cenário: Encalhe maximiza a receita
    Dado que o produto está em encalhe
    Quando o motor calcula o novo preço
    Então ele procura x entre R$ 90,00 e R$ 100,00 que maximiza x · (x/100)^e, sem o custo, que já foi pago

  Cenário: Receita plana no encalhe
    Dado que o produto está em encalhe
    E a elasticidade estimada é -1
    Quando o motor calcula o novo preço
    Então o preço sugerido é R$ 90,00, o passo máximo da regra

  Cenário: Produto normal mantém o preço
    Dado que o produto não está em risco
    Quando o motor calcula o novo preço
    Então o preço calculado é R$ 100,00

  Cenário: Alerta explica quando o preço não muda
    Dado que o produto está em ruptura
    E a elasticidade estimada é -3,0
    Quando o motor gera o alerta
    Então a mensagem termina com "Mudar o preço não melhora o resultado esperado."
```
