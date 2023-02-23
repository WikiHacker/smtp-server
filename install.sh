#!/bin/sh
# shellcheck shell=dash

# Stalwart SMTP install script -- based on the rustup installation script.

set -e
set -u

readonly BASE_PATH="/usr/local/stalwart-smtp"
readonly BIN_PATH="${BASE_PATH}/bin"
readonly CFG_PATH="${BASE_PATH}/etc"
readonly QUEUE_PATH="${BASE_PATH}/queue"
readonly LOG_PATH="${BASE_PATH}/logs"
readonly REPORT_PATH="${BASE_PATH}/reports"

readonly BASE_URL="https://github.com/stalwartlabs/smtp-server/releases/latest/download"
readonly CONFIG_URL="https://raw.githubusercontent.com/stalwartlabs/smtp-server/main/resources/config/config.toml"
readonly SYSTEMD_SVC_URL="https://raw.githubusercontent.com/stalwartlabs/smtp-server/main/resources/systemd/stalwart-smtp.service"
readonly LAUNCHCTL_SVC_URL="https://raw.githubusercontent.com/stalwartlabs/smtp-server/main/resources/systemd/stalwart.smtp.plist"

readonly CLI_URL="https://github.com/stalwartlabs/cli/releases/latest/download"

main() {
    downloader --check
    need_cmd uname
    need_cmd mktemp
    need_cmd chmod
    need_cmd mkdir
    need_cmd rm
    need_cmd rmdir
    need_cmd tar

    # Make sure we are running as root
    if [ "$(id -u)" -ne 0 ] ; then
        err "❌ Install failed: This program needs to run as root."
    fi

    # Detect OS
    local _os="unknown"
    local _uname="$(uname)"
    _account="stalwart-smtp"
    if [ "${_uname}" = "Linux" ]; then
        _os="linux"
    elif [ "${_uname}" = "Darwin" ]; then
        _os="macos"
        _account="_stalwart-smtp"
    fi

    # Start configuration mode
    if [ "$#" -eq 1 ] && [ "$1" = "--init" ]  ; then
        init
        configure
        return 0
    fi

    # Detect platform architecture
    get_architecture || return 1
    local _arch="$RETVAL"
    assert_nz "$_arch" "arch"

    # Download latest binary
    say "⏳ Downloading Stalwart SMTP for ${_arch}..."
    local _dir
    _dir="$(ensure mktemp -d)"
    local _file="${_dir}/stalwart-smtp.tar.gz"
    local _url="${BASE_URL}/stalwart-smtp-${_arch}.tar.gz"
    ensure mkdir -p "$_dir"
    ensure downloader "$_url" "$_file" "$_arch"

    # Create directories and download configuration file
    init

    # Download systemd/launchctl service
    if [ -d /etc/systemd/system ]; then
        if [ ! -f /etc/systemd/system/stalwart-smtp.service ]; then
            say "⬇️  Creating systemd service..."
            ensure downloader "${SYSTEMD_SVC_URL}" /etc/systemd/system/stalwart-smtp.service "systemd-service"
        fi
    elif [ -d /Library/LaunchDaemons ]; then
        if [ ! -f /Library/LaunchDaemons/stalwart.smtp.plist ]; then
            say "⬇️  Creating launchctl service..."
            ensure downloader "${LAUNCHCTL_SVC_URL}" /Library/LaunchDaemons/stalwart.smtp.plist "launchctl-service"
        fi
    fi

    # Create system account
    if ! id -u ${_account} > /dev/null 2>&1; then
        say "🖥️  Creating '${_account}' account..."
        if [ "${_os}" = "macos" ]; then
            local _last_uid="$(dscacheutil -q user | grep uid | awk '{print $2}' | sort -n | tail -n 1)"
            local _last_gid="$(dscacheutil -q group | grep gid | awk '{print $2}' | sort -n | tail -n 1)"
            local _uid="$((_last_uid+1))"
            local _gid="$((_last_gid+1))"

            ensure dscl /Local/Default -create Groups/_stalwart-smtp
            ensure dscl /Local/Default -create Groups/_stalwart-smtp Password \*
            ensure dscl /Local/Default -create Groups/_stalwart-smtp PrimaryGroupID $_gid
            ensure dscl /Local/Default -create Groups/_stalwart-smtp RealName "Stalwart SMTP service"
            ensure dscl /Local/Default -create Groups/_stalwart-smtp RecordName _stalwart-smtp stalwart-smtp

            ensure dscl /Local/Default -create Users/_stalwart-smtp
            ensure dscl /Local/Default -create Users/_stalwart-smtp NFSHomeDirectory /Users/_stalwart-smtp
            ensure dscl /Local/Default -create Users/_stalwart-smtp Password \*
            ensure dscl /Local/Default -create Users/_stalwart-smtp PrimaryGroupID $_gid
            ensure dscl /Local/Default -create Users/_stalwart-smtp RealName "Stalwart SMTP service"
            ensure dscl /Local/Default -create Users/_stalwart-smtp RecordName _stalwart-smtp stalwart-smtp
            ensure dscl /Local/Default -create Users/_stalwart-smtp UniqueID $_uid
            ensure dscl /Local/Default -create Users/_stalwart-smtp UserShell /bin/bash

            ensure dscl /Local/Default -delete /Users/_stalwart-smtp AuthenticationAuthority
            ensure dscl /Local/Default -delete /Users/_stalwart-smtp PasswordPolicyOptions
        else
            ensure useradd ${_account} -s /sbin/nologin -M
        fi
    fi

    # Copy binary
    say "⬇️  Installing Stalwart SMTP at ${BASE_PATH}..."
    ensure tar zxvf "$_file" -C "$_dir"
    ensure mv "$_dir/stalwart-smtp" "${BIN_PATH}/stalwart-smtp"
    ignore rm "$_file"

    # Install systemd service
    if [ -d /etc/systemd/system ]; then
        say "💡  Starting Stalwart SMTP systemd service..."
        ignore /bin/systemctl enable stalwart-smtp
        ignore /bin/systemctl restart stalwart-smtp
    elif [ -d /Library/LaunchDaemons ]; then
        say "💡  Starting Stalwart SMTP launchctl service..."
        ignore launchctl load /Library/LaunchDaemons/stalwart.smtp.plist
        ignore launchctl enable system/stalwart.smtp
        ignore launchctl start system/stalwart.smtp
    fi

    # Download CLI
    local _file="${_dir}/stalwart-cli.tar.gz"
    local _url="${CLI_URL}/stalwart-cli-${_arch}.tar.gz"
    say "⏳ Downloading Stalwart CLI for ${_arch}..."
    ensure mkdir -p "$_dir"
    ensure downloader "$_url" "$_file" "$_arch"

    # Install CLI
    say "⬇️  Installing Stalwart CLI at ${BIN_PATH}/stalwart-cli..."
    ensure tar zxvf "$_file" -C "$_dir"
    ensure mv "$_dir/stalwart-cli" "${BIN_PATH}/stalwart-cli"
    ignore rm "$_file"
    ignore rmdir "$_dir"

    # Configure
    configure

    say "🎉 Installed Stalwart SMTP! To complete the installation edit"
    say "   ${CFG_PATH}/config.toml and restart the Stalwart SMTP service."

    return 0
}

