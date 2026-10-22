FROM oraclelinux:9

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

ARG APP_USER
ARG APP_GROUP
ARG APP_UID
ARG APP_GID
ARG HOME_DIR
ARG APP_HOME
ARG SD_HOME
ARG TOOL_DATA
ARG TOOL_LOG
ARG RELEASE_VERSION
ARG RELEASE_SOURCE_COMMIT
ARG RELEASE_CREATED_AT
ARG RELEASE_PLATFORM
ARG SQLCL_VERSION=26.2.2.233.1901
ARG SQLCL_SHA256=17f89fddf69722f37d7bde0718e66490647b25b295bf52fba92ba0ad042fa256

LABEL org.opencontainers.image.version="${RELEASE_VERSION}" \
      org.opencontainers.image.revision="${RELEASE_SOURCE_COMMIT}" \
      org.opencontainers.image.created="${RELEASE_CREATED_AT}" \
      org.opencontainers.image.platform="${RELEASE_PLATFORM}"

ENV APP_USER="${APP_USER}" \
    APP_GROUP="${APP_GROUP}" \
    APP_UID="${APP_UID}" \
    APP_GID="${APP_GID}" \
    HOME_DIR="${HOME_DIR}" \
    APP_HOME="${APP_HOME}" \
    SD_HOME="${SD_HOME}" \
    TOOL_DATA="${TOOL_DATA}" \
    TOOL_LOG="${TOOL_LOG}" \
    JAVA_HOME=/usr/lib/jvm/java-17-openjdk \
    LANG=en_US.UTF-8 \
    LC_ALL=en_US.UTF-8

ENV PATH="${HOME_DIR}/.local/bin:${HOME_DIR}:${SD_HOME}/sqldeveloper/bin:/opt/sqlcl/bin:/opt/mssql-tools18/bin:${JAVA_HOME}/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

USER root

RUN dnf -y install \
      java-17-openjdk \
      python3 \
      curl \
      file \
      unzip \
      which \
      findutils \
      hostname \
      procps-ng \
      strace \
      shadow-utils \
      sudo \
      jq \
      less \
      openssl \
      ca-certificates \
      unixODBC \
      libaio \
      libnsl \
      iproute \
      net-tools \
      bind-utils \
      nmap-ncat \
      tree \
      vim-minimal \
      iputils \
      rpm \
    && dnf clean all \
    && java_path="$(readlink -f "$(command -v java)")" \
    && java_home="$(dirname "$(dirname "$java_path")")" \
    && test -x "$java_home/bin/java" \
    && ln -s "$java_home" "$JAVA_HOME" \
    && test -x "$JAVA_HOME/bin/java"

RUN curl -L -o /usr/local/bin/yq \
      https://github.com/mikefarah/yq/releases/download/v4.45.1/yq_linux_amd64 \
    && chmod +x /usr/local/bin/yq \
    && mkdir -p /u01/app \
    && curl -fL -o /u01/app/jtds-1.3.1.jar \
         https://repo1.maven.org/maven2/net/sourceforge/jtds/jtds/1.3.1/jtds-1.3.1.jar \
    && test -s /u01/app/jtds-1.3.1.jar

RUN curl -fL --retry 3 -o /tmp/sqlcl.zip \
      "https://download.oracle.com/otn_software/java/sqldeveloper/sqlcl-${SQLCL_VERSION}.zip" \
    && echo "${SQLCL_SHA256}  /tmp/sqlcl.zip" | sha256sum -c - \
    && unzip -q /tmp/sqlcl.zip -d /opt \
    && test -f /opt/sqlcl/bin/sql \
    && chmod 0755 /opt/sqlcl/bin/sql \
    && install -D -m 0644 /opt/sqlcl/LICENSE.txt /usr/share/licenses/sqlcl/LICENSE.txt \
    && install -m 0644 /opt/sqlcl/NOTICES.txt /usr/share/licenses/sqlcl/NOTICES.txt \
    && rm -f /tmp/sqlcl.zip

COPY docs/licenses/ORACLE-FUTC.txt /usr/share/licenses/sqlcl/ORACLE-FUTC.txt

RUN test -n "${APP_USER}" \
 && test -n "${APP_GROUP}" \
 && test -n "${APP_UID}" \
 && test -n "${APP_GID}" \
 && test -n "${HOME_DIR}" \
 && test -n "${APP_HOME}" \
 && test -n "${SD_HOME}" \
 && test -n "${TOOL_DATA}" \
 && test -n "${TOOL_LOG}"

RUN /usr/sbin/groupadd -g "${APP_GID}" "${APP_GROUP}" \
    && /usr/sbin/useradd -u "${APP_UID}" -m -d "${HOME_DIR}" -g "${APP_GROUP}" -s /bin/bash "${APP_USER}"

RUN mkdir -p \
      "${APP_HOME}" \
      "${SD_HOME}" \
      "${TOOL_DATA}" \
      "${TOOL_LOG}" \
      /u01/app \
      /u01/data \
      /u01/log \
    && chown -R "${APP_USER}:${APP_GROUP}" \
      "${HOME_DIR}" \
      "${APP_HOME}" \
      /u01 \
    && chgrp -R "${APP_GROUP}" /opt/sqlcl \
    && chmod -R g+rX /opt/sqlcl

USER "${APP_USER}"
WORKDIR "${HOME_DIR}"

RUN mkdir -p "${TOOL_DATA}/.shell_history" \
    && touch "${TOOL_DATA}/.shell_history/.bash_history" \
    && ln -sf "${TOOL_DATA}/.shell_history/.bash_history" "${HOME_DIR}/.bash_history"

RUN echo 'export HISTFILE=$HOME/.bash_history' >> "${HOME_DIR}/.bashrc" \
    && echo 'export HISTSIZE=10000' >> "${HOME_DIR}/.bashrc" \
    && echo 'export HISTFILESIZE=20000' >> "${HOME_DIR}/.bashrc" \
    && echo 'shopt -s histappend' >> "${HOME_DIR}/.bashrc" \
    && echo 'export PROMPT_COMMAND="history -a; history -n"' >> "${HOME_DIR}/.bashrc"

CMD ["/bin/bash", "-lc", "trap 'exit 0' TERM INT; while :; do sleep 3600 & wait $!; done"]
