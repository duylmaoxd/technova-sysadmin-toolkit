#!/usr/bin/env bash
# Biên dịch báo cáo LaTeX → bao-cao.pdf
#  - Có sẵn XeLaTeX: chạy xelatex trực tiếp
#  - Không có: dùng Docker image texlive/texlive:latest-small
set -euo pipefail
cd "$(dirname "$(readlink -f "$0")")"
if command -v xelatex >/dev/null; then
  xelatex -interaction=nonstopmode bao-cao.tex >/dev/null && xelatex -interaction=nonstopmode bao-cao.tex >/dev/null
else
  docker run --rm -u "$(id -u):$(id -g)" -e HOME=/tmp -v "$(dirname "$PWD"):/doc" -w /doc/bao-cao texlive/texlive:latest-small \
    bash -c 'xelatex -interaction=nonstopmode bao-cao.tex >/dev/null && xelatex -interaction=nonstopmode bao-cao.tex >/dev/null'
fi
rm -f bao-cao.aux bao-cao.toc bao-cao.lof bao-cao.lot bao-cao.out
echo "Đã tạo: $PWD/bao-cao.pdf"
