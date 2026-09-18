
#!/usr/bin/env bash
# This program requires Bash. Do not invoke it as: sh tcaut11.sh ...
if [ -z "${BASH_VERSION:-}" ]; then
    echo "ERROR: tcaut11.sh must be run with bash, not sh." >&2
    echo "Use: bash tcaut11.sh ...   or   ./tcaut11.sh ..." >&2
    exit 2
fi
#
# tcaut11.sh V6
#
# Oracle AI Database 26ai True Cache Automation
#
# Features
# --------
#  * Can be launched from PRIMARY, TRUE CACHE, or third/admin host
#  * Local execution never SSHs to itself
#  * Password SSH supported with ControlMaster/ControlPersist
#  * Automatic PRIMARY SID discovery
#  * Oracle Home discovery independent of current shell ORACLE_HOME
#  * Multiple Oracle Homes supported
#  * Fresh True Cache host supported (no PMON required)
#  * /etc/oratab is treated as a hint, NOT proof of a valid Oracle Home
#  * Oracle inventory/common path discovery
#  * ORACLE_BASE/orabasetab validation
#  * ORACLE_BASE_HOME / ORACLE_BASE_CONFIG normalization
#  * PATH / LD_LIBRARY_PATH normalization
#  * Stale Oracle Home detection
#  * DBCA/sqlplus/oracle/lsnrctl validation
#  * Primary ARCHIVELOG/CDB/PRIMARY validation
#  * Primary -> TC network validation
#  * DBCA True Cache BLOB preparation
#  * BLOB transfer through execution host
#  * True Cache creation
#  * Optional service configuration
#  * Optional redo transport configuration
#  * True Cache verification
#  * SCN advancement verification
#  * V$TRUE_CACHE verification
#  * HTML + log report
#
# IMPORTANT
# ---------
# Oracle 26ai database software must already be installed on the
# True Cache host. This script configures True Cache; it does not
# install Oracle Database software.
#
# Usage:
#
#   ./tcaut1.sh \
#       --primary-host x26aisvr \
#       --primary-user oracle \
#       --tc-host x26aisvrtc \
#       --tc-user oracle
#
# Useful options:
#
#   --primary-sid x26ai
#   --primary-oracle-home /u01/app/oracle/product/26ai/dbhome_1
#   --tc-oracle-home /u01/app/oracle/product/26ai/dbhome_1
#   --primary-port 22
#   --tc-port 22
#   --listener-port 1521
#   --primary-ezconnect host:1521/service
#   --primary-service SERVICE
#   --pdb PDB1
#   --tc-sid X26AI_TC
#   --tc-gdb-name X26AI_TC
#   --tc-service SERVICE_TC
#   --sga-mb 4096
#   --pga-mb 1024
#   --listener LISTENER
#   --redo-transport async|sync
#   --skip-service
#   --skip-vncr-check
#   --allow-existing-log-archive-config
#   --dry-run
#   --yes
#   --keep-artifacts
#
# Exit codes:
#   0 = success
#   1 = failure
#
set -u
set -o pipefail
VERSION="6.1"
###############################################################################
# GLOBALS
###############################################################################
SCRIPT_NAME="$(basename "$0")"
RUN_ID="$(date '+%Y%m%d_%H%M%S')"
START_TIME="$(date '+%Y-%m-%d %H:%M:%S')"
EXEC_HOST="$(hostname -s 2>/dev/null || hostname)"
WORK_ROOT="${TMPDIR:-/tmp}/truecache_deploy"
WORK_DIR="$WORK_ROOT/$RUN_ID"
SSH_DIR="/tmp/tcaut11_ssh_${UID}"
PRIMARY_CTL="$SSH_DIR/p.sock"
TC_CTL="$SSH_DIR/t.sock"
mkdir -p "$WORK_DIR" "$SSH_DIR" 2>/dev/null || {
    echo "ERROR: Cannot create work directory."
    exit 1
}
chmod 700 "$WORK_DIR" "$SSH_DIR" 2>/dev/null || true
LOG_FILE="$WORK_DIR/${SCRIPT_NAME%.sh}_${RUN_ID}.log"
HTML_FILE="$WORK_DIR/truecache_${RUN_ID}.html"
touch "$LOG_FILE" 2>/dev/null || {
    echo "ERROR: Cannot create $LOG_FILE"
    exit 1
}
exec > >(tee -a "$LOG_FILE") 2>&1
###############################################################################
# DEFAULTS
###############################################################################
PRIMARY_HOST=""
PRIMARY_USER="oracle"
PRIMARY_ADMIN_USER="oracle"
PRIMARY_SSH_PORT="22"
TC_HOST=""
TC_USER="oracle"
TC_ADMIN_USER="oracle"
TC_SSH_PORT="22"
PRIMARY_SID=""
PRIMARY_OH=""
PRIMARY_BASE=""
TC_SID=""
TC_GDB=""
TC_OH=""
TC_BASE=""
PRIMARY_DB_NAME=""
PRIMARY_DB_UNIQUE=""
PRIMARY_SERVICE=""
PRIMARY_EZ=""
PRIMARY_CDB_SERVICE=""
PDB_NAME=""
TC_SERVICE=""
LISTENER_NAME="LISTENER"
LISTENER_PORT="1521"
SGA_MB=""
PGA_MB=""
FLASH_CACHE_MB=""
REDO_TRANSPORT=""
SKIP_SERVICE=0
SKIP_VNCR=0
ALLOW_EXISTING_LOG_ARCHIVE_CONFIG=0
TC_LOG_ARCHIVE_DEST=""
DRY_RUN=0
AUTO_YES=0
KEEP_ARTIFACTS=0
PRIMARY_CLUSTER="NO"
PRIMARY_SSH_MODE=""
TC_SSH_MODE=""
BLOB_PRIMARY=""
BLOB_LOCAL=""
BLOB_TC=""
TC_CDB_SERVICE=""
TC_SERVICE_EXISTING_ON_PRIMARY=0
PRIMARY_SERVICE_CREATED=0

