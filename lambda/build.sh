#!/bin/bash

# Build script for Lambda function package
# This script installs dependencies and creates a zip file for deployment

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTPUT_ZIP="${SCRIPT_DIR}/process_survey.zip"
PACKAGE_DIR="${SCRIPT_DIR}/package"

echo "Building Lambda package..."

# Clean up previous builds
rm -rf "${PACKAGE_DIR}"
rm -f "${OUTPUT_ZIP}"

# Create package directory
mkdir -p "${PACKAGE_DIR}"

# Copy handler file
cp "${SCRIPT_DIR}/handler.py" "${PACKAGE_DIR}/"

# Install dependencies
echo "Installing dependencies..."
pip install -r "${SCRIPT_DIR}/requirements.txt" -t "${PACKAGE_DIR}" --quiet

# Create zip file
echo "Creating zip file..."
cd "${PACKAGE_DIR}"
zip -r "${OUTPUT_ZIP}" . -q

# Clean up package directory
cd "${SCRIPT_DIR}"
rm -rf "${PACKAGE_DIR}"

echo "Build complete: ${OUTPUT_ZIP}"
echo "File size: $(du -h "${OUTPUT_ZIP}" | cut -f1)"
