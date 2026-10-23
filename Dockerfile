ARG image_repo=ubuntu
ARG image_tag=noble

FROM ${image_repo}:${image_tag} AS volttron_base

#
SHELL [ "bash", "-c" ]
#
ENV OS_TYPE=debian
ENV DIST=noble
ENV VOLTTRON_GIT_BRANCH=${volttron_git_branch}
ENV VOLTTRON_USER_HOME=/home/volttron
ENV VOLTTRON_HOME=${VOLTTRON_USER_HOME}/.volttron
ENV CODE_ROOT=/code
ENV VOLTTRON_ROOT=${CODE_ROOT}/volttron
ENV VOLTTRON_USER=volttron
ENV USER_PIP_BIN=${VOLTTRON_USER_HOME}/.local/bin
ENV CONFIG=/home/volttron/configs
ENV TZ=UTC
ENV LOCAL_USER_ID=1000
#ENV RMQ_ROOT=${VOLTTRON_USER_HOME}/rabbitmq_server
#ENV RMQ_HOME=${RMQ_ROOT}/rabbitmq_server-3.7.7
#
USER root
RUN set -eux; apt-get update; apt-get install -y --no-install-recommends \
    procps \
    gosu \
    vim \
    tree \
    build-essential \
    python3-dev \
    python3-pip \
    python3-setuptools \
    python3-venv \
    rustup \
    openssl \
    libssl-dev \
    libevent-dev \
    libpq-dev \
    git \
    gnupg \
    dirmngr \
    apt-transport-https \
    wget \
    curl \
    ca-certificates \
    libffi-dev \
    libx11-6 \
    libxext6 \
    libxrender1 \
    libxi6 \
    sqlite3
#
# Set default 'python' to 'python3'
RUN update-alternatives --install /usr/bin/python python /usr/bin/python3 1

#
# Set global.break-system-packages to true to allow pip to install packages
#
RUN python3 -m pip config set global.break-system-packages true

#
# Upgrade pip so that we get a pre-compiled wheel for 'cryptopgraphy', which is a dependency of Volttron
# See https://cryptography.io/en/latest/faq/#installing-cryptography-fails-with-error-can-not-find-rust-compiler
RUN python3 -m pip install --upgrade --ignore-installed pip
RUN python3 -m pip install bacpypes3

RUN set -eux && apt-get update --fix-missing  && apt-get install -y --no-install-recommends locales \
    default-jdk \
    iputils-ping \
    libgeos-dev \
    libeccodes-tools \
    openssl \
    libssl-dev \
    python3-tk

RUN apt-get install python3-scipy python3-sklearn python3-sklearn-lib python-sklearn-doc -y

#
# Install rust and cargo
#
RUN rustup default stable

# Download and install energyplus 8.5.0
# DO NOT update to latest version; IDF files for energyplus are not backward compatible
RUN wget https://github.com/NREL/EnergyPlus/releases/download/v8.5.0/EnergyPlus-8.5.0-c87e61b44b-Linux-x86_64.sh

# This command will automate the interactive installation script by automatically answering the three questions being presented:
# The printf command mimics the manual action of entering "yes" followed by two "enter" commands to accept the default configuration
RUN printf 'y\n\n\n\n\n' | bash EnergyPlus-8.5.0-c87e61b44b-Linux-x86_64.sh



# Create a user called 'volttron'
RUN userdel -r ubuntu 2>/dev/null || true; \
    id -u $VOLTTRON_USER &>/dev/null || adduser --uid $LOCAL_USER_ID --disabled-password --gecos "" $VOLTTRON_USER
#
RUN mkdir -p /code && chown $VOLTTRON_USER.$VOLTTRON_USER /code && \
    echo "export PATH=/home/volttron/.local/bin:$PATH" > /home/volttron/.bashrc
#
############################################
# ENDING volttron_base stage
# Creating volttron_core stage
############################################
FROM volttron_base AS volttron_core

