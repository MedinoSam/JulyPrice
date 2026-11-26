# Integração com o ERP

Rotas: `POST /api/erp/vendas-estoque` e `GET /api/erp/precos-ajustados?desde=`, ambas com o header `X-ERP-Token`.

```gherkin
# language: pt
Funcionalidade: Troca de dados com o ERP
  Como ERP da loja
  Quero enviar vendas e estoque e receber os preços ajustados
  Para que a loja venda sempre ao preço decidido pela plataforma

  Contexto:
    Dado que a API tem o token do ERP configurado

  Cenário: Carga de vendas dispara o ciclo
    Dado uma carga com produtos e vendas do dia
    Quando o ERP envia a carga com o token correto
    Então os produtos e as vendas são gravados
    E o motor executa um ciclo com origem "erp"

  Cenário: Produto novo usa o preço do ERP
    Dado que o produto "SKU9001" não existe na plataforma
    Quando o ERP envia o produto com preço de R$ 79,90
    Então o produto é criado com preço de R$ 79,90
    E R$ 79,90 vira o primeiro preço do produto, usado pelo teto padrão

  Cenário: A plataforma é dona do preço
    Dado que o produto "SKU9001" já existe com preço de R$ 83,90
    Quando o ERP envia o produto com preço de R$ 79,90
    Então o nome, a categoria, o custo e o estoque são atualizados
    Mas o preço continua R$ 83,90

  Cenário: Mesmo dia enviado duas vezes
    Dado que a venda de "SKU9001" em 2026-11-08 já foi recebida
    Quando o ERP envia de novo a venda do mesmo produto e dia
    Então a venda do dia é substituída, sem duplicar

  Cenário: ERP lê só os preços alterados
    Dado que dois produtos tiveram o preço alterado depois de 2026-11-09T00:00:00Z
    Quando o ERP consulta os preços ajustados desde 2026-11-09T00:00:00Z
    Então recebe só esses dois produtos, com o horário da alteração em UTC

  Cenário: Preço igual não conta como alteração
    Dado um produto com preço de R$ 100,00
    Quando a plataforma grava o mesmo preço de R$ 100,00
    Então o horário da última alteração não muda
    E o ERP não recebe o produto de novo

  Esquema do Cenário: Acesso às rotas do ERP
    Dado que <configuracao>
    Quando o ERP chama uma rota do ERP <com_token>
    Então a resposta tem status <status>

    Exemplos:
      | configuracao                             | com_token             | status |
      | a API tem o token do ERP configurado     | com o token correto   | 200    |
      | a API tem o token do ERP configurado     | com um token errado   | 401    |
      | a API tem o token do ERP configurado     | sem o header          | 401    |
      | a API não tem o token do ERP configurado | com qualquer token    | 503    |

  Cenário: Carga inválida
    Quando o ERP envia um corpo que não é JSON
    Então a resposta tem status 400 e a mensagem "JSON inválido"

  Cenário: Campo obrigatório ausente
    Quando o ERP envia um produto sem o campo "custo"
    Então a resposta tem status 400 e a mensagem "campo 'custo' ausente ou inválido (esperado Float64)"
```
