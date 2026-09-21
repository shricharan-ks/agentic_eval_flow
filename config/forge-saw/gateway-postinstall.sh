#!/usr/bin/env bash
# Post-install for a standalone OpenShell gateway used by ABEvalFlow.
#
# A freshly installed gateway cannot yet be driven by the pipeline. Three things
# are missing, and each produces a distinct, confusing failure:
#
#   1. the CI client has no mTLS identity that this gateway's CA trusts
#      -> "received fatal alert: CertificateRequired"
#   2. the CI OIDC subject is not a member of the gateway workspace
#      -> "The caller does not have permission to execute the specified operation"
#   3. the gateway has no inference route
#      -> "cluster inference is not configured" inside the sandbox
#
# This script fixes all three. It runs a Job in the namespace (the VM is only
# reachable through the Kubernetes API, via virtctl) and prints nothing secret.
#
# Usage:
#   NS=<namespace> SANDBOX=<helm-release> \
#   MODEL=rits/zai-org/glm-5-3 \
#   [LITELLM_URL=http://litellm:4000/v1] [SUBJECT=<oidc-sub>] \
#     ./config/forge-saw/gateway-postinstall.sh
#
# SUBJECT is the OIDC subject the pipeline authenticates as. Leave it unset to
# skip the membership step and add it later; `openshell whoami` in the evaluate
# step log prints the value, as does the gateway's own error message.
set -euo pipefail

NS="${NS:?set NS to the target namespace}"
SANDBOX="${SANDBOX:?set SANDBOX to the openshell-saw helm release name}"
MODEL="${MODEL:?set MODEL to the model id served by your endpoint}"
LITELLM_URL="${LITELLM_URL:-http://litellm.${NS}.svc.cluster.local:4000/v1}"
SUBJECT="${SUBJECT:-}"
SSH_SECRET="${SSH_SECRET:-openshell-aap-ssh}"
SETUP_IMAGE="${SETUP_IMAGE:-ghcr.io/rh-forge/forge-saw-setup:latest}"
JOB="${SANDBOX}-postinstall"

LITELLM_HOST="$(printf '%s' "$LITELLM_URL" | sed -E 's#^https?://##; s#[:/].*$##')"
LITELLM_PORT="$(printf '%s' "$LITELLM_URL" | sed -nE 's#^https?://[^:/]+:([0-9]+).*$#\1#p')"
LITELLM_PORT="${LITELLM_PORT:-4000}"

echo "namespace=$NS sandbox=$SANDBOX model=$MODEL endpoint=$LITELLM_URL"

# The provider profile is data, not a script: ship it through a ConfigMap so the
# Job can import it without a nested heredoc.
oc create configmap "${SANDBOX}-provider-profile" -n "$NS" --dry-run=client -o yaml \
  --from-literal=profile.yaml="$(cat <<PROF
id: litellm-local
display_name: Namespace LiteLLM
description: OpenAI-compatible inference endpoint in this namespace
category: inference
credentials:
  - name: api_key
    description: proxy key (any value when the proxy does not check it)
    env_vars:
      - OPENAI_API_KEY
    required: true
    auth_style: bearer
    header_name: authorization
    query_param: ""
endpoints:
  - host: ${LITELLM_HOST}
    port: ${LITELLM_PORT}
    protocol: rest
    access: read-write
    enforcement: enforce
binaries:
  - /usr/bin/curl
  - /usr/local/bin/curl
inference_capable: true
discovery:
  credentials:
    - api_key
PROF
)" | oc apply -f - >/dev/null

oc delete job "$JOB" -n "$NS" --ignore-not-found >/dev/null 2>&1 || true

oc apply -n "$NS" -f - <<JOBYAML >/dev/null
apiVersion: batch/v1
kind: Job
metadata:
  name: ${JOB}
  labels:
    app.kubernetes.io/part-of: openshell-cnv-fedora
