#!/bin/bash

set -e

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${GREEN}• Building RebootNotify binaries...${NC}"

# 构建函数
build_binary() {
    local arch=$1
    local label=$2
    local goarch=$3

    echo -e "${YELLOW}• Building for ${label}...${NC}"
    CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o "RebootNotify-linux-${label}" .
    echo -e "${GREEN}• Built RebootNotify-linux-${label}${NC}"
}

# 检查 Go 是否安装
if ! command -v go &> /dev/null; then
    echo -e "${RED}• Error: Go is not installed${NC}"
    exit 1
fi

# 检查 Go 版本
GO_VERSION=$(go version | awk '{print $3}' | sed 's/go//')
REQUIRED_VERSION="1.26"

if [ "$(printf '%s\n' "$REQUIRED_VERSION" "$GO_VERSION" | sort -V | head -n1)" != "$REQUIRED_VERSION" ]; then
    echo -e "${YELLOW}• Warning: Go version ${GO_VERSION} may be too old. Recommended version: ${REQUIRED_VERSION}${NC}"
fi

# 清理旧的构建文件
echo -e "${YELLOW}• Cleaning old builds...${NC}"
rm -f RebootNotify-linux-*

# 构建不同架构
build_binary "amd64" "x86_64" "amd64"
build_binary "arm64" "arm64" "arm64"

# 显示构建结果
echo ""
echo -e "${GREEN}• Build completed successfully!${NC}"
echo ""
echo "Generated binaries:"
ls -lh RebootNotify-linux-* | awk '{print "  " $9 " (" $5 ")"}'