# True Cache sizing / AWR evidence calculated from Primary AWR history.
PRIMARY_AWR_BID=""
PRIMARY_AWR_EID=""
PRIMARY_AWR_BEGIN=""
PRIMARY_AWR_END=""
PRIMARY_AWR_DB_TIME_SEC=""
PRIMARY_AWR_AAS=""
PRIMARY_AWR_REPORT=""
PRIMARY_AWR_LOCAL=""
TC_READ_ONLY_PCT=""
TC_PRIMARY_BUFFER_MB=""
TC_SHARED_POOL_MB=""
TC_PRIMARY_SGA_TARGET_MB=""
TC_PRIMARY_PGA_TARGET_MB=""
TC_PRIMARY_PGA_MAX_MB=""
TC_OTHER_SGA_MB=""
TC_RECOMMENDED_BUFFER_MB=""
TC_RECOMMENDED_SGA_MB=""
TC_RECOMMENDED_PGA_MB=""
TC_FLASH_CACHE_MB=""
TC_FLASH_METADATA_MB=""
TC_BUFFER_CACHE_HIT_PCT=""
TC_TRUE_CACHE_HIT_PCT=""
DEPLOY_STATUS="NOT STARTED"
FAIL_REASON=""
ERRORS=""
WARNINGS=""
###############################################################################
# OUTPUT
###############################################################################
timestamp() {
    date '+%Y-%m-%d %H:%M:%S'
}
log() {
    printf '%s | INFO  | %s\n' "$(timestamp)" "$*"
}
warn() {
    printf '%s | WARN  | %s\n' "$(timestamp)" "$*"
    if [ -n "$WARNINGS" ]; then WARNINGS="$WARNINGS
$*"; else WARNINGS="$*"; fi
}
error() {
    printf '%s | ERROR | %s\n' "$(timestamp)" "$*"
    if [ -n "$ERRORS" ]; then ERRORS="$ERRORS
$*"; else ERRORS="$*"; fi
}
die() {
    error "$*"
    FAIL_REASON="$*"
    exit 1
}
section() {
    echo
    echo "============================================================"
    echo "$*"
    echo "============================================================"
}
###############################################################################
# USAGE
###############################################################################
usage() {
cat <<EOF
$SCRIPT_NAME V$VERSION
Oracle 26ai True Cache
automation.
Required:
  --primary-host HOST
  --tc-host HOST
Optional:
  --primary-user USER                 SSH/login user
  --primary-admin-user USER           OS user for Oracle administration
  --tc-user USER                      SSH/login user
  --tc-admin-user USER                OS user for Oracle administration
  --primary-port PORT
  --tc-port PORT
  --primary-sid SID
  --primary-oracle-home HOME
  --tc-oracle-home HOME
  --primary-service SERVICE
  --primary-ezconnect HOST\:PORT/SERVICE
  --pdb PDB
  --tc-sid SID
  --tc-gdb-name GDBNAME
  --tc-service SERVICE
  --listener NAME
  --listener-port PORT
  --sga-mb MB
  --pga-mb MB
  --flash-cache-mb MB
  --redo-transport async|sync
Flags:
  --skip-service
  --skip-vncr-check
  --allow-existing-log-archive-config
  --dry-run
  --yes
  --keep-artifacts
  --help
Examples:
  $SCRIPT_NAME \\
      --primary-host x26aisvr \\
      --primary-user oracle \\
      --tc-host x26aisvrtc \\
      --tc-user oracle
  $SCRIPT_NAME \\
      --primary-host x26aisvr \\
      --tc-host x26aisvrtc \\
      --primary-oracle-home /u01/app/oracle/product/26ai/dbhome_1
\\
      --tc-oracle-home
/u01/app/oracle/product/26ai/dbhome_1 \\
      --primary-ezconnect x26aisvr:1521/X26AI
EOF
}
###############################################################################
# ARGUMENT PARSER
###############################################################################
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --primary-host)
                [[ $# -ge 2 ]] || die "Missing value for --primary-host"
                PRIMARY_HOST="$2"
                shift 2
                ;;
            --tc-host)
                [[ $# -ge 2 ]] || die "Missing value for --tc-host"
                TC_HOST="$2"
                shift 2
                ;;
            --primary-user)
                [[ $# -ge 2 ]] || die "Missing value for --primary-user"
                PRIMARY_USER="$2"
                shift 2
                ;;
            --primary-admin-user)
                [[ $# -ge 2 ]] || die "Missing value for --primary-admin-user"
                PRIMARY_ADMIN_USER="$2"
                shift 2
                ;;
            --tc-user)
                [[ $# -ge 2 ]] || die "Missing value for --tc-user"
                TC_USER="$2"
                shift 2
                ;;
            --tc-admin-user)
                [[ $# -ge 2 ]] || die "Missing value for --tc-admin-user"
                TC_ADMIN_USER="$2"
                shift 2
                ;;
            --primary-port)
                [[ $# -ge 2 ]] || die "Missing value for --primary-port"
                PRIMARY_SSH_PORT="$2"
                shift 2
                ;;
            --tc-port)
                [[ $# -ge 2 ]] || die "Missing value for --tc-port"
                TC_SSH_PORT="$2"
                shift 2
                ;;
            --primary-sid)
                [[ $# -ge 2 ]] || die "Missing value for --primary-sid"
                PRIMARY_SID="$2"
                shift 2
                ;;
            --primary-oracle-home)
                [[ $# -ge 2 ]] || die "Missing value for --primary-oracle-home"
                PRIMARY_OH="$2"
                shift 2
                ;;
            --tc-oracle-home)
                [[ $# -ge 2 ]] || die "Missing value for --tc-oracle-home"
                TC_OH="$2"
                shift 2
                ;;
            --primary-service)
                [[ $# -ge 2 ]] || die "Missing value for --primary-service"
                PRIMARY_SERVICE="$2"
                shift 2
                ;;
            --primary-ezconnect)
                [[ $# -ge 2 ]] || die "Missing value for --primary-ezconnect"
                PRIMARY_EZ="$2"
                shift 2
                ;;
            --pdb)
                [[ $# -ge 2 ]] || die "Missing value for --pdb"
                PDB_NAME="$2"
                shift 2
                ;;
            --tc-sid)
                [[ $# -ge 2 ]] || die "Missing value for --tc-sid"
                TC_SID="$2"
                shift 2
                ;;
            --tc-gdb-name)
                [[ $# -ge 2 ]] || die "Missing value for --tc-gdb-name"
                TC_GDB="$2"
                shift 2
                ;;
            --tc-service)
                [[ $# -ge 2 ]] || die "Missing value for --tc-service"
                TC_SERVICE="$2"
                shift 2
                ;;
            --listener)
                [[ $# -ge 2 ]] || die "Missing value for --listener"
                LISTENER_NAME="$2"
                shift 2
                ;;
            --listener-port)
                [[ $# -ge 2 ]] || die "Missing value for --listener-port"
                LISTENER_PORT="$2"
                shift 2
                ;;
            --sga-mb)
                [[ $# -ge 2 ]] || die "Missing value for --sga-mb"
                SGA_MB="$2"
                shift 2
                ;;
            --pga-mb)
                [[ $# -ge 2 ]] || die "Missing value for --pga-mb"
                PGA_MB="$2"
                shift 2
                ;;
            --flash-cache-mb)
                [[ $# -ge 2 ]] || die "Missing value for --flash-cache-mb"
                FLASH_CACHE_MB="$2"
                shift 2
                ;;
            --redo-transport)
                [[ $# -ge 2 ]] || die "Missing value for --redo-transport"
                REDO_TRANSPORT="${2,,}"
                shift 2
                ;;
            --skip-service)
                SKIP_SERVICE=1
                shift
                ;;
            --skip-vncr-check)
                SKIP_VNCR=1
                shift
                ;;
            --allow-existing-log-archive-config)
                ALLOW_EXISTING_LOG_ARCHIVE_CONFIG=1
                shift
                ;;
            --dry-run)
                DRY_RUN=1
                shift
                ;;
            --yes)
                AUTO_YES=1
                shift
                ;;
            --keep-artifacts)
                KEEP_ARTIFACTS=1
                shift
                ;;
            --help|-h)
                usage
                exit 0
                ;;
            *)
                die "Unknown argument: $1"
                ;;
        esac
    done
}
###############################################################################
# BASIC VALIDATION
###############################################################################
validate_host_value() {
    local name="$1"
    local value="$2"
    [[ -n "$value" ]] || die "$name cannot be empty"
    if [[ "$value" =~ [[:space:]] ]]; then
        die "$name contains whitespace: $value"
    fi
}
validate_port() {
    local name="$1"
    local p="$2"
    [[ "$p" =~ ^[0-9]+$ ]] ||
        die "$name must be numeric: $p"
    (( p >= 1 && p <= 65535 )) ||
        die "$name outside valid range: $p"
}
validate_oracle_name() {
    local label="$1"
    local value="$2"
    [[ "$value" =~ ^[A-Za-z][A-Za-z0-9_\$#]*$ ]] ||
        die "$label '$value' is not a valid Oracle identifier"
    (( ${#value} <= 128 )) ||
        die "$label '$value' exceeds 128 characters"
}
###############################################################################
# LOCAL HOST DETECTION
###############################################################################
get_local_ips() {
    {
        hostname -I 2>/dev/null || true
        if command -v ip >/dev/null 2>&1; then
            ip -4 addr show 2>/dev/null |
                awk '/inet / {sub(/\/.*/,
"", $2); print $2}'
        fi
    } | awk 'NF' | sort -u
}
get_target_ips() {
    local host="$1"
    if command -v getent >/dev/null 2>&1; then
        getent ahostsv4 "$host" 2>/dev/null |
            awk '{print $1}' |
            sort -u
    fi
}
is_local_host() {
    local target="$1"
    local short
    local fqdn
    local names
    local ips
    local target_ips
    short="$(hostname -s 2>/dev/null || true)"
    fqdn="$(hostname -f 2>/dev/null || true)"
    names="$(printf '%s\n%s\n%s\nlocalhost\n127.0.0.1\n' \
        "$short" "$fqdn" "$(hostname 2>/dev/null || true)")"
    if printf '%s\n' "$names" | grep -Fxq "$target"; then
        return 0
    fi
    ips="$(get_local_ips)"
    target_ips="$(get_target_ips "$target")"
    if [[ -n "$target_ips" ]]; then
        while IFS= read -r ip; do
            [[ -n "$ip" ]] || continue
            if printf '%s\n' "$ips" | grep -Fxq "$ip"; then
                return 0
            fi
        done <<< "$target_ips"
    fi
    return 1
}
###############################################################################
# TCP CHECK
###############################################################################
tcp_reachable() {
    local host="$1"
    local port="$2"
    if command -v nc >/dev/null 2>&1; then
        nc -z -w 5 "$host" "$port" >/dev/null 2>&1
        return $?
    fi
    if command -v timeout >/dev/null 2>&1; then
        timeout 5 bash -c "</dev/tcp/$host/$port" \
            >/dev/null 2>&1
        return $?
    fi
    bash -c "</dev/tcp/$host/$port" \
        >/dev/null 2>&1
}
###############################################################################
# SSH
###############################################################################
role_host() {
    case "$1" in
        PRIMARY) printf '%s' "$PRIMARY_HOST" ;;
        TRUECACHE) printf '%s' "$TC_HOST" ;;
        *) return 1 ;;
    esac
}
role_user() {
    case "$1" in
        PRIMARY) printf '%s' "$PRIMARY_USER" ;;
        TRUECACHE) printf '%s' "$TC_USER" ;;
        *) return 1 ;;
    esac
}
role_admin_user() {
    case "$1" in
        PRIMARY) printf '%s' "$PRIMARY_ADMIN_USER" ;;
        TRUECACHE) printf '%s' "$TC_ADMIN_USER" ;;
        *) return 1 ;;
    esac
}
role_port() {
    case "$1" in
        PRIMARY) printf '%s' "$PRIMARY_SSH_PORT" ;;
        TRUECACHE) printf '%s' "$TC_SSH_PORT" ;;
        *) return 1 ;;
    esac
}
role_socket() {
    case "$1" in
        PRIMARY) printf '%s' "$PRIMARY_CTL" ;;
        TRUECACHE) printf '%s' "$TC_CTL" ;;
        *) return 1 ;;
    esac
}
role_mode_set() {
    case "$1" in
        PRIMARY) PRIMARY_SSH_MODE="$2" ;;
        TRUECACHE) TC_SSH_MODE="$2" ;;
    esac
}
role_mode_get() {
    case "$1" in
        PRIMARY) printf '%s' "$PRIMARY_SSH_MODE" ;;
        TRUECACHE) printf '%s' "$TC_SSH_MODE" ;;
    esac
}
ssh_common_opts() {
    local role="$1"
    local socket
    socket="$(role_socket "$role")"
    printf '%s\n' \
        -o ConnectTimeout=10 \
        -o ServerAliveInterval=15 \
        -o ServerAliveCountMax=2 \
        -o StrictHostKeyChecking=accept-new \
        -o ControlMaster=auto \
        -o ControlPersist=600 \
        -o ControlPath="$socket"
}
ensure_connection() {
    local role="$1"
    local host user admin port socket
    local -a opts
    host="$(role_host "$role")"
    user="$(role_user "$role")"
    admin="$(role_admin_user "$role")"
    port="$(role_port "$role")"
    socket="$(role_socket "$role")"

    if is_local_host "$host"; then
        role_mode_set "$role" "LOCAL"
        log "$role is local: $host"

        # If already the administrative user, no sudo/su is necessary.
        if [[ "$(id -un)" == "$admin" ]]; then
            log "$role local execution user is already administrative user: $admin"
            return 0
        fi

        if [[ "$user" == "$admin" ]]; then
            die "$role is local but current OS user '$(id -un)' is not the requested administrative user '$admin'."
        fi

        # IMPORTANT: sudo authenticates the INVOKING USER ($user/current user),
        # never the target administrative user.  The target user's password is
        # neither requested nor used.  Validate the exact escalation command
        # that will be used later: sudo su - <admin>.
        log "$role local SSH/login user: $user"
        log "$role administrative user: $admin"
        log "Validating 'sudo su - $admin'. If prompted, enter the password of '$user', not '$admin'."
        if ! sudo su - "$admin" >/dev/null <<'EOF'
id -un
exit
EOF
        then
            die "Unable to execute 'sudo su - $admin' on local host. Enter the password of the current/login user '$user'; the '$admin' password is never requested."
        fi
        log "$role sudo su - $admin: OK (authenticated as $(id -un))"
        return 0
    fi

    log "Testing SSH to $role: $user@$host:$port"
    mapfile -t opts < <(ssh_common_opts "$role")
    if ssh -p "$port" "${opts[@]}" -o BatchMode=yes "$user@$host" true >/dev/null 2>&1; then
        role_mode_set "$role" "KEY"
        log "$role SSH authentication: passwordless/key based"
    else
        log "Keyless SSH unavailable for $role."
        if ! tcp_reachable "$host" "$port"; then
            die "$role TCP/$port unreachable at $host. Password will NOT be requested."
        fi
        log "$role TCP/$port reachable."
        log "Opening SSH ControlMaster for $role."
        log "If SSH authentication requires a password, enter the password of login user '$user' (not '$admin')."
        rm -f "$socket" 2>/dev/null || true
        if ssh -p "$port" "${opts[@]}" "$user@$host" true; then
            role_mode_set "$role" "PASSWORD"
            log "$role SSH ControlMaster established."
        else
            die "Unable to establish SSH connection to $role: $user@$host:$port"
        fi
    fi

    if [[ "$user" != "$admin" ]]; then
        log "$role SSH/login user: $user"
        log "$role administrative user: $admin"
        log "Validating 'sudo su - $admin' on $host. If prompted, enter the password of '$user'. Do NOT enter the '$admin' password."

        # Use a real SSH terminal for the one-time sudo authentication. This
        # runs the exact command permitted by the user's existing sudo policy.
        # No sudoers change is performed and no admin/oracle password is used.
        if ! ssh -tt \
            -o RequestTTY=force \
            -o ControlMaster=no \
            -o ControlPath=none \
            -o ConnectTimeout=10 \
            -o ServerAliveInterval=15 \
            -o ServerAliveCountMax=2 \
            -o StrictHostKeyChecking=accept-new \
            -p "$port" \
            "$user@$host" \
            "sudo su - $(printf '%q' "$admin")" <<'EOF'
id -un
exit
EOF
        then
            die "Unable to execute 'sudo su - $admin' on $host. If prompted, enter the password of login user '$user'. The '$admin' password is never requested."
        fi
        log "$role sudo su - $admin: OK; sudo authentication cached for subsequent commands"
    fi
}
role_exec() {
    local role="$1"
    local script="$2"
    local user admin
    user="$(role_user "$role")"
    admin="$(role_admin_user "$role")"

    if [[ "$(role_mode_get "$role")" == "LOCAL" ]]; then
        if [[ "$(id -un)" == "$admin" ]]; then
            bash -s <<< "$script"
        else
            # sudo authenticates the current/login user.  The sudo timestamp
            # was established by ensure_connection using sudo -v.  The only
            # privileged command is 'su', matching the user's required model.
            sudo su - "$admin" <<< "$script"
        fi
        return $?
    fi

    local host port
    local -a opts
    host="$(role_host "$role")"
    port="$(role_port "$role")"
    mapfile -t opts < <(ssh_common_opts "$role")

    if [[ "$user" == "$admin" ]]; then
        ssh -p "$port" "${opts[@]}" "$user@$host" 'bash -s' <<< "$script"
    else
        # sudo was authenticated earlier through a real SSH tty.  Reuse the
        # ControlMaster for the actual command; no oracle/admin password is
        # ever supplied.  sudo executes only 'su', and su creates the oracle
        # login environment before bash reads the supplied script.
        ssh -p "$port" "${opts[@]}" "$user@$host" \
            "sudo su - $(printf '%q' "$admin")" <<< "$script"
    fi
}
role_exec_tty() {
    local role="$1"
    local script="$2"
    local user admin
    user="$(role_user "$role")"
    admin="$(role_admin_user "$role")"

    if [[ "$(role_mode_get "$role")" == "LOCAL" ]]; then
        if [[ "$(id -un)" == "$admin" ]]; then
            bash -s < /dev/tty <<< "$script"
        else
            # The sudo timestamp was authenticated as the current/login user.
            sudo su - "$admin" <<< "$script"
        fi
        return $?
    fi

    local host port
    host="$(role_host "$role")"
    port="$(role_port "$role")"

    if [[ "$user" == "$admin" ]]; then
        ssh -tt -o RequestTTY=force -o ControlMaster=no -o ControlPath=none \
            -o ConnectTimeout=10 -o ServerAliveInterval=15 -o ServerAliveCountMax=2 \
            -o StrictHostKeyChecking=accept-new -p "$port" "$user@$host" \
            'bash -s' <<< "$script"
    else
        ssh -tt -o RequestTTY=force -o ControlMaster=no -o ControlPath=none \
            -o ConnectTimeout=10 -o ServerAliveInterval=15 -o ServerAliveCountMax=2 \
            -o StrictHostKeyChecking=accept-new -p "$port" "$user@$host" \
            "sudo su - $(printf '%q' "$admin")" <<< "$script"
    fi
}
role_capture() {
    local role="$1"
    local script="$2"
    local user admin
    user="$(role_user "$role")"
    admin="$(role_admin_user "$role")"

    if [[ "$(role_mode_get "$role")" == "LOCAL" ]]; then
        if [[ "$(id -un)" == "$admin" ]]; then
            bash -s <<< "$script"
        else
            sudo su - "$admin" <<< "$script"
        fi
        return $?
    fi

    local host port
    local -a opts
    host="$(role_host "$role")"
    port="$(role_port "$role")"
    mapfile -t opts < <(ssh_common_opts "$role")

    if [[ "$user" == "$admin" ]]; then
        ssh -p "$port" "${opts[@]}" "$user@$host" 'bash -s' <<< "$script"
    else
        ssh -p "$port" "${opts[@]}" "$user@$host" \
            "sudo su - $(printf '%q' "$admin")" <<< "$script"
    fi
}
role_copy_to() {
    local role="$1"
    local src="$2"
    local dest="$3"
    local user admin
    user="$(role_user "$role")"
    admin="$(role_admin_user "$role")"

    if [[ "$(role_mode_get "$role")" == "LOCAL" ]]; then
        if [[ "$user" == "$admin" || "$(id -un)" == "$admin" ]]; then
            cp -f -- "$src" "$dest"
            return $?
        fi
        # Sudo policy may allow only: sudo su - oracle.
        # Send a shell script to that login shell; do not sudo cp/tee directly.
        local encoded
        encoded="$(base64 -w 0 -- "$src")" || return 1
        sudo su - "$admin" <<EOF
printf '%s' '$encoded' | base64 -d > $(printf '%q' "$dest")
EOF
        return $?
    fi

    local host port qdest
    local -a opts
    host="$(role_host "$role")"
    port="$(role_port "$role")"
    qdest="$(printf '%q' "$dest")"
    mapfile -t opts < <(ssh_common_opts "$role")

    if [[ "$user" == "$admin" ]]; then
        cat -- "$src" | ssh \
            -p "$port" \
            "${opts[@]}" \
            "$user@$host" \
            "cat > $qdest"
    else
        local encoded
        encoded="$(base64 -w 0 -- "$src")" || return 1
        ssh \
            -p "$port" \
            "${opts[@]}" \
            "$user@$host" \
            "sudo su - $(printf '%q' "$admin")" <<EOF
printf '%s' '$encoded' | base64 -d > $qdest
EOF
    fi
}
role_copy_from() {
    local role="$1"
    local src="$2"
    local dest="$3"
    local user admin
    user="$(role_user "$role")"
    admin="$(role_admin_user "$role")"

    if [[ "$(role_mode_get "$role")" == "LOCAL" ]]; then
        if [[ "$user" == "$admin" || "$(id -un)" == "$admin" ]]; then
            cp -f -- "$src" "$dest"
        else
            sudo su - "$admin" <<EOF | base64 -d > "$dest"
base64 -w 0 -- $(printf '%q' "$src")
EOF
        fi
        return $?
    fi

    local host port qsrc
    local -a opts
    host="$(role_host "$role")"
    port="$(role_port "$role")"
    qsrc="$(printf '%q' "$src")"
    mapfile -t opts < <(ssh_common_opts "$role")

    if [[ "$user" == "$admin" ]]; then
        ssh \
            -p "$port" \
            "${opts[@]}" \
            "$user@$host" \
            "base64 -w 0 -- $qsrc" | base64 -d > "$dest"
    else
        ssh \
            -p "$port" \
            "${opts[@]}" \
            "$user@$host" \
            "sudo su - $(printf '%q' "$admin")" <<EOF | base64 -d > "$dest"
base64 -w 0 -- $qsrc
EOF
    fi
}
###############################################################################
# ORACLE ENVIRONMENT
###############################################################################
oracle_env_script() {
    local sid="$1"
    local oh="$2"
    local base="$3"
    cat <<EOF
export ORACLE_SID=$(printf '%q' "$sid")
export ORACLE_HOME=$(printf '%q' "$oh")
export ORACLE_BASE=$(printf '%q' "$base")
export ORACLE_BASE_HOME="\$ORACLE_HOME"
export ORACLE_BASE_CONFIG="\$ORACLE_HOME"
export PATH="\$ORACLE_HOME/bin:\$PATH"
export LD_LIBRARY_PATH="\$ORACLE_HOME/lib"
EOF
}
###############################################################################
# ORACLE BASE DERIVATION
###############################################################################
derive_oracle_base() {
    local oh="$1"
    local result=""
#
# Standard Oracle layout:
#
# /u01/app/oracle/product/26ai/dbhome_1
#                         ^^^^^
#
    if [[ "$oh" =~ ^(.+)/product/[^/]+/[^/]+$ ]]; then
        result="${BASH_REMATCH[1]}"
    elif [[ "$oh" =~ ^(.+)/product/[^/]+$ ]]; then
        result="${BASH_REMATCH[1]}"
    else
        result="$(dirname "$(dirname "$(dirname "$oh")")")"
    fi
    printf '%s' "$result"
}
###############################################################################
# ORABASETAB
###############################################################################
read_orabasetab() {
    local role="$1"
    local oh="$2"
    local script
    script=$(
        cat <<EOF
set -u
OH=$(printf '%q' "$oh")
if [ -f "\$OH/install/orabasetab" ];
then
    cat "\$OH/install/orabasetab"
else
    echo "__NO_ORABASETAB__"
fi
EOF
    )
    role_capture "$role" "$script"
}
write_orabasetab() {
    local role="$1"
    local oh="$2"
    local base="$3"
    local home_name="$4"
    local script
    script=$(
        cat <<EOF
set -u
OH=$(printf '%q' "$oh")
BASE=$(printf '%q' "$base")
HOME_NAME=$(printf '%q' "$home_name")
mkdir -p "\$OH/install"
TAB="\$OH/install/orabasetab"
if [ -f "\$TAB" ]; then
    cp -p "\$TAB" "\$TAB.tcaut7.bak.\$(date +%Y%m%d_%H%M%S)"
fi
printf '%s:%s:%s\:N:\\n' "\$OH" "\$BASE" "\$HOME_NAME" > "\$TAB"
chmod 644 "\$TAB"
echo "__ORABASETAB_UPDATED__"
cat "\$TAB"
EOF
    )
    role_exec "$role" "$script"
}
###############################################################################
# ORACLE HOME VALIDATION
###############################################################################
validate_oracle_home() {
    local role="$1"
    local oh="$2"
    [[ -n "$oh" ]] || return 1
    local script
    script=$(
        cat <<EOF
set -u
OH=$(printf '%q' "$oh")
echo "ORACLE_HOME=\$OH"
[ -d "\$OH" ] || {
    echo "__HOME_DIRECTORY_MISSING__"
    exit 10
}
for f in oracle sqlplus dbca lsnrctl; do
    if [ -x "\$OH/bin/\$f" ]; then
        echo "BIN_\$f=OK"
    else
        echo "BIN_\$f=MISSING"
    fi
done
if [ -x "\$OH/bin/oracle" ] && \
   [ -x "\$OH/bin/sqlplus" ] && \
   [ -x "\$OH/bin/dbca" ]; then
    echo "__VALID_DB_HOME__"
else
    echo "__INVALID_DB_HOME__"
    exit 11
fi
EOF
    )
    role_capture "$role" "$script"
}
###############################################################################
# ORACLE HOME DISCOVERY - PRIMARY
###############################################################################
discover_primary_sid() {
    if [[ -n "$PRIMARY_SID" ]]; then
        validate_oracle_name "PRIMARY SID" "$PRIMARY_SID"
        return 0
    fi
    log "Discovering Primary SID from PMON."
    # Keep the remote script literal.  Do not construct this with nested
    # single-quote/double-quote substitutions; that was the source of the
    # broken sed pipeline when this program was invoked through sh.
    local script
    script=$(cat <<'REMOTE_SID'
set -u
ps -eo args= 2>/dev/null |
while IFS= read -r line; do
    case "$line" in
        *ora_pmon_*)
            sid="${line#*ora_pmon_}"
            sid="${sid%%[[:space:]]*}"
            case "$sid" in
                ''|*[!A-Za-z0-9_$#-]*) continue ;;
                *) printf '%s\n' "$sid"; exit 0 ;;
            esac
            ;;
    esac
done
REMOTE_SID
)
    PRIMARY_SID="$(role_capture PRIMARY "$script" 2>/dev/null | tr -d '\r' | head -1)"
    [[ -n "$PRIMARY_SID" ]] ||
        die "Could not discover Primary SID from PMON. Use --primary-sid."
    validate_oracle_name "PRIMARY SID" "$PRIMARY_SID"
    log "Primary SID discovered: $PRIMARY_SID"
}
discover_primary_home() {
    if [[ -n "$PRIMARY_OH" ]]; then
        log "Primary ORACLE_HOME supplied: $PRIMARY_OH"
        return 0
    fi
    log "Discovering Primary ORACLE_HOME from running PMON process."
    local script
    script=$(cat <<'REMOTE_HOME'
set -u
SID="__SID__"
PID="$(ps -eo pid=,args= 2>/dev/null | awk -v sid="$SID" '$0 ~ "ora_pmon_" sid "([[:space:]]|$)" {print $1; exit}')"
if [ -n "$PID" ] && [ -e "/proc/$PID/exe" ]; then
    EXE="$(readlink -f "/proc/$PID/exe" 2>/dev/null || true)"
    case "$EXE" in
        */bin/oracle) dirname "$(dirname "$EXE")"; exit 0 ;;
    esac
fi
if [ -r /etc/oratab ]; then
    awk -F: -v sid="$SID" '$1 == sid && $2 != "" && $2 !~ /^\*/ {print $2; exit}' /etc/oratab
fi
REMOTE_HOME
)
    script="${script//__SID__/$PRIMARY_SID}"
    PRIMARY_OH="$(role_capture PRIMARY "$script" 2>/dev/null | tr -d '\r' | awk '/^\// {print; exit}')"
    if [[ -z "$PRIMARY_OH" ]]; then
        log "PMON/ORATAB discovery returned no Oracle Home; searching standard Oracle locations."
        PRIMARY_OH="$(discover_home_from_inventory_and_paths PRIMARY 2>/dev/null | head -1 || true)"
    fi
    [[ -n "$PRIMARY_OH" ]] || die "Unable to discover Primary ORACLE_HOME. PMON and /etc/oratab did not provide a valid home. Use --primary-oracle-home."
    log "Primary ORACLE_HOME discovered: $PRIMARY_OH"
}
###############################################################################
# GENERIC ORACLE HOME SEARCH
###############################################################################
discover_home_from_inventory_and_paths() {
    local role="$1"
    local script
    script=$(
        cat <<'EOF'
set -u
found=""
add_candidate() {
    h="$1"
    [ -n "$h" ] || return
    [ -d "$h" ] || return
    if [ -x "$h/bin/dbca" ] && \
       [ -x "$h/bin/sqlplus" ] && \
       [ -x "$h/bin/oracle" ]; then
        printf '%s\n' "$h"
    fi
}
#
# -----------------------------------------------------------------
# 1. /etc/oratab homes
# -----------------------------------------------------------------
if [ -f /etc/oratab ];
then
    awk -F: '
        $0 !~ /^[[:space:]]*#/ &&
        $2 != "" &&
        $2 !~ /^[*]/ {
            print $2
        }
    ' /etc/oratab |
    while IFS= read -r h; do
        add_candidate "$h"
    done
fi
#
# -----------------------------------------------------------------
# 2. oraInst.loc / inventory.xml
# -----------------------------------------------------------------
if [ -f /etc/oraInst.loc ]; then
    INV="$(
        sed -n 's/^[[:space:]]*inventory_loc[[:space:]]*=[[:space:]]*//p' \
        /etc/oraInst.loc |
        head -1
    )"
    if [ -n "$INV" ] && [ -f "$INV/ContentsXML/inventory.xml" ]; then
        grep -o 'LOC="[^"]*"' \
"$INV/ContentsXML/inventory.xml" 2>/dev/null |
        sed 's/^LOC="//;s/"$//' |
        while IFS= read -r h; do
            add_candidate "$h"
        done
    fi
fi
#
# -----------------------------------------------------------------
# 3. Common Oracle installation roots
# -----------------------------------------------------------------
for root in \
    /u01/app/oracle \
    /u02/app/oracle \
    /opt/oracle \
    /oracle
do
    [ -d "$root" ] || continue
# -----------------------------------------------------------------
# 3. Common Oracle installation roots
# -----------------------------------------------------------------
for root in \
    /u01/app/oracle \
    /u02/app/oracle \
    /opt/oracle \
    /oracle
do
    [ -d "$root" ] || continue
    find "$root" \
        -type f \
        -name dbca \
        -perm /111 \
        -path '*/bin/dbca' \
        -print 2>/dev/null |
    sed 's#/bin/dbca$##' |
    while IFS= read -r h; do
        add_candidate "$h"
    done
done

   done
done
EOF
    )
    role_capture "$role" "$script" |
        grep '^/' |
        sort -u
}
discover_tc_home() {
    if [[ -n "$TC_OH" ]]; then
        log "True Cache ORACLE_HOME supplied: $TC_OH"
        return 0
    fi
    log "Searching True Cache host for a complete Oracle Database Home."
    local candidates
    candidates="$(discover_home_from_inventory_and_paths TRUECACHE)"
#
# Prefer the same path as the Primary if it exists on TC.
#
    if [[ -n "$PRIMARY_OH" ]]; then
        local check
        check=$(
            role_capture TRUECACHE \
            "$(cat <<EOF
if [ -x $(printf '%q' "$PRIMARY_OH")/bin/dbca ] &&
   [ -x $(printf '%q' "$PRIMARY_OH")/bin/sqlplus ] &&
   [ -x $(printf '%q' "$PRIMARY_OH")/bin/oracle ]; then
    echo "$(printf '%s' "$PRIMARY_OH")"
fi
EOF
)"
        )
        if [[ -n "$check" ]]; then
            TC_OH="$PRIMARY_OH"
            log "True Cache uses same Oracle Home path as Primary: $TC_OH"
            return 0
        fi
    fi
    TC_OH="$(printf '%s\n' "$candidates" | head -1)"
    if [[ -n "$TC_OH" ]]; then
        log "True Cache ORACLE_HOME discovered: $TC_OH"
        return 0
    fi
    warn "Automatic True Cache ORACLE_HOME discovery found no complete Oracle Home."
    if [[ "$AUTO_YES" -eq 1 ]]; then
        die "No valid True Cache Oracle Home found. Use --tc-oracle-home."
    fi
    read -r -p "Enter True Cache ORACLE_HOME (ENTER to abort):
