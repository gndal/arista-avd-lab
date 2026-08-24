# The inter-VRF firewall: FRR for routing, nftables for policy.
#
# Every real vendor firewall image was tried in this lab's predecessor
# (ceos-evpn-firewall-lab) and dropped: PAN-OS had a start-vs-install console
# bug, FTDv hung mid-boot for 57+ minutes, and ASAv's default-originate never
# passed its own bestpath check. A plain Linux container starts in seconds,
# needs no image acquisition or vendor entitlement, and is fully debuggable --
# real config files, real logs, no VM console black box.
#
# Debian bookworm ships FRR 8.4.4, which is the version frr.conf declares.
FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends \
        frr \
        frr-pythontools \
        iproute2 \
        nftables \
        iputils-ping \
        tcpdump \
        vlan \
        procps \
    && rm -rf /var/lib/apt/lists/*
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh
CMD ["/entrypoint.sh"]