init() {
    # Create directories
    ensure mkdir -p ${BIN_PATH}
    ensure mkdir -p ${QUEUE_PATH}
    ensure mkdir -p ${LOG_PATH}
    ensure mkdir -p ${REPORT_PATH}
    ensure mkdir -p ${CFG_PATH}/certs
    ensure mkdir -p ${CFG_PATH}/private

    # Download configuration file
    if [ ! -f ${CFG_PATH}/config.toml ]; then
        say "⬇️  Creating configuration file at ${CFG_PATH}/config.toml..."
        ensure downloader "${CONFIG_URL}" "${CFG_PATH}/config.toml" "config"
    fi

}

configure() {

    read -p "Enter the SMTP server's hostname [mx.yourdomain.org]: " hostname
    local hostname=${hostname:-mx.yourdomain.org}

    read -p "Enter your domain name [yourdomain.org]: " domain
    local domain=${domain:-yourdomain.org}

    read -p "Enter the SMTP server's admininstrator password [changeme]: " pass
    local pass=${pass:-changeme}

    ignore sed -i -r "s/__HOST__/${hostname}/g; s/__DOMAIN__/${domain}/g; s/__ADMIN_PASS__/${pass}/g;" ${CFG_PATH}/config.toml

    # Create self-signed certificates
    say "🔑  Creating TLS and DKIM certificates..."
    if [ ! -f ${CFG_PATH}/certs/tls.crt ]; then
        ignore openssl req -x509 -nodes -days 1825 -newkey rsa:4096 -subj '/CN=localhost' -keyout ${CFG_PATH}/private/tls.key -out ${CFG_PATH}/certs/tls.crt
    fi
    if [ ! -f ${CFG_PATH}/certs/dkim.crt ]; then
        ignore openssl genrsa -out ${CFG_PATH}/private/dkim.key 2048
        ignore openssl rsa -in ${CFG_PATH}/private/dkim.key -pubout -out ${CFG_PATH}/certs/dkim.crt
    fi

    # Read DKIM cert
    local pk="$(openssl rsa -in ${CFG_PATH}/private/dkim.key -pubout -outform der 2>/dev/null | openssl base64 -A)"
    echo ""
    echo "To enable DKIM please add the following record to your DNS server:"
    echo ""
    echo "Record: stalwart_smtp._domainkey.${domain}"
    echo "Value: v=DKIM1; p=${pk}"
    echo "Type: TXT"
    echo "TTL: 86400"
    echo ""

    # Set permissions
    ensure chown -R ${_account}:${_account} ${BASE_PATH}
    ensure chmod a+rx ${BASE_PATH}
    ensure chmod -R a+rx ${BIN_PATH}
    ensure chmod -R 770 ${CFG_PATH} ${QUEUE_PATH}
}

