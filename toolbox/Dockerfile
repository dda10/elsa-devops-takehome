# Toolbox: kubectl, helm, terraform and k6 preinstalled. Scripts are bind-mounted, not baked in.
FROM debian:bookworm-slim

ARG TARGETARCH
ARG KUBECTL_VERSION=v1.31.4
ARG HELM_VERSION=v3.16.4
ARG TERRAFORM_VERSION=1.9.8
ARG K6_VERSION=0.54.0

RUN apt-get update \
 && apt-get install -y --no-install-recommends bash ca-certificates curl git jq unzip sed gawk \
 && rm -rf /var/lib/apt/lists/*

RUN curl -fsSLo /usr/local/bin/kubectl "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${TARGETARCH}/kubectl" \
 && chmod +x /usr/local/bin/kubectl

RUN curl -fsSL "https://get.helm.sh/helm-${HELM_VERSION}-linux-${TARGETARCH}.tar.gz" | tar -xz -C /tmp \
 && mv /tmp/linux-${TARGETARCH}/helm /usr/local/bin/helm \
 && rm -rf /tmp/linux-${TARGETARCH}

RUN curl -fsSLo /tmp/terraform.zip "https://releases.hashicorp.com/terraform/${TERRAFORM_VERSION}/terraform_${TERRAFORM_VERSION}_linux_${TARGETARCH}.zip" \
 && unzip -q /tmp/terraform.zip -d /usr/local/bin \
 && rm /tmp/terraform.zip

RUN curl -fsSL "https://github.com/grafana/k6/releases/download/v${K6_VERSION}/k6-v${K6_VERSION}-linux-${TARGETARCH}.tar.gz" | tar -xz -C /tmp \
 && mv /tmp/k6-v${K6_VERSION}-linux-${TARGETARCH}/k6 /usr/local/bin/k6

# Terraform/helm cache and kube config live in /root; keep them writable for non-interactive runs.
ENV TF_IN_AUTOMATION=1 \
    HELM_NO_PLUGINS=1
