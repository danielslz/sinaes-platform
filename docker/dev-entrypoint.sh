#!/bin/sh
# Prepara e inicia o ambiente de desenvolvimento dentro do container "app".
set -e

cd /app

# 1. Dependências: reinstala só quando o package-lock.json muda.
LOCK_HASH="$(sha256sum package-lock.json | cut -d' ' -f1)"
HASH_FILE="node_modules/.package-lock.sha256"

if [ ! -f "$HASH_FILE" ] || [ "$(cat "$HASH_FILE")" != "$LOCK_HASH" ]; then
  echo "[entrypoint] Instalando dependências (npm ci)..."
  npm ci
  echo "$LOCK_HASH" > "$HASH_FILE"
else
  echo "[entrypoint] Dependências já instaladas."
fi

# 2. Prisma: gera o client e sincroniza o schema com o Mongo.
echo "[entrypoint] Gerando Prisma Client..."
npx prisma generate

echo "[entrypoint] Aplicando schema no banco (prisma db push)..."
npx prisma db push --skip-generate

# 3. MinIO: cria o bucket e a política pública (com retry até o MinIO responder).
echo "[entrypoint] Configurando bucket do MinIO..."
attempt=1
until npm run --silent minio:setup; do
  if [ "$attempt" -ge 15 ]; then
    echo "[entrypoint] Não foi possível configurar o MinIO. Seguindo sem ele."
    break
  fi
  attempt=$((attempt + 1))
  echo "[entrypoint] MinIO indisponível, tentando novamente em 2s..."
  sleep 2
done

# 4. Seed: o seed apaga dados existentes, então só roda com o banco vazio.
if [ "${SEED_ON_EMPTY_DB:-true}" = "true" ]; then
  DIMENSIONS="$(node -e "
    const { PrismaClient } = require('@prisma/client');
    const p = new PrismaClient();
    p.dimensionDefinition.count()
      .then((n) => { console.log(n); return p.\$disconnect(); })
      .catch(() => { console.log('error'); process.exit(0); });
  ")"

  if [ "$DIMENSIONS" = "0" ]; then
    echo "[entrypoint] Banco vazio, executando seed..."
    npx prisma db seed
  else
    echo "[entrypoint] Banco já populado, seed ignorado."
  fi
fi

# 5. Next.js em modo dev, acessível de fora do container.
echo "[entrypoint] Iniciando Next.js em http://localhost:3000 ..."
exec npm run dev -- --hostname 0.0.0.0 --port 3000