get_architecture() {
    local _ostype _cputype _bitness _arch _clibtype
    _ostype="$(uname -s)"
    _cputype="$(uname -m)"
    _clibtype="gnu"

    if [ "$_ostype" = Linux ]; then
        if [ "$(uname -o)" = Android ]; then
            _ostype=Android
        fi
        if ldd --version 2>&1 | grep -q 'musl'; then
            _clibtype="musl"
        fi
    fi

    if [ "$_ostype" = Darwin ] && [ "$_cputype" = i386 ]; then
        # Darwin `uname -m` lies
        if sysctl hw.optional.x86_64 | grep -q ': 1'; then
            _cputype=x86_64
        fi
    fi

    if [ "$_ostype" = SunOS ]; then
        # Both Solaris and illumos presently announce as "SunOS" in "uname -s"
        # so use "uname -o" to disambiguate.  We use the full path to the
        # system uname in case the user has coreutils uname first in PATH,
        # which has historically sometimes printed the wrong value here.
        if [ "$(/usr/bin/uname -o)" = illumos ]; then
            _ostype=illumos
        fi

        # illumos systems have multi-arch userlands, and "uname -m" reports the
        # machine hardware name; e.g., "i86pc" on both 32- and 64-bit x86
        # systems.  Check for the native (widest) instruction set on the
        # running kernel:
        if [ "$_cputype" = i86pc ]; then
            _cputype="$(isainfo -n)"
        fi
    fi

    case "$_ostype" in

        Android)
            _ostype=linux-android
            ;;

        Linux)
            check_proc
            _ostype=unknown-linux-$_clibtype
            _bitness=$(get_bitness)
            ;;

        FreeBSD)
            _ostype=unknown-freebsd
            ;;

        NetBSD)
            _ostype=unknown-netbsd
            ;;

        DragonFly)
            _ostype=unknown-dragonfly
            ;;

        Darwin)
            _ostype=apple-darwin
            ;;

        illumos)
            _ostype=unknown-illumos
            ;;

        MINGW* | MSYS* | CYGWIN* | Windows_NT)
            _ostype=pc-windows-gnu
            ;;

        *)
            err "unrecognized OS type: $_ostype"
            ;;

    esac

    case "$_cputype" in

        i386 | i486 | i686 | i786 | x86)
            _cputype=i686
            ;;

        xscale | arm)
            _cputype=arm
            if [ "$_ostype" = "linux-android" ]; then
                _ostype=linux-androideabi
            fi
            ;;

        armv6l)
            _cputype=arm
            if [ "$_ostype" = "linux-android" ]; then
                _ostype=linux-androideabi
            else
                _ostype="${_ostype}eabihf"
            fi
            ;;

        armv7l | armv8l)
            _cputype=armv7
            if [ "$_ostype" = "linux-android" ]; then
                _ostype=linux-androideabi
            else
                _ostype="${_ostype}eabihf"
            fi
            ;;

        aarch64 | arm64)
            _cputype=aarch64
            ;;

        x86_64 | x86-64 | x64 | amd64)
            _cputype=x86_64
            ;;

        mips)
            _cputype=$(get_endianness mips '' el)
            ;;

        mips64)
            if [ "$_bitness" -eq 64 ]; then
                # only n64 ABI is supported for now
                _ostype="${_ostype}abi64"
                _cputype=$(get_endianness mips64 '' el)
            fi
            ;;

        ppc)
            _cputype=powerpc
            ;;

        ppc64)
            _cputype=powerpc64
            ;;

        ppc64le)
            _cputype=powerpc64le
            ;;

        s390x)
            _cputype=s390x
            ;;
        riscv64)
            _cputype=riscv64gc
            ;;
        *)
            err "unknown CPU type: $_cputype"

    esac

    # Detect 64-bit linux with 32-bit userland
    if [ "${_ostype}" = unknown-linux-gnu ] && [ "${_bitness}" -eq 32 ]; then
        case $_cputype in
            x86_64)
                if [ -n "${RUSTUP_CPUTYPE:-}" ]; then
                    _cputype="$RUSTUP_CPUTYPE"
                else {
                    # 32-bit executable for amd64 = x32
                    if is_host_amd64_elf; then {
                         echo "This host is running an x32 userland; as it stands, x32 support is poor," 1>&2
                         echo "and there isn't a native toolchain -- you will have to install" 1>&2
                         echo "multiarch compatibility with i686 and/or amd64, then select one" 1>&2
                         echo "by re-running this script with the RUSTUP_CPUTYPE environment variable" 1>&2
                         echo "set to i686 or x86_64, respectively." 1>&2
                         echo 1>&2
                         echo "You will be able to add an x32 target after installation by running" 1>&2
                         echo "  rustup target add x86_64-unknown-linux-gnux32" 1>&2
                         exit 1
                    }; else
                        _cputype=i686
                    fi
                }; fi
                ;;
            mips64)
                _cputype=$(get_endianness mips '' el)
                ;;
            powerpc64)
                _cputype=powerpc
                ;;
            aarch64)
                _cputype=armv7
                if [ "$_ostype" = "linux-android" ]; then
                    _ostype=linux-androideabi
                else
                    _ostype="${_ostype}eabihf"
                fi
                ;;
            riscv64gc)
                err "riscv64 with 32-bit userland unsupported"
                ;;
        esac
    fi

    # Detect armv7 but without the CPU features Rust needs in that build,
    # and fall back to arm.
    # See https://github.com/rust-lang/rustup.rs/issues/587.
    if [ "$_ostype" = "unknown-linux-gnueabihf" ] && [ "$_cputype" = armv7 ]; then
        if ensure grep '^Features' /proc/cpuinfo | grep -q -v neon; then
            # At least one processor does not have NEON.
            _cputype=arm
        fi
    fi

    _arch="${_cputype}-${_ostype}"

    RETVAL="$_arch"
}

