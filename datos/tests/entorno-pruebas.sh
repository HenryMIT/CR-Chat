#!/usr/bin/env bash
# Entorno de pruebas del backend (proyecto compose "crchat-be").
#   datos/tests/entorno-pruebas.sh up      # genera secretos aleatorios (fuera del repo) y levanta todo
#   datos/tests/entorno-pruebas.sh test    # PHPUnit + api_test.py + ws_test.py
#   datos/tests/entorno-pruebas.sh down    # baja el entorno y borra sus volúmenes
set -euo pipefail
RAIZ="$(cd "$(dirname "$0")/../.." && pwd)"
COMPOSE_FILE="$RAIZ/datos/docker-compose.pruebas-backend.yml"
ENV_FILE="${XDG_RUNTIME_DIR:-/tmp}/crchat-be-pruebas.env"
dc() { docker compose -p crchat-be -f "$COMPOSE_FILE" --env-file "$ENV_FILE" "$@"; }
rnd() { python3 -c "import secrets,sys; print(secrets.token_urlsafe(int(sys.argv[1])))" "$1"; }

case "${1:-}" in
  up)
    if [ ! -f "$ENV_FILE" ]; then
      umask 077
      {
        echo "PRUEBAS_PG_SUPERPASS=$(rnd 24)"
        echo "PRUEBAS_MIGRATOR_PASSWORD=$(rnd 24)"
        echo "PRUEBAS_APP_RW_PASSWORD=$(rnd 24)"
        echo "PRUEBAS_APP_RO_PASSWORD=$(rnd 24)"
        echo "PRUEBAS_REDIS_PASSWORD=$(rnd 24)"
        echo "PRUEBAS_MINIO_PASSWORD=$(rnd 24)"
        echo "PRUEBAS_JWT_ACCESS_KEY=$(rnd 48)"
        echo "PRUEBAS_MSG_ENC_KEY=$(python3 -c 'import base64,secrets; print(base64.b64encode(secrets.token_bytes(32)).decode())')"
      } > "$ENV_FILE"
    fi
    dc up -d --build --wait web-datos ws minio
    dc up -d minio-init
    ;;
  test)
    dc exec -T web-datos composer validate --strict --no-check-publish
    dc exec -T web-datos vendor/bin/phpunit
    API_URL=http://127.0.0.1:18080 python3 "$RAIZ/datos/tests/api_test.py"
    API_URL=http://127.0.0.1:18080 WS_URL=ws://127.0.0.1:18081/ws python3 "$RAIZ/datos/tests/ws_test.py"
    ;;
  down)
    dc down -v --remove-orphans
    rm -f "$ENV_FILE"
    ;;
  *)
    echo "uso: $0 up|test|down" >&2; exit 2 ;;
esac
