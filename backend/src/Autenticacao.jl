# Usuários (perfis admin e gerente), senhas com PBKDF2-HMAC-SHA256 e sessões por cookie.

const ITERACOES_PBKDF2 = 100_000
const HORAS_SESSAO = 12
const COOKIE_SESSAO = "julyprice_sessao"
const PERFIS = ("admin", "gerente")

# PBKDF2 com um único bloco (32 bytes), suficiente para guardar o hash da senha.
function pbkdf2(senha::AbstractString, salt::Vector{UInt8}; iter::Int=ITERACOES_PBKDF2)
    chave = Vector{UInt8}(senha)
    u = hmac_sha256(chave, vcat(salt, UInt8[0, 0, 0, 1]))
    t = copy(u)
    for _ in 2:iter
        u = hmac_sha256(chave, u)
        t .⊻= u
    end
    t
end

iguais_tempo_constante(a::AbstractVector{UInt8}, b::AbstractVector{UInt8}) =
    length(a) == length(b) && reduce(|, a .⊻ b; init=0x00) == 0x00
iguais_tempo_constante(a::AbstractString, b::AbstractString) = iguais_tempo_constante(codeunits(a), codeunits(b))

hash_token(token::AbstractString) = bytes2hex(sha256(token))

function criar_usuario(conn, login::AbstractString, nome::AbstractString, perfil::AbstractString, senha::AbstractString)
    perfil in PERFIS || throw(ErroCliente(400, "perfil deve ser admin ou gerente"))
    isempty(strip(login)) && throw(ErroCliente(400, "login vazio"))
    length(senha) >= 8 || throw(ErroCliente(400, "a senha deve ter ao menos 8 caracteres"))
    salt = rand(RandomDevice(), UInt8, 16)
    execute(conn, """INSERT INTO usuarios VALUES (\$1,\$2,\$3,\$4,\$5) ON CONFLICT (login) DO UPDATE SET
                     nome=EXCLUDED.nome, perfil=EXCLUDED.perfil, senha_hash=EXCLUDED.senha_hash, salt=EXCLUDED.salt""",
            [login, nome, perfil, bytes2hex(pbkdf2(senha, salt)), bytes2hex(salt)])
    execute(conn, "DELETE FROM sessoes WHERE login = \$1", [login])  # troca de senha derruba as sessões abertas
    (login=login, nome=nome, perfil=perfil)
end

"Confere login e senha e abre uma sessão. Devolve o token (vai só no cookie) e o usuário."
function autenticar(conn, login::AbstractString, senha::AbstractString)
    df = consulta(conn, "SELECT * FROM usuarios WHERE login = \$1", [login])
    # Login inexistente também paga o PBKDF2, para o tempo de resposta não revelar quais logins existem
    salt = isempty(df) ? zeros(UInt8, 16) : hex2bytes(only(df.salt))
    calculado = pbkdf2(senha, salt)
    (!isempty(df) && iguais_tempo_constante(calculado, hex2bytes(only(df.senha_hash)))) ||
        throw(ErroCliente(401, "login ou senha inválidos"))
    token = bytes2hex(rand(RandomDevice(), UInt8, 32))
    execute(conn, "DELETE FROM sessoes WHERE expira_em < now()")
    execute(conn, "INSERT INTO sessoes VALUES (\$1, \$2, now() + make_interval(hours => \$3))",
            Any[hash_token(token), login, HORAS_SESSAO])
    u = first(eachrow(df))
    (token=token, usuario=(login=u.login, nome=u.nome, perfil=u.perfil))
end

encerrar_sessao(conn, token::AbstractString) = execute(conn, "DELETE FROM sessoes WHERE token = \$1", [hash_token(token)])

function usuario_da_sessao(conn, token::AbstractString)
    df = consulta(conn, """SELECT u.login, u.nome, u.perfil FROM sessoes s JOIN usuarios u ON u.login = s.login
                           WHERE s.token = \$1 AND s.expira_em > now()""", [hash_token(token)])
    isempty(df) ? nothing : (login=only(df.login), nome=only(df.nome), perfil=only(df.perfil))
end

function token_do_cookie(req)
    for par in split(HTTP.header(req, "Cookie", ""), ';')
        kv = split(strip(par), '='; limit=2)
        length(kv) == 2 && kv[1] == COOKIE_SESSAO && return String(kv[2])
    end
    nothing
end

# Sem Secure: a API roda em http local atrás do proxy do Vite. Em produção com HTTPS, acrescentar "; Secure".
cookie_sessao(token::AbstractString, max_age::Int) =
    "$COOKIE_SESSAO=$token; Path=/; HttpOnly; SameSite=Strict; Max-Age=$max_age"