" TC_OH
    [[ -n "$TC_OH" ]] ||
        die "True Cache ORACLE_HOME was not supplied."
}
###############################################################################
# ORACLE HOME NAME
###############################################################################
discover_home_name() {
    local role="$1"
    local oh="$2"
    local script
    script=$(
        cat <<EOF
OH=$(printf '%q' "$oh")
if [ -f "\$OH/install/orabasetab" ];
then
    awk -F: '
        \$1=="'"$oh"'" {
            print \$3
            exit
        }
    ' "\$OH/install/orabasetab"
fi
EOF
    )
    role_capture "$role" "$script" |
        tr -d '\r' |
        head -1
}
derive_home_name() {
    local oh="$1"
    local basename
    basename="$(basename "$oh")"
#
# Typical:
# dbhome_1 -> use a deterministic Oracle Home name.
#
    if [[ "$oh" == *"/26ai/"* ]]; then
        printf '%s' "OraDB26Home1"
    elif [[ "$oh" == *"/23."* ]]; then
        printf '%s' "OraDB23Home1"
    elif [[ "$oh" == *"/19"* ]]; then
        printf '%s' "OraDB19Home1"
    else
        printf '%s' "$basename"
    fi
}
###############################################################################
# ORABASETAB NORMALIZATION
###############################################################################
normalize_oracle_environment() {
    local role="$1"
    local oh sid base home_name
    if [[ "$role" == "PRIMARY" ]]; then
        oh="$PRIMARY_OH"
        sid="$PRIMARY_SID"
        base="$PRIMARY_BASE"
    else
        oh="$TC_OH"
        sid="$TC_SID"
        base="$TC_BASE"
    fi
    [[ -n "$base" ]] ||
        base="$(derive_oracle_base "$oh")"
    home_name="$(discover_home_name "$role" "$oh")"
    if [[ -z "$home_name" ]]; then
        home_name="$(derive_home_name "$oh")"
        warn "$role: Oracle Home name was not found in orabasetab.
Derived: $home_name"
    fi
    local tab
    tab="$(read_orabasetab "$role" "$oh" || true)"
    log "$role ORACLE_BASE candidate: $base"
    log "$role Oracle Home name: $home_name"
    if [[ "$tab" == "__NO_ORABASETAB__" ]]; then
        warn "$role: $oh/install/orabasetab does not exist."
        if [[ "$DRY_RUN" -eq 0 ]]; then
            log "$role: Creating correct
orabasetab."
            write_orabasetab "$role" "$oh" "$base" "$home_name" ||
                die "$role: failed to create
orabasetab"
        fi
    else
        local first_line
        first_line="$(printf '%s\n' "$tab" |
            grep -v '^[[:space:]]*#' |
            head -1)"
        if [[ -n "$first_line" ]]; then
            local current_oh current_base current_name current_ro
            IFS=: read -r current_oh current_base current_name current_ro _ <<< "$first_line"
            log "$role orabasetab current home : ${current_oh:-EMPTY}"
            log "$role orabasetab current base : ${current_base:-EMPTY}"
            log "$role orabasetab current name : ${current_name:-EMPTY}"
            if [[ "$current_oh" != "$oh" ||
                  "$current_base" != "$base" ||
                  "$current_name" != "$home_name" ]]; then
                warn "$role: orabasetab does not match
selected Oracle Home."
                if [[ "$DRY_RUN" -eq 0 ]]; then
                    log "$role: Correcting orabasetab."
                    write_orabasetab "$role" "$oh" "$base" "$home_name" ||
                        die "$role: failed to correct
orabasetab"
                else
                    log "$role: DRY RUN - orabasetab would be
corrected."
                fi
            else
                log "$role: orabasetab is
consistent."
            fi
        fi
    fi
    if [[ "$role" == "PRIMARY" ]]; then
        PRIMARY_BASE="$base"
    else
        TC_BASE="$base"
    fi
}
###############################################################################
# STALE HOME DETECTION
###############################################################################
detect_stale_oracle_home_reference() {
    local role="$1"
    local oh="$2"
    log "$role: checking Oracle Home for stale references."
    local script
    script=$(
        cat <<EOF
set -u
OH=$(printf '%q' "$oh")
if [ ! -d "\$OH" ]; then
    exit 0
fi
# Search installation/runtime text files only.
# Do NOT modify them automatically.
grep -R -n -E '/u[0-9]+/app/oracle/product/[0-9][^/]*/dbhome[^/]*' \
    "\$OH/bin/dbca" \
    "\$OH/bin/orabase" \
    "\$OH/bin/orabaseconfig" \
    "\$OH/bin/oraenv" \
    "\$OH/install" \
    2>/dev/null |
awk -v oh="\$OH" 'index(\$0, oh)==0 {print}' |
head -100 || true
EOF
    )
    local result
    result="$(role_capture "$role" "$script" || true)"
    if [[ -n "$result" ]]; then
        warn "$role: possible stale Oracle Home references
detected:"
        printf '%s\n' "$result"
#
# Specifically identify references to a different home.
#
        local stale
        stale="$(
            printf '%s\n' "$result" |
            grep -oE '/u[0-9]+/app/oracle/product/[^/]+/dbhome[^/:]*' |
            sort -u |
grep -v -F "$oh" |
            head -20 || true
        )"
        if [[ -n "$stale" ]]; then
            warn "$role: references to another Oracle
Home:"
            printf '%s\n' "$stale"
            return 2
        fi
    fi
    return 0
}
###############################################################################
# RUNTIME ENVIRONMENT VALIDATION
###############################################################################
validate_oracle_runtime() {
    local role="$1"
    local oh sid base
    if [[ "$role" == "PRIMARY" ]]; then
        oh="$PRIMARY_OH"
        sid="$PRIMARY_SID"
        base="$PRIMARY_BASE"
    else
        oh="$TC_OH"
        sid="$TC_SID"
        base="$TC_BASE"
    fi
    log "$role: validating Oracle runtime environment."
    local env_script
    env_script="$(oracle_env_script "$sid" "$oh" "$base")"
    local script
    script=$(
        cat <<EOF
set -u
$env_script
echo "ORACLE_SID=\$ORACLE_SID"
echo "ORACLE_HOME=\$ORACLE_HOME"
echo "ORACLE_BASE=\$ORACLE_BASE"
echo "ORACLE_BASE_HOME=\$ORACLE_BASE_HOME"
echo "ORACLE_BASE_CONFIG=\$ORACLE_BASE_CONFIG"
echo "PATH=\$PATH"
echo "LD_LIBRARY_PATH=\$LD_LIBRARY_PATH"
echo
echo "DBCA:"
"\$ORACLE_HOME/bin/dbca" -help >/dev/null 2>&1
echo "DBCA_RC=\$?"
echo
echo "SQLPLUS VERSION:"
"\$ORACLE_HOME/bin/sqlplus" -V
echo
echo "LSNRCTL VERSION:"
"\$ORACLE_HOME/bin/lsnrctl" version 2>&1 | head -10
echo
echo "ORACLE:"
ls -l "\$ORACLE_HOME/bin/oracle"
echo
echo "PLATFORM_COMMON:"
if [ -f "\$ORACLE_HOME/bin/platform_common" ]; then
    echo "platform_common=OK"
else
    echo "platform_common=MISSING"
fi
EOF
    )
    role_exec "$role" "$script" ||
        die "$role Oracle runtime validation failed."
}
###############################################################################
# DBCA INTERNAL VALIDATION
###############################################################################
validate_dbca_launcher() {
    local role="$1"
    local oh
    if [[ "$role" == "PRIMARY" ]]; then
        oh="$PRIMARY_OH"
    else
        oh="$TC_OH"
    fi
    log "$role: validating DBCA launcher."
    local script
    script=$(
        cat <<EOF
set -u
OH=$(printf '%q' "$oh")
echo "DBCA=\$OH/bin/dbca"
[ -x "\$OH/bin/dbca" ] || exit 10
stale_refs=$(grep -nE '/u[0-9]+/app/oracle/product/[0-9][^/]*/dbhome[^/]*' "\$OH/bin/dbca" 2>/dev/null | grep -v -F "\$OH" || true)
if [ -n "\$stale_refs" ]; then
    echo "__DBCA_STALE_REFERENCE__"
    printf '%s\n' "\$stale_refs"
fi
echo
echo "DBCA first lines:"
sed -n '1,80p' "\$OH/bin/dbca"
EOF
    )
    local output
    output="$(role_capture "$role" "$script" || true)"
    printf '%s\n' "$output"
    if printf '%s\n' "$output" |
       grep -q "__DBCA_STALE_REFERENCE__"; then
        die "$role DBCA launcher contains a reference to another Oracle
Home. Installation must be repaired before True Cache deployment."
    fi
}
###############################################################################
# SQLPLUS WRAPPER
###############################################################################
role_sql() {
    local role="$1"
    local sql="$2"
    local oh sid base env_script script

    if [[ "$role" == "PRIMARY" ]]; then
        oh="$PRIMARY_OH"
        sid="$PRIMARY_SID"
        base="$PRIMARY_BASE"
    else
        oh="$TC_OH"
        sid="$TC_SID"
        base="$TC_BASE"
    fi

    # Build the remote script line-by-line.  Do NOT use an outer unquoted
    # heredoc here.  The SQL text can contain $, quotes, backslashes and
    # heredoc-looking text; expanding it through a second heredoc was the
    # source of the previous '-s' / '/' export corruption.
    env_script="$(oracle_env_script "$sid" "$oh" "$base")"

    script="set -u"
    script+=$'\n'
    script+="$env_script"
    script+=$'\n'
    script+='"$ORACLE_HOME/bin/sqlplus" -s / as sysdba <<'\''__TCAUT_SQL__'\''' 
    script+=$'\n'
    script+='whenever sqlerror exit 1'
    script+=$'\n'
    script+='whenever oserror exit 1'
    script+=$'\n'
    script+='set heading off'
    script+=$'\n'
    script+='set feedback off'
    script+=$'\n'
    script+='set pagesize 0'
    script+=$'\n'
    script+='set linesize 32767'
    script+=$'\n'
    script+='set trimspool on'
    script+=$'\n'
    script+='set tab off'
    script+=$'\n'
    script+='set verify off'
    script+=$'\n'
    script+='set echo off'
    script+=$'\n'
    script+="$sql"
    script+=$'\n'
    script+='exit'
    script+=$'\n'
    script+='__TCAUT_SQL__'
    script+=$'\n'

    role_capture "$role" "$script"
}

###############################################################################
# PRIMARY DATABASE VALIDATION
###############################################################################
validate_primary_database() {
    section "PRIMARY DATABASE VALIDATION"
    local result
    result="$(
        role_sql PRIMARY "
select
    '__TCAUT_DB__'||name||'|'||
    db_unique_name||'|'||
    log_mode||'|'||
    cdb||'|'||
    database_role||'|'||
    open_mode
from v\$database;
" |
        tr -d '\r' |
        sed -n 's/^[[:space:]]*__TCAUT_DB__//p' |
        head -1
    )"
    [[ -n "$result" ]] ||
        die "Unable to query V\$DATABASE on Primary."
    IFS='|' read -r \
        PRIMARY_DB_NAME \
        PRIMARY_DB_UNIQUE \
        PRIMARY_LOG_MODE \
        PRIMARY_CDB \
        PRIMARY_ROLE \
        PRIMARY_OPEN_MODE <<< "$result"
    log "DB_NAME      
: $PRIMARY_DB_NAME"
    log "DB_UNIQUE_NAME: $PRIMARY_DB_UNIQUE"
    log "LOG_MODE     
: $PRIMARY_LOG_MODE"
    log "CDB          
: $PRIMARY_CDB"
    log "DATABASE_ROLE : $PRIMARY_ROLE"
    log "OPEN_MODE    
: $PRIMARY_OPEN_MODE"
    [[ "$PRIMARY_ROLE" == "PRIMARY" ]] ||
        die "Selected Primary is not a PRIMARY
database."
    [[ "$PRIMARY_LOG_MODE" == "ARCHIVELOG" ]] ||
        die "Primary database must be in ARCHIVELOG
mode."
    [[ "$PRIMARY_CDB" == "YES" ]] ||
        die "Oracle 26ai True Cache requires a CDB
primary."
    [[ "$PRIMARY_OPEN_MODE" == *"READ WRITE"* ]] ||
        die "Primary database is not READ WRITE."
    PRIMARY_CLUSTER="$(
        role_sql PRIMARY "
