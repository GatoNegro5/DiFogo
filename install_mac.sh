#!/bin/bash
# ==========================================
# DiFogo - macOS Automated Deployer & Bypass (Dynamic Wildcard)
# ==========================================

# 3.2.21: mismo nombre que publica .github/workflows/release.yml (GatoMix-MacOS.zip con GatoMix.app en la raiz)
GITHUB_ZIP_URL="https://github.com/GatoNegro5/DiFogo/releases/latest/download/GatoMix-MacOS.zip"
TMP_DIR="/tmp/difogo_install"

echo ">> Descargando desde GitHub..."
mkdir -p "$TMP_DIR"
curl -L -s -o "$TMP_DIR/app.zip" "$GITHUB_ZIP_URL"

echo ">> Extrayendo binarios..."
unzip -q "$TMP_DIR/app.zip" -d "$TMP_DIR/"

# Detección dinámica del nombre del bundle .app
APP_DIR=$(find "$TMP_DIR" -maxdepth 1 -name "*.app" -type d | head -n 1)
if [ -z "$APP_DIR" ]; then
    echo "[ERROR] No se encontró ningún archivo .app en el zip."
    rm -rf "$TMP_DIR"
    exit 1
fi

APP_BASENAME=$(basename "$APP_DIR")
APP_EXEC_NAME="${APP_BASENAME%.*}"

echo ">> Instalando $APP_BASENAME en /Applications..."
rm -rf "/Applications/$APP_BASENAME"
mv "$APP_DIR" "/Applications/"

echo ">> Aplicando parche de arquitectura (Bypass Gatekeeper)..."
xattr -cr "/Applications/$APP_BASENAME"

echo ">> Limpiando temporales..."
rm -rf "$TMP_DIR"

echo ">> Despliegue exitoso. Lanzando $APP_EXEC_NAME..."
open -a "$APP_EXEC_NAME"