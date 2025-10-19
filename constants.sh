# Constants - shared by all scripts
readonly NS="jailed_ns"
readonly HOMEJ="/home/${USER}/.jailed"
readonly VETH_HOST="veth0-${NS}"
readonly VETH_NS="veth1-${NS}"
readonly HOST_IP="10.200.200.1"
readonly NS_IP="10.200.200.2"
readonly SUBNET_MASK="24"
readonly HANDSHAKE_TIMEOUT=5 # seconds
readonly FW_CHAIN="JAIL_FWD_${NS}"
readonly color_red='\033[0;31m'
readonly color_green='\033[0;32m'
readonly color_yellow='\033[0;33m'
readonly color_nc='\033[0m';

log() {
    local level="$1"
    local msg="$2"

    case "$level" in
        "INFO")    echo -e "[${color_yellow}INFO${color_nc}]    $msg" ;;
        "SUCCESS") echo -e "[${color_green}SUCCESS${color_nc}] $msg" ;;
        "ERROR")   echo -e "[${color_red}ERROR${color_nc}]   $msg" >&2 ;;
        *)         echo -e "$msg" ;;
    esac
}