select value
from v\$parameter
where name='cluster_database';
" |
        tr -d '[:space:]'
    )"
    [[ -n "$PRIMARY_CLUSTER" ]] || PRIMARY_CLUSTER="FALSE"
    log "CLUSTER_DATABASE: $PRIMARY_CLUSTER"
}
###############################################################################
# LOG ARCHIVE CONFIGURATION CHECK
###############################################################################
check_log_archive_parameters() {
    section "LOG ARCHIVE PARAMETER CHECK"

    local result meaningful n value
    local selected=""

    result="$({
        role_sql PRIMARY "
select name||'='||value
from v\$parameter
where
    name='log_archive_config'
    or name='log_archive_dest'
    or regexp_like(name,'^log_archive_dest_[0-9]+'||chr(36))
order by name;
" || true
    } | tr -d '\r' | sed '/^[[:space:]]*$/d')"

    if [[ -n "$result" ]]; then
        printf '%s\n' "$result"
    else
        log "No LOG_ARCHIVE_CONFIG/LOG_ARCHIVE_DEST parameters returned."
    fi

    meaningful="$({
        printf '%s\n' "$result" |
        grep -Ei '^log_archive_dest_[0-9]+=' |
        grep -Eiv '=([[:space:]]*)$|=NONE$|=null$|=LOCATION=$' || true
    })"

    if [[ -n "$meaningful" ]]; then
        warn "Existing LOG_ARCHIVE destination configuration detected."
    fi

    # Never overwrite an existing LOG_ARCHIVE_DEST_n.  Select the first
    # unused destination slot so an existing Data Guard/archive destination
    # such as DEST_2 is preserved and True Cache can use DEST_3, DEST_4, etc.
    for n in $(seq 1 31); do
        value="$({
            printf '%s\n' "$result" |
            awk -F= -v wanted="log_archive_dest_${n}" '
                tolower($1)==tolower(wanted) {
                    $1=""
                    sub(/^=/,"",$0)
                    print
                    exit
                }
            '
        })"

        if [[ -z "${value//[[:space:]]/}" || "${value^^}" == "NONE" ]]; then
            selected="LOG_ARCHIVE_DEST_${n}"
            TC_LOG_ARCHIVE_DEST="$selected"
            break
        fi

        log "Existing LOG_ARCHIVE_DEST_${n} detected; preserving it."
    done

    [[ -n "$selected" ]] ||
        die "No unused LOG_ARCHIVE_DEST_n slot is available (checked DEST_1 through DEST_31)."

    log "Selected unused LOG_ARCHIVE destination for True Cache configuration: $TC_LOG_ARCHIVE_DEST"

    if [[ -n "$meaningful" ]]; then
        log "Existing LOG_ARCHIVE destinations will NOT be overwritten."
    fi
}
###############################################################################
# PRIMARY SERVICES
###############################################################################
discover_primary_services() {
    local result
    result="$(
        role_sql PRIMARY "
select name
from v\$active_services
where upper(name) not in
      ('SYS\$BACKGROUND','SYS\$USERS','XDB')
order by name;
" |
        tr -d '\r' |
        sed '/^[[:space:]]*$/d'
    )"
    printf '%s\n' "$result"
}
discover_primary_cdb_services() {
    role_sql PRIMARY "
select name
from v\$services
where con_id=1
  and upper(name) not in
      ('SYS\$BACKGROUND','SYS\$USERS','XDB')
order by name;
" |
        tr -d '\r' |
        sed '/^[[:space:]]*$/d'
}
discover_pdbs() {
    role_sql PRIMARY "
select name
from v\$pdbs
where name <> 'PDB\$SEED'
order by name;
" |
        tr -d '\r' |
        sed '/^[[:space:]]*$/d'
}
###############################################################################
# PRIMARY EZCONNECT
###############################################################################
parse_ezconnect_host() {
    printf '%s' "$1" | sed 's#^\([^:/]*\).*#\1#'
}
parse_ezconnect_port() {
    printf '%s' "$1" |
        sed -n 's#^[^:]*:\([0-9][0-9]*\)/.*#\1#p'
}
###############################################################################
# INTERACTIVE SELECTION
###############################################################################
choose_primary_service() {
    [[ "$SKIP_SERVICE" -eq 1 ]] && return 0

    # If --primary-service was not supplied, discover application services
    # already present in the selected Primary PDB.  If none exists, do NOT
    # silently invent a service name here; the caller must supply one because
    # DBCA needs a specific Primary application service to cache.
    if [[ -z "$PRIMARY_SERVICE" ]]; then
        local services count
        services="$(role_sql PRIMARY "
set heading off feedback off pages 0 verify off echo off
select s.name
from v\$services s
join v\$pdbs p on p.con_id=s.con_id
where upper(p.name)=upper('$(printf '%s' "${PDB_NAME:-}")')
  and upper(s.name) not in ('SYS\$BACKGROUND','SYS\$USERS','XDB')
order by s.name;
" 2>/dev/null | tr -d '\r' | sed '/^[[:space:]]*$/d')"

        if [[ -n "$services" ]]; then
            count="$(printf '%s\n' "$services" | grep -c . || true)"
            if [[ "$count" -eq 1 ]]; then
                PRIMARY_SERVICE="$(printf '%s\n' "$services" | head -1)"
            elif [[ "$AUTO_YES" -eq 1 ]]; then
                die "Multiple application services exist for Primary PDB '$PDB_NAME'. Specify --primary-service."
            else
                echo
                echo "Application services for Primary PDB $PDB_NAME:"
                printf '%s\n' "$services" | nl -ba
                read -r -p "Enter Primary service for True Cache: " PRIMARY_SERVICE
            fi
        else
            if [[ "$AUTO_YES" -eq 1 ]]; then
                die "No Primary application service exists for PDB '$PDB_NAME'. Specify --primary-service SERVICE so it can be created automatically."
            fi
            read -r -p "No application service exists for Primary PDB '$PDB_NAME'. Enter service name to create: " PRIMARY_SERVICE
        fi
    fi

    [[ -n "$PRIMARY_SERVICE" ]] || die "Primary service is required unless --skip-service is specified."
    validate_oracle_name "Primary service" "$PRIMARY_SERVICE"

    ###########################################################################
    # CREATE/START PRIMARY PDB SERVICE WHEN MISSING
    #
    # Oracle DBCA requires the Primary application service to exist before
    # -configureTrueCacheInstanceService is executed. For a single-instance
    # Primary, DBMS_SERVICE is the supported mechanism. A PDB-specific service
    # must be created while the session is in that PDB.
    ###########################################################################
    local service_state
    service_state="$(role_sql PRIMARY "
set heading off feedback off pages 0 verify off echo off
select case
         when exists (
           select 1
           from v\$services s
           join v\$pdbs p on p.con_id=s.con_id
           where upper(s.name)=upper('$(printf '%s' "$PRIMARY_SERVICE")')
             and upper(p.name)=upper('$(printf '%s' "$PDB_NAME")')
         ) then 'TARGET_EXISTS'
         when exists (
           select 1
           from v\$services s
           where upper(s.name)=upper('$(printf '%s' "$PRIMARY_SERVICE")')
         ) then 'WRONG_PDB'
         else 'MISSING'
       end
from dual;
" 2>/dev/null | tr -d '[:space:]')"

    case "$service_state" in
        TARGET_EXISTS)
            log "Primary service '$PRIMARY_SERVICE' already exists in PDB '$PDB_NAME'."
            ;;
        WRONG_PDB)
            die "Primary service '$PRIMARY_SERVICE' already exists outside PDB '$PDB_NAME'. Refusing to reuse or move it automatically."
            ;;
        MISSING)
            log "Primary service '$PRIMARY_SERVICE' does not exist in PDB '$PDB_NAME'. Creating it with DBMS_SERVICE."
            local create_script
            # Build the Oracle environment locally/remotely for the Primary.
            local env_script
            env_script="$(oracle_env_script "$PRIMARY_SID" "$PRIMARY_OH" "$PRIMARY_BASE")"
            create_script=$(cat <<EOF
set -u
$env_script
"\$ORACLE_HOME/bin/sqlplus" -s / as sysdba <<SQL
set echo on
set serveroutput on
whenever sqlerror exit failure rollback
alter session set container=$(printf '%s' "$PDB_NAME");
begin
    dbms_service.create_service(
        service_name => '$(printf '%s' "$PRIMARY_SERVICE")',
        network_name => '$(printf '%s' "$PRIMARY_SERVICE")'
    );
    dbms_service.start_service(
        service_name => '$(printf '%s' "$PRIMARY_SERVICE")'
    );
end;
/
exit
SQL
EOF
)
            role_exec PRIMARY "$create_script" ||
                die "Failed to create/start Primary service '$PRIMARY_SERVICE' in PDB '$PDB_NAME' with DBMS_SERVICE."
            PRIMARY_SERVICE_CREATED=1
            log "Primary service '$PRIMARY_SERVICE' created and started in PDB '$PDB_NAME'."
            ;;
        *)
            die "Unable to determine whether Primary service '$PRIMARY_SERVICE' exists for PDB '$PDB_NAME'."
            ;;
    esac

    # Idempotent service start logic:
    #   * newly created service: create block already starts it
    #   * existing + already active: leave it alone
    #   * existing + not active: start it
    # This is deliberately based on the supplied PRIMARY_SERVICE/PDB values;
    # there is no service-name or PDB hardcoding here.
    local service_active="NO"
    if [[ "$PRIMARY_SERVICE_CREATED" -eq 0 ]]; then
        service_active="$(role_sql PRIMARY "
set heading off feedback off pages 0 verify off echo off
alter session set container=$(printf '%s' "$PDB_NAME");
select case
         when exists (
           select 1
           from v\$active_services s
           where upper(s.name)=upper('$(printf '%s' "$PRIMARY_SERVICE")')
         ) then 'YES'
         else 'NO'
       end
from dual;
" 2>/dev/null | tr -d '[:space:]')"

        if [[ "$service_active" == "YES" ]]; then
            log "Primary service '$PRIMARY_SERVICE' already exists and is running in PDB '$PDB_NAME'; no START_SERVICE required."
        else
            local start_script
            local env_script
            env_script="$(oracle_env_script "$PRIMARY_SID" "$PRIMARY_OH" "$PRIMARY_BASE")"
            start_script=$(cat <<EOF
set -u
$env_script
"\$ORACLE_HOME/bin/sqlplus" -s / as sysdba <<SQL
set echo off
set heading off feedback off pages 0 verify off
whenever sqlerror exit failure rollback
alter session set container=$(printf '%s' "$PDB_NAME");
begin
    dbms_service.start_service(
        service_name => '$(printf '%s' "$PRIMARY_SERVICE")'
    );
end;
/
exit
SQL
EOF
)
            role_exec PRIMARY "$start_script" ||
                die "Failed to start Primary service '$PRIMARY_SERVICE' in PDB '$PDB_NAME'."
            log "Primary service '$PRIMARY_SERVICE' was existing but not running; start requested in PDB '$PDB_NAME'."
        fi
    else
        log "Primary service '$PRIMARY_SERVICE' was created and started in PDB '$PDB_NAME'; no duplicate START_SERVICE call."
    fi

    # Verify both dictionary ownership and active registration.
    local verify
    verify="$(role_sql PRIMARY "
set heading off feedback off pages 0 verify off echo off
select case
         when exists (
           select 1
           from v\$active_services s
           join v\$pdbs p on p.con_id=s.con_id
           where upper(p.name)=upper('$(printf '%s' "$PDB_NAME")')
             and upper(s.name)=upper('$(printf '%s' "$PRIMARY_SERVICE")')
         ) then 'OK'
         else 'NOT_ACTIVE'
       end
from dual;
" 2>/dev/null | tr -d '[:space:]')"

    [[ "$verify" == "OK" ]] ||
        die "Primary service '$PRIMARY_SERVICE' exists for PDB '$PDB_NAME' but is not active after DBMS_SERVICE.START_SERVICE."

    log "Primary PDB service verified and active: $PRIMARY_SERVICE (PDB=$PDB_NAME)"
}
choose_pdb() {
    [[ "$SKIP_SERVICE" -eq 1 ]] && return 0
    if [[ -n "$PDB_NAME" ]]; then
        validate_oracle_name "PDB" "$PDB_NAME"
        return 0
    fi
    local pdbs count
    pdbs="$(discover_pdbs)"
    [[ -n "$pdbs" ]] || die "No application PDB found. True Cache service configuration requires a PDB."
    count="$(printf '%s\n' "$pdbs" | grep -c . || true)"
    if [[ "$count" -eq 1 ]]; then
        PDB_NAME="$(printf '%s\n' "$pdbs" | head -1)"
        log "PDB automatically selected: $PDB_NAME"
    elif [[ "$AUTO_YES" -eq 1 ]]; then
        die "Multiple PDBs found. Specify --pdb."
    else
        echo
        echo "Available PDBs:"
        printf '%s\n' "$pdbs" | nl -ba
        read -r -p "Enter PDB name: " PDB_NAME
        [[ -n "$PDB_NAME" ]] || die "PDB name required."
    fi
    validate_oracle_name "PDB" "$PDB_NAME"
}
choose_primary_ezconnect() {
    # Primary EZConnect is deliberately mandatory. Do not discover or construct
    # it automatically: the exact Primary listener/service supplied by the DBA
    # is used by both DBCA -createTrueCache and the connectivity checks.
    [[ -n "$PRIMARY_EZ" ]] ||
        die "Primary EZConnect is required. Specify --primary-ezconnect host:port/service."

    if ! printf '%s\n' "$PRIMARY_EZ" |
        grep -Eq '^[^:/[:space:]]+:[0-9]+/[^[:space:]]+$'; then
        die "Invalid Primary EZConnect '$PRIMARY_EZ'. Expected host:port/service."
    fi

    local ez_service ez_host ez_port listener_output
    ez_host="$(parse_ezconnect_host "$PRIMARY_EZ")"
    ez_port="$(parse_ezconnect_port "$PRIMARY_EZ")"
    ez_service="$(printf '%s' "$PRIMARY_EZ" | sed -n 's#^[^/]*/\(.*\)$#\1#p')"

    [[ -n "$ez_host" && -n "$ez_port" && -n "$ez_service" ]] ||
        die "Unable to parse Primary EZConnect '$PRIMARY_EZ'."
    validate_port "Primary EZConnect port" "$ez_port"
    validate_oracle_name "Primary CDB service" "$ez_service"
    PRIMARY_CDB_SERVICE="$ez_service"

    if [[ "$PRIMARY_CLUSTER" == "TRUE" ]]; then
        log "Primary is RAC; using supplied SCAN EZConnect: $PRIMARY_EZ"
    else
        log "Primary EZConnect supplied explicitly: $PRIMARY_EZ"
    fi

    # Validate the supplied endpoint against the Primary listener, but never
    # replace it with an automatically constructed value.
    listener_output="$(role_capture PRIMARY "
set -u
export ORACLE_SID=$(printf '%q' "$PRIMARY_SID")
export ORACLE_HOME=$(printf '%q' "$PRIMARY_OH")
export PATH=\"\$ORACLE_HOME/bin:\$PATH\"
\"\$ORACLE_HOME/bin/lsnrctl\" status 2>&1
" || true)"

    if ! printf '%s\n' "$listener_output" | grep -Fqi "$ez_service"; then
        warn "Supplied Primary EZConnect service '$ez_service' was not found in Primary listener output."
        printf '%s\n' "$listener_output"
        die "Primary EZConnect listener validation failed: $PRIMARY_EZ"
    fi

    log "Primary EZConnect validated: $PRIMARY_EZ"
}