check_proc() {
    # Check for /proc by looking for the /proc/self/exe link
    # This is only run on Linux
    if ! test -L /proc/self/exe ; then
        err "fatal: Unable to find /proc/self/exe.  Is /proc mounted?  Installation cannot proceed without /proc."
    fi
}

get_bitness() {
    need_cmd head
    # Architecture detection without dependencies beyond coreutils.
    # ELF files start out "\x7fELF", and the following byte is
    #   0x01 for 32-bit and
    #   0x02 for 64-bit.
    # The printf builtin on some shells like dash only supports octal
    # escape sequences, so we use those.
    local _current_exe_head
    _current_exe_head=$(head -c 5 /proc/self/exe )
    if [ "$_current_exe_head" = "$(printf '\177ELF\001')" ]; then
        echo 32
    elif [ "$_current_exe_head" = "$(printf '\177ELF\002')" ]; then
        echo 64
    else
        err "unknown platform bitness"
    fi
}

is_host_amd64_elf() {
    need_cmd head
    need_cmd tail
    # ELF e_machine detection without dependencies beyond coreutils.
    # Two-byte field at offset 0x12 indicates the CPU,
    # but we're interested in it being 0x3E to indicate amd64, or not that.
    local _current_exe_machine
    _current_exe_machine=$(head -c 19 /proc/self/exe | tail -c 1)
    [ "$_current_exe_machine" = "$(printf '\076')" ]
}

