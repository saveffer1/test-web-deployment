#!/usr/bin/env bash
#===============================================================================
# Script: full-auto-ansible-ssh-setup.sh
# Description: Automates SSH key creation (.pem), distribution via ssh-copy-id using
#              correct host IPs, connectivity verification with Ansible ping,
#              and idempotent authorized_key enforcement.
# Usage: sudo ./full-auto-ansible-ssh-setup.sh
# Tested on: Ubuntu 22.04 LTS
#===============================================================================

set -euo pipefail

NC='\033[0m'; BLUE='\033[1;34m'; GREEN='\033[1;32m'; YELLOW='\033[1;33m'; RED='\033[1;31m'; CYAN='\033[1;36m'; BOLD='\033[1m'

if [ "$(id -u)" -ne 0 ]; then
  echo -e "${RED}${BOLD}ERROR:${NC} This script must be run as root (sudo)." >&2
  exit 1
fi

read -rp "$(echo -e ${BOLD}Enter\ SSH\ username:${NC}\ )" SSH_USER
read -s -p "$(echo -e ${BOLD}Enter\ SSH\ password:${NC}\ )" SSH_PASS
echo

INVENTORY_FILE="inventory.ini"
GROUP="client_hosts"
KEYS_DIR="./keys"
EMAIL="your_email@example.com"
PRIVATE_KEY="${KEYS_DIR}/ansibleSSH.pem"
PUBLIC_KEY="${PRIVATE_KEY}.pub"

echo -e "${BLUE}[${BOLD}STEP 1${NC}${BLUE}] Installing dependencies...${NC}"
apt-get -y -q update
apt-get install -y -q software-properties-common sshpass
if ! command -v ansible &>/dev/null; then
  apt-add-repository -y ppa:ansible/ansible
  apt-get update -y -q
  apt-get install -y -q ansible
else
  echo -e "${GREEN}✓ Ansible already installed.${NC}"
fi
echo -e "${GREEN}✓ Dependencies installed successfully.${NC}"

echo -e "${BLUE}[${BOLD}STEP 2${NC}${BLUE}] Generating or converting SSH key...${NC}"
mkdir -p "${KEYS_DIR}"
chmod 700 "${KEYS_DIR}"
[ -f "${PRIVATE_KEY}" ] && rm -f "${PRIVATE_KEY}"
[ -f "${PRIVATE_KEY}.pub" ] && rm -f "${PRIVATE_KEY}.pub"
ssh-keygen -t rsa -b 4096 -f "${PRIVATE_KEY}" -N "" -q -C "${EMAIL}"
chmod 600 "${PRIVATE_KEY}"
chmod 644 "${PUBLIC_KEY}"
echo -e "${GREEN}✓ SSH key generated at ${PRIVATE_KEY}.${NC}"

echo -e "${BLUE}[${BOLD}STEP 3${NC}${BLUE}] Distributing SSH public key to remote hosts...${NC}"

get_hosts_for_ssh_copy_id() {
  awk '/ansible_ssh_host=/ {print $1, gensub(/.*=(.*)$/, "\\1", "g")}' "$1"
}

echo -e "${CYAN}DEBUG:${NC} Attempting to use inventory file: '${INVENTORY_FILE}'"
if [ ! -f "$INVENTORY_FILE" ]; then
  echo -e "${RED}ERROR:${NC} Inventory file '${INVENTORY_FILE}' does NOT exist." >&2
  exit 1
else
  echo -e "${CYAN}DEBUG:${NC} Inventory file '${INVENTORY_FILE}' found."
fi

HOST_IPS=$(get_hosts_for_ssh_copy_id "$INVENTORY_FILE")
if [ -z "$HOST_IPS" ]; then
  echo -e "${RED}ERROR:${NC} No hosts with 'ansible_ssh_host' found." >&2
  exit 1
fi

printf '%s\n' "$HOST_IPS" | while read -r hostname ip_address; do
  echo -e "➡️  Attempting to copy key for '${YELLOW}${hostname}${NC}' (${ip_address})..."

  if err=$(sshpass -p "$SSH_PASS" \
         ssh-copy-id -i "$PUBLIC_KEY" \
         -o StrictHostKeyChecking=accept-new \
         -o ConnectTimeout=8 \
         "${SSH_USER}@${ip_address}" 2>&1 >/dev/null); then
    echo -e "${GREEN}✓ Successfully copied key to '${hostname}'.${NC}"
  else
    case "$err" in
      *"No route to host"*)   echo -e "${RED}⚠️ '${hostname}' unreachable.${NC}" ;;
      *"Permission denied"*)  echo -e "${RED}🚫 '${hostname}' auth failed.${NC}" ;;
      *)                      echo -e "${RED}❌ '${hostname}' unknown error.${NC}" ;;
    esac
  fi

  echo -e "${CYAN}----------------------------------------------------${NC}"
done


echo -e "${GREEN}✓ SSH public key distribution finished.${NC}"

echo -e "${BLUE}[${BOLD}STEP 4${NC}${BLUE}] Verifying connectivity with Ansible ping...${NC}"

if ansible -i "$INVENTORY_FILE" all -m ping -u "$SSH_USER" --private-key="$PRIVATE_KEY" -o ; then
  echo -e "${GREEN}✓ Ansible ping successful for all reachable hosts.${NC}"
else
  echo -e "${YELLOW}⚠️  Some hosts were unreachable:${NC}" >&2
  ansible -i "$INVENTORY_FILE" all -m ping -u "$SSH_USER" --private-key="$PRIVATE_KEY" -o 2>/dev/null | grep -E 'UNREACHABLE!|FAILED!' || true
fi
echo -e "${GREEN}${BOLD}All done.${NC}"
