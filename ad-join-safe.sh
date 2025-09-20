#!/usr/bin/env bash
set -euo pipefail

# ====== YOUR ENV ======
REALM="ENGLANDGR.COM"
WORKGROUP="ENGLANDGR"
PRIMARY_DC="ucs5.englandgr.com"
NTP_SERVER="10.0.69.2"

IDMAP_STAR_RANGE="3000-7999"
IDMAP_DOMAIN_RANGE="2000-999999"

USE_DEFAULT_DOMAIN="yes"
TEMPLATE_SHELL="/bin/bash"
TEMPLATE_HOMEDIR="/home/%U"

ENABLE_SSHD="yes"
ENABLE_SSH_GSSAPI="yes"

# ====== helpers ======
TS="$(date +%F_%H%M%S)"
backup_cp() { local f="$1"; [[ -f "$f" ]] && cp -a "$f" "${f}.bak.${TS}"; }
require_root() { [[ $EUID -eq 0 ]] || { echo "Run as root."; exit 1; }; }
pkg_install() { pacman -S --needed --noconfirm "$@"; }

die() { echo "ERROR: $*" >&2; exit 1; }

# Ensure we never apply PAM early if something fails
PAM_TOUCHED=0
trap 'if [[ $PAM_TOUCHED -eq 0 ]]; then echo "Aborted before PAM changes. System logins remain intact."; fi' ERR

time_resync() {
  echo "==> Time sync (must be correct before Kerberos)"
  backup_cp /etc/systemd/timesyncd.conf
  # Write/patch NTP= line; do NOT break other settings
  awk -v ntp="$NTP_SERVER" '
    BEGIN{insec=0; have=0}
    /^\[Time\]/{insec=1}
    insec && /^NTP=/{ $0="NTP=" ntp; have=1 }
    {print}
    END{ if(!have){ print "NTP=" ntp } }
  ' /etc/systemd/timesyncd.conf > /etc/systemd/timesyncd.conf.new
  mv /etc/systemd/timesyncd.conf.new /etc/systemd/timesyncd.conf

  systemctl enable --now systemd-timesyncd.service || true
  timedatectl set-ntp true || true
  systemctl restart systemd-timesyncd.service || true

  echo "    Waiting for time sync..."
  # Wait up to ~20s for sync
  for i in {1..10}; do
    if timedatectl timesync-status 2>/dev/null | grep -qi 'server: .*status:.*synchronized\|synchronized: yes'; then
      echo "    Time synchronized."
      return 0
    fi
    sleep 2
  done

  echo "WARNING: Could not confirm sync; continuing anyway. If kinit fails, recheck NTP/DNS."
}

write_krb5_commented_ccache() {
  echo "==> Kerberos config (ccache COMMENTED OUT to avoid winbind breakage pre-join)"
  backup_cp /etc/krb5.conf
  cat > /etc/krb5.conf <<EOF
[libdefaults]
    default_realm = ${REALM}
    dns_lookup_realm = false
    dns_lookup_kdc = true
#   default_ccache_name = /run/user/%{uid}/krb5cc

[realms]
    ${REALM} = {
        kdc = ${PRIMARY_DC}
        admin_server = ${PRIMARY_DC}
        default_domain = ${REALM}
    }

[domain_realm]
    .${REALM,,} = ${REALM}
    ${REALM,,} = ${REALM}

[appdefaults]
    pam = {
        ticket_lifetime = 1d
        renew_lifetime  = 1d
        forwardable     = true
        proxiable       = false
        minimum_uid     = 1
    }
EOF
}

write_smb_conf() {
  echo "==> Samba config"
  backup_cp /etc/samba/smb.conf
  cat > /etc/samba/smb.conf <<EOF
[global]
    workgroup = ${WORKGROUP}
    security = ADS
    realm = ${REALM}

    winbind refresh tickets = Yes
    vfs objects = acl_xattr
    map acl inherit = Yes
    store dos attributes = Yes

    dedicated keytab file = /etc/krb5.keytab
    kerberos method = secrets and keytab

    winbind use default domain = ${USE_DEFAULT_DOMAIN}

    idmap config * : backend = tdb
    idmap config * : range = ${IDMAP_STAR_RANGE}

    idmap config ${WORKGROUP} : backend = rid
    idmap config ${WORKGROUP} : range = ${IDMAP_DOMAIN_RANGE}

    template shell  = ${TEMPLATE_SHELL}
    template homedir = ${TEMPLATE_HOMEDIR}

    winbind offline logon = yes
    winbind enum users = yes
    winbind enum groups = yes
EOF
}