###############################################################################
# MEMORY
###############################################################################
calculate_tc_memory() {
    # True Cache sizing follows the Oracle True Cache sizing calculator logic.
    # The calculator uses the uploaded/generated AWR HTML as the source for:
    #   * Primary buffer cache
    #   * Consistent gets / DB block gets
    #   * Buffer cache hit ratio
    #   * SGA target and non-buffer SGA components
    #
    # Formulae intentionally mirror the calculator:
    #   Read-only %       = CG / (CG + DB block gets) * 100
    #   TC Buffer         = Primary Buffer Cache * Read-only % * 1.10
    #   Default Buffer    = TC Buffer - Keep Cache
    #   Flash metadata    = Flash Cache * (200 / 8192)
    #   TC SGA            = TC Buffer + Flash metadata + all non-buffer SGA components
    #
    # The script does NOT invent a flash-cache size.  It defaults to 0, exactly
    # like the calculator.  Use --flash-cache-mb if a spool-file flash cache is
    # explicitly desired.

    local result
    result="$(role_capture TRUECACHE "free -m 2>/dev/null | awk '/^Mem:/ {print \$2; exit}'")"
    result="$(printf '%s' "$result" | tr -dc '0-9')"
    [[ -n "$result" ]] || result="8192"
    local ram="$result"

    # -------------------------------------------------------------------------
    # Select the worst representative AWR interval by DB Time/sec.
    # This is used to generate the AWR HTML that the sizing calculator would
    # consume.  Sizing inputs are then extracted from that HTML, rather than
    # substituting DBA_HIST_SYSSTAT deltas for the calculator's AWR values.
    # -------------------------------------------------------------------------
    local history
    history="$(role_sql PRIMARY "
set heading off feedback off pages 0 verify off echo off
select snap_id||'|'||to_char(begin_interval_time,'YYYY-MM-DD HH24:MI:SS')||'|'||to_char(end_interval_time,'YYYY-MM-DD HH24:MI:SS')||'|'||round(db_time_delta/1000000,3)||'|'||round(elapsed_seconds,3)||'|'||round(db_time_delta/1000000/nullif(elapsed_seconds,0),6)
from (
 select s.snap_id,s.begin_interval_time,s.end_interval_time,s.startup_time,
        tm.value-lag(tm.value) over(partition by tm.dbid,tm.instance_number,tm.stat_name order by s.snap_id) db_time_delta,
        (cast(s.end_interval_time as date)-cast(s.begin_interval_time as date))*86400 elapsed_seconds,
        lag(s.startup_time) over(partition by s.dbid,s.instance_number order by s.snap_id) prev_startup
 from dba_hist_snapshot s
 join dba_hist_sys_time_model tm on tm.dbid=s.dbid and tm.snap_id=s.snap_id and tm.instance_number=s.instance_number and tm.stat_name='DB time'
 where s.dbid=(select dbid from v\$database)
   and s.instance_number=(select instance_number from v\$instance)
   and s.end_interval_time > systimestamp-interval '7' day
)
where db_time_delta>0 and elapsed_seconds>0 and startup_time=prev_startup
order by db_time_delta/nullif(elapsed_seconds,0) desc
fetch first 1 row only;
" 2>/dev/null | tr -d '\r' | sed '/^[[:space:]]*$/d' | head -1)"

    if [[ -n "$history" && "$history" == *'|'* ]]; then
        IFS='|' read -r PRIMARY_AWR_EID PRIMARY_AWR_BEGIN PRIMARY_AWR_END PRIMARY_AWR_DB_TIME_SEC PRIMARY_AWR_ELAPSED PRIMARY_AWR_AAS <<< "$history"
        PRIMARY_AWR_BID="$(role_sql PRIMARY "
set heading off feedback off pages 0 verify off echo off
select max(snap_id) from dba_hist_snapshot
where dbid=(select dbid from v\$database) and instance_number=(select instance_number from v\$instance)
  and snap_id < $PRIMARY_AWR_EID
  and end_interval_time <= to_timestamp('$(printf '%s' "$PRIMARY_AWR_BEGIN")','YYYY-MM-DD HH24:MI:SS');
" 2>/dev/null | tr -d '[:space:]')"
    fi

    # -------------------------------------------------------------------------
    # Generate the same AWR HTML report that is retained in the deployment
    # artifacts, then parse that HTML using the same field-selection rules as
    # TrueCache_Sizing_UtilityV2.html.
    # -------------------------------------------------------------------------
    if [[ "$PRIMARY_AWR_EID" =~ ^[0-9]+$ && "$PRIMARY_AWR_BID" =~ ^[0-9]+$ ]]; then
        log "Primary worst workload interval: snapshot $PRIMARY_AWR_BID -> $PRIMARY_AWR_EID"
        log "Primary interval: $PRIMARY_AWR_BEGIN -> $PRIMARY_AWR_END"
        log "Primary DB Time/sec (AAS): $PRIMARY_AWR_AAS"

        PRIMARY_AWR_LOCAL="$WORK_DIR/awr_worst_primary_${PRIMARY_AWR_BID}_${PRIMARY_AWR_EID}.html"
        PRIMARY_AWR_REPORT="/tmp/truecache_deploy_${RUN_ID}_worst_awr.html"
        local awr_rc=0
        role_exec PRIMARY "
set -u
export ORACLE_SID=$(printf '%q' "$PRIMARY_SID")
export ORACLE_HOME=$(printf '%q' "$PRIMARY_OH")
export PATH=\"\$ORACLE_HOME/bin:\$PATH\"
\"\$ORACLE_HOME/bin/sqlplus\" -s / as sysdba <<'__TCAUT_AWR__' > $(printf '%q' "$PRIMARY_AWR_REPORT")
set long 100000000
set longchunksize 100000000
set pagesize 0
set linesize 32767
set trimspool on
set heading off
set feedback off
select dbms_workload_repository.awr_report_html((select dbid from v\$database),(select instance_number from v\$instance),$PRIMARY_AWR_BID,$PRIMARY_AWR_EID,8) from dual;
exit
__TCAUT_AWR__
" || awr_rc=$?
        if ((awr_rc==0)) && role_copy_from PRIMARY "$PRIMARY_AWR_REPORT" "$PRIMARY_AWR_LOCAL"; then
            log "Worst-interval AWR HTML: $PRIMARY_AWR_LOCAL"
        else
            warn "Unable to generate/copy AWR HTML for snapshots $PRIMARY_AWR_BID -> $PRIMARY_AWR_EID; calculator-style parsing will fall back to database statistics."
            PRIMARY_AWR_LOCAL=""
        fi
    else
        warn "Primary AWR history is unavailable or insufficient; using current Primary statistics for True Cache sizing."
        PRIMARY_AWR_BID=""; PRIMARY_AWR_EID=""; PRIMARY_AWR_BEGIN=""; PRIMARY_AWR_END=""; PRIMARY_AWR_DB_TIME_SEC=""; PRIMARY_AWR_AAS=""
    fi

    # -------------------------------------------------------------------------
    # Defaults.  These are overwritten by calculator-style AWR parsing below.
    # -------------------------------------------------------------------------
    TC_READ_ONLY_PCT=""
    TC_PRIMARY_BUFFER_MB=""
    TC_SHARED_POOL_MB=""
    TC_PRIMARY_SGA_TARGET_MB=""
    TC_BUFFER_CACHE_HIT_PCT=""
    TC_TRUE_CACHE_HIT_PCT=""
    TC_OTHER_SGA_MB=""

    local awr_metrics=""
    if [[ -n "$PRIMARY_AWR_LOCAL" && -s "$PRIMARY_AWR_LOCAL" ]] && command -v python3 >/dev/null 2>&1; then
        awr_metrics="$(python3 - "$PRIMARY_AWR_LOCAL" <<'__TCAUT_AWR_PARSER__'
import sys, re
from html.parser import HTMLParser

path = sys.argv[1]

class Parser(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.elements=[]
        self.head_stack=[]
        self.table_stack=[]
        self.current_table=None
        self.current_row=None
        self.current_cell=None
        self.cell_tag=None
        self.buf=[]
        self.current_heading=None
        self.current_summary=None

    def text(self):
        return ' '.join(''.join(self.buf).replace('\xa0',' ').split())

    def handle_starttag(self, tag, attrs):
        tag=tag.lower(); attrs=dict(attrs)
        if tag in ('h1','h2','h3','h4'):
            self.current_heading=[]
            self.head_stack.append(tag)
        elif tag=='table':
            self.current_table={'summary':attrs.get('summary',''),'rows':[]}
            self.table_stack.append(self.current_table)
        elif tag=='tr' and self.current_table is not None:
            self.current_row=[]
        elif tag in ('th','td') and self.current_row is not None:
            self.current_cell=[]; self.cell_tag=tag
        if self.current_cell is not None and tag not in ('th','td'):
            pass

    def handle_data(self,data):
        if self.current_heading is not None:
            self.current_heading.append(data)
        if self.current_cell is not None:
            self.current_cell.append(data)

    def handle_endtag(self, tag):
        tag=tag.lower()
        if tag in ('th','td') and self.current_cell is not None and self.current_row is not None:
            self.current_row.append(' '.join(''.join(self.current_cell).replace('\xa0',' ').split()))
            self.current_cell=None; self.cell_tag=None
        elif tag=='tr' and self.current_table is not None and self.current_row is not None:
            self.current_table['rows'].append(self.current_row)
            self.current_row=None
        elif tag=='table' and self.current_table is not None:
            t=self.current_table
            self.elements.append(('table',t))
            self.current_table=None
            if self.table_stack: self.table_stack.pop()
        elif tag in ('h1','h2','h3','h4') and self.current_heading is not None:
            h=' '.join(''.join(self.current_heading).replace('\xa0',' ').split())
            self.elements.append(('heading',h))
            self.current_heading=None
            if self.head_stack: self.head_stack.pop()

p=Parser()
with open(path,'r',encoding='utf-8',errors='replace') as f:
    p.feed(f.read())

def norm(v):
    return re.sub(r'\s*:\s*$','', ' '.join(str(v or '').replace('\xa0',' ').split())).lower()

def num(v):
    if v is None: return None
    s=''.join(str(v).replace(',','').split())
    m=re.search(r'[-+]?(?:\d+(?:\.\d*)?|\.\d+)(?:[Ee][-+]?\d+)?',s)
    return float(m.group(0)) if m else None

def table_after_heading(heading):
    target=norm(heading)
    for i,(kind,val) in enumerate(p.elements):
        if kind=='heading' and norm(val)==target:
            j=i+1
            while j<len(p.elements):
                if p.elements[j][0]=='table': return p.elements[j][1]
                if p.elements[j][0]=='heading': break
                j+=1
    return None

def find_row_value(label):
    target=norm(label)
    for kind,t in p.elements:
        if kind!='table': continue
        for cells in t['rows']:
            if len(cells)>=2 and norm(cells[0])==target:
                return num(cells[1])
    return None

def buffer_cache_gb():
    t=table_after_heading('Buffer Cache Advisory')
    if t:
        best=None
        for cells in t['rows'][1:]:
            if len(cells)<6: continue
            if norm(cells[0])!='default': continue
            sf=num(cells[3]); endmb=num(cells[5])
            if sf is None or endmb is None: continue
            score=abs(sf-1.0)
            if best is None or score<best[0]: best=(score,endmb)
        if best is not None: return best[1]/1024.0
    t=table_after_heading('Buffer Pool Statistics')
    if t:
        for cells in t['rows'][1:]:
            if cells and norm(cells[0])=='d' and len(cells)>=2:
                n=num(cells[1])
                if n is not None: return n*8/(1024*1024)
    return None

def keep_cache_gb():
    t=table_after_heading('Buffer Pool Statistics')
    if not t: return None
    for cells in t['rows'][1:]:
        if cells and norm(cells[0])=='k':
            if len(cells)<2: return 0.0
            n=num(cells[1]); return n*8/(1024*1024) if n is not None else 0.0
    return 0.0

def dynamic_gb(name):
    t=table_after_heading('Memory Dynamic Components')
    if not t: return None
    target=norm(name)
    for cells in t['rows'][1:]:
        if len(cells)>=3 and norm(cells[0])==target:
            v=num(cells[2]); return v/1024.0 if v is not None else None
    return None

def cache_size_gb(label,label_index,value_index):
    target=norm(label)
    for kind,t in p.elements:
        if kind!='table': continue
        if not re.search(r'cache sizes and other statistics', t.get('summary',''), re.I): continue
        for cells in t['rows'][1:]:
            if len(cells)<=value_index or len(cells)<=label_index: continue
            if norm(cells[label_index])!=target: continue
            m=re.match(r'^([0-9.]+)\s*([KMG])?$',cells[value_index].replace(',',''),re.I)
            if not m: return None
            v=float(m.group(1)); unit=(m.group(2) or 'M').upper()
            return v if unit=='G' else v/(1024*1024) if unit=='K' else v/1024.0
    return None

def metric(name):
    return find_row_value(name)

buf=buffer_cache_gb()
keep=keep_cache_gb()
cg=metric('consistent gets')
bg=metric('db block gets')
hit=metric('Buffer Hit %')
sga=dynamic_gb('SGA Target')
shared=dynamic_gb('shared pool')
if shared is None: shared=cache_size_gb('Shared Pool Size',0,2)
logbuf=cache_size_gb('Log Buffer',3,4) or 0.0
large=dynamic_gb('large pool') or 0.0
java=dynamic_gb('java pool') or 0.0
streams=dynamic_gb('streams pool') or 0.0
sharedio=dynamic_gb('Shared IO Pool') or 0.0
named=(shared or 0.0)+logbuf+large+java+streams+sharedio
other=max((sga or 0.0)-(buf or 0.0)-named,0.0) if sga is not None else None
ro=(cg/(cg+bg)*100.0) if cg is not None and bg is not None and cg+bg>0 else None

vals=[buf,keep,cg,bg,hit,sga,shared,logbuf,large,java,streams,sharedio,other,ro]
def f(v): return '' if v is None else ('%.6f'%v).rstrip('0').rstrip('.')
print('|'.join(f(v) for v in vals))
__TCAUT_AWR_PARSER__
2>/dev/null | tr -d '\r' | sed '/^[[:space:]]*$/d' | tail -1)"
    fi

    if [[ "$awr_metrics" == *'|'* ]]; then
        local pbuf pkeep cg bg phit psga psp plog plarge pjava pstreams psharedio pother pro
        IFS='|' read -r pbuf pkeep cg bg phit psga psp plog plarge pjava pstreams psharedio pother pro <<< "$awr_metrics"
        [[ -n "$pbuf" ]] && TC_PRIMARY_BUFFER_MB="$(awk -v v="$pbuf" 'BEGIN{printf "%.0f",v*1024}')"
        [[ -n "$pro" ]] && TC_READ_ONLY_PCT="$(awk -v v="$pro" 'BEGIN{printf "%.2f",v}')"
        [[ -n "$phit" ]] && TC_BUFFER_CACHE_HIT_PCT="$(awk -v v="$phit" 'BEGIN{printf "%.2f",v}')"
        [[ -n "$psga" ]] && TC_PRIMARY_SGA_TARGET_MB="$(awk -v v="$psga" 'BEGIN{printf "%.0f",v*1024}')"
        [[ -n "$psp" ]] && TC_SHARED_POOL_MB="$(awk -v v="$psp" 'BEGIN{printf "%.0f",v*1024}')"
        # Store the calculator's exact non-buffer components temporarily in MB.
        local awr_logbuf_mb awr_large_mb awr_java_mb awr_streams_mb awr_sharedio_mb awr_other_mb
        awr_logbuf_mb="$(awk -v v="${plog:-0}" 'BEGIN{printf "%.0f",v*1024}')"
        awr_large_mb="$(awk -v v="${plarge:-0}" 'BEGIN{printf "%.0f",v*1024}')"
        awr_java_mb="$(awk -v v="${pjava:-0}" 'BEGIN{printf "%.0f",v*1024}')"
        awr_streams_mb="$(awk -v v="${pstreams:-0}" 'BEGIN{printf "%.0f",v*1024}')"
        awr_sharedio_mb="$(awk -v v="${psharedio:-0}" 'BEGIN{printf "%.0f",v*1024}')"
        awr_other_mb="$(awk -v v="${pother:-0}" 'BEGIN{printf "%.0f",v*1024}')"
        # The calculator SGA includes ALL non-buffer SGA components, including
        # Shared Pool.  Keep the residual "Other Primary SGA" separate, then
        # add Shared Pool + Log Buffer + Large/Java/Streams/Shared IO + Other.
        # Do not omit Shared Pool here; doing so understates the TC SGA.
        TC_OTHER_SGA_MB="$(awk -v a="${TC_SHARED_POOL_MB:-0}" -v b="$awr_logbuf_mb" -v c="$awr_large_mb" -v d="$awr_java_mb" -v e="$awr_streams_mb" -v f="$awr_sharedio_mb" -v g="$awr_other_mb" 'BEGIN{printf "%.0f",a+b+c+d+e+f+g}')"
        [[ -n "$pkeep" ]] && TC_KEEP_CACHE_GB="$pkeep"
    fi

    # -------------------------------------------------------------------------
    # Database fallback only when the generated AWR could not provide a field.
    # These values are not substitutes when the calculator-style AWR value exists.
    # -------------------------------------------------------------------------
    if [[ -z "$TC_PRIMARY_BUFFER_MB" || "$TC_PRIMARY_BUFFER_MB" == "0" || -z "$TC_SHARED_POOL_MB" || "$TC_SHARED_POOL_MB" == "0" || -z "$TC_PRIMARY_SGA_TARGET_MB" || "$TC_PRIMARY_SGA_TARGET_MB" == "0" || -z "$TC_READ_ONLY_PCT" ]]; then
        local current_metrics
        current_metrics="$(role_sql PRIMARY "
set heading off feedback off pages 0 verify off echo off
select round(100*consistent_gets/nullif(consistent_gets+db_block_gets,0),2)||'|'||round(buffer_cache_size/1024/1024,0)||'|'||round(shared_pool_size/1024/1024,0)||'|'||round(sga_target/1024/1024,0)
from (
 select (select value from v\$sysstat where name='consistent gets') consistent_gets,
        (select value from v\$sysstat where name='db block gets') db_block_gets,
        (select nvl(sum(bytes),0) from v\$sgainfo where name='Buffer Cache Size') buffer_cache_size,
        (select nvl(sum(bytes),0) from v\$sgainfo where name='Shared Pool Size') shared_pool_size,
        (select value from v\$parameter where name='sga_target') sga_target
 from dual
);
" 2>/dev/null | tr -d '\r' | sed '/^[[:space:]]*$/d' | head -1)"
        if [[ "$current_metrics" == *'|'* ]]; then
            local cro cbuf csp csga
            IFS='|' read -r cro cbuf csp csga <<< "$current_metrics"
            [[ -n "$TC_READ_ONLY_PCT" ]] || TC_READ_ONLY_PCT="$cro"
            [[ -n "$TC_PRIMARY_BUFFER_MB" || -z "$cbuf" ]] || TC_PRIMARY_BUFFER_MB="$cbuf"
            [[ -n "$TC_SHARED_POOL_MB" || -z "$csp" ]] || TC_SHARED_POOL_MB="$csp"
            [[ -n "$TC_PRIMARY_SGA_TARGET_MB" || -z "$csga" ]] || TC_PRIMARY_SGA_TARGET_MB="$csga"
        fi
    fi

    # Keep cache is an explicit calculator input; absent from AWR it is 0 GB.
    local keep_cache_mb=0
    if [[ -n "${TC_KEEP_CACHE_GB:-}" ]]; then
        keep_cache_mb="$(awk -v v="$TC_KEEP_CACHE_GB" 'BEGIN{printf "%.0f",v*1024}')"
    fi

    # Exact calculator formula: Primary Buffer Cache x Read-Only % x 1.10.
    TC_RECOMMENDED_BUFFER_MB="$(awk -v buf="${TC_PRIMARY_BUFFER_MB:-0}" -v ro="${TC_READ_ONLY_PCT:-0}" 'BEGIN{printf "%.0f",buf*ro/100*1.10}')"

    # Exact calculator display values: keep cache is capped at TC buffer and
    # default buffer is the remainder.  The DBCA target uses the total TC buffer.
    local default_buffer_mb
    keep_cache_mb="$(awk -v k="$keep_cache_mb" -v b="$TC_RECOMMENDED_BUFFER_MB" 'BEGIN{if(k>b)k=b;printf "%.0f",k}')"
    default_buffer_mb="$(awk -v b="$TC_RECOMMENDED_BUFFER_MB" -v k="$keep_cache_mb" 'BEGIN{v=b-k;if(v<0)v=0;printf "%.0f",v}')"

    # Exact calculator flash-cache behavior: disabled/unspecified = 0.
    if [[ -z "$FLASH_CACHE_MB" ]]; then FLASH_CACHE_MB="0"; fi
    [[ "$FLASH_CACHE_MB" =~ ^[0-9]+([.][0-9]+)?$ ]] || die "Flash cache MB must be numeric."
    TC_FLASH_CACHE_MB="$(awk -v v="$FLASH_CACHE_MB" 'BEGIN{printf "%.0f",v}')"
    TC_FLASH_METADATA_MB="$(awk -v f="$TC_FLASH_CACHE_MB" 'BEGIN{printf "%.0f",f*200/8192}')"

    # Exact calculator SGA: TC buffer + flash metadata + every non-buffer SGA
    # component copied from the Primary AWR.  If AWR component parsing was
    # unavailable, preserve the Primary SGA minus Primary buffer as the fallback.
    if [[ -z "$TC_OTHER_SGA_MB" ]]; then
        TC_OTHER_SGA_MB="$(awk -v sga="${TC_PRIMARY_SGA_TARGET_MB:-0}" -v buf="${TC_PRIMARY_BUFFER_MB:-0}" 'BEGIN{v=sga-buf;if(v<0)v=0;printf "%.0f",v}')"
    fi
    TC_RECOMMENDED_SGA_MB="$(awk -v b="$TC_RECOMMENDED_BUFFER_MB" -v f="$TC_FLASH_METADATA_MB" -v o="$TC_OTHER_SGA_MB" 'BEGIN{printf "%.0f",b+f+o}')"

    # PGA is not part of the supplied HTML calculator formula.  Keep the
    # existing explicit-PGA behavior; otherwise use Primary PGA target as the
    # deployment default because DBCA requires a PGA target.
    local primary_pga_metrics
    primary_pga_metrics="$(role_sql PRIMARY "
set heading off feedback off pages 0 verify off echo off
select nvl((select value from v\$parameter where name='pga_aggregate_target'),0)||'|'||
       nvl((select value from v\$pgastat where name='maximum PGA allocated'),0)
from dual;
" 2>/dev/null | tr -d '\r' | sed '/^[[:space:]]*$/d' | head -1)"
    if [[ "$primary_pga_metrics" == *'|'* ]]; then
        local ppga_target_bytes ppga_max_bytes
        IFS='|' read -r ppga_target_bytes ppga_max_bytes <<< "$primary_pga_metrics"
        TC_PRIMARY_PGA_TARGET_MB="$(awk -v v="${ppga_target_bytes:-0}" 'BEGIN{printf "%.0f",v/1024/1024}')"
        TC_PRIMARY_PGA_MAX_MB="$(awk -v v="${ppga_max_bytes:-0}" 'BEGIN{printf "%.0f",v/1024/1024}')"
    fi
    if [[ -z "$PGA_MB" || "$PGA_MB" == "0" ]]; then
        if [[ "${TC_PRIMARY_PGA_TARGET_MB:-0}" =~ ^[0-9]+$ ]] && (( TC_PRIMARY_PGA_TARGET_MB > 0 )); then
            PGA_MB="$TC_PRIMARY_PGA_TARGET_MB"
        elif [[ "${TC_PRIMARY_PGA_MAX_MB:-0}" =~ ^[0-9]+$ ]] && (( TC_PRIMARY_PGA_MAX_MB > 0 )); then
            PGA_MB="$TC_PRIMARY_PGA_MAX_MB"
        else
            die "Primary PGA_AGGREGATE_TARGET and maximum PGA allocation are unavailable; specify --pga-mb explicitly."
        fi
    fi
    TC_RECOMMENDED_PGA_MB="$PGA_MB"

    # Explicit --sga-mb remains an intentional user override.  Otherwise use
    # the calculator SGA result.
    if [[ -z "$SGA_MB" || "$SGA_MB" == "0" ]]; then SGA_MB="$TC_RECOMMENDED_SGA_MB"; fi
    [[ "$SGA_MB" =~ ^[0-9]+$ ]] || die "SGA MB must be numeric."
    [[ "$PGA_MB" =~ ^[0-9]+$ ]] || die "PGA MB must be numeric."

    log "True Cache physical memory: ${ram} MB"
    [[ -n "$PRIMARY_AWR_EID" ]] && log "True Cache sizing source: Primary AWR snapshots $PRIMARY_AWR_BID -> $PRIMARY_AWR_EID" || log "True Cache sizing source: current Primary statistics (AWR unavailable)"
    log "Primary read-only workload percentage: ${TC_READ_ONLY_PCT:-N/A}%"
    log "Primary DB cache: ${TC_PRIMARY_BUFFER_MB:-N/A} MB"
    log "Primary shared pool: ${TC_SHARED_POOL_MB:-N/A} MB"
    log "Primary SGA target: ${TC_PRIMARY_SGA_TARGET_MB:-N/A} MB"
    log "Primary PGA aggregate target: ${TC_PRIMARY_PGA_TARGET_MB:-N/A} MB"
    log "Primary maximum PGA allocated: ${TC_PRIMARY_PGA_MAX_MB:-N/A} MB"
    log "Recommended True Cache buffer cache: ${TC_RECOMMENDED_BUFFER_MB:-N/A} MB (Primary DB cache x read-only % x 1.10)"
    log "Recommended True Cache default buffer cache: ${default_buffer_mb} MB"
    log "Recommended True Cache keep cache: ${keep_cache_mb} MB"
    log "Recommended True Cache SGA: ${TC_RECOMMENDED_SGA_MB:-N/A} MB (calculator formula)"
    log "Recommended True Cache PGA: ${TC_RECOMMENDED_PGA_MB:-N/A} MB (not calculated by the supplied HTML calculator)"
    log "True Cache flash cache: ${TC_FLASH_CACHE_MB:-N/A} MB"
    log "Flash cache DRAM metadata estimate: ${TC_FLASH_METADATA_MB:-N/A} MB"
    log "True Cache buffer cache hit ratio: ${TC_BUFFER_CACHE_HIT_PCT:-N/A}%"
    log "True Cache hit ratio estimate: ${TC_TRUE_CACHE_HIT_PCT:-N/A}%"
}