ARG volttron_repo=https://github.com/VOLTTRON/volttron.git
ARG volttron_git_branch=main

# copy over /core, i.e. the custom startup scripts for this image
RUN mkdir /startup $VOLTTRON_HOME && \
    chown $VOLTTRON_USER.$VOLTTRON_USER $VOLTTRON_HOME
COPY --chown=volttron:volttron ./core /startup
RUN chmod +x /startup/*

COPY --chown=volttron:volttron agents/EnergyplusAgent /code/EnergyPlusAgent
RUN cp /code/EnergyPlusAgent/eplus_config/socket.cfg /code/EnergyPlusAgent/eplus_config/building1/socket.cfg && \
    cp /code/EnergyPlusAgent/eplus_config/variables.cfg /code/EnergyPlusAgent/eplus_config/building1/variables.cfg

#
# copy over volttron repo
USER $VOLTTRON_USER


RUN git clone --branch ${volttron_git_branch} --single-branch ${volttron_repo} ${VOLTTRON_ROOT}
RUN sed -i 's/psycopg2-binary==2.9.7/psycopg2-binary==2.9.13/g' ${VOLTTRON_ROOT}/requirements.py
RUN sed -i 's/action, option_string, explicit_arg = option_tuple/action, option_string, explicit_arg, *unused = option_tuple/' ${VOLTTRON_ROOT}/volttron/platform/config.py

WORKDIR ${VOLTTRON_ROOT}

#
# Set global.break-system-packages to true to allow pip to install packages
#
RUN python3 -m pip config set global.break-system-packages true
#
# Upgrade pip so that we get a pre-compiled wheel for 'cryptography', which is a dependency of Volttron
# See https://cryptography.io/en/latest/faq/#installing-cryptography-fails-with-error-can-not-find-rust-compiler
RUN python3 -m pip install --upgrade --ignore-installed pip

#
# Now install volttron required packages
#
RUN python3 -m pip install --user 'Cython<3'
RUN pip install -e . --user --no-build-isolation
RUN echo "package installed at `date`"

#
#############################################
## RABBITMQ SPECIFIC INSTALLATION
#############################################
## the ARG install_rmq must be declared twice due to scope; see https://docs.docker.com/engine/reference/builder/#using-arg-variables
#USER root
#ARG install_rmq
#RUN if [ "${install_rmq}" = "false" ] ; then \
#      echo "Not installing RMQ dependencies.";  \
#    else \
#      ./scripts/rabbit_dependencies.sh $OS_TYPE $DIST && \
#      python -m pip install gevent-pika; \
#    fi
##
#USER $VOLTTRON_USER
#ARG install_rmq
#RUN if [ "${install_rmq}" = "false" ] ; then \
#      echo "Not installing RMQ"; \
#    else \
#      mkdir $RMQ_ROOT && \
#      set -eux && \
#      wget -P $VOLTTRON_USER_HOME https://github.com/rabbitmq/rabbitmq-server/releases/download/v3.7.7/rabbitmq-server-generic-unix-3.7.7.tar.xz && \
#      tar -xf $VOLTTRON_USER_HOME/rabbitmq-server-generic-unix-3.7.7.tar.xz --directory $RMQ_ROOT && \
#      $RMQ_HOME/sbin/rabbitmq-plugins enable rabbitmq_management rabbitmq_federation rabbitmq_federation_management rabbitmq_shovel rabbitmq_shovel_management rabbitmq_auth_mechanism_ssl rabbitmq_trust_store;  \
#    fi
############################################

RUN python -m pip install --user pyzmq psycopg2-binary

########################################
# The following lines should be run from any Dockerfile that
# is inheriting from this one as this will make the volttron
# run in the proper location.
#
# The user must be root at this point to allow gosu to work
########################################
USER root
WORKDIR ${VOLTTRON_USER_HOME}
ENTRYPOINT ["/startup/entrypoint.sh"]
CMD ["/startup/bootstart.sh"]
