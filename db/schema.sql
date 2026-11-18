-- JulyPrice: Plataforma de Precificação Dinâmica — esquema PostgreSQL

-- Regra global (uma única linha, id = 1), mantida pelo Administrador
CREATE TABLE IF NOT EXISTS regras_negocio (
    id                      INT PRIMARY KEY DEFAULT 1 CHECK (id = 1),
    limite_estoque_minimo   BIGINT           NOT NULL CHECK (limite_estoque_minimo >= 0),
    limite_dias_inatividade BIGINT           NOT NULL CHECK (limite_dias_inatividade >= 0),
    taxa_ajuste_alto        DOUBLE PRECISION NOT NULL CHECK (taxa_ajuste_alto >= 0),
    taxa_ajuste_baixo       DOUBLE PRECISION NOT NULL CHECK (taxa_ajuste_baixo >= 0 AND taxa_ajuste_baixo < 1),
    atualizado_em           TIMESTAMP        NOT NULL DEFAULT now()
);
INSERT INTO regras_negocio (id, limite_estoque_minimo, limite_dias_inatividade, taxa_ajuste_alto, taxa_ajuste_baixo)
VALUES (1, 10, 30, 0.05, 0.10) ON CONFLICT (id) DO NOTHING;

CREATE TABLE IF NOT EXISTS produtos (
    id           TEXT PRIMARY KEY,           -- SKU vindo do ERP
    nome         TEXT             NOT NULL,
    categoria    TEXT             NOT NULL DEFAULT '',
    custo        DOUBLE PRECISION NOT NULL CHECK (custo >= 0),
    preco        DOUBLE PRECISION NOT NULL CHECK (preco > 0),
    estoque      BIGINT           NOT NULL CHECK (estoque >= 0),
    dias_parado  BIGINT           NOT NULL CHECK (dias_parado >= 0),
    elasticidade DOUBLE PRECISION NOT NULL DEFAULT -1.0,
    preco_alterado_em TIMESTAMP     -- só muda quando a plataforma altera o preço (o ERP lê por aqui)
);

-- Limites definidos pelo Gerente Comercial, por produto
CREATE TABLE IF NOT EXISTS limites_preco (
    produto_id      TEXT PRIMARY KEY REFERENCES produtos(id) ON DELETE CASCADE,
    preco_minimo    DOUBLE PRECISION NOT NULL CHECK (preco_minimo > 0),
    preco_maximo    DOUBLE PRECISION NOT NULL,
    margem_desejada DOUBLE PRECISION NOT NULL DEFAULT 0 CHECK (margem_desejada >= 0),
    CHECK (preco_maximo >= preco_minimo)
);

-- Histórico diário de vendas recebido do ERP
CREATE TABLE IF NOT EXISTS vendas (
    produto_id TEXT             NOT NULL REFERENCES produtos(id) ON DELETE CASCADE,
    data       DATE             NOT NULL,
    quantidade BIGINT           NOT NULL CHECK (quantidade >= 0),
    preco      DOUBLE PRECISION NOT NULL CHECK (preco > 0),
    PRIMARY KEY (produto_id, data)
);

-- Cada passagem do motor por um produto gera um ajuste (máquina de estados)
CREATE TABLE IF NOT EXISTS ajustes_preco (
    id             BIGSERIAL PRIMARY KEY,
    produto_id     TEXT             NOT NULL REFERENCES produtos(id) ON DELETE CASCADE,
    risco          TEXT             NOT NULL CHECK (risco IN ('normal', 'ruptura', 'encalhe')),
    estado         TEXT             NOT NULL CHECK (estado IN ('NotificadoGerente', 'Finalizado', 'Revertido')),
    preco_anterior DOUBLE PRECISION NOT NULL,
    preco_calculado DOUBLE PRECISION NOT NULL,  -- antes do clamp
    preco_novo     DOUBLE PRECISION NOT NULL,   -- depois do clamp
    elasticidade   DOUBLE PRECISION NOT NULL,
    criado_em      TIMESTAMP        NOT NULL DEFAULT now(),
    revisado_em    TIMESTAMP
);
CREATE INDEX IF NOT EXISTS ix_ajustes_estado ON ajustes_preco (estado);
CREATE INDEX IF NOT EXISTS ix_ajustes_produto ON ajustes_preco (produto_id, criado_em DESC);

CREATE TABLE IF NOT EXISTS alertas (
    id           BIGSERIAL PRIMARY KEY,
    produto_id   TEXT      NOT NULL REFERENCES produtos(id) ON DELETE CASCADE,
    ajuste_id    BIGINT    REFERENCES ajustes_preco(id) ON DELETE CASCADE,
    tipo         TEXT      NOT NULL,
    mensagem     TEXT      NOT NULL,
    data_criacao TIMESTAMP NOT NULL DEFAULT now(),
    lido         BOOLEAN   NOT NULL DEFAULT false
);

