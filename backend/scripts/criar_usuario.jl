# Cria ou atualiza um usuário do painel (troca a senha e derruba as sessões dele).
#
# Uso:
#   julia --project=backend backend/scripts/criar_usuario.jl <login> <admin|gerente> "<nome>"
#
# A senha é pedida no terminal. Sem terminal (scripts), vem de JULYPRICE_SENHA.
# O banco vem de JULYPRICE_DATABASE_URL, como na API. O schema precisa estar aplicado (suba a API uma vez).

using CoreSistemaInteligente
const C = CoreSistemaInteligente

length(ARGS) == 3 || error("uso: criar_usuario.jl <login> <admin|gerente> \"<nome>\"")
login, perfil, nome = ARGS
senha = haskey(ENV, "JULYPRICE_SENHA") ? ENV["JULYPRICE_SENHA"] : begin
    s = Base.getpass("Senha para $login")
    t = read(s, String)
    Base.shred!(s)
    t
end

conn = C.conectar()
try
    u = C.criar_usuario(conn, login, nome, perfil, senha)
    println("Usuário $(u.login) ($(u.perfil)) salvo.")
catch e
    e isa C.ErroCliente ? println(stderr, "Erro: ", e.msg) : rethrow()
    exit(1)
finally
    close(conn)
end
