#!/usr/bin/env bash

set -Eeuo pipefail

readonly IMAGE_REF="ghcr.io/${GITHUB_REPOSITORY}:${GITHUB_SHA}"
readonly SSH_DIR="${RUNNER_TEMP}/moneta-ssh"
readonly SSH_KEY_FILE="${SSH_DIR}/deploy-key"
readonly KNOWN_HOSTS_FILE="${SSH_DIR}/known-hosts"
readonly IMAGE_TAR="${RUNNER_TEMP}/moneta-image.tar"
readonly DOCKER_CONFIG="${RUNNER_TEMP}/moneta-docker"
export DOCKER_CONFIG

for required_name in \
    CF_ACCESS_CLIENT_ID \
    CF_ACCESS_CLIENT_SECRET \
    CF_TEAM_NAME \
    DEPLOY_TARGET \
    DEPLOY_SSH_KEY \
    DEPLOY_SSH_HOST_KEY \
    GITHUB_TOKEN; do
    if [[ -z "${!required_name:-}" ]]; then
        echo "Missing required deployment secret: ${required_name}" >&2
        exit 1
    fi
done

cleanup() {
    set +e
    docker logout ghcr.io >/dev/null 2>&1
    sudo warp-cli --accept-tos disconnect >/dev/null 2>&1
    sudo warp-cli --accept-tos registration delete >/dev/null 2>&1
    sudo rm -f /var/lib/cloudflare-warp/mdm.xml
    rm -rf "${SSH_DIR}" "${DOCKER_CONFIG}" "${IMAGE_TAR}"
}
trap cleanup EXIT

curl -fsSL https://pkg.cloudflareclient.com/pubkey.gpg \
    | sudo gpg --yes --dearmor --output /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg
printf 'deb [signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] https://pkg.cloudflareclient.com/ %s main\n' \
    "$(lsb_release -cs)" \
    | sudo tee /etc/apt/sources.list.d/cloudflare-client.list >/dev/null
sudo apt-get update --quiet
sudo apt-get install --yes --quiet cloudflare-warp

mdm_file="$(mktemp)"
chmod 600 "${mdm_file}"
{
    printf '%s\n' '<dict>'
    printf '%s\n' '  <key>auth_client_id</key>'
    printf '  <string>%s</string>\n' "${CF_ACCESS_CLIENT_ID}"
    printf '%s\n' '  <key>auth_client_secret</key>'
    printf '  <string>%s</string>\n' "${CF_ACCESS_CLIENT_SECRET}"
    printf '%s\n' '  <key>auto_connect</key>'
    printf '%s\n' '  <integer>1</integer>'
    printf '%s\n' '  <key>onboarding</key>'
    printf '%s\n' '  <false/>'
    printf '%s\n' '  <key>organization</key>'
    printf '  <string>%s</string>\n' "${CF_TEAM_NAME}"
    printf '%s\n' '  <key>service_mode</key>'
    printf '%s\n' '  <string>warp</string>'
    printf '%s\n' '</dict>'
} >"${mdm_file}"
sudo install -d -m 755 /var/lib/cloudflare-warp
sudo install -m 600 "${mdm_file}" /var/lib/cloudflare-warp/mdm.xml
rm -f "${mdm_file}"
sudo systemctl enable warp-svc >/dev/null
sudo systemctl restart warp-svc

daemon_ready=0
for _ in $(seq 1 30); do
    if sudo warp-cli --accept-tos status >/dev/null 2>&1; then
        daemon_ready=1
        break
    fi
    sleep 1
done
if [[ "${daemon_ready}" -ne 1 ]]; then
    sudo systemctl status warp-svc --no-pager >&2 || true
    sudo journalctl --unit=warp-svc --lines=100 --no-pager >&2 || true
    echo "Cloudflare WARP daemon failed to become ready." >&2
    exit 1
fi

sudo warp-cli --accept-tos connect >/dev/null

connected=0
for _ in $(seq 1 60); do
    if sudo warp-cli --accept-tos status 2>/dev/null | grep -q 'Connected'; then
        connected=1
        break
    fi
    sleep 1
done
if [[ "${connected}" -ne 1 ]]; then
    echo "Cloudflare private network connection failed." >&2
    exit 1
fi

install -d -m 700 "${SSH_DIR}"
printf '%s\n' "${DEPLOY_SSH_KEY}" >"${SSH_KEY_FILE}"
printf '%s\n' "${DEPLOY_SSH_HOST_KEY}" >"${KNOWN_HOSTS_FILE}"
chmod 600 "${SSH_KEY_FILE}" "${KNOWN_HOSTS_FILE}"

reachable=0
for _ in $(seq 1 30); do
    if timeout 2 bash -c "</dev/tcp/${DEPLOY_TARGET}/22" 2>/dev/null; then
        reachable=1
        break
    fi
    sleep 1
done
if [[ "${reachable}" -ne 1 ]]; then
    echo "Private deployment endpoint is unreachable." >&2
    exit 1
fi

printf '%s' "${GITHUB_TOKEN}" \
    | docker login ghcr.io --username "${GITHUB_ACTOR}" --password-stdin >/dev/null
docker pull --quiet "${IMAGE_REF}"
docker save --output "${IMAGE_TAR}" "${IMAGE_REF}"

config_path="$(tar --extract --to-stdout --file="${IMAGE_TAR}" manifest.json | jq --raw-output '.[0].Config')"
case "${config_path}" in
    blobs/sha256/*)
        config_digest="${config_path##*/}"
        ;;
    *.json)
        config_digest="${config_path##*/}"
        config_digest="${config_digest%.json}"
        ;;
    *)
        echo "Docker archive contains an unexpected config path." >&2
        exit 1
        ;;
esac
if [[ ! "${config_digest}" =~ ^[0-9a-f]{64}$ ]]; then
    echo "Docker archive contains an invalid config digest." >&2
    exit 1
fi
image_id="sha256:${config_digest}"

zstd --quiet --threads=0 --stdout "${IMAGE_TAR}" \
    | ssh \
        -T \
        -i "${SSH_KEY_FILE}" \
        -o BatchMode=yes \
        -o IdentitiesOnly=yes \
        -o StrictHostKeyChecking=yes \
        -o UserKnownHostsFile="${KNOWN_HOSTS_FILE}" \
        -o HostKeyAlias=moneta-deploy \
        -o ServerAliveInterval=15 \
        -o ServerAliveCountMax=4 \
        "moneta-deploy@${DEPLOY_TARGET}" \
        "deploy ${GITHUB_SHA} ${image_id}"