###############################################################################
# TC SID/GDB
###############################################################################
choose_tc_identifiers() {
    if [[ -z "$TC_SID" ]]; then
        local default_sid="${PRIMARY_SID}_TC"
        if [[ "$AUTO_YES" -eq 1 ]]; then
            TC_SID="$default_sid"
        else
            read -r -p "True Cache SID [$default_sid]: " answer
            TC_SID="${answer:-$default_sid}"
        fi
    fi
    validate_oracle_name "True Cache SID" "$TC_SID"
    if [[ -z "$TC_GDB" ]]; then
        local default_gdb="${PRIMARY_DB_NAME}_TC"
        if [[ "$AUTO_YES" -eq 1 ]]; then
            TC_GDB="$default_gdb"
        else
            read -r -p "True Cache Global DB Name
[$default_gdb]: " answer
            TC_GDB="${answer:-$default_gdb}"
        fi
    fi
    validate_oracle_name "True Cache GDB name" "$TC_GDB"
    if [[ -z "$TC_SERVICE" && "$SKIP_SERVICE" -eq 0 ]]; then
        # If the Primary service already has a True Cache service association,
        # reuse that SAME service for an additional True Cache. Oracle documents
        # this as the uniform multi-True-Cache configuration: run DBCA once and
        # start the existing True Cache service on the additional nodes.
        local existing_tc_service
        existing_tc_service="$(role_sql PRIMARY "
set heading off feedback off pages 0 verify off echo off
select true_cache_service
from v\$active_services
where upper(name)=upper('$(printf '%s' "$PRIMARY_SERVICE")')
  and true_cache_service is not null;
" 2>/dev/null | tr -d '\r' | sed '/^[[:space:]]*$/d' | head -1)"

        if [[ -n "$existing_tc_service" ]]; then
            TC_SERVICE="$existing_tc_service"
            TC_SERVICE_EXISTING_ON_PRIMARY=1
            log "Existing Primary True Cache service detected: $TC_SERVICE"
            log "This run will reuse the existing service; DBCA association will NOT be recreated."
        else
            TC_SERVICE="${PRIMARY_SERVICE}_TC"
            if [[ "$AUTO_YES" -eq 0 ]]; then
                read -r -p "True Cache service [$TC_SERVICE]: " answer
                TC_SERVICE="${answer:-$TC_SERVICE}"
            fi
        fi
    fi
    validate_oracle_name "True Cache service" "$TC_SERVICE"
}
###############################################################################
# LISTENER
###############################################################################
validate_listener_port() {
    validate_port "Listener port" "$LISTENER_PORT"
}
detect_tc_listener() {
    local script
    script=$(
        cat <<EOF
OH=$(printf '%q' "$TC_OH")
if [ -x "\$OH/bin/lsnrctl" ]; then
    "\$OH/bin/lsnrctl" status \
        $(printf '%q' "$LISTENER_NAME") \
        >/dev/null 2>&1
    if [ \$? -eq 0 ]; then
        echo "__LISTENER_EXISTS__"
    else
        echo "__LISTENER_NOT_RUNNING__"
    fi
else
    echo "__LSNRCTL_MISSING__"
fi
EOF
    )
    role_capture TRUECACHE "$script"
}
###############################################################################
# TC -> PRIMARY NETWORK
###############################################################################
check_tc_to_primary() {
    section "TRUE CACHE -> PRIMARY NETWORK CHECK"
    local ez_host ez_port
    ez_host="$(parse_ezconnect_host "$PRIMARY_EZ")"
    ez_port="$(parse_ezconnect_port "$PRIMARY_EZ")"
    if [[ -z "$ez_port" ]]; then
        ez_port="$LISTENER_PORT"
    fi
    log "Testing from True Cache:"
    log "Destination host: $ez_host"
    log "Destination port: $ez_port"
    local script
    script=$(
        cat <<EOF
HOST=$(printf '%q' "$ez_host")
PORT=$(printf '%q' "$ez_port")
if command -v nc >/dev/null 2>&1; then
    nc -z -w 5 "\$HOST" "\$PORT"
    rc=\$?
elif command -v timeout >/dev/null 2>&1; then
    timeout 5 bash -c "</dev/tcp/\$HOST/\$PORT" >/dev/null 2>&1
    rc=\$?
else
    bash -c "</dev/tcp/\$HOST/\$PORT" >/dev/null 2>&1
    rc=\$?
fi
echo "TC_TO_PRIMARY_RC=\$rc"
exit \$rc
EOF
    )
    role_exec TRUECACHE "$script" ||
        die "True Cache host cannot reach Primary $ez_host:$ez_port."
    log "True Cache -> Primary TCP connectivity: OK"
#
# tnsping is useful but not mandatory.
#
    local env_script
    env_script="$(oracle_env_script "$TC_SID" "$TC_OH" "$TC_BASE")"
    script=$(
        cat <<EOF
set -u
$env_script
if [ -x "\$ORACLE_HOME/bin/tnsping" ]; then
    "\$ORACLE_HOME/bin/tnsping" $(printf '%q' "$PRIMARY_EZ") 3
else
    echo "tnsping not available."
fi
EOF
    )
    role_exec TRUECACHE "$script" || true
}
###############################################################################
# PRIMARY LISTENER
###############################################################################
validate_primary_listener() {
    section "PRIMARY LISTENER VALIDATION"
    local env_script
    env_script="$(oracle_env_script "$PRIMARY_SID" "$PRIMARY_OH" "$PRIMARY_BASE")"
    local script
    script=$(
        cat <<EOF
set -u
$env_script
if [ -x "\$ORACLE_HOME/bin/lsnrctl" ]; then
    "\$ORACLE_HOME/bin/lsnrctl" status
else
    echo "lsnrctl unavailable."
fi
EOF
    )
    role_exec PRIMARY "$script" || warn "Primary listener status command failed."
}
###############################################################################
# DEPLOYMENT PLAN
###############################################################################
show_plan() {
    section "TRUE CACHE DEPLOYMENT PLAN"
    echo
    echo "Execution Host       : $EXEC_HOST"
    echo
    echo "PRIMARY"
    echo " 
Host               : $PRIMARY_HOST"
    echo " 
SSH User           : $PRIMARY_USER"
    echo "  Admin User         : $PRIMARY_ADMIN_USER"
    echo " 
SID                : $PRIMARY_SID"
    echo "  DB
Name            : $PRIMARY_DB_NAME"
    echo "  DB
Unique Name     : $PRIMARY_DB_UNIQUE"
    echo "  Oracle
Home        : $PRIMARY_OH"
    echo "  Oracle
Base        : $PRIMARY_BASE"
    echo " 
EZConnect          : $PRIMARY_EZ"
    echo " 
Service            : ${PRIMARY_SERVICE:-NOT SET}"
    echo " 
PDB                : ${PDB_NAME:-NOT SET}"
    echo "  Cluster
Database   : $PRIMARY_CLUSTER"
    echo " 
SSH                : $PRIMARY_SSH_MODE"
    echo
    echo "TRUE CACHE"
    echo " 
Host               : $TC_HOST"
    echo " 
SSH User           : $TC_USER"
    echo "  Admin User         : $TC_ADMIN_USER"
    echo "  SID                : $TC_SID"
    echo "  GDB
Name           : $TC_GDB"
    echo "  Oracle
Home        : $TC_OH"
    echo "  Oracle
Base        : $TC_BASE"
    echo " 
Service            : ${TC_SERVICE:-NOT SET}"
    echo " 
Listener           : $LISTENER_NAME"
    echo " 
Listener Port      : $LISTENER_PORT"
    echo "  SGA
MB             : $SGA_MB"
    echo "  PGA
MB             : $PGA_MB"
    echo " 
SSH                : $TC_SSH_MODE"
    echo
    echo "TRUE CACHE SIZING EVIDENCE"
    echo "  Worst AWR Snapshots : ${PRIMARY_AWR_BID:-N/A} -> ${PRIMARY_AWR_EID:-N/A}"
    echo "  Worst Interval      : ${PRIMARY_AWR_BEGIN:-N/A} -> ${PRIMARY_AWR_END:-N/A}"
    echo "  DB Time/sec (AAS)   : ${PRIMARY_AWR_AAS:-N/A}"
    echo "  Read-Only Workload  : ${TC_READ_ONLY_PCT:-N/A}%"
    echo "  Primary DB Cache    : ${TC_PRIMARY_BUFFER_MB:-N/A} MB"
    echo "  Primary Shared Pool: ${TC_SHARED_POOL_MB:-N/A} MB"
    echo "  Primary SGA Target : ${TC_PRIMARY_SGA_TARGET_MB:-N/A} MB"
    echo "  TC Buffer Cache     : ${TC_RECOMMENDED_BUFFER_MB:-N/A} MB"
    echo "  TC Recommended SGA  : ${TC_RECOMMENDED_SGA_MB:-N/A} MB"
    echo "  TC Flash Cache      : ${TC_FLASH_CACHE_MB:-N/A} MB"
    echo "  Flash Cache Metadata: ${TC_FLASH_METADATA_MB:-N/A} MB"
    echo "  Buffer Cache Hit    : ${TC_BUFFER_CACHE_HIT_PCT:-N/A}%"
    echo "  True Cache Hit Est. : ${TC_TRUE_CACHE_HIT_PCT:-N/A}%"
    echo "  AWR HTML            : ${PRIMARY_AWR_REPORT:-N/A}"
    echo
    echo "OPTIONS"
    echo "  Service
Config     : $([[ $SKIP_SERVICE -eq 1 ]] && echo SKIP || echo ENABLED)"
    echo "  VNCR
Check         : $([[ $SKIP_VNCR -eq 1 ]] && echo SKIP || echo ENABLED)"
    echo "  Redo
Transport     : ${REDO_TRANSPORT:-Oracle default}"
    echo "  Dry Run            : $([[ $DRY_RUN -eq 1 ]] && echo YES || echo NO)"
    echo
}
confirm_deployment() {
    [[ "$AUTO_YES" -eq 1 ]] && return 0
    [[ "$DRY_RUN" -eq 1 ]] && return 0
    echo
    echo "WARNING: The next phase will create/configure
the True Cache database."
    echo
    read -r -p "Continue? [y/N]: " answer
    case "${answer,,}" in
        y|yes) ;;
        *) die "Deployment cancelled by
user."
;;
    esac
}
###############################################################################
# DBCA BLOB PREPARATION
###############################################################################
prepare_true_cache_blob() {
    section "PREPARE TRUE CACHE CONFIGURATION BLOB"
    BLOB_LOCAL="$WORK_DIR/truecache_blob"
    local primary_blob_dir="$WORK_DIR/primary_blob"
#
# The blob is first created on the Primary.
#
    local env_script
    env_script="$(oracle_env_script "$PRIMARY_SID" "$PRIMARY_OH" "$PRIMARY_BASE")"
    local script
    script=$(
        cat <<EOF
set -u
$env_script
DIR=$(printf '%q' "$primary_blob_dir")
mkdir -p "\$DIR"
chmod 700 "\$DIR"
"\$ORACLE_HOME/bin/dbca" \
    -configureDatabase \
    -prepareTrueCacheConfigFile \
    -sourceDB $(printf '%q' "$PRIMARY_DB_UNIQUE") \
    -trueCacheBlobLocation "\$DIR" \
    -silent
rc=\$?
echo "DBCA_PREPARE_RC=\$rc"
if [ \$rc -ne 0 ]; then
    exit \$rc
fi
find "\$DIR" -type f -maxdepth 2 -print
EOF
    )
    if [[ "$DRY_RUN" -eq 1 ]]; then
        log "DRY RUN: DBCA prepareTrueCacheConfigFile would
execute."
        return 0
    fi
    role_exec PRIMARY "$script" ||
        die "DBCA -prepareTrueCacheConfigFile failed."
#
# Find actual BLOB on Primary.
#
    local finder
    finder=$(cat <<EOF
find $(printf '%q' "$primary_blob_dir") -maxdepth 2 -type f \
    ! -name '*.log' \
    ! -name '*.out' \
    ! -name '*.txt' \
    -print 2>/dev/null | grep -Ei '\\.(tar\\.gz|tgz|zip|blob)$' | head -1
EOF
    )
    BLOB_PRIMARY="$(role_capture PRIMARY "$finder" |
        tr -d '\r' |
        head -1)"
    [[ -n "$BLOB_PRIMARY" ]] ||
        die "True Cache configuration BLOB was not found on
Primary."
    log "Primary BLOB: $BLOB_PRIMARY"
#
# Download to execution host.
#
    log "Copying True Cache BLOB to execution
host."
    if ! role_copy_from PRIMARY "$BLOB_PRIMARY" "$BLOB_LOCAL"; then
#
# Binary-safe fallback through SSH stdout.
#
        log "SCP BLOB transfer failed; attempting
binary-safe SSH transfer."
        local host user port
        host="$(role_host PRIMARY)"
        user="$(role_user PRIMARY)"
        port="$(role_port PRIMARY)"
        local -a opts
        mapfile -t opts < <(ssh_common_opts PRIMARY)
        # Retry through the same administrative-user-aware path.
        role_copy_from PRIMARY "$BLOB_PRIMARY" "$BLOB_LOCAL" ||
            die "Unable to retrieve True Cache BLOB from Primary."
    fi
    [[ -s "$BLOB_LOCAL" ]] ||
        die "Downloaded True Cache BLOB is empty."
    chmod 600 "$BLOB_LOCAL"
    log "Local BLOB: $BLOB_LOCAL"
    ls -lh "$BLOB_LOCAL"
}
###############################################################################
# COPY BLOB TO TC
###############################################################################
copy_blob_to_tc() {
    section "COPY TRUE CACHE BLOB TO TRUE CACHE"
    BLOB_TC="/tmp/tcaut11_truecache_${RUN_ID}.blob"
    if [[ "$DRY_RUN" -eq 1 ]]; then
        log "DRY RUN: BLOB would be copied to $BLOB_TC"
        return 0
    fi
    role_copy_to TRUECACHE "$BLOB_LOCAL" "$BLOB_TC" ||
        die "Unable to copy True Cache BLOB to True Cache
host."
    local script
    script=$(
        cat <<EOF
BLOB=$(printf '%q' "$BLOB_TC")
[ -s "\$BLOB" ] || {
    echo "BLOB_MISSING_OR_EMPTY"
    exit 10
}
chmod 600 "\$BLOB"
ls -lh "\$BLOB"
EOF
    )
    role_exec TRUECACHE "$script" ||
        die "True Cache BLOB validation failed."
    log "True Cache BLOB installed at $BLOB_TC"
}
###############################################################################
# CHECK EXISTING TC DATABASE
###############################################################################
check_tc_sid_unused() {
    section "TRUE CACHE SID SAFETY CHECK"
    local script
    script=$(
        cat <<EOF
set -u
SID=$(printf '%q' "$TC_SID")
if pgrep -x "ora_pmon_\$SID" >/dev/null 2>&1; then
    echo "__PMON_EXISTS__"
    exit 10
fi
if [ -f /etc/oratab ];
then
    awk -F: -v sid="\$SID" '
        \$1==sid && \$2!="" && \$2 !~ /^[*]/ {
            print
"__ORATAB_EXISTS__:" \$0
        }
    ' /etc/oratab
fi
EOF
    )
    local result
    result="$(role_capture TRUECACHE "$script" || true)"
    printf '%s\n' "$result"
    if printf '%s\n' "$result" | grep -q "__PMON_EXISTS__"; then
        die "True Cache SID $TC_SID is already running. Refusing
to overwrite existing database."
    fi
    if printf '%s\n' "$result" | grep -q "__ORATAB_EXISTS__"; then
        die "True Cache SID $TC_SID already exists in /etc/oratab.
Choose a new SID."
    fi
    log "True Cache SID is unused."
}
###############################################################################
# CREATE LISTENER OPTION
###############################################################################
tc_listener_option() {
    local result
    result="$(detect_tc_listener || true)"
    if printf '%s\n' "$result" | grep -q "__LISTENER_EXISTS__"; then
        echo "-listeners"
        echo "$LISTENER_NAME"
    else
        echo "-createListener"
        echo "${LISTENER_NAME}:${LISTENER_PORT}"
    fi
}
###############################################################################
# CREATE TRUE CACHE SOURCE CONNECTION VALIDATION
###############################################################################
validate_create_true_cache_source() {
    section "TRUE CACHE -> PRIMARY DBCA SOURCE VALIDATION"

    local ez_host ez_port ez_service
    ez_host="$(parse_ezconnect_host "$PRIMARY_EZ")"
    ez_port="$(parse_ezconnect_port "$PRIMARY_EZ")"
    ez_service="${PRIMARY_EZ#*/}"

    [[ -n "$ez_host" && -n "$ez_port" && -n "$ez_service" ]] ||
        die "Invalid Primary EZConnect for DBCA: $PRIMARY_EZ"

    log "DBCA source host   : $ez_host"
    log "DBCA source port   : $ez_port"
    log "DBCA source service: $ez_service"

    local script
    script=$(
        cat <<EOF
set -u
HOST=$(printf '%q' "$ez_host")
PORT=$(printf '%q' "$ez_port")

if command -v nc >/dev/null 2>&1; then
    nc -z -w 5 "\$HOST" "\$PORT" >/dev/null 2>&1
    rc=\$?
elif command -v timeout >/dev/null 2>&1; then
    timeout 5 bash -c "</dev/tcp/\$HOST/\$PORT" >/dev/null 2>&1
    rc=\$?
else
    bash -c "</dev/tcp/\$HOST/\$PORT" >/dev/null 2>&1
    rc=\$?
fi

echo "PRIMARY_LISTENER_TCP_RC=\$rc"
exit \$rc
EOF
    )

    role_exec_tty TRUECACHE "$script" ||
        die "True Cache cannot reach Primary listener at $PRIMARY_EZ."

    local env_script
    env_script="$(oracle_env_script "$TC_SID" "$TC_OH" "$TC_BASE")"
    script=$(
        cat <<EOF
set -u
$env_script
if [ -x "\$ORACLE_HOME/bin/tnsping" ]; then
    echo "--- tnsping $PRIMARY_EZ ---"
    "\$ORACLE_HOME/bin/tnsping" $(printf '%q' "$PRIMARY_EZ") 3
    rc=\$?
    echo "TNSPING_RC=\$rc"
    exit \$rc
else
    echo "tnsping not available; TCP validation already passed."
fi
EOF
    )

    role_exec TRUECACHE "$script" ||
        die "True Cache cannot resolve/connect to Primary EZConnect $PRIMARY_EZ."

    log "DBCA source listener validation: OK"
}