get_endianness() {
    local cputype=$1
    local suffix_eb=$2
    local suffix_el=$3

    # detect endianness without od/hexdump, like get_bitness() does.
    need_cmd head
    need_cmd tail

    local _current_exe_endianness
    _current_exe_endianness="$(head -c 6 /proc/self/exe | tail -c 1)"
    if [ "$_current_exe_endianness" = "$(printf '\001')" ]; then
        echo "${cputype}${suffix_el}"
    elif [ "$_current_exe_endianness" = "$(printf '\002')" ]; then
        echo "${cputype}${suffix_eb}"
    else
        err "unknown platform endianness"
    fi
}

say() {
    printf 'stalwart-smtp: %s\n' "$1"
}

err() {
    say "$1" >&2
    exit 1
}

need_cmd() {
    if ! check_cmd "$1"; then
        err "need '$1' (command not found)"
    fi
}

check_cmd() {
    command -v "$1" > /dev/null 2>&1
}

assert_nz() {
    if [ -z "$1" ]; then err "assert_nz $2"; fi
}

# Run a command that should never fail. If the command fails execution
# will immediately terminate with an error showing the failing
# command.
ensure() {
    if ! "$@"; then err "command failed: $*"; fi
}

# This wraps curl or wget. Try curl first, if not installed,
# use wget instead.
downloader() {
    local _dld
    local _ciphersuites
    local _err
    local _status
    local _retry
    if check_cmd curl; then
        _dld=curl
    elif check_cmd wget; then
        _dld=wget
    else
        _dld='curl or wget' # to be used in error message of need_cmd
    fi

    if [ "$1" = --check ]; then
        need_cmd "$_dld"
    elif [ "$_dld" = curl ]; then
        check_curl_for_retry_support
        _retry="$RETVAL"
        get_ciphersuites_for_curl
        _ciphersuites="$RETVAL"
        if [ -n "$_ciphersuites" ]; then
            _err=$(curl $_retry --proto '=https' --tlsv1.2 --ciphers "$_ciphersuites" --silent --show-error --fail --location "$1" --output "$2" 2>&1)
            _status=$?
        else
            echo "Warning: Not enforcing strong cipher suites for TLS, this is potentially less secure"
            if ! check_help_for "$3" curl --proto --tlsv1.2; then
                echo "Warning: Not enforcing TLS v1.2, this is potentially less secure"
                _err=$(curl $_retry --silent --show-error --fail --location "$1" --output "$2" 2>&1)
                _status=$?
            else
                _err=$(curl $_retry --proto '=https' --tlsv1.2 --silent --show-error --fail --location "$1" --output "$2" 2>&1)
                _status=$?
            fi
        fi
        if [ -n "$_err" ]; then
            if echo "$_err" | grep -q 404; then
                err "❌  Binary for platform '$3' not found, this platform may be unsupported."
            else
                echo "$_err" >&2
            fi
        fi
        return $_status
    elif [ "$_dld" = wget ]; then
        if [ "$(wget -V 2>&1|head -2|tail -1|cut -f1 -d" ")" = "BusyBox" ]; then
            echo "Warning: using the BusyBox version of wget.  Not enforcing strong cipher suites for TLS or TLS v1.2, this is potentially less secure"
            _err=$(wget "$1" -O "$2" 2>&1)
            _status=$?
        else
            get_ciphersuites_for_wget
            _ciphersuites="$RETVAL"
            if [ -n "$_ciphersuites" ]; then
                _err=$(wget --https-only --secure-protocol=TLSv1_2 --ciphers "$_ciphersuites" "$1" -O "$2" 2>&1)
                _status=$?
            else
                echo "Warning: Not enforcing strong cipher suites for TLS, this is potentially less secure"
                if ! check_help_for "$3" wget --https-only --secure-protocol; then
                    echo "Warning: Not enforcing TLS v1.2, this is potentially less secure"
                    _err=$(wget "$1" -O "$2" 2>&1)
                    _status=$?
                else
                    _err=$(wget --https-only --secure-protocol=TLSv1_2 "$1" -O "$2" 2>&1)
                    _status=$?
                fi
            fi
        fi
        if [ -n "$_err" ]; then
            if echo "$_err" | grep -q ' 404 Not Found'; then
                err "❌  Binary for platform '$3' not found, this platform may be unsupported."
            else
                echo "$_err" >&2
            fi
        fi
        return $_status
    else
        err "Unknown downloader"   # should not reach here
    fi
}

