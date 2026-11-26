# Revisão do gerente

Implementação: `executar_motor`, `revisar_ajuste!`, `revisar_ajustes` e `revisar_lote` em `backend/src/Repositorio.jl`.

```gherkin
# language: pt
Funcionalidade: Revisão das sugestões de preço pelo gerente
  Como gerente comercial
  Quero aprovar, descartar ou reverter as sugestões do motor
  Para que nenhum preço em risco mude sem a minha decisão

  Contexto:
    Dado que estou logado como gerente "maria"

  Cenário: Sugestão de risco fica pendente
    Dado um produto em ruptura com preço de R$ 79,90
    Quando o motor executa o ciclo e sugere R$ 83,90
    Então o ajuste fica no estado "NotificadoGerente"
    E é gravado um alerta do tipo "RUPTURA"
    E o preço do produto continua R$ 79,90

  Cenário: Aprovar aplica o preço
    Dado uma sugestão pendente de R$ 79,90 para R$ 83,90
    Quando aprovo a sugestão com o comentário "estoque só chega semana que vem"
    Então o preço do produto passa a ser R$ 83,90
    E o ajuste fica no estado "Finalizado"
    E o ajuste registra "maria" como revisor e o comentário
    E o alerta da sugestão fica lido

  Cenário: Aprovar depois que o preço mudou
    Dado uma sugestão pendente com preço anterior de R$ 79,90
    E o preço atual do produto já não é R$ 79,90
    Quando aprovo a sugestão
    Então recebo o erro 409 "o preço do produto mudou desde a sugestão; descarte-a e rode o motor de novo"
    E o preço do produto não muda

  Cenário: Descartar mantém o preço
    Dado uma sugestão pendente de R$ 79,90 para R$ 83,90
    Quando descarto a sugestão
    Então o ajuste fica no estado "Descartado"
    E o preço do produto continua R$ 79,90

  Cenário: Revisar um ajuste que não está pendente
    Dado um ajuste no estado "Descartado"
    Quando tento aprová-lo
    Então recebo um erro 409 dizendo que o ajuste não está pendente

  Cenário: Reverter o último ajuste aprovado
    Dado um ajuste de risco "Finalizado" de R$ 79,90 para R$ 83,90
    E ele é o ajuste mais recente do produto
    E não há sugestão pendente para o produto
    Quando reverto o ajuste
    Então o preço do produto volta a R$ 79,90
    E o ajuste fica no estado "Revertido"

  Esquema do Cenário: Reversão recusada
    Dado um ajuste "Finalizado" em que <situacao>
    Quando reverto o ajuste
    Então recebo o erro 409 "<mensagem>"

    Exemplos:
      | situacao                                     | mensagem                                                                  |
      | há uma sugestão pendente para o produto      | há sugestão pendente para o produto; revise-a primeiro                    |
      | existe um ajuste finalizado mais recente     | existe ajuste mais recente; reverta-o primeiro                            |
      | o ajuste foi feito pelo clamp de um normal   | ajuste feito pelos limites do produto; altere os limites em vez de reverter |

  Cenário: Revisão em lote com um item recusado
    Dado três sugestões pendentes
    E o preço de um dos produtos mudou desde a sugestão
    Quando aprovo as três em lote
    Então duas sugestões ficam "Finalizado"
    E a terceira volta com o motivo da recusa
    E as duas aprovações são mantidas

  Cenário: Lote grande demais
    Quando tento aprovar 501 sugestões em lote
    Então recebo o erro 400 "no máximo 500 ajustes por lote"

  Cenário: Produto com sugestão pendente fica fora do ciclo
    Dado um produto com sugestão pendente
    Quando o motor executa o ciclo
    Então nenhuma sugestão nova é gerada para esse produto

  Esquema do Cenário: Cooldown de sugestão descartada
    Dado o cooldown de 7 dias com diferença mínima de 5%
    E uma sugestão de ruptura de R$ 105,00 descartada há <dias> dias para o mesmo produto
    Quando o motor sugere R$ <novo> em ruptura para o produto
    Então a nova sugestão é <resultado>

    Exemplos:
      | dias | novo   | resultado                         |
      | 3    | 104,00 | suprimida e contada em suprimidas |
      | 3    | 115,00 | gravada                           |
      | 8    | 104,00 | gravada                           |
```
