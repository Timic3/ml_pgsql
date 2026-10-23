# Official MTA:SA Linux server (x64, or arm64 when built with --platform linux/arm64) for
# integration tests and benchmarks.
# focal: provides libssl1.1, which MTA's built-in MySQL driver (dbconmy.so) needs.
FROM ubuntu:20.04

RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends tzdata \
 && apt-get install -y --no-install-recommends libncursesw6 libssl1.1 ca-certificates curl procps \
 && rm -rf /var/lib/apt/lists/*

# The arm64 server is mta-server-arm64 and loads modules from arm64/modules; alias both to
# the x64 names so compose and the test scripts are architecture-independent.
RUN arch="$(uname -m)" \
 && case "$arch" in aarch64) pkg=arm64 ;; *) pkg=x64 ;; esac \
 && curl -fsSL "https://linux.multitheftauto.com/dl/multitheftauto_linux_${pkg}.tar.gz" | tar xz -C /opt \
 && mv /opt/multitheftauto_linux_${pkg} /mta \
 && curl -fsSL https://linux.multitheftauto.com/dl/baseconfig.tar.gz | tar xz -C /tmp \
 && cp /tmp/baseconfig/* /mta/mods/deathmatch/ \
 && mkdir -p /mta/x64/modules /mta/mods/deathmatch/resources /mta/mods/deathmatch/logs \
 && if [ "$pkg" = arm64 ]; then ln -s /mta/x64/modules /mta/arm64/modules && ln -s mta-server-arm64 /mta/mta-server64; fi

WORKDIR /mta
# -n: plain console, -u: unbuffered output, -x: no crash handler (let crashes surface)
ENTRYPOINT ["./mta-server64", "-n", "-u", "-x"]
