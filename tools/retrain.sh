#!/bin/bash
# Fallback PCIe Gen2 retrain helper.
#
# The driver performs the required GPU-internal setup during device
# initialization.  This service is deliberately a fallback: it first checks
# every supported GPU and touches only links which are still below Gen2.
set -euo pipefail

readonly REQUIRED_GEN=2
readonly READY_TIMEOUT=60

info() { echo "retrain: $*"; }
warn() { echo "retrain: $*" >&2; }

supported_gpus() {
    lspci -D -d 10de:20c2 2>/dev/null | awk '{print tolower($1)}'
    lspci -D -d 10de:2082 2>/dev/null | awk '{print tolower($1)}'
}

link_generation() {
    local value
    value="$(setpci -s "$1" CAP_EXP+12.w 2>/dev/null || true)"
    if [[ "${value}" =~ ^[[:xdigit:]]{4}$ ]]; then
        printf '%d\n' "$((16#${value} & 0x0f))"
    else
        printf '?\n'
    fi
}

upstream_port() {
    local path
    path="$(readlink -f "/sys/bus/pci/devices/$1" 2>/dev/null || true)"
    [[ -n "${path}" ]] || return 1
    basename "$(dirname "${path}")"
}

wait_for_nvidia() {
    local elapsed
    for ((elapsed = 0; elapsed < READY_TIMEOUT; elapsed++)); do
        if nvidia-smi -L >/dev/null 2>&1; then
            return 0
        fi
        sleep 1
    done
    return 1
}

set_target_gen2() {
    local bdf="$1" before after desired
    before="$(setpci -s "${bdf}" CAP_EXP+30.w 2>/dev/null || true)"
    [[ "${before}" =~ ^[[:xdigit:]]{4}$ ]] || return 1
    printf -v desired '%04x' "$(( (16#${before} & ~0x0f) | REQUIRED_GEN ))"
    setpci -s "${bdf}" "CAP_EXP+30.w=${desired}" >/dev/null
    after="$(setpci -s "${bdf}" CAP_EXP+30.w 2>/dev/null || true)"
    info "${bdf}: target-link-speed ${before} -> ${after}"
}

retrain_one() {
    local gpu="$1" bridge before after ctrl desired
    before="$(link_generation "${gpu}")"

    # This is the safety gate: a link already at Gen2 or higher is never
    # reconfigured or retrained by the user-space fallback.
    if [[ "${before}" =~ ^[0-9]+$ ]] && (( before >= REQUIRED_GEN )); then
        info "gpu=${gpu} already Gen${before}; skip"
        return 0
    fi
    if [[ "${before}" != "1" ]]; then
        warn "gpu=${gpu} current link generation is '${before}', not confirmed Gen1; skip"
        return 1
    fi

    bridge="$(upstream_port "${gpu}")" || {
        warn "gpu=${gpu} upstream bridge not found; skip"
        return 1
    }

    if [[ ! -r "/sys/bus/pci/devices/${gpu}/max_link_speed" ]] ||
       ! grep -Eq '([5-9]|[1-9][0-9])\.0 GT/s' "/sys/bus/pci/devices/${gpu}/max_link_speed"; then
        warn "gpu=${gpu} does not advertise Gen2 capability; skip"
        return 1
    fi

    # Recheck immediately before the retrain request.  The driver may have
    # completed its own initialization while this service was starting.
    before="$(link_generation "${gpu}")"
    if [[ "${before}" =~ ^[0-9]+$ ]] && (( before >= REQUIRED_GEN )); then
        info "gpu=${gpu} reached Gen${before} during startup; skip"
        return 0
    fi
    if [[ "${before}" != "1" ]]; then
        warn "gpu=${gpu} current link generation changed to '${before}', not confirmed Gen1; skip"
        return 1
    fi

    set_target_gen2 "${gpu}" || {
        warn "gpu=${gpu} cannot set target link speed; skip"
        return 1
    }
    set_target_gen2 "${bridge}" || {
        warn "gpu=${gpu} bridge=${bridge} cannot set target link speed; skip"
        return 1
    }

    ctrl="$(setpci -s "${bridge}" CAP_EXP+10.w 2>/dev/null || true)"
    [[ "${ctrl}" =~ ^[[:xdigit:]]{4}$ ]] || {
        warn "gpu=${gpu} bridge=${bridge} link control unreadable; skip"
        return 1
    }

    info "gpu=${gpu} Gen${before}; requesting Gen2 retrain through ${bridge}"
    printf -v desired '%04x' "$((16#${ctrl} | 0x20))"
    setpci -s "${bridge}" "CAP_EXP+10.w=${desired}" >/dev/null

    for _ in {1..10}; do
        sleep 1
        after="$(link_generation "${gpu}")"
        if [[ "${after}" =~ ^[0-9]+$ ]] && (( after >= REQUIRED_GEN )); then
            info "gpu=${gpu} negotiated Gen${after}"
            return 0
        fi
    done

    warn "gpu=${gpu} remains Gen${after}; fallback retrain failed"
    return 1
}

command -v lspci >/dev/null || { warn "lspci not found; skip"; exit 0; }
command -v setpci >/dev/null || { warn "setpci not found; skip"; exit 0; }
if ! wait_for_nvidia; then
    warn "NVIDIA driver was not ready within ${READY_TIMEOUT}s; skip"
    exit 0
fi

mapfile -t GPUS < <(supported_gpus | sort -u)
if (( ${#GPUS[@]} == 0 )); then
    info "no supported CMP 170HX found; skip"
    exit 0
fi

failed=0
for gpu in "${GPUS[@]}"; do
    retrain_one "${gpu}" || failed=$((failed + 1))
done

if (( failed > 0 )); then
    warn "${failed}/${#GPUS[@]} GPU(s) did not reach Gen2"
    exit 1
fi

info "all ${#GPUS[@]} supported GPU(s) are Gen2 or higher"
