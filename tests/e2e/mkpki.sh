#!/bin/bash
# Throwaway PKI for the e2e tests: CA, server and client certs into /out
set -e
cd /out
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 30 \
  -keyout ca.key -out ca.crt -subj "/CN=jbx-test-ca" 2>/dev/null
for n in server client; do
  openssl req -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes \
    -keyout $n.key -out $n.csr -subj "/CN=jbx-test-$n" 2>/dev/null
  eku=$([[ $n == server ]] && echo serverAuth || echo clientAuth)
  printf 'basicConstraints=CA:FALSE\nkeyUsage=digitalSignature,keyAgreement\nextendedKeyUsage=%s\n' $eku > $n.ext
  openssl x509 -req -in $n.csr -CA ca.crt -CAkey ca.key -CAcreateserial -days 30 \
    -extfile $n.ext -out $n.crt 2>/dev/null
done
rm -f *.csr *.ext *.srl
chmod 644 *
ls
