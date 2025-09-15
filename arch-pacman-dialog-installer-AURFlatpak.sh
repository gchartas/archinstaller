#!/usr/bin/env bash
#
# arch-pacman-dialog-installer-AURFlatpak.sh
# Dialog-driven installer that reads categories from an external config and
# installs via pacman, AUR helper (paru/yay), and Flatpak based on category.
#
# Usage:
#   chmod +x arch-pacman-dialog-installer-AURFlatpak.sh
#   ./arch-pacman-dialog-installer-AURFlatpak.sh [-c /path/to/config]
#
# Debug tips:
#   DEBUG=1 ./arch-pacman-dialog-installer-AURFlatpak.sh -c ./my.conf
#     (disables screen clears, enables xtrace)
#
set -euo pipefail
shopt -s lastpipe

if [[ ${DEBUG:-0} -eq 1 ]]; then set -x; fi

# Require a TTY (dialog needs it)
if [[ ! -t 1 ]]; then
  echo "This script must be run in a terminal (TTY)." >&2
  exit 1
fi

# Clean TTY on exit/Ctrl-C (but don't clear when DEBUG=1)
cleanup() { [[ ${DEBUG:-0} -eq 1 ]] || clear; stty sane || true; }
trap cleanup EXIT INT TERM

# ------------------------------
# Locate & source config (robust)
# ------------------------------
SCRIPT_DIR="$(cd -- "$(dirname -- "$0")" && pwd)"
CONF_FILE=""

# Parse -c anywhere, supporting -c /path and -c=/path
for arg in "$@"; do
  case "$arg" in
    -c) SHIFT_NEXT=1 ;;
    -c=*) CONF_FILE="${arg#*=}" ;;
    *) if [[ ${SHIFT_NEXT:-0} -eq 1 ]]; then CONF_FILE="$arg"; SHIFT_NEXT=0; fi ;;
  esac
done

# If not provided, try env var
if [[ -z "${CONF_FILE}" && -n "${CONFIG-}" ]]; then CONF_FILE="$CONFIG"; fi

# Auto-discover using the script's own basename (with and without .conf)
if [[ -z "${CONF_FILE}" ]]; then
  BASENAME="$(basename -- "$0")"
  BASENAME_NOEXT="${BASENAME%.sh}"
  for candidate in \
    "$SCRIPT_DIR/$BASENAME_NOEXT.conf" \
    "$SCRIPT_DIR/$BASENAME_NOEXT" \
    "$SCRIPT_DIR/arch-pacman-dialog-installer.conf" \
    "$SCRIPT_DIR/packages.conf" \
    "$SCRIPT_DIR/arch-pacman-dialog-installer"; do
    [[ -f "$candidate" ]] && CONF_FILE="$candidate" && break
  done
fi

if [[ -z "${CONF_FILE}" || ! -f "${CONF_FILE}" ]]; then
  echo "Configuration file not found." >&2
  echo "Pass it with -c /path/to/conf or name it like the script: $BASENAME_NOEXT[.conf]" >&2
  exit 1
fi

# shellcheck source=/dev/null
source "$CONF_FILE"

# Validate required symbols from config
# Validate required symbols from config (arrays may be associative)
if ! declare -p CATEGORIES >/dev/null 2>&1; then
  echo "CATEGORIES not defined in config" >&2; exit 1
fi
if ! declare -p CAT_DESC >/dev/null 2>&1; then
  echo "CAT_DESC not defined in config" >&2; exit 1
fi


# Ensure each referenced category has at least an empty array defined
for cat in "${CATEGORIES[@]}"; do
  if ! declare -p "$cat" >/dev/null 2>&1; then
    eval "$cat=()"
  fi
  if [[ -z "${CAT_DESC[$cat]+set}" ]]; then
    CAT_DESC[$cat]="$cat"
  fi
done

TITLE="Arch Installer (pacman + AUR + Flatpak)"
BACKTITLE="Space=toggle, Enter=confirm, Tab=move. Esc/Cancel to go back."
HEIGHT=0; WIDTH=0; MENU_HEIGHT=0

# Preselect behavior: 1 = when entering a category for the FIRST time, all items are preselected
# Set to 0 if you want the previous behavior (all OFF by default)
PRESELECT_ALL_FIRST_TIME=1

# Track whether a category has been visited at least once (to avoid re-enabling everything)
declare -A VISITED_CAT=()


# ------------------------------
# OS & prerequisites
# ------------------------------
if ! [[ -r /etc/os-release ]]; then
  echo "/etc/os-release missing" >&2; exit 1
fi
if ! grep -q '^ID=arch$' /etc/os-release; then
  echo "Warning: designed for Arch Linux (ID=arch)." >&2
fi

if ! command -v dialog >/dev/null 2>&1; then
  echo "Installing 'dialog' (sudo)..."; sudo pacman -Sy --needed --noconfirm dialog || {
    echo "Failed to install 'dialog'. Please install it manually: sudo pacman -S dialog" >&2
    exit 1
  }
