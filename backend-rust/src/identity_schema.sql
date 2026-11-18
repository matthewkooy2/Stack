CREATE TABLE IF NOT EXISTS jac_principals(
    owner TEXT PRIMARY KEY REFERENCES accounts(id) ON DELETE CASCADE,
    user_id TEXT NOT NULL UNIQUE,
    jwt_cutoff INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS jac_retired_roots(owner TEXT PRIMARY KEY);
CREATE TRIGGER IF NOT EXISTS jac_retired_root_guard BEFORE INSERT ON accounts
WHEN EXISTS(SELECT 1 FROM jac_retired_roots WHERE owner=NEW.id)
BEGIN SELECT RAISE(ABORT,'Retired account root'); END;
CREATE TABLE IF NOT EXISTS sso_challenges(
    digest BLOB PRIMARY KEY,purpose TEXT NOT NULL,expires INTEGER NOT NULL,data TEXT NOT NULL,
    owner TEXT REFERENCES accounts(id) ON DELETE CASCADE
);
CREATE INDEX IF NOT EXISTS sso_expiry ON sso_challenges(expires);
CREATE TABLE IF NOT EXISTS sso_bindings(
    provider TEXT NOT NULL,subject TEXT NOT NULL,owner TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
    PRIMARY KEY(provider,subject),UNIQUE(provider,owner)
);
CREATE TABLE IF NOT EXISTS sso_emails(
    email TEXT PRIMARY KEY,owner TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE
);
CREATE TABLE IF NOT EXISTS apple_grants(
    owner TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,client TEXT NOT NULL,sealed TEXT NOT NULL,
    PRIMARY KEY(owner,client)
);
