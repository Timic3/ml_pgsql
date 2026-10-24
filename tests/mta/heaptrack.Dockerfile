# The MTA server image plus heaptrack, which traces every allocation of the unmodified
# mta-server64 through LD_PRELOAD. Used by `SOAK_HEAPTRACK=1 tests/soak.sh` to attribute memory
# growth (analyse the trace with heaptrack_print, which is installed here too).
ARG BASE=mlpg-mta:amd64
FROM ${BASE}
# heaptrack 1.1 writes its trace to the working directory, which must stay /mta for the server
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends heaptrack \
 && rm -rf /var/lib/apt/lists/* \
 && sed -i 's|^output=$(pwd)/|output=${HEAPTRACK_DIR:-$(pwd)}/|' /usr/bin/heaptrack \
 && grep -q 'HEAPTRACK_DIR' /usr/bin/heaptrack
ENV HEAPTRACK_DIR=/mta/mods/deathmatch/logs
ENTRYPOINT ["heaptrack", "./mta-server64", "-n", "-u", "-x"]