###############################################################################
# CREATE TRUE CACHE
###############################################################################
create_true_cache() {
    section "CREATE TRUE CACHE"
    if [[ "$DRY_RUN" -eq 1 ]]; then
        log "DRY RUN: DBCA createTrueCache would
execute."
        echo
        echo "DBCA command:"
        echo "  $TC_OH/bin/dbca -createTrueCache \\"
        echo "   
-gdbName $TC_GDB \\"
        echo "    -sid $TC_SID \\"
        echo "   
-sourceDBConnectionString $PRIMARY_EZ \\"
        echo "   
-trueCacheBlobFromSourceDB $BLOB_TC \\"
        echo "   
-sgaTargetInMB $SGA_MB \\"
        echo "   
-pgaAggregateTargetInMB $PGA_MB \\"
        echo "   
..."
        return 0
    fi
    local listener_args
    listener_args="$(tc_listener_option)"
    local listener_opt listener_val
    listener_opt="$(printf '%s\n' "$listener_args" | sed -n '1p')"
    listener_val="$(printf '%s\n' "$listener_args" | sed -n '2p')"
    local env_script
    env_script="$(oracle_env_script "$TC_SID" "$TC_OH" "$TC_BASE")"
    local script
    script=$(
        cat <<EOF
set -u
$env_script
BLOB=$(printf '%q' "$BLOB_TC")
[ -s "\$BLOB" ] || {
    echo "True Cache BLOB missing."
    exit 20
}
CMD=(
    "\$ORACLE_HOME/bin/dbca"
    "-createTrueCache"
    "-gdbName" $(printf '%q' "$TC_GDB")
    "-sid" $(printf '%q' "$TC_SID")
    "-sourceDBConnectionString" $(printf '%q' "$PRIMARY_EZ")
    "-trueCacheBlobFromSourceDB"
"\$BLOB"
    "-sgaTargetInMB" $(printf '%q' "$SGA_MB")
    "-pgaAggregateTargetInMB" $(printf '%q' "$PGA_MB")
)
CMD+=(
    $(printf '%q' "$listener_opt")
    $(printf '%q' "$listener_val")
)
CMD+=("-silent")
echo
echo "Executing DBCA
createTrueCache..."
echo "Oracle Home: \$ORACLE_HOME"
echo "Primary
EZConnect: $(printf '%q' "$PRIMARY_EZ")"
echo "True Cache
SID: $(printf '%q' "$TC_SID")"
echo "True Cache
GDB: $(printf '%q' "$TC_GDB")"
echo
if [ ! -c /dev/tty ]; then
    echo "ERROR: DBCA createTrueCache cannot access /dev/tty."
    exit 90
fi
"\${CMD[@]}" < /dev/tty
rc=\$?
echo
echo "DBCA return
code: \$rc"
exit \$rc
EOF
    )
    role_exec_tty TRUECACHE "$script" ||
        die "DBCA -createTrueCache failed."
    log "True Cache DBCA creation completed."
}
###############################################################################
# TC DATABASE INFORMATION
###############################################################################
get_tc_database_info() {
    local result
    result="$(
        role_sql TRUECACHE "
select
    name||'|'||
    db_unique_name||'|'||
    database_role||'|'||
    open_mode||'|'||
    cdb
from v\$database;
" |
        tr -d '\r' |
        sed '/^[[:space:]]*$/d' |
        head -1
    )"
    printf '%s' "$result"
}
###############################################################################
# TC SERVICE DISCOVERY
###############################################################################
discover_tc_cdb_service() {
    local services
    services="$(
        role_sql TRUECACHE "
select name
from v\$services
where con_id=1
  and upper(name) not in
      ('SYS\$BACKGROUND','SYS\$USERS','XDB')
order by name;
" |
        tr -d '\r' |
        sed '/^[[:space:]]*$/d'
    )"
#
# Prefer GDB name.
#
    if printf '%s\n' "$services" |
       grep -Fxqi "$TC_GDB"; then
        TC_CDB_SERVICE="$TC_GDB"
        return 0
    fi
#
# Otherwise first CDB service.
#
    TC_CDB_SERVICE="$(printf '%s\n' "$services" | head -1)"
    if [[ -z "$TC_CDB_SERVICE" ]]; then
        TC_CDB_SERVICE="$TC_GDB"
        warn "Could not discover TC CDB service. Assuming $TC_GDB."
    fi
    log "True Cache CDB service: $TC_CDB_SERVICE"
}
###############################################################################
# CONFIGURE SERVICE
###############################################################################

###############################################################################
# CONFIGURE SERVICE
###############################################################################
###############################################################################
# CONFIGURE SERVICE
###############################################################################
configure_true_cache_service() {
    [[ "$SKIP_SERVICE" -eq 1 ]] && {
        log "True Cache service configuration skipped."
        return 0
    }

    section "CONFIGURE TRUE CACHE SERVICE"

    [[ -n "$PRIMARY_SERVICE" ]] || die "Primary service is required for service configuration."
    [[ -n "$PDB_NAME" ]] || die "PDB is required for service configuration."
    [[ -n "$TC_SERVICE" ]] || die "True Cache service is required for service configuration."

    # The DBCA service command is intentionally executed from PRIMARY.
    # For multiple True Caches serving the same Primary service, Oracle says
    # to run this DBCA command once, then manually start the same True Cache
    # service on each additional True Cache.
    discover_tc_cdb_service
    local tc_ez="${TC_HOST}:${LISTENER_PORT}/${TC_CDB_SERVICE}"

    log "Primary service: $PRIMARY_SERVICE"
    log "Primary PDB: $PDB_NAME"
    log "True Cache service: $TC_SERVICE"
    log "True Cache CDB EZConnect: $tc_ez"

    local primary_service_ok
    primary_service_ok="$(role_sql PRIMARY "
set heading off feedback off pages 0 verify off echo off
select count(*)
from v\$services s
join v\$pdbs p on p.con_id=s.con_id
where upper(p.name)=upper('$(printf '%s' "$PDB_NAME")')
  and upper(s.name)=upper('$(printf '%s' "$PRIMARY_SERVICE")');
" 2>/dev/null | tr -d '[:space:]')"
    [[ "$primary_service_ok" == "1" ]] ||
        die "Primary service '$PRIMARY_SERVICE' does not exist for PDB '$PDB_NAME'. DBCA requires the existing Primary PDB service."

    local associated_tc_service
    associated_tc_service="$(role_sql PRIMARY "
set heading off feedback off pages 0 verify off echo off
select true_cache_service
from v\$active_services
where upper(name)=upper('$(printf '%s' "$PRIMARY_SERVICE")')
  and true_cache_service is not null;
" 2>/dev/null | tr -d '\r' | sed '/^[[:space:]]*$/d' | head -1)"

    if [[ -n "$associated_tc_service" ]]; then
        if [[ "${associated_tc_service^^}" != "${TC_SERVICE^^}" ]]; then
            die "Primary service '$PRIMARY_SERVICE' is already associated with True Cache service '$associated_tc_service'. Do not create '$TC_SERVICE' as a second service for the same Primary service. Reuse '$associated_tc_service' for the additional True Cache."
        fi
        TC_SERVICE_EXISTING_ON_PRIMARY=1
        log "Primary service '$PRIMARY_SERVICE' is already associated with True Cache service '$TC_SERVICE'."
    fi

    if [[ "$DRY_RUN" -eq 1 ]]; then
        if [[ "$TC_SERVICE_EXISTING_ON_PRIMARY" -eq 1 ]]; then
            log "DRY RUN: DBCA service association will NOT be rerun; existing service '$TC_SERVICE' will be started on $TC_HOST."
        else
            log "DRY RUN: DBCA will run ON PRIMARY to configure '$PRIMARY_SERVICE' -> '$TC_SERVICE'."
            log "DRY RUN: DBCA True Cache CDB target: $tc_ez"
        fi
        return 0
    fi

    if [[ "$TC_SERVICE_EXISTING_ON_PRIMARY" -eq 0 ]]; then
        #######################################################################
        # FIRST TRUE CACHE FOR THIS PRIMARY SERVICE
        #
        # DBCA is run ON PRIMARY. It creates/updates the True Cache service
        # association on the Primary and starts that service on the first TC.
        #######################################################################
        local TCAUT_SYS_PASSWORD="${TCAUT_SYS_PASSWORD:-}"
        if [[ -z "$TCAUT_SYS_PASSWORD" ]]; then
            if [[ "$AUTO_YES" -eq 1 ]]; then
                die "True Cache SYS password is required for DBCA service configuration. Set TCAUT_SYS_PASSWORD before running with --yes."
            fi
            echo
            read -r -s -p "Enter SYS password for True Cache ($TC_HOST): " TCAUT_SYS_PASSWORD
            echo
            [[ -n "$TCAUT_SYS_PASSWORD" ]] || die "True Cache SYS password was not supplied."
        fi

        local env_script script
        env_script="$(oracle_env_script "$PRIMARY_SID" "$PRIMARY_OH" "$PRIMARY_BASE")"
        script=$(cat <<EOF
set -u
$env_script
SYS_USER="SYS"
SYS_PASSWORD=$(printf '%q' "$TCAUT_SYS_PASSWORD")

CMD=(
    "\$ORACLE_HOME/bin/dbca"
    "-configureDatabase"
    "-configureTrueCacheInstanceService"
    "-sourceDB" $(printf '%q' "$PRIMARY_DB_UNIQUE")
    "-trueCacheConnectString" $(printf '%q' "$tc_ez")
    "-trueCacheServiceName" $(printf '%q' "$TC_SERVICE")
    "-serviceName" $(printf '%q' "$PRIMARY_SERVICE")
    "-pdbName" $(printf '%q' "$PDB_NAME")
    "-sysDBAUserName" "\$SYS_USER"
    "-sysDBAPassword" "\$SYS_PASSWORD"
    "-silent"
)

echo "Executing DBCA True Cache service configuration ON PRIMARY..."
echo "Primary DB: $(printf '%q' "$PRIMARY_DB_UNIQUE")"
echo "Primary service: $(printf '%q' "$PRIMARY_SERVICE")"
echo "PDB: $(printf '%q' "$PDB_NAME")"
echo "True Cache CDB: $(printf '%q' "$tc_ez")"
echo "True Cache service: $(printf '%q' "$TC_SERVICE")"
"\${CMD[@]}"
rc=\$?
unset SYS_PASSWORD
exit \$rc
EOF
)

        role_exec PRIMARY "$script" ||
            die "DBCA True Cache service configuration failed on Primary."

        log "DBCA True Cache service configuration completed on Primary."
        return 0
    fi

    ###########################################################################
    # ADDITIONAL TRUE CACHE FOR AN EXISTING UNIFORM SERVICE
    #
    # DO NOT rerun DBCA -configureTrueCacheInstanceService. Oracle documents
    # that for multiple True Caches serving the same service, DBCA is run once
    # and the existing True Cache service is manually started on additional
    # True Caches. This START is deliberately executed against the NEW TC, not
    # the Primary, and it does not create a new service.
    ###########################################################################
    log "Existing uniform True Cache service detected."
    log "DBCA will NOT be rerun for $TC_HOST."
    log "Starting existing True Cache service '$TC_SERVICE' on additional True Cache."

    local env_script tc_script
    env_script="$(oracle_env_script "$TC_SID" "$TC_OH" "$TC_BASE")"
    tc_script=$(cat <<EOF
set -u
$env_script

SERVICE=$(printf '%q' "$TC_SERVICE")

# Service must already exist on the True Cache. We intentionally do not
# CREATE_SERVICE here: service creation/association belongs to Primary DBCA.
SERVICE_EXISTS=\$(\"\$ORACLE_HOME/bin/sqlplus\" -s / as sysdba <<SQL
set heading off feedback off pages 0 verify off echo off
select count(*) from v\$services where upper(name)=upper('$(printf '%s' "$TC_SERVICE")');
exit
SQL
)
SERVICE_EXISTS=\$(printf '%s' "\$SERVICE_EXISTS" | tr -d '[:space:]')

if [[ "\$SERVICE_EXISTS" != "1" ]]; then
    echo "True Cache service '$TC_SERVICE' does not exist on $TC_HOST."
    echo "DBCA must establish the service association from the Primary before it can be started on an additional True Cache."
    exit 41
fi

"\$ORACLE_HOME/bin/sqlplus" -s / as sysdba <<SQL
set serveroutput on
begin
    dbms_service.start_service(service_name => '$(printf '%s' "$TC_SERVICE")');
end;
/
exit
SQL
rc=\$?
exit \$rc
EOF
)

    role_exec TRUECACHE "$tc_script" ||
        die "Unable to start existing True Cache service '$TC_SERVICE' on additional True Cache $TC_HOST. No service was created on the True Cache."

    log "Existing True Cache service '$TC_SERVICE' started on $TC_HOST."
}

###############################################################################
# REMOTE LISTENER VALIDATION
###############################################################################
check_remote_listener() {
    [[ "$SKIP_SERVICE" -eq 1 ]] && return 0
    section "REMOTE LISTENER CHECK"
    local result
    result="$(
        role_sql TRUECACHE "
select value
from v\$parameter
where name='remote_listener';
" |
        tr -d '\r' |
        sed '/^[[:space:]]*$/d'
    )"
    if [[ -n "$result" ]]; then
        log "True Cache REMOTE_LISTENER: $result"
    else
        warn "True Cache REMOTE_LISTENER is empty."
        warn "Review listener/service registration if DBCA
service configuration or applications cannot connect."
    fi
}
###############################################################################
# VNCR CHECK
###############################################################################
check_vncr() {
    [[ "$SKIP_VNCR" -eq 1 ]] && return 0
    [[ "$SKIP_SERVICE" -eq 1 ]] && return 0
    section "VNCR / LISTENER REGISTRATION CHECK"
#
# We inspect listener configuration only.
# We do not automatically rewrite listener.ora.
#
    local script
    script=$(
        cat <<EOF
set -u
ORACLE_HOME=$(printf '%q' "$PRIMARY_OH")
TC_HOST=$(printf '%q' "$TC_HOST")
for f in "\${TNS_ADMIN:-/does/not/exist}/listener.ora" "\$ORACLE_HOME/network/admin/listener.ora"; do
    [ -f "\$f" ] || continue
    echo "Inspecting \$f"
    grep -iE 'VALID_NODE_CHECKING_REGISTRATION|REGISTRATION_INVITED_NODES|invited|SECURE_REGISTER' "\$f" 2>/dev/null || true
done
EOF
    )
    role_exec PRIMARY "$script" || true
    warn "VNCR configuration is installation/listener
specific. If registration is blocked, add the True Cache host to the listener's
allowed registration nodes according to your Oracle Grid/listener
configuration."
}
###############################################################################
# REDO TRANSPORT
###############################################################################
configure_redo_transport() {
    [[ -n "$REDO_TRANSPORT" ]] || return 0
    case "$REDO_TRANSPORT" in
        async|sync) ;;
        *) die "--redo-transport must be
async or sync." ;;
    esac
    section "CONFIGURE REDO TRANSPORT"
    log "Requested True Cache redo transport: $REDO_TRANSPORT"
    if [[ "$DRY_RUN" -eq 1 ]]; then
        log "DRY RUN: redo transport would be set to $REDO_TRANSPORT."
        return 0
    fi
    local sql="
alter system set
true_cache_config=
'redo_transport=$REDO_TRANSPORT'
append scope=spfile;
"
    role_sql TRUECACHE "$sql" >/dev/null ||
        die "Unable to configure TRUE_CACHE_CONFIG redo
transport."
    log "Redo transport set in SPFILE."
    log "True Cache must be restarted for this static
setting."
    if [[ "$AUTO_YES" -eq 0 ]]; then
        read -r -p "Restart True Cache now? [y/N]: " answer
        case "${answer,,}" in
            y|yes)
                restart_true_cache
                ;;
            *)
                warn "True Cache was NOT
restarted. Redo transport change is pending restart."
                ;;
        esac
    else
        restart_true_cache
    fi
}
restart_true_cache() {
    section "RESTART TRUE CACHE"
    local env_script
    env_script="$(oracle_env_script "$TC_SID" "$TC_OH" "$TC_BASE")"
    local script
    script=$(
        cat <<EOF
set -u
$env_script
"\$ORACLE_HOME/bin/sqlplus" -s / as sysdba <<'__TCAUT_SQL__'
whenever sqlerror exit 1
shutdown immediate;
startup;
exit
__TCAUT_SQL__
EOF
    )
    role_exec TRUECACHE "$script" ||
        die "True Cache restart failed."
    log "True Cache restarted."
}
###############################################################################
# TC VERIFICATION
###############################################################################
verify_true_cache() {
    section "TRUE CACHE VERIFICATION"
    local result
    result="$(
        get_tc_database_info
    )"
    echo "True Cache database:"
    echo "$result"
    local name dbuniq role openmode cdb
    IFS='|' read -r name dbuniq role openmode cdb <<< "$result"
    if [[ "$role" != "TRUE CACHE" ]]; then
        error "Expected DATABASE_ROLE=TRUE CACHE but received:
$role"
    else
        log "DATABASE_ROLE=TRUE CACHE: OK"
    fi
    if [[ "$openmode" != "READ ONLY WITH APPLY" ]]; then
        error "Expected OPEN_MODE=READ ONLY WITH APPLY but
