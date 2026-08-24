# Low-level design

Topology, addressing, and variable layering. See `docs/decisions.md` for
*why* each of these choices was made, and `docs/verification.md` for
evidence they actually work.

## Topology

13 containers, lab name `esidc`, mgmt network `clab-esidc` on
`172.40.40.0/24` (distinct from `home/avd`'s `172.20.20.0/24` and
`home/arista-avd-dc-wan`'s `172.30.30.0/24`, so all three can run on the
containerlab VM at once, capacity permitting -- they cannot run
*simultaneously* on this VM without exceeding available vCPU, see
`docs/troubleshooting.md`'s boot-contention note).

```
                    spine1 (.11)          spine2 (.12)          AS 65100
                   /  |  |  \  \  \      /  |  |  \  \  \
            Eth1  Eth2 Eth3 Eth4 Eth5 Eth6  (spine side; leaf/borderleaf
                                              side is always Eth1->spine1,
                                              Eth2->spine2)
   leaf1a(.21) leaf1b(.22)   leaf2a(.23) leaf2b(.24)   borderleaf1(.31) borderleaf2(.32)
   \___ AS 65101 ___/        \___ AS 65102 ___/         \____ AS 65103 ____/
   ESI pair, RACK1            ESI pair, RACK2            pair, no shared ESI
     |Eth3  |Eth4               |Eth3  |Eth4                |Eth3        |Eth3
   h1-red h1-blue              h2-red h2-blue                |           |
   (.41)  (.42)                (.43)  (.44)                  fw1 (.51), AS 65500
   bond0, LACP 802.3ad to both leaves in the pair        eth1/eth2 routed, dot1q per VRF
```

`fw1` is dual-homed to both borderleaves -- one routed link each, four BGP
sessions total (one per VRF per borderleaf). See `docs/decisions.md` for the
history here: this was briefly single-homed to `borderleaf1` only, then
reverted back to dual-homed by request.

- Underlay/overlay: eBGP, unique-per-pair ASN (`65101`/`65102`/`65103`),
  spines share `65100` (they never peer with each other, only with leaves,
  so a shared ASN is correct and simpler than one per spine).
- Node ids (drive loopback/VTEP pool offsets): spines 1-2; `leaf1a`=1,
  `leaf1b`=2, `leaf2a`=3, `leaf2b`=4, `borderleaf1`=5, `borderleaf2`=6 --
  unique across every l3leaf, not just within a node_group.
- Pools: spine loopback `10.255.0.0/24`; l3leaf loopback `10.255.2.0/24`;
  VTEP `10.255.3.0/24`; uplink p2p `10.254.0.0/24`.
- `startup-delay` staggers container boot by role (spine 0s, leaf 20s,
  borderleaf 40s, hosts/firewall 60s) -- eight cEOS nodes on the VM's 10
  vCPU contend for CPU on cold boot; see `docs/troubleshooting.md` for the
  observed real-world timing this is meant to absorb.

## Tenants

Both VRFs present on every leaf pair (no `filter.tenants`) -- deliberate, so
the fabric has both a pure-EVPN cross-rack path (same VRF) and an
inter-VRF-via-firewall path to exercise.

| Tenant | VRF | L3 VNI | VLAN / L2 VNI | Anycast GW | Hosts |
|---|---|---|---|---|---|
| Tenant_Red (mac base 10000) | VRF_RED | 10 | 110 / 10110 | 10.10.110.1/24 | h1-red .101, h2-red .102 |
| Tenant_Blue (mac base 20000) | VRF_BLUE | 20 | 120 / 20120 | 10.20.120.1/24 | h1-blue .101, h2-blue .102 |

L2 VNI = `mac_vrf_vni_base + vlan_id` (AVD's default scheme) -- 10000+110,
20000+120. This bit an early draft of `tests/anta_catalog.yml`; see
`docs/troubleshooting.md`.

## Firewall handoff

Routed, one link per borderleaf, one dot1q subinterface per VRF (tags 3110 /
3120, deliberately not the tenant VLAN ids, so a transit tag can never be
confused with a tenant L2 domain):

| VRF | borderleaf1 | fw1 | borderleaf2 | fw1 |
|---|---|---|---|---|
| RED  | 10.255.10.0/31 | 10.255.10.1/31 | 10.255.10.2/31 | 10.255.10.3/31 |
| BLUE | 10.255.20.0/31 | 10.255.20.1/31 | 10.255.20.2/31 | 10.255.20.3/31 |

`fw1` has no VRFs of its own -- both tenants' routes land in one FRR table,
and `nftables` decides what may cross (ICMP only). See `docs/decisions.md`
for why `fw1` advertises only `0.0.0.0/0` back into the fabric.

### Borderleaf-only policy (`group_vars/BORDERLEAFS.yml`)

Everything below exists specifically because the borderleaves are the
devices in the fabric peering with something eos_designs doesn't itself
model (`fw1`, a plain external eBGP speaker) -- see that file's own header
for the fuller case for why this content has its own group_vars file rather
than living in `FABRIC/network_services.yml` alongside the peer IPs. Applied
identically to both borderleaves' fw1 sessions. All four objects are
live-verified, not just rendered -- see `docs/verification.md`.

| Object | Kind | Applied via | What it does |
|---|---|---|---|
| `RM-FW-IN` | route-map | `bgp_peers[].route_map_in` | Tags routes learned from fw1 with community `65103:100` and local-preference `80` (vs `100` on native EVPN routes) |
| `RM-FW-OUT` | route-map | `bgp_peers[].route_map_out` | Only advertises routes the fabric itself originates (matches `ASPATH-LOCAL-ONLY`) |
| `ASPATH-LOCAL-ONLY` | AS-path access-list | `RM-FW-OUT`'s `match` | `permit ^$` -- empty AS-path only, meaningful as an outbound-only filter (see the file's own comment for why inbound would reject everything) |
| `ACL-FW-TRANSIT-IN` | IPv4 ACL | *(not currently referenced)* | Defined but unwired -- `eos_config replace:config`'s command ordering breaks an interface referencing an ACL defined later in the same file; see `docs/troubleshooting.md` |

`bgp_peers[].maximum_routes: 100` / `maximum_routes_warning_only: true` are
also set on both fw1 sessions (defined alongside the peer IPs in
`network_services.yml`, since they're peer-level fields, not standalone
objects) -- edge hardening with no equivalent elsewhere in this fabric,
since a leaf's only peers are its own AVD-managed spines.

## Variable layering

```
inventory/site_registry.yml                  SoT: nodes, cabling, hosts, firewall
        |
        | playbooks/render_lab.yml (generate + validate)
        v
containerlab/topology.clab.yml               GENERATED
inventory/inventory.yml                      GENERATED
inventory/group_vars/SPINES.yml                      hand-authored, VALIDATED against registry
inventory/group_vars/L3LEAFS.yml                          "
inventory/group_vars/BORDERLEAFS.yml                      "  (fw1-handoff-only objects)
inventory/group_vars/FABRIC/connection.yml                "  (Ansible connection vars)
inventory/group_vars/FABRIC/fabric_variables.yml           "
inventory/group_vars/FABRIC/network_services.yml           "
        |
        | playbooks/build.yml (arista.avd.eos_designs + eos_cli_config_gen)
        v
inventory/intended/structured_configs/*.yml  GENERATED, committed
inventory/intended/configs/*.cfg             GENERATED, committed
        |
        | playbooks/deploy_confirm.yml
        v
        live fabric
```

`group_vars/` placement rule: files scoped to eos_designs' fabric-wide
group live under `FABRIC/` (connection.yml, fabric_variables.yml,
network_services.yml); files scoped to AVD-native device-type groups
(SPINES, L3LEAFS) or a real-but-AVD-invisible Ansible child group
(BORDERLEAFS) are flat at the group_vars/ top level, one file per group,
named after the group.

`playbooks/render_lab.yml --check --diff` is the CI drift gate for the first
half of this chain (registry vs. generated files vs. hand-authored
group_vars). `.gitlab-ci.yml`'s `render-and-diff` job covers the second half
-- it fails if re-running `build.yml` changes anything under
`inventory/intended/`, meaning the committed render is stale relative to
`group_vars`.

## Known gaps

- `.gitlab-ci.yml`'s `precheck` stage brings the lab up inline
  (`containerlab deploy`) if it is not already running. A cold multi-node
  deploy inline in a routine push's precheck is exactly the boot-CPU-
  contention scenario `docs/troubleshooting.md` describes for the sibling
  `home/avd` repo. Worth splitting into an explicit manual "ensure lab is up"
  job if this pipeline sees enough real use for the difference to matter.
- The exact `show` command for inspecting EVPN DF election on this cEOS
  build was not found -- see `docs/troubleshooting.md`.
- No host or firewall HA beyond the ESI/BGP redundancy already described --
  e.g. `fw1` itself is a single container with no active/standby pair. Not
  in scope for this build.