# Check if curl supports the --retry flag, then pass it to the curl invocation.
check_curl_for_retry_support() {
  local _retry_supported=""
  # "unspecified" is for arch, allows for possibility old OS using macports, homebrew, etc.
  if check_help_for "notspecified" "curl" "--retry"; then
    _retry_supported="--retry 3"
  fi

  RETVAL="$_retry_supported"

}

check_help_for() {
    local _arch
    local _cmd
    local _arg
    _arch="$1"
    shift
    _cmd="$1"
    shift

    local _category
    if "$_cmd" --help | grep -q 'For all options use the manual or "--help all".'; then
      _category="all"
    else
      _category=""
    fi

    case "$_arch" in

        *darwin*)
        if check_cmd sw_vers; then
            case $(sw_vers -productVersion) in
                10.*)
                    # If we're running on macOS, older than 10.13, then we always
                    # fail to find these options to force fallback
                    if [ "$(sw_vers -productVersion | cut -d. -f2)" -lt 13 ]; then
                        # Older than 10.13
                        echo "Warning: Detected macOS platform older than 10.13"
                        return 1
                    fi
                    ;;
                11.*)
                    # We assume Big Sur will be OK for now
                    ;;
                *)
                    # Unknown product version, warn and continue
                    echo "Warning: Detected unknown macOS major version: $(sw_vers -productVersion)"
                    echo "Warning TLS capabilities detection may fail"
                    ;;
            esac
        fi
        ;;

    esac

    for _arg in "$@"; do
        if ! "$_cmd" --help $_category | grep -q -- "$_arg"; then
            return 1
        fi
    done

    true # not strictly needed
}