received: $openmode"
    else
        log "OPEN_MODE=READ ONLY WITH APPLY: OK"
    fi
    if [[ "$cdb" != "YES" ]]; then
        warn "True Cache CDB flag is $cdb."
    fi
    echo
    echo 'V$TRUE_CACHE:'
    role_sql TRUECACHE "
select * from v\$true_cache;
" || true
    echo
    echo 'Standby redo logs:'
    role_sql TRUECACHE "
select thread#,
sequence#, bytes
from v\$standby_log
order by thread#,
sequence#;
" || true
    echo
    echo 'Active services:'
    role_sql TRUECACHE "
select service_id,name
from v\$active_services
order by name;
" || true
    if [[ -n "$TC_SERVICE" ]]; then
        local svc_count
        svc_count="$(
            role_sql TRUECACHE "
select count(*)
from v\$active_services
where upper(name)=upper('$(printf '%s' "$TC_SERVICE")');
" |
            tr -d '[:space:]'
        )"
        if [[ "$svc_count" == "1" ]]; then
            log "True Cache service $TC_SERVICE: ACTIVE"
        else
            warn "True Cache service $TC_SERVICE is not active."
        fi
    fi
}
###############################################################################
# SCN ADVANCEMENT
###############################################################################
verify_scn_advancement() {
    section "TRUE CACHE SCN ADVANCEMENT"
    local scn1 scn2
    scn1="$(
        role_sql TRUECACHE "
select current_scn from v\$database;
" |
        tr -d '[:space:]'
    )"
    log "Initial CURRENT_SCN: $scn1"
    sleep 5
    scn2="$(
        role_sql TRUECACHE "
select current_scn from v\$database;
" |
        tr -d '[:space:]'
    )"
    log "Later CURRENT_SCN : $scn2"
    if [[ "$scn1" =~ ^[0-9]+$ && "$scn2" =~ ^[0-9]+$ ]]; then
        if (( scn2 > scn1 )); then
            log "CURRENT_SCN advanced:
APPLY activity is progressing."
        else
            warn "CURRENT_SCN did not
advance during the sample interval."
        fi
    else
        warn "Could not compare CURRENT_SCN values."
    fi
}
###############################################################################
# PRIMARY TRUE CACHE VIEW
###############################################################################
verify_primary_true_cache() {
    section "PRIMARY TRUE CACHE STATUS"
    role_sql PRIMARY "
select * from v\$true_cache;
" || true
    if [[ -n "$PRIMARY_SERVICE" ]]; then
        role_sql PRIMARY "
select
service_id,name,true_cache_service
from v\$active_services
where upper(name)=upper('$(printf '%s' "$PRIMARY_SERVICE")');
" || true
    fi
}
###############################################################################
# REPORT
###############################################################################
html_escape() {
    sed \
        -e 's/&/\&amp;/g' \
        -e 's/</\&lt;/g' \
        -e 's/>/\&gt;/g' \
        -e 's/"/\&quot;/g'
}
generate_report() {
    section "GENERATE REPORT"
    local status="$1"
    {
        echo '<!DOCTYPE html>'
        echo '<html><head><meta
charset="UTF-8">'
        echo '<title>Oracle True Cache Deployment
Report</title>'
        cat <<'HTML'
<style>
body {
    font-family: Arial, Helvetica, sans-serif;
    margin: 30px;
    background: #f6f7f9;
    color: #20242a;
}
h1,h2 { color:#20242a; }
table {
    border-collapse: collapse;
    width: 100%;
    background: white;
    margin-bottom: 25px;
}
th,td {
    border: 1px solid #d8dce1;
    padding: 8px;
    text-align: left;
}
th { background:#eef1f4;
}
.ok { color:#176b35;
font-weight\:bold; }
.warn { color:#9a6500;
font-weight\:bold; }
.err { color:#a11;
font-weight\:bold; }
pre {
    background:#111820;
    color:#e8edf2;
    padding:15px;
    overflow\:auto;
    border-radius:5px;
}
</style>
HTML
        echo '</head><body>'
        echo '<h1>Oracle 26ai True Cache Deployment
Report</h1>'
        echo '<table>'
        echo "<tr><th>Version</th><td>$VERSION</td></tr>"
        echo "<tr><th>Execution
Host</th><td>$(printf '%s' "$EXEC_HOST" | html_escape)</td></tr>"
        echo "<tr><th>Start</th><td>$(printf '%s' "$START_TIME" | html_escape)</td></tr>"
        echo "<tr><th>End</th><td>$(timestamp)</td></tr>"
        if [[ "$status" == "SUCCESS" ]]; then
            echo '<tr><th>Status</th><td
class="ok">SUCCESS</td></tr>'
        else
            echo '<tr><th>Status</th><td
class="err">FAILED</td></tr>'
        fi
        echo '</table>'
        echo '<h2>Primary</h2>'
        echo '<table>'
        echo "<tr><th>Host</th><td>$(printf '%s' "$PRIMARY_HOST" | html_escape)</td></tr>"
        echo "<tr><th>SID</th><td>$(printf '%s' "$PRIMARY_SID" | html_escape)</td></tr>"
        echo "<tr><th>DB
Name</th><td>$(printf '%s' "$PRIMARY_DB_NAME" | html_escape)</td></tr>"
        echo "<tr><th>DB Unique
Name</th><td>$(printf '%s' "$PRIMARY_DB_UNIQUE" | html_escape)</td></tr>"
        echo "<tr><th>Oracle
Home</th><td>$(printf '%s' "$PRIMARY_OH" | html_escape)</td></tr>"
        echo "<tr><th>Oracle
Base</th><td>$(printf '%s' "$PRIMARY_BASE" | html_escape)</td></tr>"
        echo "<tr><th>EZConnect</th><td>$(printf '%s' "$PRIMARY_EZ" | html_escape)</td></tr>"
        echo '</table>'
        echo '<h2>True Cache</h2>'
        echo '<table>'
        echo "<tr><th>Host</th><td>$(printf '%s' "$TC_HOST" | html_escape)</td></tr>"
        echo "<tr><th>SID</th><td>$(printf '%s' "$TC_SID" | html_escape)</td></tr>"
        echo "<tr><th>GDB
Name</th><td>$(printf '%s' "$TC_GDB" | html_escape)</td></tr>"
        echo "<tr><th>Oracle
Home</th><td>$(printf '%s' "$TC_OH" | html_escape)</td></tr>"
        echo "<tr><th>Oracle
Base</th><td>$(printf '%s' "$TC_BASE" | html_escape)</td></tr>"
        echo "<tr><th>Service</th><td>$(printf '%s' "$TC_SERVICE" | html_escape)</td></tr>"
        echo "<tr><th>Listener</th><td>$(printf '%s' "$LISTENER_NAME:$LISTENER_PORT" | html_escape)</td></tr>"
        echo "<tr><th>SGA MB</th><td>$SGA_MB</td></tr>"
        echo "<tr><th>PGA MB</th><td>$PGA_MB</td></tr>"
        echo '</table>'
        echo '<h2>True Cache Sizing Evidence</h2>'
        echo '<table>'
        echo "<tr><th>Worst AWR Snapshots</th><td>$(printf '%s -> %s' "${PRIMARY_AWR_BID:-N/A}" "${PRIMARY_AWR_EID:-N/A}" | html_escape)</td></tr>"
        echo "<tr><th>Worst Interval</th><td>$(printf '%s -> %s' "${PRIMARY_AWR_BEGIN:-N/A}" "${PRIMARY_AWR_END:-N/A}" | html_escape)</td></tr>"
        echo "<tr><th>DB Time/sec (AAS)</th><td>$(printf '%s' "${PRIMARY_AWR_AAS:-N/A}" | html_escape)</td></tr>"
        echo "<tr><th>Read-Only Workload %</th><td>${TC_READ_ONLY_PCT:-N/A}</td></tr>"
        echo "<tr><th>Primary DB Cache MB</th><td>$TC_PRIMARY_BUFFER_MB</td></tr>"
        echo "<tr><th>Primary Shared Pool MB</th><td>$TC_SHARED_POOL_MB</td></tr>"
        echo "<tr><th>Primary SGA Target MB</th><td>$TC_PRIMARY_SGA_TARGET_MB</td></tr>
        <tr><th>Primary PGA Target MB</th><td>$TC_PRIMARY_PGA_TARGET_MB</td></tr>
        <tr><th>Primary Maximum PGA MB</th><td>$TC_PRIMARY_PGA_MAX_MB</td></tr>"
        echo "<tr><th>Recommended TC Buffer Cache MB</th><td>$TC_RECOMMENDED_BUFFER_MB</td></tr>"
        echo "<tr><th>Recommended TC SGA MB</th><td>$TC_RECOMMENDED_SGA_MB</td></tr>
        <tr><th>Recommended TC PGA MB</th><td>$TC_RECOMMENDED_PGA_MB</td></tr>"
        echo "<tr><th>Recommended TC Flash Cache MB</th><td>$TC_FLASH_CACHE_MB</td></tr>"
        echo "<tr><th>Flash Cache DRAM Metadata MB</th><td>$TC_FLASH_METADATA_MB</td></tr>"
        echo "<tr><th>Buffer Cache Hit Ratio %</th><td>${TC_BUFFER_CACHE_HIT_PCT:-N/A}</td></tr>"
        echo "<tr><th>True Cache Hit Ratio Estimate %</th><td>${TC_TRUE_CACHE_HIT_PCT:-N/A}</td></tr>"
        echo "<tr><th>AWR HTML</th><td>$(printf '%s' "${PRIMARY_AWR_REPORT:-N/A}" | html_escape)</td></tr>"
        echo '</table>'
        if [ -n "$WARNINGS" ]; then
            echo '<h2>Warnings</h2><ul>'
            local w
            while IFS= read -r w; do
                [ -n "$w" ] || continue
                echo "<li class=\"warn\">$(printf '%s' "$w" | html_escape)</li>"
            done <<EOF_WARNINGS
$WARNINGS
EOF_WARNINGS
            echo '</ul>'
        fi
        if [ -n "$ERRORS" ]; then
            echo '<h2>Errors</h2><ul>'
            local e
            while IFS= read -r e; do
                [ -n "$e" ] || continue
                echo "<li class=\"err\">$(printf '%s' "$e" | html_escape)</li>"
            done <<EOF_ERRORS
$ERRORS
EOF_ERRORS
            echo '</ul>'
        fi
        echo '<h2>Execution Log</h2>'
        echo '<pre>'
        html_escape < "$LOG_FILE"
        echo '</pre>'
        echo '</body></html>'
    } > "$HTML_FILE"
    log "HTML report: $HTML_FILE"
    log "Log file   
: $LOG_FILE"
}
###############################################################################
# CLEANUP
###############################################################################
cleanup() {
    section "30_CLEANUP"
    if [[ -S "$PRIMARY_CTL" ]]; then
        log "Closing Primary SSH ControlMaster."
        ssh -S "$PRIMARY_CTL" -O exit \
            "$(role_user PRIMARY)@$(role_host PRIMARY)" \
            >/dev/null 2>&1 || true
    fi
    if [[ -S "$TC_CTL" ]]; then
        log "Closing True Cache SSH ControlMaster."
        ssh -S "$TC_CTL" -O exit \
            "$(role_user TRUECACHE)@$(role_host TRUECACHE)" \
            >/dev/null 2>&1 || true
    fi
    rm -f "$PRIMARY_CTL" "$TC_CTL" 2>/dev/null || true
    if [[ "$KEEP_ARTIFACTS" -eq 0 ]]; then
        if [[ -f "$BLOB_LOCAL" ]]; then
            rm -f "$BLOB_LOCAL"
            log "Temporary local BLOB
removed."
        fi
    else
        log "BLOB retained because --keep-artifacts was
specified."
    fi
    if [[ -n "$BLOB_TC" && "$KEEP_ARTIFACTS" -eq 0 ]]; then
        local script
        script=$(
            cat <<EOF
rm -f $(printf '%q' "$BLOB_TC") 2>/dev/null || true
EOF
        )
        role_exec TRUECACHE "$script" >/dev/null 2>&1 || true
    fi
    if [[ "$KEEP_ARTIFACTS" -eq 1 ]]; then
        log "Deployment artifacts retained at:"
        log "$WORK_DIR"
    else
        log "Deployment log/report retained at:"
        log "$WORK_DIR"
    fi
}
###############################################################################
# MAIN
###############################################################################
main() {
    parse_args "$@"
    validate_host_value "Primary host" "$PRIMARY_HOST"
    validate_host_value "True Cache host" "$TC_HOST"
    validate_port "Primary SSH port" "$PRIMARY_SSH_PORT"
    validate_port "True Cache SSH port" "$TC_SSH_PORT"
    validate_port "Listener port" "$LISTENER_PORT"
    section "00_INITIALIZATION"
    log "$(basename "$0") version: V$VERSION"
    log "Execution host: $EXEC_HOST"
    log "Run ID: $RUN_ID"
    log "Work directory: $WORK_DIR"
    if [[ "$EUID" -ne 0 ]]; then
        log "Running as UID $EUID."
    fi
#
# Never SSH to ourselves.
#
    if is_local_host "$PRIMARY_HOST"; then
        log "Primary host is the execution host: LOCAL"
    else
        log "Primary host is remote: $PRIMARY_HOST"
    fi
    if is_local_host "$TC_HOST"; then
        log "True Cache host is the execution host:
LOCAL"
    else
        log "True Cache host is remote: $TC_HOST"
    fi
    section "01_CONNECTIVITY"
    ensure_connection PRIMARY
    ensure_connection TRUECACHE
    section "02_DISCOVER_PRIMARY"
    discover_primary_sid
    discover_primary_home
#
# Determine Primary Base before runtime validation.
#
    PRIMARY_BASE="$(derive_oracle_base "$PRIMARY_OH")"
    normalize_oracle_environment PRIMARY
    section "03_VALIDATE_PRIMARY_ORACLE_HOME"
    local primary_home_check
    primary_home_check="$(validate_oracle_home PRIMARY "$PRIMARY_OH" || true)"
    printf '%s\n' "$primary_home_check"
    printf '%s\n' "$primary_home_check" |
        grep -q "__VALID_DB_HOME__" ||
        die "Primary Oracle Home is not a complete Database
Home."
    detect_stale_oracle_home_reference PRIMARY "$PRIMARY_OH" || {
        rc=$?
        if [[ "$rc" -eq 2 ]]; then
            die "Primary Oracle Home
contains stale references to another Oracle Home."
        fi
    }
    validate_oracle_runtime PRIMARY
    validate_dbca_launcher PRIMARY
    section "04_VALIDATE_PRIMARY_DATABASE"
    validate_primary_database
    check_log_archive_parameters
    validate_primary_listener
    section "05_PRIMARY_CONNECTION"
    choose_primary_ezconnect
    choose_pdb
    choose_primary_service
#
# Primary CDB EZConnect may have been supplied manually.
#
    [[ -n "$PRIMARY_EZ" ]] ||
        die "Primary EZConnect is required."
    section "06_DISCOVER_TRUE_CACHE_ORACLE_HOME"
    discover_tc_home
    TC_BASE="$(derive_oracle_base "$TC_OH")"
#
# Fresh TC has no SID yet, so normalization of TC environment
# is done without requiring PMON.
#
#
# Use a temporary SID for environment only until the real TC SID
# is selected.
#
    if [[ -z "$TC_SID" ]]; then
        TC_SID="${PRIMARY_SID}_TC"
    fi
    validate_oracle_name "True Cache SID" "$TC_SID"
    normalize_oracle_environment TRUECACHE
    section "07_VALIDATE_TRUE_CACHE_ORACLE_HOME"
    local tc_home_check
    tc_home_check="$(validate_oracle_home TRUECACHE "$TC_OH" || true)"
    printf '%s\n' "$tc_home_check"
    printf '%s\n' "$tc_home_check" |
        grep -q "__VALID_DB_HOME__" ||
        die "True Cache Oracle Home is not a complete
Database Home."
    detect_stale_oracle_home_reference TRUECACHE "$TC_OH" || {
        rc=$?
        if [[ "$rc" -eq 2 ]]; then
            die "True Cache Oracle Home
contains stale references to another Oracle Home."
        fi
    }
    validate_oracle_runtime TRUECACHE
    validate_dbca_launcher TRUECACHE
    section "08_TRUE_CACHE_CONFIGURATION"
    choose_tc_identifiers
    calculate_tc_memory
    detect_tc_listener
    check_tc_sid_unused
    check_tc_to_primary
    show_plan
    confirm_deployment
    section "09_DBCA_PREPARATION"
    validate_create_true_cache_source
    prepare_true_cache_blob
    copy_blob_to_tc
    section "10_TRUE_CACHE_CREATION"
    create_true_cache
    section "11_POST_CREATE"
#
# DBCA should have created/started the database.
#
    sleep 5
    verify_true_cache
    verify_scn_advancement
    section "12_SERVICE_CONFIGURATION"
    configure_true_cache_service
    check_remote_listener
    check_vncr
    section "13_REDO_TRANSPORT"
    configure_redo_transport
    section "14_FINAL_VERIFICATION"
    verify_true_cache
    verify_scn_advancement
    verify_primary_true_cache
    DEPLOY_STATUS="SUCCESS"
    generate_report "SUCCESS"
    cleanup
    section "COMPLETE"
    echo
    echo "TRUE CACHE DEPLOYMENT SUCCESSFUL"
    echo
    echo "Primary:"
    echo "  $PRIMARY_HOST / $PRIMARY_SID"
    echo
    echo "True Cache:"
    echo "  $TC_HOST / $TC_SID"
    echo
    echo "Oracle Home:"
    echo "  $TC_OH"
    echo
    echo "Report:"
    echo "  $HTML_FILE"
    echo
    echo "Log:"
    echo "  $LOG_FILE"
    echo
    exit 0
}
###############################################################################
# EXIT HANDLING
###############################################################################
on_exit() {
    local rc=$?
#
# If main failed, preserve report information.
#
    if [[ "$rc" -ne 0 ]]; then
        DEPLOY_STATUS="FAILED"
#
# Avoid recursive cleanup if cleanup itself triggers exit.
#
        generate_report "FAILED" 2>/dev/null || true
        cleanup 2>/dev/null || true
        echo
        echo "============================================================"
        echo "TRUE CACHE DEPLOYMENT
FAILED"
        echo "============================================================"
        echo "Return code : $rc"
        echo "Work dir   
: $WORK_DIR"
        echo "Log        
: $LOG_FILE"
        echo "Report     
: $HTML_FILE"
        if [[ -n "$FAIL_REASON" ]]; then
            echo "Reason      : $FAIL_REASON"
        fi
        echo
    fi
}
trap on_exit EXIT
main "$@"


