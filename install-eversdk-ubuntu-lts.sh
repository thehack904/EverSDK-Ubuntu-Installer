#!/usr/bin/env bash
#
# install-eversdk-ubuntu-lts.sh
#
# Reproducible EverSDK installer / recovery utility for Ubuntu 22.04 / 24.04 / 26.04 LTS.
#
# Design goals:
#   - Use the upstream JohnnyonFlame/EverSDK repository and build-sdk.sh.
#   - Run the installer as the normal user. sudo is used only for apt operations.
#   - Build updates in a staging tree so a failed build does not damage the
#     current EverSDK installation.
#   - Back up an existing EverSDK tree before every install/update replacement.
#   - Track only apt packages that were absent before this installer added them.
#   - Provide backup, restore, status, and clean removal from one menu.
#
# Do NOT run this script with sudo.
#

set -uo pipefail
IFS=$'\n\t'

SCRIPT_VERSION="1.0.0"

EVERSDK_REPO="https://github.com/JohnnyonFlame/EverSDK.git"
SRC_ROOT="${HOME}/src"
EVERSDK_DIR="${SRC_ROOT}/EverSDK"

STATE_ROOT="${HOME}/.local/state/eversdk-ubuntu-installer"
LEGACY_STATE_ROOT="${HOME}/.local/state/commander-keen-evercade/eversdk-installer"
BACKUP_DIR="${STATE_ROOT}/backups"
LOG_DIR="${STATE_ROOT}/logs"
INTRODUCED_PACKAGES_FILE="${STATE_ROOT}/apt-packages-introduced.txt"
LAST_SUCCESS_FILE="${STATE_ROOT}/last-success.txt"
SUPPORTED_UBUNTU_VERSIONS=("22.04" "24.04" "26.04")

APT_PACKAGES=(
  git
  build-essential
  autoconf
  ninja-build
  meson
  cmake
  bison
  flex
  gawk
  gettext
  g++
  help2man
  libncurses-dev
  libtool-bin
  texinfo
  unzip
  libffi-dev
  libexpat1-dev
  patchelf
  gperf
  intltool
  golang
  adb
)

timestamp() {
  date '+%Y%m%d-%H%M%S'
}

hr() {
  printf '%s\n' '============================================================'
}

pause() {
  printf '\nPress Enter to continue...'
  read -r _
}

die() {
  printf '\nERROR: %s\n' "$*" >&2
  exit 1
}

ensure_not_root() {
  if [[ ${EUID} -eq 0 ]]; then
    die "Do not run this installer with sudo or as root. Run it as your normal user."
  fi
}

check_host() {
  local supported=0
  local version

  if [[ ! -r /etc/os-release ]]; then
    die "Cannot identify this operating system. This installer supports Ubuntu 22.04, 24.04, and 26.04 LTS."
  fi

  # shellcheck disable=SC1091
  . /etc/os-release

  if [[ "${ID:-}" == "ubuntu" ]]; then
    for version in "${SUPPORTED_UBUNTU_VERSIONS[@]}"; do
      if [[ "${VERSION_ID:-}" == "$version" ]]; then
        supported=1
        break
      fi
    done
  fi

  if ((supported == 0)); then
    printf '\nThis installer supports Ubuntu 22.04, 24.04, and 26.04 LTS.\n'
    printf 'Detected: %s\n' "${PRETTY_NAME:-${ID:-unknown} ${VERSION_ID:-unknown}}"
    return 1
  fi

  return 0
}

migrate_legacy_state() {
  local legacy_parent="${HOME}/.local/state/commander-keen-evercade"
  local legacy_pkg_file="${LEGACY_STATE_ROOT}/apt-packages-introduced.txt"
  local tmp_pkg_file

  [[ -d "$LEGACY_STATE_ROOT" ]] || return 0

  printf '\nLegacy EverSDK installer state detected:\n'
  printf '  %s\n' "$LEGACY_STATE_ROOT"
  printf 'Migrating to:\n'
  printf '  %s\n' "$STATE_ROOT"

  # Fast path: if the new state directory does not yet exist, move the entire
  # legacy tree atomically on the same filesystem.
  if [[ ! -e "$STATE_ROOT" ]]; then
    mkdir -p "$(dirname "$STATE_ROOT")"
    if mv "$LEGACY_STATE_ROOT" "$STATE_ROOT"; then
      rmdir "$legacy_parent" 2>/dev/null || true
      printf 'Legacy installer state migration complete.\n'
      return 0
    fi
    printf 'Could not move the legacy state directory directly; attempting a safe merge.\n' >&2
  fi

  # Merge path: preserve any state already created at the new location and
  # move legacy files only when they do not overwrite an existing file.
  mkdir -p "$STATE_ROOT" "$BACKUP_DIR" "$LOG_DIR"

  if [[ -d "${LEGACY_STATE_ROOT}/backups" ]]; then
    find "${LEGACY_STATE_ROOT}/backups" -maxdepth 1 -type f -name 'EverSDK-*.tar.gz' \
      -exec mv -n -t "$BACKUP_DIR" -- {} + 2>/dev/null || true
  fi

  if [[ -d "${LEGACY_STATE_ROOT}/logs" ]]; then
    find "${LEGACY_STATE_ROOT}/logs" -maxdepth 1 -type f -name 'build-*.log' \
      -exec mv -n -t "$LOG_DIR" -- {} + 2>/dev/null || true
  fi

  # Package ownership is safety-critical. Merge both records rather than
  # allowing either side to replace the other.
  if [[ -f "$legacy_pkg_file" ]]; then
    tmp_pkg_file="${STATE_ROOT}/.apt-packages-introduced.merge.$$"
    {
      [[ -f "$INTRODUCED_PACKAGES_FILE" ]] && cat "$INTRODUCED_PACKAGES_FILE"
      cat "$legacy_pkg_file"
    } | sed '/^[[:space:]]*$/d' | sort -u > "$tmp_pkg_file"
    mv "$tmp_pkg_file" "$INTRODUCED_PACKAGES_FILE"
    rm -f "$legacy_pkg_file"
  fi

  # Preserve the newest-location metadata if both exist. Otherwise carry the
  # legacy success record forward.
  if [[ -f "${LEGACY_STATE_ROOT}/last-success.txt" && ! -e "$LAST_SUCCESS_FILE" ]]; then
    mv "${LEGACY_STATE_ROOT}/last-success.txt" "$LAST_SUCCESS_FILE"
  fi

  rmdir "${LEGACY_STATE_ROOT}/backups" 2>/dev/null || true
  rmdir "${LEGACY_STATE_ROOT}/logs" 2>/dev/null || true
  rmdir "$LEGACY_STATE_ROOT" 2>/dev/null || true
  rmdir "$legacy_parent" 2>/dev/null || true

  if [[ -d "$LEGACY_STATE_ROOT" ]]; then
    printf 'WARNING: Some legacy state files remain at:\n  %s\n' "$LEGACY_STATE_ROOT" >&2
    printf 'They were left in place rather than overwritten or deleted.\n' >&2
  else
    printf 'Legacy installer state migration complete.\n'
  fi
}

