# Official jx Docker image
# This gives you a ready-to-use environment with Erlang/OTP + jx preinstalled.
#
# Build:
#   docker build -t ghcr.io/dl-alexandre/jx:latest .
#
# Run:
#   docker run --rm -it ghcr.io/dl-alexandre/jx:latest jx --help

FROM elixir:1.19-otp-28

# Install system dependencies
RUN apt-get update && apt-get install -y \
    libsqlite3-dev \
    build-essential \
    git \
    curl \
    tmux \
    openssh-client \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Install jx from Hex (will be replaced by binary download later)
RUN mix local.hex --force && \
    mix escript.install hex jido_orchestrator --force

# Make jx available on PATH
ENV PATH="/root/.mix/escripts:${PATH}"

# Default command
ENTRYPOINT ["jx"]
CMD ["--help"]
