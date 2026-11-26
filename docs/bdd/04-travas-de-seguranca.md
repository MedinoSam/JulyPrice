# Travas de segurança

Implementação: `aplicar_clamp`, `limite_padrao` e `limitar_variacao` em `backend/src/MotorPrecificacao.jl`; `preparar_ciclo` em `backend/src/Repositorio.jl`.

```gherkin
# language: pt
Funcionalidade: Travas de preço
  Como gerente comercial
  Quero que nenhum preço saia dos limites do negócio
  Para automatizar sem risco de preços absurdos ou sem margem

  Esquema do Cenário: Clamp pelos limites do gerente
    Dado um produto com custo de R$ <custo>
    E limites com preço mínimo R$ <minimo>, preço máximo R$ <maximo> e margem desejada de <margem>
    E o preço calculado pelo motor é R$ <calculado>
    Quando o motor aplica o clamp
    Então o preço final é R$ <final>

    Exemplos:
      | custo | minimo | maximo | margem | calculado | final  |
      | 50,00 | 60,00  | 100,00 | 30%    | 62,00     | 65,00  |
      | 50,00 | 60,00  | 100,00 | 30%    | 104,00    | 100,00 |
      | 50,00 | 60,00  | 100,00 | 30%    | 80,00     | 80,00  |
      | 90,00 | 60,00  | 110,00 | 30%    | 105,00    | 110,00 |

  Cenário: Piso acima do teto vale o teto
    Dado um produto com custo de R$ 90,00 e margem desejada de 30%
    E preço máximo de R$ 110,00
    Quando o motor aplica o clamp
    Então o piso de R$ 117,00 é ignorado
    E o preço final não passa de R$ 110,00

  Cenário: Teto padrão para produto sem limites
    Dado o teto padrão de 30%
    E um produto sem limites cadastrados, com primeiro preço de R$ 100,00
    E preço atual de R$ 128,00 em ruptura
    Quando o motor calcula o novo preço
    Então o preço final não passa de R$ 130,00

  Cenário: Teto padrão desligado
    Dado o teto padrão de 0%
    E um produto sem limites cadastrados
    Quando o motor calcula o novo preço
    Então não há teto além da faixa da regra

  Cenário: Variação máxima na janela
    Dado a variação máxima de 15% em uma janela de 30 dias
    E o preço do produto no início da janela era R$ 100,00
    E o preço atual é R$ 112,00 em ruptura
    Quando o motor calcula o novo preço
    Então o preço final não passa de R$ 115,00

  Cenário: As travas não forçam o preço a voltar
    Dado a variação máxima de 15% em uma janela de 30 dias
    E o preço do produto no início da janela era R$ 100,00
    E o preço atual já é R$ 120,00
    Quando o motor aplica as travas
    Então a faixa permitida ainda inclui R$ 120,00

  Cenário: Produto normal fora dos limites é corrigido direto
    Dado um produto sem risco com preço atual de R$ 120,00
    E o gerente definiu preço máximo de R$ 100,00
    Quando o motor executa o ciclo
    Então o preço do produto passa a ser R$ 100,00 sem aprovação
    E o ajuste fica no estado "Finalizado"
    E é gravado um alerta do tipo "LIMITE"

  Cenário: Produto normal dentro dos limites não gera registro
    Dado um produto sem risco com preço dentro dos limites
    Quando o motor executa o ciclo
    Então nenhum ajuste é gravado para o produto
```
