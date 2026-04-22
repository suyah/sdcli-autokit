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

ENV PATH="${HOME_DIR}/.local/bin:${HOME_DIR}:${SD_HOME}/sqldeveloper/bin:/opt/mssql-tools18/bin:${JAVA_HOME}/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

USER root

RUN dnf -y install \
      java-17-openjdk \
      curl \
      wget \
      file \
      unzip \
      which \
      findutils \
      hostname \
      procps-ng \
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
      iputils \
    && dnf clean all

RUN curl -sSL https://packages.microsoft.com/config/rhel/9/prod.repo \
      -o /etc/yum.repos.d/microsoft-prod.repo \
    && ACCEPT_EULA=Y dnf -y install \
         msodbcsql18 \
         mssql-tools18 \
    && dnf clean all

RUN curl -L -o /usr/local/bin/yq \
      https://github.com/mikefarah/yq/releases/download/v4.45.1/yq_linux_amd64 \
    && chmod +x /usr/local/bin/yq

RUN dnf -y install oracle-instantclient-release-el9 \
    && dnf -y install \
         oracle-instantclient19.30-basic.x86_64 \
         oracle-instantclient19.30-sqlplus.x86_64 \
         oracle-instantclient19.30-tools.x86_64 \
    && dnf clean all

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
      /u01/install \
    && chown -R "${APP_USER}:${APP_GROUP}" \
      "${HOME_DIR}" \
      "${APP_HOME}" \
      /u01

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

RUN echo 'export PATH=/usr/lib/oracle/19.30/client64/bin:$PATH' >> "${HOME_DIR}/.bashrc" \
    && echo 'export LD_LIBRARY_PATH=/usr/lib/oracle/19.30/client64/lib:$LD_LIBRARY_PATH' >> "${HOME_DIR}/.bashrc"

CMD ["/bin/bash", "-lc", "trap 'exit 0' TERM INT; while :; do sleep 3600 & wait $!; done"]