spec:
  backoffLimit: 2
  template:
    metadata:
      labels:
        app.kubernetes.io/part-of: openshell-cnv-fedora
    spec:
      restartPolicy: Never
      serviceAccountName: ${SANDBOX}-setup
      imagePullSecrets: [{name: ghcr-rh-forge-auth}]
      volumes:
        - name: ssh-key
          secret: {secretName: ${SSH_SECRET}, defaultMode: 0400}
        - name: profile
          configMap: {name: ${SANDBOX}-provider-profile}
      containers:
        - name: postinstall
          image: ${SETUP_IMAGE}
          volumeMounts:
            - {name: ssh-key, mountPath: /ssh-key, readOnly: true}
            - {name: profile, mountPath: /profile, readOnly: true}
          env:
            - {name: NS, value: "${NS}"}
            - {name: VM, value: "${SANDBOX}"}
            - {name: MODEL, value: "${MODEL}"}
            - {name: SUBJECT, value: "${SUBJECT}"}
            - {name: LITELLM_URL, value: "${LITELLM_URL}"}
          command: [/usr/bin/bash, -ec]
          args:
            - |
              g() { virtctl -n "\$NS" ssh "cloud-user@vm/\${VM}" \
                      --identity-file=/ssh-key/key \
                      --local-ssh-opts=-oStrictHostKeyChecking=no \
                      --local-ssh-opts=-oUserKnownHostsFile=/dev/null \
                      --command="export PATH=/usr/local/bin:\\\$HOME/.local/bin:\\\$PATH; \$1" 2>/dev/null; }

              echo "=== 1/3 export the gateway's mTLS client identity ==="
              # The VM generates its own CA, so the client certificate has to come
              # from the VM. The evaluate task mounts this Secret.
              out=/tmp/mtls; mkdir -p "\$out"; chmod 700 "\$out"
              g "cat ~/.local/state/openshell/tls/ca.crt"         > "\$out/ca.crt"
              g "cat ~/.local/state/openshell/tls/client/tls.crt" > "\$out/tls.crt"
              g "cat ~/.local/state/openshell/tls/client/tls.key" > "\$out/tls.key"
              for f in ca.crt tls.crt tls.key; do
                test -s "\$out/\$f" || { echo "ERROR: \$f came back empty"; exit 1; }
                echo "  \$f: \$(wc -c < "\$out/\$f") bytes"
              done
              grep -q "BEGIN CERTIFICATE" "\$out/ca.crt" || { echo "ERROR: ca.crt is not a certificate"; exit 1; }
              kubectl create secret generic openshell-mtls -n "\$NS" \
                --from-file=ca.crt="\$out/ca.crt" \
                --from-file=tls.crt="\$out/tls.crt" \
                --from-file=tls.key="\$out/tls.key" \
                --dry-run=client -o yaml | kubectl apply -f -

              echo "=== 2/3 workspace membership ==="
              if [ -n "\${SUBJECT}" ]; then
                g "openshell workspace member add --workspace 'default' --subject '\${SUBJECT}' --role user 2>&1 | head -5"
                g "openshell workspace member list --workspace default 2>&1 | head -5"
              else
                echo "  SUBJECT not set - skipping. Add it once you know the OIDC subject:"
                echo "    openshell workspace member add --workspace default --subject <sub> --role user"
              fi

              echo "=== 3/3 provider and inference route ==="
              B64="\$(base64 -w0 /profile/profile.yaml)"
              g "echo \$B64 | base64 -d > /tmp/profile.yaml; openshell provider profile import --file /tmp/profile.yaml 2>&1 | head -5"
              # Cluster inference accepts builtin provider types only, so the
              # provider is created as type openai while the imported profile
              # supplies the real endpoint.
              g "openshell provider delete litellm >/dev/null 2>&1; openshell provider create --name litellm --type openai --credential OPENAI_API_KEY=unused --config base_url=\${LITELLM_URL} 2>&1 | head -5"
              g "openshell inference set --provider litellm --model '\${MODEL}' --no-verify 2>&1 | head -5"
              g "openshell inference set --system --provider litellm --model '\${MODEL}' --no-verify 2>&1 | head -5"
              g "openshell inference get 2>&1 | head -10"
              echo "=== done ==="
JOBYAML

echo "waiting for job/${JOB} ..."
until oc get job "$JOB" -n "$NS" -o jsonpath='{.status.conditions[*].type}' 2>/dev/null | grep -qE "Complete|Failed"; do sleep 10; done
oc logs -n "$NS" "job/$JOB" | grep -v "known hosts"
oc get job "$JOB" -n "$NS" -o jsonpath='{.status.conditions[*].type}{"\n"}'