join_domain_before_winbind() {
  echo "==> Domain join (BEFORE starting winbind)"
  # Make sure services are stopped; especially winbind
  systemctl stop winbind.service 2>/dev/null || true
  systemctl stop nmb.service 2>/dev/null || true
  systemctl stop smb.service 2>/dev/null || true

  read -r -p "AD user for kinit/join (e.g. Administrator): " KUSER
  kinit "$KUSER" || die "kinit failed. Check time/DNS/password."
  klist || true

  # net ads join (no OU used)
  net ads join -S "$PRIMARY_DC" -U "$KUSER" || die "Domain join failed"
  echo "Joined domain successfully."
}

enable_services_after_join() {
  echo "==> Start services AFTER join"
  systemctl enable --now smb.service nmb.service
  systemctl enable --now winbind.service
}

nsswitch_update() {
  echo "==> Update nsswitch (safe)"
  backup_cp /etc/nsswitch.conf
  sed -i \
    -e 's/^passwd:.*/passwd: files winbind systemd/' \
    -e 's/^group:.*/group: files winbind [SUCCESS=merge] systemd/' \
    /etc/nsswitch.conf
}

pam_winbind_conf() {
  echo "==> Write /etc/security/pam_winbind.conf"
  backup_cp /etc/security/pam_winbind.conf
  cat > /etc/security/pam_winbind.conf <<'EOF'
[Global]
   debug = no
   debug_state = no
   try_first_pass = yes
   krb5_auth = yes
   krb5_ccache_type = FILE:/run/user/%u/krb5cc
   cached_login = yes
   silent = no
   mkhomedir = yes
EOF
}

domain_smoke_tests() {
  echo "==> Smoke tests (wbinfo/getent)"
  wbinfo -t || die "Trust secret check failed (wbinfo -t)."
  wbinfo -u | head -n 5 || die "wbinfo -u failed."
  wbinfo -g | head -n 5 || die "wbinfo -g failed."
  getent passwd "gchartas" >/dev/null || echo "Note: getent for gchartas didn’t return yet (OK if user not logged in before)."
}

pam_apply_last() {
  echo "==> Apply PAM LAST (only after domain checks pass)"
  backup_cp /etc/pam.d/system-auth
  cat > /etc/pam.d/system-auth <<'EOF'
#%PAM-1.0
auth       required                pam_faillock.so preauth
auth       [success=1 default=bad] pam_winbind.so
auth       [success=1 default=bad] pam_unix.so try_first_pass nullok
auth       [default=die]           pam_faillock.so authfail
auth       optional                pam_permit.so
auth       required                pam_env.so
auth       required                pam_faillock.so authsucc

account    [success=1 default=ignore] pam_winbind.so
account    required                  pam_unix.so
account    optional                  pam_permit.so
account    required                  pam_time.so

password   [success=1 default=ignore] pam_winbind.so
password   required                  pam_unix.so try_first_pass nullok shadow sha512
password   optional                  pam_permit.so

session    required                  pam_mkhomedir.so skel=/etc/skel/ umask=0022
session    required                  pam_limits.so
session    required                  pam_winbind.so
session    required                  pam_unix.so
session    optional                  pam_permit.so
EOF
  PAM_TOUCHED=1
}

configure_sshd() {
  [[ "${ENABLE_SSHD}" == "yes" ]] || return 0
  echo "==> SSHD + GSSAPI"
  pkg_install openssh
  systemctl enable --now sshd.service
  if [[ "${ENABLE_SSH_GSSAPI}" == "yes" ]]; then
    backup_cp /etc/ssh/sshd_config
    if grep -q '^GSSAPIAuthentication' /etc/ssh/sshd_config; then
      sed -i 's/^GSSAPIAuthentication.*/GSSAPIAuthentication yes/' /etc/ssh/sshd_config
    else
      echo "GSSAPIAuthentication yes" >> /etc/ssh/sshd_config
    fi
    systemctl restart sshd.service
  fi
}

maybe_enable_ccache_after_join() {
  echo
  read -r -p "Uncomment default_ccache_name in /etc/krb5.conf now (recommended post-join)? [y/N] " ans
  if [[ "${ans,,}" == "y" ]]; then
    backup_cp /etc/krb5.conf
    sed -i 's/^#\s*default_ccache_name/default_ccache_name/' /etc/krb5.conf
    echo "default_ccache_name uncommented."
  else
    echo "Leaving default_ccache_name commented for now."
  fi
}

# ====== main ======
require_root

echo "==> Installing base packages"
pkg_install samba smbclient cifs-utils bind krb5

time_resync
write_krb5_commented_ccache
write_smb_conf
join_domain_before_winbind
enable_services_after_join
nsswitch_update
pam_winbind_conf
domain_smoke_tests
pam_apply_last
configure_sshd
maybe_enable_ccache_after_join

echo
echo "==> Done."
echo "   - Try: kinit gchartas ; getent passwd gchartas ; id gchartas"
echo "   - First GUI login should auto-create /home/gchartas"
