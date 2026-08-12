#!/usr/bin/env bash
set -e
export PATH=/usr/local/bin:/usr/bin:/bin:/home/ubuntu/.local/bin:$PATH
printf '%s\n' 'stage=3' 'package=0' 'package_name=Node.js' > /run/claude-dev/progress
printf '%s\n' 'event=stage:3|[3/6] 安装 Node.js' >> /run/claude-dev/events
tar -xJf /home/ubuntu/.bundle/node-v*-linux-x64.tar.xz -C /usr/local --strip-components=1
printf '%s\n' 'stage=4' 'package=0' 'package_name=Claude Code' > /run/claude-dev/progress
printf '%s\n' 'event=stage:4|[4/6] 安装 Claude Code' >> /run/claude-dev/events
printf '%s\n' 'event=stage:3|[3/6] 安装 Claude Code' >> /run/claude-dev/events
npm install -g /home/ubuntu/.bundle/anthropic-ai-claude-code-linux-x64-*.tgz
npm install -g /home/ubuntu/.bundle/anthropic-ai-claude-code-[0-9]*.tgz
cc_asset=$(find /home/ubuntu/.bundle/cc-pocket -maxdepth 1 -name 'cc-pocket-daemon-*-linux-x86_64.tar.gz' | head -1)
mkdir -p /home/ubuntu/.local/share/cc-pocket/versions/"${cc_asset##*/}"
tar -xzf "$cc_asset" -C /home/ubuntu/.local/share/cc-pocket/versions/"${cc_asset##*/}"
cc_dir=$(find /home/ubuntu/.local/share/cc-pocket/versions/"${cc_asset##*/}" -maxdepth 1 -type d -name cc-pocket-daemon | head -1)
mkdir -p /home/ubuntu/.local/bin
ln -sfn "$cc_dir/bin/cc-pocket-daemon" /home/ubuntu/.local/bin/cc-pocket-daemon
chown -R ubuntu:ubuntu /home/ubuntu/.local/share/cc-pocket /home/ubuntu/.local/bin
command -v node && command -v npm && command -v claude && command -v cc-pocket-daemon
