# A separate Linux correctness profile; never compare its timings with macOS.
FROM haskell:9.10.3-slim-bookworm@sha256:683f74f48dcc5a40081628d12ebe8f3bb379bf3fefa46d74e785b5fbb9f21b32 AS tooling
FROM mariadb:12.3@sha256:d46e102fa8b9b72bfcdeb56f9dd538742092119dc8b11f31fe662605cd234cd9
USER root
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    ghc cabal-install build-essential libgmp-dev zlib1g-dev libffi-dev pkg-config \
    libmariadb-dev openssl python3 git ca-certificates curl libkrb5-dev \
    krb5-kdc krb5-admin-server krb5-user libpam0g-dev mariadb-plugin-gssapi-server \
    && rm -rf /var/lib/apt/lists/*
COPY --from=tooling /usr/local/bin/cabal /usr/local/bin/cabal
ENV CABAL_DIR=/root/.cabal
WORKDIR /workspace
COPY mysql-haskell.cabal ./
RUN cabal user-config init && sed -i 's|url: http://hackage.haskell.org/|url: https://hackage.haskell.org/|' /root/.cabal/config && cabal update
RUN cabal build all --only-dependencies --enable-tests -O2
COPY . .
RUN mkdir -p /opt/driver-auth && gcc -Wall -Wextra -Werror -fPIC -shared \
    validation/auth_fixture/pam_fixture.c -lpam -o /opt/driver-auth/pam_fixture.so
RUN touch /opt/driver-auth/disposable-fixture
# Git history supplies the original baseline revision. Private configuration
# and host build artifacts are excluded from the image context.
ENTRYPOINT ["python3", "validation/linux/verify.py"]
