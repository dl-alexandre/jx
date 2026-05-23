#!/usr/bin/env bash
#
# One-command installer for jx (jido_orchestrator)
#
# Usage:
#   curl -fsSL https://get.jx.run | sh
#
# This is a placeholder / starter. Real implementation will:
# - Detect OS + arch
# - Download the latest GitHub release launcher (preferred) or escript
# - Install to $HOME/.local/bin or /usr/local/bin
# - Verify the binary works
#
# For now it just gives clear instructions.

set -e

echo "jx installer (early version)"
echo
echo "The recommended way to install jx right now is:"
echo
echo "  mix escript.install hex jido_orchestrator"
echo
echo "For the fastest local dogfood experience:"
echo
echo "  git clone https://github.com/dl-alexandre/jido_orchestrator.git"
echo "  cd jido_orchestrator"
echo "  mix deps.get"
echo "  mix jx.build"
echo "  ./bin/jx --help"
echo
echo "We are actively working on a proper curl | sh installer that"
echo "will download a self-contained binary (once the Burrito/Zig"
echo "packaging issues are resolved)."
echo
echo "Watch https://github.com/dl-alexandre/jido_orchestrator/releases"
echo "for the first official standalone binaries."
