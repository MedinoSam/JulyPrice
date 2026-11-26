# Administração das regras e do motor

Implementação: `atualizar_regras`, `definir_regra_categoria`, `simular_motor`, `executar_motor` e `motor_agendado_vencido` em `backend/src/Repositorio.jl`; `agendador` em `backend/src/Api.jl`.

```gherkin
# language: pt
Funcionalidade: Administração das regras de negócio e do motor
  Como administrador
  Quero ajustar as regras e acompanhar as execuções do motor
  Para calibrar a precificação sem mexer no código

  Contexto:
    Dado que estou logado como "admin"

  Cenário: Atualizar as regras globais
    Quando defino estoque mínimo 15, inatividade 45 dias, reajuste de 6% e redução de 8%
    Então as regras são salvas
    E o próximo ciclo usa os novos valores

  Esquema do Cenário: Regra inválida é recusada
    Quando salvo as regras com <campo> igual a <valor>
    Então a resposta tem status 400 e a mensagem "<mensagem>"

    Exemplos:
      | campo                | valor | mensagem                                            |
      | taxa_ajuste_baixo    | 1     | taxa_ajuste_baixo deve estar em [0, 1)              |
      | taxa_ajuste_alto     | -0,1  | taxa_ajuste_alto deve ser >= 0                      |
      | dias_janela_variacao | 0     | dias_janela_variacao deve ser >= 1                  |

  Cenário: Simular regras antes de salvar
    Dado as regras atuais salvas
    Quando simulo o motor com estoque mínimo de 20 unidades
    Então vejo quantos produtos ficariam em ruptura, encalhe e normal
    E vejo quantos ajustes sairiam, quantos seriam suprimidos e a variação média
    Mas nenhum ajuste, alerta ou execução é gravado
    E as regras salvas não mudam

  Cenário: Regra própria de uma categoria
    Quando salvo para "Eletrônicos" estoque mínimo 5 e reajuste de 3%
    Então os produtos de "Eletrônicos" passam a usar essa regra
    E os de outras categorias continuam na regra global

  Cenário: Remover a regra de uma categoria
    Dado que "Eletrônicos" tem regra própria
    Quando removo a regra de "Eletrônicos"
    Então os produtos de "Eletrônicos" voltam à regra global

  Cenário: Remover regra que não existe
    Quando removo a regra de "Moda", que não tem regra própria
    Então a resposta tem status 404 e a mensagem "categoria Moda sem regra própria"

  Cenário: Executar o ciclo manualmente
    Quando clico em "Executar ciclo"
    Então o motor roda com origem "manual"
    E a execução aparece no histórico com início, duração e as contagens

  Cenário: Execução que falha fica registrada
    Dado que o motor lança um erro durante o ciclo
    Quando o ciclo roda
    Então a execução é gravada no histórico com a mensagem de erro

  Esquema do Cenário: Agenda do motor
    Dado o intervalo do motor de <intervalo> horas
    E a última execução, de qualquer origem, foi há <horas> horas
    Quando o agendador confere a agenda
    Então o motor <acao>

    Exemplos:
      | intervalo | horas | acao                          |
      | 6         | 7     | roda com origem "agenda"      |
      | 6         | 2     | não roda                      |
      | 0         | 100   | não roda, a agenda está desligada |
```
