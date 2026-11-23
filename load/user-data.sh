#!/bin/bash
# user-data.sh — first-boot setup for the Gatling load generator (Amazon Linux 2023).
# cloud-init runs this once, as root. Output: /var/log/cloud-init-output.log.
# Done when /var/log/load-generator-ready exists.
set -euxo pipefail

# --- Java 21 (Amazon Corretto, from the AL2023 repo) ---
# tmux keeps a long Gatling run alive when the SSM session drops (the shell would get SIGHUP otherwise).
dnf install -y java-21-amazon-corretto-devel git tmux

# --- sbt (official RPM repo from scala-sbt.org) ---
curl -fsSL https://www.scala-sbt.org/sbt-rpm.repo -o /etc/yum.repos.d/sbt-rpm.repo
dnf install -y sbt

# --- OS limits for many concurrent connections ---
# Every open connection is a file descriptor; the default 1024 caps Gatling well below 1,000 rps.
cat > /etc/security/limits.d/90-loadgen.conf <<'EOF'
*    soft nofile 65535
*    hard nofile 65535
EOF

# More ephemeral ports, and reuse of TIME_WAIT sockets for new outgoing connections.
cat > /etc/sysctl.d/90-loadgen.conf <<'EOF'
net.ipv4.ip_local_port_range = 10000 65535
net.ipv4.tcp_tw_reuse = 1
EOF
sysctl --system

# --- Warm sbt once, as ec2-user, so the first real run doesn't download the launcher ---
sudo -iu ec2-user sbt --version || true

java -version
touch /var/log/load-generator-ready
