FROM python:3.12-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
        git openssh-client curl ca-certificates sudo \
    && rm -rf /var/lib/apt/lists/*

# UID/GID 1000 matches oser on the containerlab VM, so files touched from
# inside the container keep sane ownership on the bind-mounted workspace.
RUN groupadd -g 1000 dev && useradd -m -u 1000 -g 1000 -s /bin/bash dev \
    && echo "dev ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/dev

ENV VIRTUAL_ENV=/opt/venv
RUN python3 -m venv $VIRTUAL_ENV && chown -R dev:dev $VIRTUAL_ENV
ENV PATH="$VIRTUAL_ENV/bin:$PATH"

USER dev
WORKDIR /workspace

COPY --chown=dev:dev requirements.txt requirements.yml ./
RUN pip install --no-cache-dir --upgrade pip \
    && pip install --no-cache-dir -r requirements.txt yamllint ansible-lint \
    && ansible-galaxy collection install -r requirements.yml