ensure_state_dirs() {
  migrate_legacy_state
  mkdir -p "$SRC_ROOT" "$BACKUP_DIR" "$LOG_DIR"
  touch "$INTRODUCED_PACKAGES_FILE"
}

package_is_installed() {
  dpkg-query -W -f='${db:Status-Abbrev}' "$1" 2>/dev/null | grep -q '^ii '
}

record_introduced_packages() {
  local pkg
  for pkg in "$@"; do
    if package_is_installed "$pkg"; then
      grep -Fxq "$pkg" "$INTRODUCED_PACKAGES_FILE" 2>/dev/null ||
        printf '%s\n' "$pkg" >> "$INTRODUCED_PACKAGES_FILE"
    fi
  done

  if [[ -f "$INTRODUCED_PACKAGES_FILE" ]]; then
    sort -u -o "$INTRODUCED_PACKAGES_FILE" "$INTRODUCED_PACKAGES_FILE"
  fi
}

human_gib_from_kib() {
  local kib="${1:-0}"
  awk -v kib="$kib" 'BEGIN { printf "%.1f GiB", kib / 1048576 }'
}

estimate_build_time() {
  local cpus="$1"
  local mem_kib="$2"
  local jobs="$3"
  local min_minutes max_minutes mem_gib

  # This is intentionally conservative. EverSDK builds a complete ARM
  # cross-toolchain plus libraries, so elapsed time varies significantly with
  # CPU generation, virtualization overhead, storage latency, network speed,
  # and whether source archives are already cached.
  if ((cpus <= 2)); then
    min_minutes=180
    max_minutes=360
  elif ((cpus <= 4)); then
    min_minutes=120
    max_minutes=240
  elif ((cpus <= 8)); then
    min_minutes=90
    max_minutes=180
  else
    min_minutes=75
    max_minutes=150
  fi

  # Ubuntu 26.04 is deliberately constrained to two internal crosstool-NG
  # jobs for stability with the older pinned toolchain. Do not imply that a
  # large vCPU allocation will scale the toolchain linearly on this release.
  if [[ "${VERSION_ID:-}" == "26.04" && "$jobs" -le 2 ]]; then
    ((min_minutes < 150)) && min_minutes=150
    ((max_minutes < 300)) && max_minutes=300
  fi

  mem_gib=$((mem_kib / 1048576))
  if ((mem_gib < 4)); then
    min_minutes=$((min_minutes + 60))
    max_minutes=$((max_minutes + 120))
  elif ((mem_gib < 8)); then
    min_minutes=$((min_minutes + 30))
    max_minutes=$((max_minutes + 60))
  fi

  printf '%d %d\n' "$min_minutes" "$max_minutes"
}

format_minutes_range() {
  local min_minutes="$1"
  local max_minutes="$2"
  local min_h min_m max_h max_m

  min_h=$((min_minutes / 60))
  min_m=$((min_minutes % 60))
  max_h=$((max_minutes / 60))
  max_m=$((max_minutes % 60))

  if ((min_h > 0)); then
    printf '%dh %02dm' "$min_h" "$min_m"
  else
    printf '%dm' "$min_m"
  fi

  printf ' - '

  if ((max_h > 0)); then
    printf '%dh %02dm' "$max_h" "$max_m"
  else
    printf '%dm' "$max_m"
  fi
}

preflight_resource_confirmation() {
  local cpus mem_kib swap_kib disk_kib disk_gib cpu_model sockets cores_per_socket threads_per_core
  local jobs estimate min_minutes max_minutes answer

  cpus="$(nproc 2>/dev/null || printf '1')"
  [[ "$cpus" =~ ^[0-9]+$ ]] || cpus=1

  mem_kib="$(awk '/^MemTotal:/ {print $2; exit}' /proc/meminfo 2>/dev/null)"
  swap_kib="$(awk '/^SwapTotal:/ {print $2; exit}' /proc/meminfo 2>/dev/null)"
  [[ "$mem_kib" =~ ^[0-9]+$ ]] || mem_kib=0
  [[ "$swap_kib" =~ ^[0-9]+$ ]] || swap_kib=0

  disk_kib="$(df -Pk "$HOME" 2>/dev/null | awk 'NR==2 {print $4}')"
  [[ "$disk_kib" =~ ^[0-9]+$ ]] || disk_kib=0
  disk_gib="$(awk -v kib="$disk_kib" 'BEGIN { printf "%.1f", kib / 1048576 }')"

  cpu_model="$(lscpu 2>/dev/null | awk -F: '/Model name:/ {sub(/^[[:space:]]+/, "", $2); print $2; exit}')"
  sockets="$(lscpu 2>/dev/null | awk -F: '/Socket\(s\):/ {gsub(/[[:space:]]/, "", $2); print $2; exit}')"
  cores_per_socket="$(lscpu 2>/dev/null | awk -F: '/Core\(s\) per socket:/ {gsub(/[[:space:]]/, "", $2); print $2; exit}')"
  threads_per_core="$(lscpu 2>/dev/null | awk -F: '/Thread\(s\) per core:/ {gsub(/[[:space:]]/, "", $2); print $2; exit}')"

  [[ -n "$cpu_model" ]] || cpu_model="unknown"
  [[ -n "$sockets" ]] || sockets="unknown"
  [[ -n "$cores_per_socket" ]] || cores_per_socket="unknown"
  [[ -n "$threads_per_core" ]] || threads_per_core="unknown"

  if [[ "${VERSION_ID:-}" == "26.04" ]]; then
    jobs=2
  else
    jobs=$((cpus + 1))
  fi

  estimate="$(estimate_build_time "$cpus" "$mem_kib" "$jobs")"
  IFS=" " read -r min_minutes max_minutes <<< "$estimate"

  printf '\n'
  hr
  printf 'EverSDK build resource preflight\n'
  hr
  printf 'Ubuntu:             %s\n' "${PRETTY_NAME:-${VERSION_ID:-unknown}}"
  printf 'CPU model:          %s\n' "$cpu_model"
  printf 'Logical CPUs:       %s\n' "$cpus"
  printf 'CPU topology:       %s socket(s), %s core(s)/socket, %s thread(s)/core\n' \
    "$sockets" "$cores_per_socket" "$threads_per_core"
  printf 'Memory:             %s\n' "$(human_gib_from_kib "$mem_kib")"
  printf 'Swap:               %s\n' "$(human_gib_from_kib "$swap_kib")"
  printf 'Disk free in HOME:  %s GiB\n' "$disk_gib"
  printf 'Planned build jobs: %s\n' "$jobs"
  printf '\nEstimated total EverSDK install/build time: '
  format_minutes_range "$min_minutes" "$max_minutes"
  printf '\n'
  printf '\nThis is a conservative estimate, not a guarantee. CPU generation, VM overhead,\n'
  printf 'storage speed, network speed, and cached downloads can materially change it.\n'

  if ((disk_kib > 0 && disk_kib < 12582912)); then
    printf '\nWARNING: Less than 12 GiB is free in %s.\n' "$HOME" >&2
    printf 'The EverSDK staging build may run out of disk space.\n' >&2
  fi

  if ((mem_kib > 0 && mem_kib < 4194304)); then
    printf '\nWARNING: Less than 4 GiB of RAM was detected.\n' >&2
    printf 'The GCC toolchain build may be slow or fail under memory pressure.\n' >&2
  fi

  printf '\nNo packages, source archives, or repositories have been downloaded yet.\n'
  printf 'Review the information above before continuing.\n\n'
  printf 'Continue with EverSDK download and compilation? [y/N]: '
  read -r answer

  case "$answer" in
    y|Y|yes|YES|Yes)
      printf '\nPreflight accepted. Continuing.\n'
      return 0
      ;;
    *)
      printf '\nCancelled before downloads or compilation began.\n'
      return 1
      ;;
  esac
}

