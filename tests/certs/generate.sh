#!/usr/bin/env sh
# Creates a throwaway CA and a server certificate for host "postgres" (TLS tests only).
set -eu
cd "$(dirname "$0")"
openssl req -x509 -newkey rsa:2048 -nodes -keyout ca.key -out ca.crt -days 3650 -subj "/CN=ml_pgsql test CA" 2>/dev/null
openssl req -newkey rsa:2048 -nodes -keyout server.key -out server.csr -subj "/CN=postgres" 2>/dev/null
printf "subjectAltName=DNS:postgres\n" > san.ext
openssl x509 -req -in server.csr -CA ca.crt -CAkey ca.key -CAcreateserial -out server.crt -days 3650 -extfile san.ext 2>/dev/null
rm -f server.csr san.ext ca.srl
