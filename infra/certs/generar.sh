#!/bin/bash
# =============================================================================
# Genera (una sola vez) la CA interna y los certificados de CR_Chat en /certs
# (volumen `certs`):
#   ca.crt                       CA de confianza (pública)
#   pg1.{crt,key} pg2.{crt,key}  servidor TLS de pgBackRest en cada nodo
#   backup.{crt,key}             cliente de pgBackRest (CN=backup)
#   haproxy.pem                  terminador TLS de S3 (haproxy:9443 -> minio:9000)
# Idempotente: si ya existe ca.crt no hace nada. Para rotar: borrar el volumen
# `certs` y reiniciar los servicios.
# =============================================================================
set -euo pipefail
D=/certs
DIAS=${CERT_DIAS:-825}
if [ -s "$D/ca.crt" ]; then
    echo "certs: ya existen, no se regeneran"; exit 0
fi
cd "$D"
umask 077
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days 3650 \
    -subj "/CN=CR_Chat CA interna" -keyout ca.key -out ca.crt 2>/dev/null

emitir() {  # emitir <nombre> <CN> <uso: server|client> [SAN DNS...]
    local n=$1 cn=$2 uso=$3; shift 3
    local san="" ext
    for h in "$@"; do san="${san:+$san,}DNS:$h"; done
    openssl req -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes \
        -subj "/CN=$cn" -keyout "$n.key" -out "$n.csr" 2>/dev/null
    ext=$(mktemp)
    {
        echo "basicConstraints=CA:FALSE"
        if [ "$uso" = server ]; then echo "extendedKeyUsage=serverAuth,clientAuth"; else echo "extendedKeyUsage=clientAuth"; fi
        [ -n "$san" ] && echo "subjectAltName=$san"
    } > "$ext"
    openssl x509 -req -in "$n.csr" -CA ca.crt -CAkey ca.key -CAcreateserial \
        -days "$DIAS" -extfile "$ext" -out "$n.crt" 2>/dev/null
    rm -f "$n.csr" "$ext"
}
emitir pg1 pg1 server pg1
emitir pg2 pg2 server pg2
emitir backup backup client
emitir haproxy haproxy server haproxy localhost
cat haproxy.crt haproxy.key > haproxy.pem
rm -f haproxy.key ca.srl

# Dueños: postgres (999) para pgBackRest; haproxy (99) para su PEM.
chown 999:999 pg1.* pg2.* backup.*
chmod 600 pg1.key pg2.key backup.key
chown 99:99 haproxy.pem && chmod 600 haproxy.pem
chmod 644 ca.crt pg1.crt pg2.crt backup.crt haproxy.crt
# La clave de la CA no se necesita en ningún servicio: se descarta (rotación = regenerar todo).
rm -f ca.key
echo "certs: generados en $D"; ls -l "$D"
