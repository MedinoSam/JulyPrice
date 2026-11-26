# Acesso e autenticação

Implementação: `backend/src/Autenticacao.jl`, `autorizar!` em `backend/src/Api.jl` e `backend/scripts/criar_usuario.jl`.

```gherkin
# language: pt
Funcionalidade: Login e perfis de acesso
  Como dono da plataforma
  Quero que só usuários autorizados vejam e mudem preços
  Para proteger as decisões de preço

  Contexto:
    Dado o usuário "maria" com perfil "gerente"
    E o usuário "admin" com perfil "admin"

  Cenário: Login com sucesso
    Quando "maria" entra com a senha correta
    Então recebe o cookie de sessão "julyprice_sessao" HttpOnly e SameSite=Strict, válido por 12 horas
    E o banco guarda só o hash SHA-256 do token

  Esquema do Cenário: Login recusado
    Quando alguém entra com o login "<login>" e uma senha errada
    Então a resposta tem status 401 e a mensagem "login ou senha inválidos"

    Exemplos:
      | login     |
      | maria     |
      | inexistente |

  Cenário: Rota protegida sem sessão
    Dado que não há sessão
    Quando alguém lista as sugestões
    Então a resposta tem status 401 e a mensagem "sessão expirada ou ausente; faça login"
    E o painel volta para a tela de login

  Esquema do Cenário: Permissões por perfil
    Dado que estou logado como "<usuario>"
    Quando acesso "<rota>"
    Então a resposta tem status <status>

    Exemplos:
      | usuario | rota                        | status |
      | maria   | GET /api/sugestoes-alertas  | 200    |
      | maria   | GET /api/regras             | 200    |
      | maria   | PUT /api/regras             | 403    |
      | maria   | POST /api/motor/executar    | 403    |
      | admin   | PUT /api/regras             | 200    |
      | admin   | GET /api/sugestoes-alertas  | 200    |

  Cenário: Logout
    Dado que estou logado como "maria"
    Quando saio do painel
    Então a sessão é apagada do banco
    E a próxima requisição com o cookie antigo recebe 401

  Esquema do Cenário: Criação de usuário pelo terminal
    Quando crio o usuário "<login>" com perfil "<perfil>" e senha "<senha>"
    Então <resultado>

    Exemplos:
      | login   | perfil  | senha        | resultado                                                    |
      | joao    | gerente | senhaforte1  | o usuário é salvo                                            |
      | joao    | gerente | curta        | recebo o erro "a senha deve ter ao menos 8 caracteres"       |
      | joao    | dono    | senhaforte1  | recebo o erro "perfil deve ser admin ou gerente"             |

  Cenário: Recriar um usuário encerra as sessões dele
    Dado que "maria" está logada
    Quando recrio o usuário "maria" com outra senha
    Então as sessões abertas de "maria" são encerradas
```
