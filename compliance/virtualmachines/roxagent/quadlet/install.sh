#!/bin/bash
# Install roxagent Quadlet units on a RHEL VM
#
# Usage:
#   ./install.sh                                                      # Install locally
#   ./install.sh user@host                                            # SSH (port 22)
#   ./install.sh user@host 2222                                       # SSH with custom port
#   ./install.sh virtctl -n openshift-cnv cloud-user@vmi/rhel10-1     # Via virtctl

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Host paths that may not exist on all RHEL versions (e.g. DNF paths on
# yum-only RHEL 8). Volume= lines referencing these are stripped when the
# source path is absent.
OPTIONAL_HOST_PATHS=(
    /etc/yum.repos.d
    /etc/yum/repos.d
    /etc/distro.repos.d
    /etc/redhat-release
    /etc/system-release-cpe
    /var/cache/dnf
    /var/lib/dnf
)

# --- Transport abstraction ---------------------------------------------------
# Each transport defines two functions:
#   remote_copy <local-file> <remote-dest>   — copy a file to the target
#   remote_exec                              — run a script from stdin on target

setup_transport_local() {
    remote_copy() { sudo cp "$1" "$2"; }
    remote_exec() { bash -s; }
}

setup_transport_ssh() {
    local host="$1"
    local port="${2:-22}"
    remote_copy() { scp -P "${port}" "$1" "${host}:$2"; }
    remote_exec() { ssh -p "${port}" "${host}" bash -s; }
}

setup_transport_virtctl() {
    # Expects virtctl flags + target, e.g.:
    #   -n openshift-cnv cloud-user@vmi/rhel10-1
    # The last positional arg is the target; everything else are flags.
    local target="${*: -1}"
    local -a flags=("${@:1:$#-1}")

    remote_copy() {
        virtctl scp "${flags[@]}" "$1" "${target}:$2"
    }
    remote_exec() {
        virtctl ssh "${flags[@]}" "${target}" --command 'bash -s'
    }
}

# --- Install logic (shared) --------------------------------------------------

REMOTE_INSTALL_SCRIPT=$(cat << 'SCRIPT'
set -euo pipefail

OPTIONAL_HOST_PATHS=(
    /etc/yum.repos.d
    /etc/yum/repos.d
    /etc/distro.repos.d
    /etc/redhat-release
    /etc/system-release-cpe
    /var/cache/dnf
    /var/lib/dnf
)

# Strip Volume= lines for host paths that don't exist on this machine
pattern=""
for p in "${OPTIONAL_HOST_PATHS[@]}"; do
    if [ ! -d "$p" ]; then
        echo "  Stripping mount for missing path: $p"
        pattern="${pattern:+${pattern}|}Volume=${p}[:/]"
    fi
done
if [ -n "$pattern" ]; then
    grep -Ev "$pattern" /tmp/roxagent.container > /tmp/roxagent.container.filtered
    mv /tmp/roxagent.container.filtered /tmp/roxagent.container
fi

# Quadlet container file
sudo mkdir -p /etc/containers/systemd/
sudo mv /tmp/roxagent.container /etc/containers/systemd/
sudo restorecon -Rv /etc/containers/systemd/ 2>/dev/null || true

# Timer and prep service
sudo mv /tmp/roxagent.timer /etc/systemd/system/
sudo mv /tmp/roxagent-prep.service /etc/systemd/system/
sudo restorecon -Rv /etc/systemd/system/roxagent.timer /etc/systemd/system/roxagent-prep.service 2>/dev/null || true

echo "Reloading systemd..."
sudo systemctl daemon-reload

echo "Enabling and starting timer..."
sudo systemctl enable --now roxagent.timer

echo "Status:"
sudo systemctl list-timers roxagent.timer
SCRIPT
)

install_local() {
    echo "Installing Quadlet units locally..."

    # Filter container file for missing optional paths
    local filtered
    filtered=$(filter_container_file "${SCRIPT_DIR}/roxagent.container")

    sudo mkdir -p /etc/containers/systemd/
    echo "$filtered" | sudo tee /etc/containers/systemd/roxagent.container >/dev/null
    sudo restorecon -Rv /etc/containers/systemd/ 2>/dev/null || true

    sudo cp "${SCRIPT_DIR}/roxagent.timer" /etc/systemd/system/
    sudo cp "${SCRIPT_DIR}/roxagent-prep.service" /etc/systemd/system/
    sudo restorecon -Rv /etc/systemd/system/roxagent.timer /etc/systemd/system/roxagent-prep.service 2>/dev/null || true

    echo "Reloading systemd..."
    sudo systemctl daemon-reload

    echo "Enabling and starting timer..."
    sudo systemctl enable --now roxagent.timer

    echo "Status:"
    sudo systemctl list-timers roxagent.timer
}

install_remote() {
    echo "Copying files to target..."
    remote_copy "${SCRIPT_DIR}/roxagent.container" /tmp/
    remote_copy "${SCRIPT_DIR}/roxagent.timer" /tmp/
    remote_copy "${SCRIPT_DIR}/roxagent-prep.service" /tmp/

    echo "Running install on target..."
    echo "$REMOTE_INSTALL_SCRIPT" | remote_exec
}

# Produce a filtered roxagent.container on stdout, removing Volume= lines
# whose host source path does not exist on this machine.
filter_container_file() {
    local file="$1"
    local pattern=""
    for p in "${OPTIONAL_HOST_PATHS[@]}"; do
        if [ ! -d "$p" ]; then
            echo "  Stripping mount for missing path: $p" >&2
            pattern="${pattern:+${pattern}|}Volume=${p}[:/]"
        fi
    done
    if [ -z "$pattern" ]; then
        cat "$file"
    else
        grep -Ev "$pattern" "$file"
    fi
}

# --- Main ---------------------------------------------------------------------

if [ $# -eq 0 ]; then
    setup_transport_local
    install_local
elif [[ "$1" == "virtctl" ]]; then
    shift
    setup_transport_virtctl "$@"
    install_remote
else
    setup_transport_ssh "$1" "${2:-22}"
    install_remote
fi

echo ""
echo "Done! The roxagent will run hourly."
echo ""
echo "To run immediately:  sudo systemctl start roxagent.service"
echo "To view logs:        sudo journalctl -u roxagent.service -f"
echo "To check timer:      sudo systemctl list-timers roxagent.timer"
