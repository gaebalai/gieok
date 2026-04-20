#!/usr/bin/env bash
#
# generate.sh — extract-pdf.sh 테스트용 픽스처를 재생성한다.
#
# 일반 테스트는 commit 된 픽스처를 사용한다. 본 스크립트는 픽스처가 손실되거나
# 업데이트가 필요해진 경우의 재생성 용도.
#
# 의존:
#   - python3 (Python 3.8+)        픽스처 PDF 의 수작업 생성
#   - qpdf                         암호화 PDF 생성
#   - magick (ImageMagick)         스캔 이미지 PDF 생성
#
# 실행:
#   bash tools/claude-brain/tests/fixtures/pdf/generate.sh

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
cd "${HERE}"

for bin in python3 qpdf magick; do
  if ! command -v "${bin}" >/dev/null 2>&1; then
    echo "ERROR: ${bin} not found. Install poppler / qpdf / imagemagick." >&2
    exit 1
  fi
done

python3 "${HERE}/make-pdf.py"

# 암호화 PDF: sample-8p.pdf 를 256bit AES 로 보호 (user-password=빈값, owner-password=test).
# 빈 user-password 를 사용하면 pdfinfo 가 메타데이터를 읽을 수 있으므로 extract-pdf.sh 의
# "Encrypted: yes" 감지 경로를 테스트할 수 있다.
qpdf --encrypt --owner-password=test --user-password= --bits=256 -- \
  sample-8p.pdf sample-encrypted.pdf

# 스캔 이미지 PDF: 1페이지의 공백 이미지 (텍스트 레이어 없음)
# magick 의 -size + canvas 로 공백 페이지를 만들고 PDF 로 변환
magick -size 612x792 xc:white -density 72 sample-scanned.pdf

echo "Generated fixtures:"
ls -la *.pdf