install_dependencies() {
  local -a required=("${APT_PACKAGES[@]}")
  local -a missing=()
  local -a unavailable=()
  local pkg

  # Ubuntu 26.04 ships GCC 15 by default. GMP 6.2.1, used by the pinned
  # crosstool-NG toolchain, fails one of its legacy compiler probes with GCC 15.
  # Install an older host compiler only for the EverSDK build environment; do
  # not alter /usr/bin/gcc or system-wide update-alternatives. GNU Make 4.3 is
  # built privately in the staging tree later because glibc 2.26 can hang under
  # GNU Make 4.4+.
  if [[ "${VERSION_ID:-}" == "26.04" ]]; then
    required+=(gcc-13 g++-13)
  fi

  printf '\nChecking build dependencies for Ubuntu %s...\n' "${VERSION_ID:-unknown}"

  for pkg in "${required[@]}"; do
    if ! package_is_installed "$pkg"; then
      missing+=("$pkg")
    fi
  done

  if ((${#missing[@]} == 0)); then
    printf 'All required apt packages are already installed.\n'
    return 0
  fi

  printf '\nThe following packages are currently absent and will be installed:\n'
  printf '  %s\n' "${missing[@]}"
  printf '\nOnly these newly introduced packages will be recorded as installer-owned.\n'
  printf 'sudo will be used only for apt package management.\n\n'

  if ! sudo apt-get update; then
    printf '\nPackage index update failed. No EverSDK tree has been changed.\n' >&2
    return 1
  fi

  for pkg in "${missing[@]}"; do
    if ! apt-cache show "$pkg" >/dev/null 2>&1; then
      unavailable+=("$pkg")
    fi
  done

  if ((${#unavailable[@]} > 0)); then
    printf '\nThe following required packages are unavailable on Ubuntu %s:\n' "${VERSION_ID:-unknown}" >&2
    printf '  %s\n' "${unavailable[@]}" >&2
    printf '\nInstallation stopped before cloning or building EverSDK.\n' >&2
    return 1
  fi

  if ! sudo apt-get install -y "${missing[@]}"; then
    # apt can sometimes install some packages before returning a failure.
    # Record only packages from our original "missing" set that now exist.
    record_introduced_packages "${missing[@]}"
    printf '\nDependency installation did not complete successfully.\n' >&2
    printf 'Any packages that were successfully added by this attempt have been recorded.\n' >&2
    printf 'No EverSDK tree has been changed.\n' >&2
    return 1
  fi

  record_introduced_packages "${missing[@]}"
  printf '\nDependencies are ready.\n'
  return 0
}

prepare_host_build_env() {
  local staging="$1"
  local shim_dir="${staging}/.host-compiler-bin"
  local make_version="4.3"
  local make_archive="${staging}/.host-make-${make_version}.tar.gz"
  local make_src="${staging}/.host-make-${make_version}-src"
  local make_prefix="${staging}/.host-make-${make_version}"
  local make_sha256="e05fdde47c5f7ca45cb697e973894ff4f5d79e13b750ed57d7b66d8defc78e19"
  local tmp="${make_archive}.part"
  local url actual
  local downloaded=0

  if [[ "${VERSION_ID:-}" != "26.04" ]]; then
    return 0
  fi

  if ! command -v gcc-13 >/dev/null 2>&1 || ! command -v g++-13 >/dev/null 2>&1; then
    printf '\nUbuntu 26.04 requires gcc-13 and g++-13 for the EverSDK host build.\n' >&2
    return 1
  fi

  mkdir -p "$shim_dir"
  ln -sfn "$(command -v gcc-13)" "${shim_dir}/gcc"
  ln -sfn "$(command -v gcc-13)" "${shim_dir}/cc"
  ln -sfn "$(command -v g++-13)" "${shim_dir}/g++"
  ln -sfn "$(command -v g++-13)" "${shim_dir}/c++"

  # EverSDK's upstream crosstool wrapper derives its own bootstrap make
  # parallelism from nproc.  Keep this override private to the Ubuntu 26.04
  # staging build so that wrapper uses at most two jobs.  crosstool-NG's
  # internal toolchain parallelism is capped separately with CT_JOBS=2 when
  # build-sdk.sh is launched.  The system nproc utility is not modified.
  cat > "${shim_dir}/nproc" <<'EOF_NPROC'
#!/usr/bin/env bash
printf '1\n'
EOF_NPROC
  chmod +x "${shim_dir}/nproc"

  printf '\nUbuntu 26.04 compatibility mode enabled.\n'
  printf '  Host compiler: %s\n' "$(gcc-13 --version | head -n1)"
  printf '  Compiler shim: %s\n' "$shim_dir"
  printf '  Outer build cap: nproc reports 1 (EverSDK wrapper uses at most 2 jobs)\n'
  printf '  Toolchain cap:   CT_JOBS=2 (crosstool-NG internal builds use 2 jobs)\n'
  printf '  CMake policy:    minimum policy version 3.5 for CMake 4.x compatibility\n'
  printf '  System default gcc, nproc, make, and CMake are not modified.\n'
  printf '\nPreparing private GNU Make %s for the EverSDK host build...\n' "$make_version"

  for url in \
    "https://ftp.riken.jp/GNU/make/make-${make_version}.tar.gz" \
    "https://ftpmirror.gnu.org/make/make-${make_version}.tar.gz" \
    "https://ftp.gnu.org/gnu/make/make-${make_version}.tar.gz"; do
    printf '  Trying: %s\n' "$url"
    rm -f "$tmp"
    if wget -4 --tries=2 --timeout=20 --max-redirect=10 -O "$tmp" "$url"; then
      if [[ -s "$tmp" ]]; then
        actual="$(sha256sum "$tmp" | awk '{print $1}')"
        if [[ "$actual" == "$make_sha256" ]]; then
          mv "$tmp" "$make_archive"
          downloaded=1
          printf '  [ OK ] GNU Make %s source SHA-256 verified.\n' "$make_version"
          break
        fi
        printf '  [FAIL] SHA-256 mismatch from %s\n' "$url" >&2
        printf '         expected: %s\n' "$make_sha256" >&2
        printf '         actual:   %s\n' "$actual" >&2
      fi
    fi
  done

  rm -f "$tmp"

  if ((downloaded == 0)); then
    printf '\nCould not download a verified GNU Make %s source archive.\n' "$make_version" >&2
    return 1
  fi

  rm -rf "$make_src" "$make_prefix"
  mkdir -p "$make_src" "$make_prefix"

  if ! tar -xzf "$make_archive" -C "$make_src" --strip-components=1; then
    printf '\nCould not extract GNU Make %s source.\n' "$make_version" >&2
    return 1
  fi

  if ! (
    cd "$make_src" || exit 1
    CC=gcc-13 CXX=g++-13 ./configure --prefix="$make_prefix" --disable-dependency-tracking &&
    /usr/bin/make -j"$(nproc)" &&
    /usr/bin/make install
  ); then
    printf '\nPrivate GNU Make %s build failed.\n' "$make_version" >&2
    return 1
  fi

  if [[ ! -x "${make_prefix}/bin/make" ]]; then
    printf '\nPrivate GNU Make %s binary was not generated.\n' "$make_version" >&2
    return 1
  fi

  # Use relative links so they remain valid when the validated staging tree
  # is promoted (renamed) to ~/src/EverSDK.
  ln -sfn "../.host-make-${make_version}/bin/make" "${shim_dir}/make"
  ln -sfn "../.host-make-${make_version}/bin/make" "${shim_dir}/gmake"

  printf '  Host make:     %s\n' "$("${shim_dir}/make" --version | head -n1)"
  printf '  Make shim:     %s\n' "${shim_dir}/make"
  printf '  System default make is not modified.\n'
  return 0
}

host_build_compiler_description() {
  if [[ "${VERSION_ID:-}" == "26.04" ]] && command -v gcc-13 >/dev/null 2>&1; then
    gcc-13 --version 2>/dev/null | head -n1
  elif command -v gcc >/dev/null 2>&1; then
    gcc --version 2>/dev/null | head -n1
  else
    printf 'unknown'
  fi
}

host_build_make_description() {
  local candidate="${EVERSDK_DIR}/.host-compiler-bin/make"

  if [[ "${VERSION_ID:-}" == "26.04" && -x "$candidate" ]]; then
    "$candidate" --version 2>/dev/null | head -n1
  elif [[ "${VERSION_ID:-}" == "26.04" ]]; then
    printf 'GNU Make 4.3 private build (prepared during install)'
  elif command -v make >/dev/null 2>&1; then
    make --version 2>/dev/null | head -n1
  else
    printf 'unknown'
  fi
}

backup_tree() {
  local reason="${1:-manual}"
  local ts archive

  if [[ ! -d "$EVERSDK_DIR" ]]; then
    printf 'No current EverSDK tree exists at %s; nothing to back up.\n' "$EVERSDK_DIR"
    return 0
  fi

  ensure_state_dirs
  ts="$(timestamp)"
  archive="${BACKUP_DIR}/EverSDK-${ts}-${reason}.tar.gz"

  printf '\nBacking up current EverSDK tree...\n'
  printf '  Source: %s\n' "$EVERSDK_DIR"
  printf '  Backup: %s\n' "$archive"

  if tar -C "$SRC_ROOT" -czf "$archive" EverSDK; then
    printf 'Backup complete.\n'
    return 0
  fi

  rm -f "$archive"
  printf '\nBackup failed. The existing EverSDK tree was NOT changed.\n' >&2
  return 1
}

git_head() {
  local dir="$1"
  git -C "$dir" rev-parse HEAD 2>/dev/null || true
}

git_branch() {
  local dir="$1"
  git -C "$dir" branch --show-current 2>/dev/null || true
}

validate_eversdk_tree() {
  local dir="$1"
  local failed=0
  local compiler=""

  printf '\nValidating EverSDK build...\n'

  if [[ ! -x "$dir/build-sdk.sh" ]]; then
    printf '  [FAIL] build-sdk.sh is missing or not executable.\n'
    failed=1
  else
    printf '  [ OK ] upstream build-sdk.sh exists.\n'
  fi

  if [[ ! -f "$dir/toolchain/armhf.cmake" ]]; then
    printf '  [FAIL] toolchain/armhf.cmake was not generated.\n'
    failed=1
  else
    printf '  [ OK ] CMake ARM toolchain file exists.\n'
  fi

  if [[ ! -f "$dir/toolchain/meson-cross.ini" ]]; then
    printf '  [FAIL] toolchain/meson-cross.ini was not generated.\n'
    failed=1
  else
    printf '  [ OK ] Meson ARM cross file exists.\n'
  fi

  compiler="$(find "$dir/toolchain" -type f -name 'arm*-linux-gnueabihf-gcc' -perm -u+x -print -quit 2>/dev/null || true)"
  if [[ -z "$compiler" ]]; then
    printf '  [FAIL] ARM hard-float GCC was not found in the generated toolchain.\n'
    failed=1
  else
    printf '  [ OK ] ARM compiler found: %s\n' "${compiler#$dir/}"
    if "$compiler" --version >/dev/null 2>&1; then
      printf '  [ OK ] ARM compiler starts successfully.\n'
    else
      printf '  [FAIL] ARM compiler exists but could not be executed.\n'
      failed=1
    fi
  fi

  if [[ -f "$dir/out/shell.tar.gz" ]]; then
    printf '  [ OK ] out/shell.tar.gz exists.\n'
  else
    printf '  [INFO] out/shell.tar.gz was not found; core toolchain validation continues.\n'
  fi

  if ((failed != 0)); then
    printf '\nEverSDK validation FAILED.\n' >&2
    return 1
  fi

  printf '\nEverSDK validation PASSED.\n'
  return 0
}

download_cache_archive() {
  local archive_name="$1"
  shift
  local archive="${SRC_ROOT}/${archive_name}"
  local tmp="${archive}.part"
  local url
  local downloaded=0

  if [[ -s "$archive" ]]; then
    printf '  [cached] %s\n' "$archive_name"
    return 0
  fi

  for url in "$@"; do
    printf '  Trying: %s\n' "$url"
    rm -f "$tmp"

    if wget -4 --tries=2 --timeout=20 --max-redirect=10 -O "$tmp" "$url"; then
      if [[ -s "$tmp" ]]; then
        mv "$tmp" "$archive"
        printf '  [saved] %s\n' "$archive"
        printf '  Source:  %s\n' "$url"
        downloaded=1
        break
      fi
    fi
  done

  if ((downloaded == 0)); then
    rm -f "$tmp"
    printf '\nCould not obtain required source archive: %s\n' "$archive_name" >&2
    return 1
  fi

  return 0
}

seed_known_upstream_tarballs() {
  # EverSDK's crosstool-NG configuration uses ${HOME}/src as its local source
  # archive cache.  This contributor network cannot reliably reach the default
  # GNU download endpoints used by crosstool-NG, while the RIKEN GNU mirror is
  # reachable.  Seed the specific GNU archives known to be required by this
  # toolchain into the normal crosstool-NG cache rather than patching EverSDK.
  #
  # crosstool-NG still performs its own configured digest verification before
  # using these archives.
  local failed=0

  printf '\nPreloading known GNU source archives required by this EverSDK toolchain...\n'
  printf '  Cache:        %s\n' "$SRC_ROOT"
  printf '  Network mode: IPv4\n\n'

  download_cache_archive \
    "libiconv-1.16.tar.gz" \
    "https://ftp.riken.jp/GNU/libiconv/libiconv-1.16.tar.gz" \
    "https://ftpmirror.gnu.org/libiconv/libiconv-1.16.tar.gz" \
    "https://ftp.gnu.org/gnu/libiconv/libiconv-1.16.tar.gz" \
    "http://ftpmirror.gnu.org/libiconv/libiconv-1.16.tar.gz" \
    || failed=1

  download_cache_archive \
    "gettext-0.21.tar.xz" \
    "https://ftp.riken.jp/GNU/gettext/gettext-0.21.tar.xz" \
    "https://ftpmirror.gnu.org/gettext/gettext-0.21.tar.xz" \
    "https://ftp.gnu.org/gnu/gettext/gettext-0.21.tar.xz" \
    "http://ftpmirror.gnu.org/gettext/gettext-0.21.tar.xz" \
    || failed=1

  download_cache_archive \
    "glibc-2.26.tar.xz" \
    "https://ftp.riken.jp/GNU/glibc/glibc-2.26.tar.xz" \
    "https://ftpmirror.gnu.org/glibc/glibc-2.26.tar.xz" \
    "https://ftp.gnu.org/gnu/glibc/glibc-2.26.tar.xz" \
    "http://ftpmirror.gnu.org/glibc/glibc-2.26.tar.xz" \
    || failed=1

  if ((failed != 0)); then
    printf '\nOne or more required source archives could not be cached.\n' >&2
    printf 'The EverSDK build has not started and the current installation was not changed.\n' >&2
    printf 'This is a source-download/reachability problem, not a compiler failure.\n' >&2
    return 1
  fi

  printf '\nRequired GNU source archives are available in the local cache.\n'
  printf 'crosstool-NG will perform its normal digest verification during the build.\n'
  return 0
}


seed_verified_eversdk_archive() {
  local staging="$1"
  local archive_name="$2"
  local expected="$3"
  shift 3

  local dl_dir="${staging}/dl"
  local archive="${dl_dir}/${archive_name}"
  local tmp="${archive}.part"
  local url
  local actual
  local downloaded=0

  mkdir -p "$dl_dir"

  if [[ -s "$archive" ]]; then
    actual="$(sha256sum "$archive" | awk '{print $1}')"
    if [[ "$actual" == "$expected" ]]; then
      printf '  [cached] %s\n' "$archive_name"
      return 0
    fi

    printf '  Existing %s archive has the wrong hash; replacing it.\n' "$archive_name"
    rm -f "$archive"
  fi

  printf '\nPreloading EverSDK source archive:\n'
  printf '  %s\n' "$archive_name"

  for url in "$@"; do
    printf '  Trying: %s\n' "$url"
    rm -f "$tmp"

    if wget -4 --tries=2 --timeout=20 --max-redirect=10 -O "$tmp" "$url"; then
      if [[ -s "$tmp" ]]; then
        actual="$(sha256sum "$tmp" | awk '{print $1}')"

        if [[ "$actual" == "$expected" ]]; then
          mv "$tmp" "$archive"
          printf '  [saved] %s\n' "$archive"
          printf '  SHA-256 verified: %s\n' "$actual"
          printf '  Source: %s\n' "$url"
          downloaded=1
          break
        fi

        printf '  Hash mismatch from this mirror; ignoring file.\n' >&2
        printf '    Expected: %s\n' "$expected" >&2
        printf '    Found:    %s\n' "$actual" >&2
      fi
    fi
  done

  rm -f "$tmp"

  if ((downloaded == 0)); then
    printf '\nCould not obtain a valid %s archive from configured mirrors.\n' "$archive_name" >&2
    return 1
  fi

  return 0
}

seed_eversdk_library_archives() {
  local staging="$1"
  local failed=0

  # FreeType is normally fetched from Savannah, which is unreachable on the
  # contributor network. Coreutils is normally fetched from ftp.gnu.org, which
  # is also unreachable. Seed both into EverSDK's ordinary ./dl cache.
  #
  # These SHA-256 values are the exact values used by upstream EverSDK's
  # wget-helper.sh. Upstream will re-check the same hashes during build-sdk.sh.

  seed_verified_eversdk_archive \
    "$staging" \
    "freetype-2.12.1.tar.xz" \
    "4766f20157cc4cf0cd292f80bf917f92d1c439b243ac3018debf6b9140c41a7f" \
    "https://download-mirror.savannah.gnu.org/releases/freetype/freetype-2.12.1.tar.xz" \
    "https://mirror.rabisu.com/mirrors/savannah/freetype/freetype-2.12.1.tar.xz" \
    "https://openbsd.c3sl.ufpr.br/savannah-nongnu/freetype/freetype-2.12.1.tar.xz" \
    || failed=1

  seed_verified_eversdk_archive \
    "$staging" \
    "coreutils-9.3.tar.xz" \
    "adbcfcfe899235b71e8768dcf07cd532520b7f54f9a8064843f8d199a904bbaa" \
    "https://ftp.riken.jp/GNU/coreutils/coreutils-9.3.tar.xz" \
    "https://ftpmirror.gnu.org/coreutils/coreutils-9.3.tar.xz" \
    "https://ftp.gnu.org/gnu/coreutils/coreutils-9.3.tar.xz" \
    "http://ftpmirror.gnu.org/coreutils/coreutils-9.3.tar.xz" \
    || failed=1

  if ((failed != 0)); then
    printf '\nOne or more EverSDK source archives could not be preloaded safely.\n' >&2
    printf 'The EverSDK build has not started and the current installation was not changed.\n' >&2
    return 1
  fi

  printf '\nEverSDK source preload complete.\n'
  printf 'Upstream wget-helper.sh will re-check the same SHA-256 values during the build.\n'
  return 0
}

install_or_update() {
  local ts staging log old_dir commit branch
  ts="$(timestamp)"
  staging="${SRC_ROOT}/.EverSDK-build-${ts}"
  log="${LOG_DIR}/build-${ts}.log"
  old_dir="${SRC_ROOT}/.EverSDK-old-${ts}"

  hr
  printf 'EverSDK install / update\n'
  hr

  if ! check_host; then
    return 1
  fi

  if ! preflight_resource_confirmation; then
    return 1
  fi

  ensure_state_dirs

  if ! install_dependencies; then
    printf '\nInstallation stopped before cloning or building EverSDK.\n'
    return 1
  fi

  if ! seed_known_upstream_tarballs; then
    printf '\nInstallation stopped before cloning or building EverSDK.\n'
    return 1
  fi

  if [[ -e "$staging" || -e "$old_dir" ]]; then
    printf '\nUnexpected staging path already exists. Nothing was changed.\n' >&2
    printf '  %s\n  %s\n' "$staging" "$old_dir" >&2
    return 1
  fi

  # Required safety point: back up the existing tree before replacement.
  if [[ -d "$EVERSDK_DIR" ]]; then
    if ! backup_tree "pre-update"; then
      return 1
    fi
  fi

  printf '\nCloning a clean copy of upstream EverSDK...\n'
  if ! git clone "$EVERSDK_REPO" "$staging"; then
    rm -rf "$staging"
    printf '\nClone failed. The current EverSDK installation was NOT changed.\n' >&2
    return 1
  fi

  commit="$(git_head "$staging")"
  branch="$(git_branch "$staging")"

  printf '\nUpstream source selected:\n'
  printf '  Repository: %s\n' "$EVERSDK_REPO"
  printf '  Branch:     %s\n' "${branch:-detached/unknown}"
  printf '  Commit:     %s\n' "${commit:-unknown}"
  printf '  Host GCC:   %s\n' "$(host_build_compiler_description)"
  printf '  Build log:  %s\n' "$log"

  if ! seed_eversdk_library_archives "$staging"; then
    printf '\nInstallation stopped before building EverSDK.\n'
    printf 'The previous EverSDK installation was NOT changed.\n'
    return 1
  fi

  if ! prepare_host_build_env "$staging"; then
    printf '\nInstallation stopped before building EverSDK.\n'
    printf 'The previous EverSDK installation was NOT changed.\n'
    return 1
  fi

  printf '\nBuilding with the upstream ./build-sdk.sh process.\n'
  printf 'This can take a substantial amount of time. Full output is being logged.\n\n'

  (
    cd "$staging" || exit 1
    unset LD_LIBRARY_PATH
    unset LIBRARY_PATH

    if [[ "${VERSION_ID:-}" == "26.04" ]]; then
      # Keep GCC 13 scoped to this build process. crosstool-NG and its host-side
      # companion libraries resolve gcc/cc/g++/c++ through this private PATH.
      export PATH="${staging}/.host-compiler-bin:${PATH}"
      export MAKE="${staging}/.host-compiler-bin/make"

      # crosstool-NG 1.26.0 honors CT_JOBS as an explicit runtime override
      # for CT_PARALLEL_JOBS.  This prevents the final GCC build from falling
      # back to automatic CPU-count-based parallelism and exhausting memory.
      export CT_JOBS=2

      # CMake 4.0 removed compatibility with policy versions older than 3.5.
      # EverSDK still builds third-party projects whose CMakeLists.txt declare
      # older minima (for example libzip 1.10.0).  CMake 4.x explicitly
      # supports this environment variable as an external compatibility floor,
      # allowing those projects to configure without modifying upstream source.
      export CMAKE_POLICY_VERSION_MINIMUM=3.5
    fi

    ./build-sdk.sh
  ) 2>&1 | tee "$log"
  local build_rc=${PIPESTATUS[0]}

  if ((build_rc != 0)); then
    printf '\n============================================================\n' >&2
    printf 'EVERSDK BUILD FAILED\n' >&2
    printf '============================================================\n' >&2
    printf 'The previous EverSDK installation was NOT replaced.\n' >&2
    printf 'Failed staging tree: %s\n' "$staging" >&2
    printf 'Build log:           %s\n' "$log" >&2
    printf '\nRecommended next step:\n' >&2
    printf '  Return to the menu and choose "Show status".\n' >&2
    printf '  The prior EverSDK tree should still be usable.\n' >&2
    printf '\nYou may also choose "Restore latest EverSDK backup" or\n' >&2
    printf '"Remove EverSDK and installer-created files" without diagnosing the toolchain.\n' >&2
    printf '\nThe failed staging tree is retained for troubleshooting and will be\n' >&2
    printf 'cleaned by the Remove option.\n' >&2
    return 1
  fi

  if ! validate_eversdk_tree "$staging"; then
    printf '\nThe build command finished, but validation failed.\n' >&2
    printf 'The previous EverSDK installation was NOT replaced.\n' >&2
    printf 'Staging tree: %s\n' "$staging" >&2
    printf 'Build log:    %s\n' "$log" >&2
    return 1
  fi

  printf '\nPromoting the validated build into %s ...\n' "$EVERSDK_DIR"

  if [[ -d "$EVERSDK_DIR" ]]; then
    if ! mv "$EVERSDK_DIR" "$old_dir"; then
      printf 'Could not move the existing EverSDK tree. New build was not promoted.\n' >&2
      return 1
    fi
  fi

  if ! mv "$staging" "$EVERSDK_DIR"; then
    printf '\nCould not promote the validated build.\n' >&2
    if [[ -d "$old_dir" && ! -e "$EVERSDK_DIR" ]]; then
      mv "$old_dir" "$EVERSDK_DIR" || true
      printf 'The previous EverSDK tree was put back in place.\n' >&2
    fi
    return 1
  fi

  rm -rf "$old_dir"

  {
    printf 'installed_at=%s\n' "$(date --iso-8601=seconds)"
    printf 'ubuntu_version=%s\n' "${VERSION_ID:-unknown}"
    printf 'ubuntu_pretty_name=%s\n' "${PRETTY_NAME:-unknown}"
    printf 'host_build_compiler=%s\n' "$(host_build_compiler_description)"
    printf 'host_build_make=%s\n' "$(host_build_make_description)"
    if [[ "${VERSION_ID:-}" == "26.04" ]]; then
      printf 'crosstool_parallel_jobs=2\n'
    fi
    printf 'repository=%s\n' "$EVERSDK_REPO"
    printf 'branch=%s\n' "${branch:-unknown}"
    printf 'commit=%s\n' "${commit:-unknown}"
    printf 'build_log=%s\n' "$log"
  } > "$LAST_SUCCESS_FILE"

  printf '\n============================================================\n'
  printf 'EVERSDK INSTALLATION SUCCESSFUL\n'
  printf '============================================================\n'
  printf 'EverSDK: %s\n' "$EVERSDK_DIR"
  printf 'Commit:  %s\n' "${commit:-unknown}"
  printf 'Log:     %s\n' "$log"
  printf '\nThe contributor does not need to modify the generated toolchain manually.\n'
}

manual_backup() {
  hr
  printf 'Back up current EverSDK\n'
  hr
  check_host || return 1
  ensure_state_dirs
  backup_tree "manual"
}

latest_backup() {
  find "$BACKUP_DIR" -maxdepth 1 -type f -name 'EverSDK-*.tar.gz' \
    -printf '%T@ %p\n' 2>/dev/null |
    sort -nr |
    head -n 1 |
    cut -d' ' -f2-
}

restore_latest_backup() {
  local selected ts displaced

  hr
  printf 'Restore latest EverSDK backup\n'
  hr

  check_host || return 1
  ensure_state_dirs

  # Select the restore source BEFORE backing up the current tree, so a
  # pre-restore safety backup does not accidentally become the restore source.
  selected="$(latest_backup)"

  if [[ -z "$selected" || ! -f "$selected" ]]; then
    printf '\nNo EverSDK backups are available in:\n  %s\n' "$BACKUP_DIR"
    return 1
  fi

  printf '\nLatest backup:\n  %s\n' "$selected"
  printf '\nThis will replace:\n  %s\n' "$EVERSDK_DIR"
  printf '\nContinue with restore? [y/N]: '
  read -r answer
  [[ "$answer" =~ ^[Yy]$ ]] || {
    printf 'Restore cancelled.\n'
    return 0
  }

  if [[ -d "$EVERSDK_DIR" ]]; then
    if ! backup_tree "pre-restore"; then
      return 1
    fi
  fi

  ts="$(timestamp)"
  displaced="${SRC_ROOT}/.EverSDK-pre-restore-${ts}"

  if [[ -d "$EVERSDK_DIR" ]]; then
    mv "$EVERSDK_DIR" "$displaced" || {
      printf 'Could not move the current EverSDK tree. Restore cancelled.\n' >&2
      return 1
    }
  fi

  if ! tar -C "$SRC_ROOT" -xzf "$selected"; then
    printf '\nRestore extraction failed.\n' >&2
    rm -rf "$EVERSDK_DIR"
    if [[ -d "$displaced" ]]; then
      mv "$displaced" "$EVERSDK_DIR" || true
      printf 'The pre-restore EverSDK tree was put back in place.\n' >&2
    fi
    return 1
  fi

  if ! validate_eversdk_tree "$EVERSDK_DIR"; then
    printf '\nThe restored backup did not pass validation.\n' >&2
    rm -rf "$EVERSDK_DIR"
    if [[ -d "$displaced" ]]; then
      mv "$displaced" "$EVERSDK_DIR" || true
      printf 'The pre-restore EverSDK tree was put back in place.\n' >&2
    fi
    return 1
  fi

  rm -rf "$displaced"
  printf '\nRestore successful.\n'
  printf 'Restored from: %s\n' "$selected"
}

show_status() {
  local pkg commit branch backup_count log_count
  local -a introduced=()

  migrate_legacy_state

  hr
  printf 'EverSDK installer status\n'
  hr

  if check_host; then
    printf 'Host:        supported %s\n' "${PRETTY_NAME:-Ubuntu ${VERSION_ID:-unknown}}"
  else
    printf 'Host:        UNSUPPORTED for this installer\n'
  fi

  printf 'User:        %s\n' "${USER:-unknown}"
  printf 'EverSDK dir: %s\n' "$EVERSDK_DIR"
  printf 'State dir:   %s\n' "$STATE_ROOT"
  printf 'Host GCC:    %s\n' "$(host_build_compiler_description)"
  printf 'Host Make:   %s\n' "$(host_build_make_description)"

  if [[ -d "$EVERSDK_DIR" ]]; then
    printf 'EverSDK:     present\n'
    commit="$(git_head "$EVERSDK_DIR")"
    branch="$(git_branch "$EVERSDK_DIR")"
    printf 'Branch:      %s\n' "${branch:-unknown}"
    printf 'Commit:      %s\n' "${commit:-unknown}"

    if validate_eversdk_tree "$EVERSDK_DIR"; then
      printf 'Build state: VALID\n'
    else
      printf 'Build state: INVALID / INCOMPLETE\n'
    fi
  else
    printf 'EverSDK:     not installed\n'
  fi

  backup_count="$(find "$BACKUP_DIR" -maxdepth 1 -type f -name 'EverSDK-*.tar.gz' 2>/dev/null | wc -l)"
  log_count="$(find "$LOG_DIR" -maxdepth 1 -type f -name 'build-*.log' 2>/dev/null | wc -l)"

  printf '\nBackups:     %s\n' "$backup_count"
  printf 'Build logs:  %s\n' "$log_count"

  if command -v adb >/dev/null 2>&1; then
    printf 'ADB:         %s\n' "$(adb version | head -n1)"
  else
    printf 'ADB:         NOT INSTALLED\n'
  fi

  if [[ -s "$INTRODUCED_PACKAGES_FILE" ]]; then
    mapfile -t introduced < "$INTRODUCED_PACKAGES_FILE"
    printf '\nApt packages recorded as introduced by this installer:\n'

    for pkg in "${introduced[@]}"; do
      if package_is_installed "$pkg"; then
        printf '  [installed] %s\n' "$pkg"
      else
        printf '  [absent]    %s\n' "$pkg"
      fi
    done
  else
    printf '\nNo apt packages are recorded as introduced by this installer.\n'
  fi

  if [[ -f "$LAST_SUCCESS_FILE" ]]; then
    printf '\nLast successful install metadata:\n'
    sed 's/^/  /' "$LAST_SUCCESS_FILE"
  fi

  local -a staging_trees=()
  mapfile -t staging_trees < <(
    find "$SRC_ROOT" -maxdepth 1 -type d \
      \( -name '.EverSDK-build-*' -o -name '.EverSDK-old-*' -o -name '.EverSDK-pre-restore-*' \) \
      -print 2>/dev/null | sort
  )

  if ((${#staging_trees[@]} > 0)); then
    printf '\nInstaller staging/recovery trees still present:\n'
    printf '  %s\n' "${staging_trees[@]}"
  fi
}

remove_eversdk() {
  local answer purge_answer pkg
  local -a introduced=()
  local -a purgeable=()

  migrate_legacy_state

  hr
  printf 'Remove EverSDK and installer-created files\n'
  hr

  printf '\nThis removes installer-managed EverSDK files and recovery data:\n'
  printf '  %s\n' "$EVERSDK_DIR"
  printf '  backups and build logs under %s\n' "$STATE_ROOT"
  printf '  installer staging/recovery trees under %s\n' "$SRC_ROOT"
  printf '\nThe apt package-ownership record is preserved whenever recorded\n'
  printf 'installer-added packages remain installed.\n'
  printf '\nIt does NOT delete apt/dpkg logs, journal logs, or other system history.\n'
  printf '\nContinue? [y/N]: '
  read -r answer
  [[ "$answer" =~ ^[Yy]$ ]] || {
    printf 'Removal cancelled.\n'
    return 0
  }

  # Read package ownership state before removing any installer-managed files.
  if [[ -s "$INTRODUCED_PACKAGES_FILE" ]]; then
    mapfile -t introduced < "$INTRODUCED_PACKAGES_FILE"
    for pkg in "${introduced[@]}"; do
      [[ -n "$pkg" ]] || continue
      if package_is_installed "$pkg"; then
        purgeable+=("$pkg")
      fi
    done
  fi

  # Remove the EverSDK tree and disposable installer data, but deliberately
  # preserve the package-ownership record until package disposition is known.
  rm -rf "$EVERSDK_DIR"
  rm -rf "$BACKUP_DIR" "$LOG_DIR"
  rm -f "$LAST_SUCCESS_FILE"
  rm -f \
    "${SRC_ROOT}/libiconv-1.16.tar.gz" \
    "${SRC_ROOT}/libiconv-1.16.tar.gz.part" \
    "${SRC_ROOT}/gettext-0.21.tar.xz" \
    "${SRC_ROOT}/gettext-0.21.tar.xz.part" \
    "${SRC_ROOT}/glibc-2.26.tar.xz" \
    "${SRC_ROOT}/glibc-2.26.tar.xz.part"

  # Clean only installer-created staging/recovery directories.
  find "$SRC_ROOT" -maxdepth 1 -type d \
    \( -name '.EverSDK-build-*' -o -name '.EverSDK-old-*' -o -name '.EverSDK-pre-restore-*' \) \
    -exec rm -rf -- {} + 2>/dev/null || true

  printf '\nEverSDK and disposable installer-created user files have been removed.\n'

  if ((${#purgeable[@]} > 0)); then
    printf '\nThe following installed apt packages were absent before this installer\n'
    printf 'first added them and are therefore eligible for optional removal:\n'
    printf '  %s\n' "${purgeable[@]}"
    printf '\nRemove ONLY these recorded packages now? [y/N]: '
    read -r purge_answer

    if [[ "$purge_answer" =~ ^[Yy]$ ]]; then
      if sudo apt-get purge -y "${purgeable[@]}"; then
        printf '\nRecorded installer-added packages were purged.\n'
        printf 'No automatic apt autoremove was run, to avoid removing unrelated packages.\n'

        # Ownership state is no longer needed only after a successful purge.
        rm -f "$INTRODUCED_PACKAGES_FILE"
      else
        printf '\nPackage purge did not complete successfully.\n' >&2
        printf 'The package-ownership record was preserved at:\n' >&2
        printf '  %s\n' "$INTRODUCED_PACKAGES_FILE" >&2
        printf 'No apt autoremove was run.\n' >&2
        return 1
      fi
    else
      printf 'Recorded apt packages were left installed.\n'
      printf 'Package-ownership record preserved at:\n'
      printf '  %s\n' "$INTRODUCED_PACKAGES_FILE"
    fi
  else
    if [[ -s "$INTRODUCED_PACKAGES_FILE" ]]; then
      printf '\nNo recorded installer-added packages are currently installed.\n'
      printf 'Package-ownership history preserved at:\n'
      printf '  %s\n' "$INTRODUCED_PACKAGES_FILE"
    else
      printf '\nNo currently installed apt packages were recorded as installer-added.\n'
      rm -f "$INTRODUCED_PACKAGES_FILE"
    fi
  fi

  # Remove state directories only when the ownership record no longer exists.
  if [[ ! -e "$INTRODUCED_PACKAGES_FILE" ]]; then
    rmdir "$STATE_ROOT" 2>/dev/null || true
  fi

  # Never remove a non-empty user source directory.
  rmdir "${HOME}/src" 2>/dev/null || true
}

main_menu() {
  local choice

  while true; do
    clear 2>/dev/null || true
    hr
    printf ' EverSDK Setup for Ubuntu 22.04 / 24.04 / 26.04 LTS\n'
    printf ' Installer version %s\n' "$SCRIPT_VERSION"
    hr
    printf '\n'
    printf '  1. Install / update / build EverSDK\n'
    printf '  2. Back up current EverSDK\n'
    printf '  3. Restore latest EverSDK backup\n'
    printf '  4. Show status\n'
    printf '  5. Remove EverSDK and installer-created files\n'
    printf '  6. Exit\n'
    printf '\nSelect an option [1-6]: '
    read -r choice

    case "$choice" in
      1) install_or_update; pause ;;
      2) manual_backup; pause ;;
      3) restore_latest_backup; pause ;;
      4) show_status; pause ;;
      5) remove_eversdk; pause ;;
      6) printf '\nExiting.\n'; exit 0 ;;
      *) printf '\nInvalid selection.\n'; pause ;;
    esac
  done
}

usage() {
  cat <<EOF
Usage:
  $0
  $0 install
  $0 backup
  $0 restore
  $0 status
  $0 remove

With no argument, the interactive menu is shown.
EOF
}

dispatch() {
  case "${1:-menu}" in
    menu)
      main_menu
      ;;
    install|build)
      install_or_update
      ;;
    backup)
      manual_backup
      ;;
    restore)
      restore_latest_backup
      ;;
    status)
      show_status
      ;;
    remove|uninstall)
      remove_eversdk
      ;;
    -h|--help|help)
      usage
      ;;
    *)
      usage >&2
      return 2
      ;;
  esac
}

ensure_not_root
dispatch "${1:-menu}"
