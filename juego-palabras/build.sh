#!/bin/sh
# Genera index.html (versión descargable, funciona sin internet) a partir de src/page.html
cd "$(dirname "$0")"
{
  printf '%s\n' '<!DOCTYPE html>' '<html lang="es">' '<head>' '<meta charset="utf-8">' '<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">' '<meta name="theme-color" content="#ff7fb5">' '<meta name="apple-mobile-web-app-capable" content="yes">' '<meta name="mobile-web-app-capable" content="yes">'
  sed -n '1,/^<\/style>$/p' src/page.html
  printf '%s\n' '</head>' '<body>'
  sed -n '/^<\/style>$/,$p' src/page.html | sed '1d'
  printf '%s\n' '</body>' '</html>'
} > index.html
echo "index.html generado ($(wc -c < index.html) bytes)"
