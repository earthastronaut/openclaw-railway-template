FROM node:26-bookworm

RUN apt-get update \
  && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    git \
    gosu \
    inotify-tools \
    procps \
    python3 \
    tini \
    build-essential \
    zip \
    unzip \
  && rm -rf /var/lib/apt/lists/*

RUN npm install -g \
    --allow-scripts=openclaw \
    openclaw@2026.9.7 \
  && node --version | grep -Eq '^v26\.' \
  && openclaw --version | grep -Eq '^OpenClaw 2026\.9\.7( |$)'
RUN npm install -g clawhub@latest

# rclone (pinned) for optional R2 workspace sync; apt's version is too old for bisync
ARG RCLONE_RELEASE=v1.75.1
RUN ARCH="$(dpkg --print-architecture)" \
  && curl -fsSL -o /tmp/rclone.zip "https://downloads.rclone.org/${RCLONE_RELEASE}/rclone-${RCLONE_RELEASE}-linux-${ARCH}.zip" \
  && unzip -q /tmp/rclone.zip -d /tmp \
  && install -m 755 /tmp/rclone-${RCLONE_RELEASE}-linux-${ARCH}/rclone /usr/local/bin/rclone \
  && rm -rf /tmp/rclone* \
  && rclone version

WORKDIR /app

COPY package.json pnpm-lock.yaml ./
RUN npm install -g pnpm@11.24.0 \
  && pnpm install --frozen-lockfile --prod

COPY src ./src
COPY --chmod=755 entrypoint.sh ./entrypoint.sh
COPY --chmod=755 bin ./bin

# Console helpers: /app/bin on PATH and `cdw` for both login and interactive
# non-login shells, since /etc/profile rebuilds PATH from scratch.
RUN printf '%s\n' \
  'for d in /home/linuxbrew/.linuxbrew/sbin /home/linuxbrew/.linuxbrew/bin /app/bin; do' \
  '  case ":$PATH:" in *":$d:"*) ;; *) PATH="$d:$PATH" ;; esac' \
  'done' \
  'export PATH' \
  'alias cdw='"'"'cd "${OPENCLAW_WORKSPACE_DIR:-${OPENCLAW_STATE_DIR:-/data/.openclaw}/workspace}"'"'"'' \
  > /etc/profile.d/openclaw.sh \
  && chmod 644 /etc/profile.d/openclaw.sh \
  && echo '[ -r /etc/profile.d/openclaw.sh ] && . /etc/profile.d/openclaw.sh' >> /etc/bash.bashrc

RUN useradd -m -s /bin/bash openclaw \
  && chown -R openclaw:openclaw /app \
  && mkdir -p /data && chown openclaw:openclaw /data \
  && mkdir -p /home/linuxbrew/.linuxbrew && chown -R openclaw:openclaw /home/linuxbrew

USER openclaw
RUN NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

ENV PATH="/app/bin:/home/linuxbrew/.linuxbrew/bin:/home/linuxbrew/.linuxbrew/sbin:${PATH}"
ENV HOMEBREW_PREFIX="/home/linuxbrew/.linuxbrew"
ENV HOMEBREW_CELLAR="/home/linuxbrew/.linuxbrew/Cellar"
ENV HOMEBREW_REPOSITORY="/home/linuxbrew/.linuxbrew/Homebrew"

ENV PORT=8080
ENV OPENCLAW_ENTRY=/usr/local/lib/node_modules/openclaw/dist/entry.js
ENV OPENCLAW_SUPERVISOR_MODE=external
EXPOSE 8080

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s \
  CMD curl -f http://localhost:8080/setup/healthz || exit 1

USER root
ENTRYPOINT ["tini", "--", "./entrypoint.sh"]
