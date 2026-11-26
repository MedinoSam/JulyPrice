# Cenários BDD do JulyPrice

Cenários em Gherkin (Dado / Quando / Então), em português (`# language: pt`). Os valores e as mensagens de erro são os do código atual.

| # | Funcionalidade | Foco |
|---|---|---|
| 1 | [Diagnóstico de risco](01-diagnostico-de-risco.md) | ruptura, encalhe, normal e regra por categoria |
| 2 | [Elasticidade](02-elasticidade.md) | regressão log-log e limpeza dos dados do ERP |
| 3 | [Cálculo do preço](03-calculo-do-preco.md) | otimização de lucro e de receita dentro da faixa |
| 4 | [Travas de segurança](04-travas-de-seguranca.md) | clamp, teto padrão e variação na janela |
| 5 | [Revisão do gerente](05-revisao-do-gerente.md) | aprovar, descartar, reverter, lote e cooldown |
| 6 | [Integração com o ERP](06-integracao-erp.md) | carga, preços ajustados e token |
| 7 | [Acesso e autenticação](07-acesso-e-autenticacao.md) | login, sessão e perfis |
| 8 | [Administração](08-administracao.md) | regras, simulação, categorias e agenda |

Os cenários documentam o comportamento; eles não rodam como testes automáticos. A parte do motor (1 a 4) é coberta pelos testes em `backend/test/runtests.jl`.
