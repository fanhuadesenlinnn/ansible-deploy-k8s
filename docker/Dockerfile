# syntax=docker/dockerfile:1

# Ansible 控制端镜像同时支持 amd64 和 arm64；目标节点仍通过 SSH 远程管理。
FROM python:3.12-slim-bookworm

ARG ANSIBLE_USER=ansible
ARG ANSIBLE_UID=1000
ARG ANSIBLE_GID=1000

ENV PYTHONDONTWRITEBYTECODE=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PIP_NO_CACHE_DIR=1 \
    ANSIBLE_CONFIG=/workspace/ansible.cfg \
    ANSIBLE_COLLECTIONS_PATH=/usr/share/ansible/collections \
    ANSIBLE_HOME=/tmp/ansible-runtime/home \
    ANSIBLE_LOCAL_TEMP=/tmp/ansible-runtime/tmp

# openssh-client 用于连接目标节点；sshpass 让 --ask-pass 密码登录方式也能工作。
RUN apt-get update \
    && apt-get install --yes --no-install-recommends \
        bash \
        ca-certificates \
        openssh-client \
        sshpass \
    && rm -rf /var/lib/apt/lists/* \
    && groupadd --gid "${ANSIBLE_GID}" "${ANSIBLE_USER}" \
    && useradd \
        --uid "${ANSIBLE_UID}" \
        --gid "${ANSIBLE_GID}" \
        --create-home \
        --shell /bin/bash \
        "${ANSIBLE_USER}"

# 依赖与项目本机运行方式共用同一份版本约束，避免维护第二套 Ansible 环境定义。
COPY requirements.txt requirements.yml /tmp/ansible-dependencies/

RUN python -m pip install --requirement /tmp/ansible-dependencies/requirements.txt \
    && ansible-galaxy collection install \
        --requirements-file /tmp/ansible-dependencies/requirements.yml \
        --collections-path /usr/share/ansible/collections \
    && rm -rf /tmp/ansible-dependencies

COPY --chmod=0755 docker/entrypoint.sh /usr/local/bin/ansible-entrypoint

USER ${ANSIBLE_USER}
WORKDIR /workspace

ENTRYPOINT ["ansible-entrypoint"]
CMD ["ansible", "--version"]