# Return cipher suite string specified by user, otherwise return strong TLS 1.2-1.3 cipher suites
# if support by local tools is detected. Detection currently supports these curl backends:
# GnuTLS and OpenSSL (possibly also LibreSSL and BoringSSL). Return value can be empty.
get_ciphersuites_for_curl() {
    if [ -n "${RUSTUP_TLS_CIPHERSUITES-}" ]; then
        # user specified custom cipher suites, assume they know what they're doing
        RETVAL="$RUSTUP_TLS_CIPHERSUITES"
        return
    fi

    local _openssl_syntax="no"
    local _gnutls_syntax="no"
    local _backend_supported="yes"
    if curl -V | grep -q ' OpenSSL/'; then
        _openssl_syntax="yes"
    elif curl -V | grep -iq ' LibreSSL/'; then
        _openssl_syntax="yes"
    elif curl -V | grep -iq ' BoringSSL/'; then
        _openssl_syntax="yes"
    elif curl -V | grep -iq ' GnuTLS/'; then
        _gnutls_syntax="yes"
    else
        _backend_supported="no"
    fi

    local _args_supported="no"
    if [ "$_backend_supported" = "yes" ]; then
        # "unspecified" is for arch, allows for possibility old OS using macports, homebrew, etc.
        if check_help_for "notspecified" "curl" "--tlsv1.2" "--ciphers" "--proto"; then
            _args_supported="yes"
        fi
    fi

    local _cs=""
    if [ "$_args_supported" = "yes" ]; then
        if [ "$_openssl_syntax" = "yes" ]; then
            _cs=$(get_strong_ciphersuites_for "openssl")
        elif [ "$_gnutls_syntax" = "yes" ]; then
            _cs=$(get_strong_ciphersuites_for "gnutls")
        fi
    fi

    RETVAL="$_cs"
}

# Return cipher suite string specified by user, otherwise return strong TLS 1.2-1.3 cipher suites
# if support by local tools is detected. Detection currently supports these wget backends:
# GnuTLS and OpenSSL (possibly also LibreSSL and BoringSSL). Return value can be empty.
get_ciphersuites_for_wget() {
    if [ -n "${RUSTUP_TLS_CIPHERSUITES-}" ]; then
        # user specified custom cipher suites, assume they know what they're doing
        RETVAL="$RUSTUP_TLS_CIPHERSUITES"
        return
    fi

    local _cs=""
    if wget -V | grep -q '\-DHAVE_LIBSSL'; then
        # "unspecified" is for arch, allows for possibility old OS using macports, homebrew, etc.
        if check_help_for "notspecified" "wget" "TLSv1_2" "--ciphers" "--https-only" "--secure-protocol"; then
            _cs=$(get_strong_ciphersuites_for "openssl")
        fi
    elif wget -V | grep -q '\-DHAVE_LIBGNUTLS'; then
        # "unspecified" is for arch, allows for possibility old OS using macports, homebrew, etc.
        if check_help_for "notspecified" "wget" "TLSv1_2" "--ciphers" "--https-only" "--secure-protocol"; then
            _cs=$(get_strong_ciphersuites_for "gnutls")
        fi
    fi

    RETVAL="$_cs"
}

# Return strong TLS 1.2-1.3 cipher suites in OpenSSL or GnuTLS syntax. TLS 1.2
# excludes non-ECDHE and non-AEAD cipher suites. DHE is excluded due to bad
# DH params often found on servers (see RFC 7919). Sequence matches or is
# similar to Firefox 68 ESR with weak cipher suites disabled via about:config.
# $1 must be openssl or gnutls.
get_strong_ciphersuites_for() {
    if [ "$1" = "openssl" ]; then
        # OpenSSL is forgiving of unknown values, no problems with TLS 1.3 values on versions that don't support it yet.
        echo "TLS_AES_128_GCM_SHA256:TLS_CHACHA20_POLY1305_SHA256:TLS_AES_256_GCM_SHA384:ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384"
    elif [ "$1" = "gnutls" ]; then
        # GnuTLS isn't forgiving of unknown values, so this may require a GnuTLS version that supports TLS 1.3 even if wget doesn't.
        # Begin with SECURE128 (and higher) then remove/add to build cipher suites. Produces same 9 cipher suites as OpenSSL but in slightly different order.
        echo "SECURE128:-VERS-SSL3.0:-VERS-TLS1.0:-VERS-TLS1.1:-VERS-DTLS-ALL:-CIPHER-ALL:-MAC-ALL:-KX-ALL:+AEAD:+ECDHE-ECDSA:+ECDHE-RSA:+AES-128-GCM:+CHACHA20-POLY1305:+AES-256-GCM"
    fi
}

# This is just for indicating that commands' results are being
# intentionally ignored. Usually, because it's being executed
# as part of error handling.
ignore() {
    "$@"
}

main "$@" || exit 1