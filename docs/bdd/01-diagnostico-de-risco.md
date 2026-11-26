# Diagnóstico de risco

Implementação: `avaliar_risco` e `detectar_inatividade` em `backend/src/MotorPrecificacao.jl`.

```gherkin
# language: pt
Funcionalidade: Diagnóstico de risco do produto
  Como sistema inteligente
  Quero classificar cada produto em ruptura, encalhe ou normal
  Para saber em que direção o preço pode se mover

  Contexto:
    Dado a regra global com estoque mínimo de 10 unidades e limite de inatividade de 30 dias

  Esquema do Cenário: Classificação pelo estoque e pelos dias parado
    Dado um produto com <estoque> unidades em estoque e <dias> dias sem venda
    Quando o motor avalia o risco
    Então o risco é "<risco>"
    E o estado intermediário é "<estado>"

    Exemplos:
      | estoque | dias | risco   | estado          |
      | 4       | 0    | ruptura | AvaliadoRuptura |
      | 9       | 2    | ruptura | AvaliadoRuptura |
      | 10      | 0    | normal  | AvaliadoNormal  |
      | 150     | 31   | encalhe | AvaliadoEncalhe |
      | 150     | 30   | normal  | AvaliadoNormal  |
      | 50      | 5    | normal  | AvaliadoNormal  |

  Cenário: Ruptura tem prioridade sobre encalhe
    Dado um produto com 3 unidades em estoque e 45 dias sem venda
    Quando o motor avalia o risco
    Então o risco é "ruptura"

  Cenário: Categoria com regra própria
    Dado a categoria "Eletrônicos" com estoque mínimo de 5 unidades
    E um produto da categoria "Eletrônicos" com 7 unidades em estoque
    Quando o motor avalia o risco
    Então o risco é "normal"

  Cenário: Categoria sem regra própria usa a regra global
    Dado a categoria "Moda" sem regra própria
    E um produto da categoria "Moda" com 7 unidades em estoque
    Quando o motor avalia o risco
    Então o risco é "ruptura"
```