fi

# ------------------------------
# Selection tracking
# ------------------------------
declare -A SELECTED_MAP=()

get_selected_count_for_cat() {
  local cat=$1; local -n arr=$cat; local c=0
  for e in "${arr[@]:-}"; do
    local pkg=${e%%|*}; [[ ${SELECTED_MAP[$pkg]:-0} -eq 1 ]] && ((c++))
  done; echo $c
}

build_checklist_items_for_cat() {
  local cat=$1
  local -n arr=$cat
  local items=()
  local first_time=1
  [[ -n "${VISITED_CAT[$cat]+set}" ]] && first_time=0

  for e in "${arr[@]:-}"; do
    local pkg=${e%%|*}
    local desc=${e#*|}
    local state="off"

    if [[ -n "${SELECTED_MAP[$pkg]+set}" ]]; then
      [[ ${SELECTED_MAP[$pkg]:-0} -eq 1 ]] && state="on"
    else
      if [[ $PRESELECT_ALL_FIRST_TIME -eq 1 && $first_time -eq 1 ]]; then
        state="on"
      fi
    fi

    items+=("$pkg" "$desc" "$state")
  done
  printf '%s\n' "${items[@]}"
}


select_packages_for_category() {
  local cat=$1; local desc=${CAT_DESC[$cat]:-$cat}
  local checklist_items; mapfile -t checklist_items < <(build_checklist_items_for_cat "$cat")
  local choices
  choices=$(dialog --backtitle "$BACKTITLE" --title "$TITLE — $cat" \
    --checklist "Select packages in $cat: $desc" \
    $HEIGHT $WIDTH $MENU_HEIGHT "${checklist_items[@]}" \
    3>&1 1>&2 2>&3-)
  local status=$?; [[ ${DEBUG:-0} -eq 1 ]] || clear; [[ $status -ne 0 ]] && return 1
  local -n arr=$cat
  for e in "${arr[@]:-}"; do SELECTED_MAP["${e%%|*}"]=0; done
  read -r -a selected <<< "$choices"
  for t in "${selected[@]:-}"; do t=${t%\"}; t=${t#\"}; SELECTED_MAP[$t]=1; done
  # Mark category as visited to preserve user intent on subsequent opens
  VISITED_CAT[$cat]=1

}

# ------------------------------
# Collect selections by backend
# ------------------------------
collect_selected() {
  PACMAN_PKGS=(); AUR_PKGS=(); FLATPAK_APPS=()
  for cat in "${CATEGORIES[@]}"; do
    local -n arr=$cat
    for e in "${arr[@]:-}"; do
      # skip blank or commented entries
      [[ -z "${e//[[:space:]]/}" ]] && continue
      [[ "${e:0:1}" == "#" ]] && continue

      # get name (left of '|') and skip if still empty
      local name=${e%%|*}
      [[ -z "$name" ]] && continue

      [[ ${SELECTED_MAP[$name]:-0} -ne 1 ]] && continue
      case "$cat" in
        AUR) AUR_PKGS+=("$name") ;;
        FLATPAK) FLATPAK_APPS+=("$name") ;;
        *) PACMAN_PKGS+=("$name") ;;
      esac
    done
  done
}

