#!/usr/bin/env bash
# Renderiza diagramas Mermaid y genera docs/PROYECTO.pdf con pandoc.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DOCS="${ROOT}/docs"
DIAGRAMS="${DOCS}/diagramas"
MEDIA="${DOCS}/media"
SRC="${DOCS}/PROYECTO.md"
OUT_PDF="${DOCS}/PROYECTO.pdf"
OUT_HTML="${DOCS}/PROYECTO.html"
MMD_CONFIG="${DOCS}/mermaid-config.json"
PDF_HEADER="${DOCS}/pdf-header.tex"

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Falta '$1'. Instala dependencias (ver docs/PROYECTO.md, generacion del PDF)." >&2
    exit 1
  fi
}

require_cmd pandoc

run_mmdc() {
  if command -v mmdc >/dev/null 2>&1; then
    mmdc "$@"
  elif command -v npx >/dev/null 2>&1; then
    npx -y @mermaid-js/mermaid-cli "$@"
  else
    echo "Falta mmdc o npx. brew install mermaid-cli" >&2
    exit 1
  fi
}

# Fija la densidad para que el PNG quepa en la caja de texto (como máximo
# unos 14,5 cm de ancho y 11 cm de alto) sin estirarlo ni desbordar.
normalize_png() {
  local png="$1"
  local w h dpi
  if command -v sips >/dev/null 2>&1; then
    w=$(sips -g pixelWidth "$png" | awk '/pixelWidth/{print $2}')
    h=$(sips -g pixelHeight "$png" | awk '/pixelHeight/{print $2}')
    if [[ "${w:-0}" -gt 1600 ]]; then
      sips --resampleWidth 1600 "$png" >/dev/null
      w=$(sips -g pixelWidth "$png" | awk '/pixelWidth/{print $2}')
      h=$(sips -g pixelHeight "$png" | awk '/pixelHeight/{print $2}')
    fi
    if [[ "${h:-0}" -gt 1400 ]]; then
      sips --resampleHeight 1400 "$png" >/dev/null
      w=$(sips -g pixelWidth "$png" | awk '/pixelWidth/{print $2}')
      h=$(sips -g pixelHeight "$png" | awk '/pixelHeight/{print $2}')
    fi
    dpi=$(python3 -c "print(max(110, int(round(max(${w:-800}/5.4, ${h:-600}/4.8)))))")
    sips -s dpiWidth "$dpi" -s dpiHeight "$dpi" "$png" >/dev/null
    echo "  PNG ${w}x${h}px, ${dpi} DPI → $(basename "$png")"
  elif command -v magick >/dev/null 2>&1; then
    magick "$png" -resize '1600x1400>' -units PixelsPerInch -density 180 "$png"
  fi
}

mkdir -p "$MEDIA"

shopt -s nullglob
for mmd in "${DIAGRAMS}"/*.mmd; do
  base=$(basename "$mmd" .mmd)
  echo "Renderizando ${base}.mmd → media/${base}.png"
  # --size limita el lado mayor del PNG. -w/-H ya no existen en mermaid-cli
  # reciente y, sin tope, Puppeteer exporta un lienzo que LaTeX no cabe en A4.
  run_mmdc -t base -c "$MMD_CONFIG" -i "$mmd" -o "${MEDIA}/${base}.png" \
    -b white --size 1400 -s 2
  normalize_png "${MEDIA}/${base}.png"
done

if [[ ! -f "$SRC" ]]; then
  echo "No existe ${SRC}" >&2
  exit 1
fi

PDF_ENGINE=""
if command -v tectonic >/dev/null 2>&1; then
  PDF_ENGINE=tectonic
elif command -v xelatex >/dev/null 2>&1; then
  PDF_ENGINE=xelatex
elif command -v pdflatex >/dev/null 2>&1; then
  PDF_ENGINE=pdflatex
fi

PANDOC_COMMON=(
  --resource-path=".:media"
  -V lang=es
  -V papersize=a4
  -V geometry:"a4paper,margin=2.3cm"
  -V fontsize=11pt
  -V linestretch=1.28
  -V title="API REST Supermercado - IaC EKS"
  -V author="Marlon Ernesto Figueroa Fuentes"
  --toc
  --toc-depth=2
  -f markdown+smart
)

if [[ -n "$PDF_ENGINE" ]]; then
  echo "Generando PDF con ${PDF_ENGINE}..."
  (
    cd "$DOCS"
    pandoc "PROYECTO.md" \
      -o "PROYECTO.pdf" \
      --pdf-engine="$PDF_ENGINE" \
      --include-in-header="pdf-header.tex" \
      "${PANDOC_COMMON[@]}"
  )
  echo "PDF: ${OUT_PDF}"
else
  echo "No se encontró tectonic/xelatex/pdflatex; generando HTML como fallback..."
  (
    cd "$DOCS"
    pandoc "PROYECTO.md" \
      -o "PROYECTO.html" \
      -s \
      -c "pdf.css" \
      "${PANDOC_COMMON[@]}"
  )
  echo "HTML: ${OUT_HTML}"
  echo "Instala BasicTeX para PDF: brew install --cask basictex" >&2
  exit 1
fi