-- =====================================================================
-- Evoluções. Este arquivo é idempotente: a API o reaplica a cada subida,
-- então bancos antigos ganham as colunas e tabelas novas sem recriar o volume.
-- shortcut: sem controle de versão; trocar por migrações numeradas se surgir mudança destrutiva.
-- =====================================================================

-- Regras globais novas (0 desliga a regra correspondente)
ALTER TABLE regras_negocio
    ADD COLUMN IF NOT EXISTS dias_cooldown        BIGINT           NOT NULL DEFAULT 7    CHECK (dias_cooldown >= 0),
    ADD COLUMN IF NOT EXISTS variacao_cooldown    DOUBLE PRECISION NOT NULL DEFAULT 0.05 CHECK (variacao_cooldown >= 0),
    ADD COLUMN IF NOT EXISTS teto_padrao          DOUBLE PRECISION NOT NULL DEFAULT 0.30 CHECK (teto_padrao >= 0),
    ADD COLUMN IF NOT EXISTS variacao_max_janela  DOUBLE PRECISION NOT NULL DEFAULT 0.15 CHECK (variacao_max_janela >= 0),
    ADD COLUMN IF NOT EXISTS dias_janela_variacao BIGINT           NOT NULL DEFAULT 30   CHECK (dias_janela_variacao >= 1),
    ADD COLUMN IF NOT EXISTS intervalo_motor_horas BIGINT          NOT NULL DEFAULT 0    CHECK (intervalo_motor_horas >= 0);

-- Regra por categoria; sem linha, vale a global
CREATE TABLE IF NOT EXISTS regras_categoria (
    categoria               TEXT PRIMARY KEY,
    limite_estoque_minimo   BIGINT           NOT NULL CHECK (limite_estoque_minimo >= 0),
    limite_dias_inatividade BIGINT           NOT NULL CHECK (limite_dias_inatividade >= 0),
    taxa_ajuste_alto        DOUBLE PRECISION NOT NULL CHECK (taxa_ajuste_alto >= 0),
    taxa_ajuste_baixo       DOUBLE PRECISION NOT NULL CHECK (taxa_ajuste_baixo >= 0 AND taxa_ajuste_baixo < 1)
);

-- Preço de referência do teto padrão: o primeiro preço do produto (antes de qualquer ajuste)
ALTER TABLE produtos ADD COLUMN IF NOT EXISTS preco_base DOUBLE PRECISION;
UPDATE produtos p SET preco_base = COALESCE(
    (SELECT a.preco_anterior FROM ajustes_preco a WHERE a.produto_id = p.id ORDER BY a.id LIMIT 1), p.preco)
WHERE preco_base IS NULL;

-- Estoque do dia (opcional): dia com estoque zero não entra na estimativa de elasticidade
ALTER TABLE vendas ADD COLUMN IF NOT EXISTS estoque BIGINT CHECK (estoque >= 0);

-- Descartado (pendente recusado) separado de Revertido (finalizado desfeito); auditoria da revisão
ALTER TABLE ajustes_preco
    ADD COLUMN IF NOT EXISTS revisado_por TEXT,
    ADD COLUMN IF NOT EXISTS comentario   TEXT;
ALTER TABLE ajustes_preco DROP CONSTRAINT IF EXISTS ajustes_preco_estado_check,
    ADD CONSTRAINT ajustes_preco_estado_check
    CHECK (estado IN ('NotificadoGerente', 'Finalizado', 'Revertido', 'Descartado'));
CREATE INDEX IF NOT EXISTS ix_alertas_ajuste ON alertas (ajuste_id);
CREATE INDEX IF NOT EXISTS ix_alertas_lido ON alertas (lido, data_criacao DESC);

-- Usuários e sessões (cookie). Usuários são criados por backend/scripts/criar_usuario.jl.
CREATE TABLE IF NOT EXISTS usuarios (
    login      TEXT PRIMARY KEY,
    nome       TEXT  NOT NULL,
    perfil     TEXT  NOT NULL CHECK (perfil IN ('admin', 'gerente')),
    senha_hash TEXT NOT NULL,   -- PBKDF2-HMAC-SHA256, hex
    salt       TEXT NOT NULL    -- hex
);
CREATE TABLE IF NOT EXISTS sessoes (
    token     TEXT PRIMARY KEY,   -- SHA-256 do token do cookie, hex (o token em si não fica no banco)
    login     TEXT      NOT NULL REFERENCES usuarios(login) ON DELETE CASCADE,
    expira_em TIMESTAMP NOT NULL
);

-- Histórico de execuções do motor
CREATE TABLE IF NOT EXISTS execucoes_motor (
    id         BIGSERIAL PRIMARY KEY,
    origem     TEXT      NOT NULL CHECK (origem IN ('erp', 'manual', 'agenda')),
    inicio     TIMESTAMP NOT NULL DEFAULT now(),
    duracao_ms BIGINT,
    normal     BIGINT,
    ruptura    BIGINT,
    encalhe    BIGINT,
    ajustes    BIGINT,
    suprimidas BIGINT,
    erro       TEXT
);