# ------------------------------
# Ensurers / installers
# ------------------------------
ensure_aur_helper() {
  if command -v paru >/dev/null 2>&1; then AUR_HELPER=paru; return 0; fi
  if command -v yay >/dev/null 2>&1;  then AUR_HELPER=yay;  return 0; fi
  AUR_HELPER=""
  echo "No AUR helper found. Installing paru..."
  # Try official repo first (if present), else build paru-bin from AUR.
  if sudo pacman -Sy --needed --noconfirm paru; then AUR_HELPER=paru; return 0; fi
  echo "Falling back to building paru-bin from AUR (requires base-devel git)."
  sudo pacman -Sy --needed base-devel git --noconfirm || true
  local tmpdir; tmpdir=$(mktemp -d)
  ( set -x; cd "$tmpdir" && git clone https://aur.archlinux.org/paru-bin.git && cd paru-bin && makepkg -si --noconfirm )
  rm -rf "$tmpdir"
  if command -v paru >/dev/null 2>&1; then AUR_HELPER=paru; else echo "Failed to install paru." >&2; return 1; fi
}

DID_INSTALL_FLATPAK=0
ensure_flatpak() {
  if command -v flatpak >/dev/null 2>&1; then return 0; fi
  echo "Installing flatpak..."
  sudo pacman -Sy --needed flatpak --noconfirm || { echo "Failed to install flatpak" >&2; return 1; }
  DID_INSTALL_FLATPAK=1
}

setup_flathub_remote() {
  if ! flatpak remotes | awk '{print $1}' | grep -qx flathub; then
    flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo
  fi
}

install_pacman_pkgs() {
  local -a pkgs=("$@"); [[ ${#pkgs[@]} -eq 0 ]] && return 0
  echo "Installing with pacman: ${pkgs[*]}"
  sudo pacman -S --needed "${pkgs[@]}"
}

install_aur_pkgs() {
  local -a pkgs=("$@"); [[ ${#pkgs[@]} -eq 0 ]] && return 0
  ensure_aur_helper || return 1
  echo "Installing with $AUR_HELPER (AUR): ${pkgs[*]}"
  if [[ $AUR_HELPER == paru ]]; then
    paru -S --needed "${pkgs[@]}"
  else
    yay -S --needed "${pkgs[@]}"
  fi
}

install_flatpak_apps() {
  local -a apps=("$@"); [[ ${#apps[@]} -eq 0 ]] && return 0
  ensure_flatpak || return 1
  setup_flathub_remote
  echo "Installing with flatpak: ${apps[*]}"
  for app in "${apps[@]}"; do
    local remote="flathub" id="$app"
    if [[ $app == *:* ]]; then remote="${app%%:*}"; id="${app#*:}"; fi
    flatpak install -y "$remote" "$id"
  done
}

# ------------------------------
# Review & install
# ------------------------------
review_and_install() {
  collect_selected
  local pcount=${#PACMAN_PKGS[@]} acount=${#AUR_PKGS[@]} fcount=${#FLATPAK_APPS[@]}
  if (( pcount + acount + fcount == 0 )); then
    dialog --backtitle "$BACKTITLE" --title "$TITLE" --msgbox "No items selected." 7 40; [[ ${DEBUG:-0} -eq 1 ]] || clear; return
  fi

  local msg="Selections:
"
  msg+="  • pacman:  $pcount
"
  msg+="  • AUR:     $acount
"
  msg+="  • Flatpak: $fcount

Proceed with installation?"
  dialog --backtitle "$BACKTITLE" --title "$TITLE" --yesno "$msg" 12 50
  local yn=$?; [[ ${DEBUG:-0} -eq 1 ]] || clear; [[ $yn -ne 0 ]] && return

  echo "Using config: $CONF_FILE"
  echo "Syncing package databases..."; sudo pacman -Sy --needed --noconfirm || true
  echo
  (( pcount > 0 )) && install_pacman_pkgs "${PACMAN_PKGS[@]}"
  (( acount > 0 )) && install_aur_pkgs    "${AUR_PKGS[@]}"
  (( fcount > 0 )) && install_flatpak_apps "${FLATPAK_APPS[@]}"

  local status="Finished. pacman=$pcount, AUR=$acount, Flatpak=$fcount."
  if (( DID_INSTALL_FLATPAK == 1 )); then
    dialog --backtitle "$BACKTITLE" --title "$TITLE" \
      --yes-label "Reboot now" --no-label "Back to menu" \
      --yesno "Flatpak was just installed. A reboot is recommended to ensure session integration. Reboot now?" 12 60
    local rb=$?; [[ ${DEBUG:-0} -eq 1 ]] || clear
    if [[ $rb -eq 0 ]]; then
      echo "Rebooting..."; sudo systemctl reboot
    fi
  else
    dialog --backtitle "$BACKTITLE" --title "$TITLE" \
      --yes-label "Exit" --no-label "Back to menu" \
      --yesno "$status

Exit now?" 10 60
    local post=$?; [[ ${DEBUG:-0} -eq 1 ]] || clear; [[ $post -eq 0 ]] && exit 0
  fi
}

clear_selections() { for k in "${!SELECTED_MAP[@]}"; do SELECTED_MAP[$k]=0; done; }

# ------------------------------
# Main menu
# ------------------------------
while true; do
  MENU_ITEMS=()
  for cat in "${CATEGORIES[@]}"; do
    cnt=$(get_selected_count_for_cat "$cat")
    MENU_ITEMS+=("$cat" "${CAT_DESC[$cat]} — selected: $cnt")
  done
  MENU_ITEMS+=("INSTALL" "Review & install selections")
  MENU_ITEMS+=("CLEAR"   "Clear all selections")
  MENU_ITEMS+=("QUIT"    "Exit without installing")

  choice=$(dialog --backtitle "$BACKTITLE" --title "$TITLE" \
    --menu "Choose a category, or INSTALL when ready:" \
    $HEIGHT $WIDTH $MENU_HEIGHT "${MENU_ITEMS[@]}" \
    3>&1 1>&2 2>&3-)
  status=$?; [[ ${DEBUG:-0} -eq 1 ]] || clear; [[ $status -ne 0 ]] && break
  case "$choice" in
    INSTALL) review_and_install ;;
    CLEAR)   clear_selections ;;
    QUIT)    break ;;
    *)       select_packages_for_category "$choice" || true ;;
  esac

done

# End
