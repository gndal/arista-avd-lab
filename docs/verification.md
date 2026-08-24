# Verification

What was actually checked, when, and how -- not just "it should work." All
commands run against the live fabric on the containerlab VM
(`192.168.1.132`), lab name `esidc`. Dates below are the day this repo was
first built and verified end to end.

## 2026-08-24: full cold-start rebuild, twice

The fabric was destroyed and redeployed from scratch **twice** during this
build -- once mid-build after fixing the host container template (to prove
the fix worked from a clean boot, not just as a live patch on already-running
containers), and the render/build/push/validate/dataplane sequence below is
from the **second, fully independent run**, with no manual intervention
between `containerlab destroy` and the final dataplane pass.

```
containerlab destroy -t containerlab/topology.clab.yml --cleanup
containerlab deploy  -t containerlab/topology.clab.yml
ansible-playbook -i inventory/inventory.yml playbooks/build.yml
ansible-playbook -i inventory/inventory.yml playbooks/deploy_confirm.yml
ansible-playbook -i inventory/inventory.yml playbooks/validate.yml
ansible-playbook playbooks/verify_dataplane.yml
```

Result: all 13 containers running, all 8 EOS devices confirmed the push,
62/62 ANTA tests passed, all 4 dataplane checks passed. `build.yml` reported
`changed=0` on every host on this second run -- the rendered config was
byte-identical to what the first run had already produced and what is
committed in `inventory/intended/`, confirming the render is deterministic
across a cold rebuild.

## Underlay / overlay

`leaf1a`, `show bgp summary` (eAPI, `https://172.40.40.21/command-api`):
both spine sessions Established in `ipv4 unicast` (underlay, real NLRIs
exchanged: 9 received / 7 advertised) and `l2VpnEvpn` (overlay, 45 NLRIs
received). Same pattern confirmed on all 8 devices via the ANTA
`VerifyBGPPeersHealth` test (`tests/anta_catalog.yml`), which passed for
every device across both address families.

## ESI multihoming

- `leaf1a` and `leaf1b`'s rendered configs for `Port-Channel3` (h1-red) carry
  the **identical** `evpn ethernet-segment identifier` and `lacp system-id`
  -- confirmed by directly diffing the relevant block of both devices'
  `inventory/intended/configs/*.cfg`. This identical value on two physically
  separate switches is what lets a host present them as one LACP partner.
- `h1-blue`'s bond (`docker exec clab-esidc-h1-blue cat
  /proc/net/bonding/bond0`): both `eth1` and `eth2` report the same
  `Aggregator ID`, `Number of ports: 2`, and a `Partner Mac Address` matching
  the shared `lacp system-id` from the config above -- a real single LACP
  bundle spanning two switches, not two independent links.
- `show port-channel` on every leaf: both `Port-Channel3` and
  `Port-Channel4` report their expected member (`Ethernet3` / `Ethernet4`)
  active. Covered continuously by ANTA's `VerifyPortChannels` and
  `VerifyLACPInterfacesStatus`.

## Firewall handoff

- `borderleaf1`/`borderleaf2`, `show bgp summary vrf VRF_RED` /
  `vrf VRF_BLUE`: both borderleaves' sessions to `fw1` Established, in both
  VRFs -- 4 sessions total. Covered continuously by ANTA's
  `VerifyBGPPeersHealth` (vrf-scoped, borderleaf-tagged entry) and
  `VerifyReachability` (the /31s).
- `fw1`, `vtysh -c "show ip route bgp"`: both tenant subnets
  (`10.10.110.0/24`, `10.20.120.0/24`) present with **two** BGP paths each
  (one via each borderleaf, equal weight) -- real dual-homed redundancy for
  the firewall path, not just a single working link.
- `leaf1a`, `show ip route vrf VRF_RED 0.0.0.0/0`: the default route from
  `fw1` resolves via VXLAN with **two** `vias`, one to each borderleaf's VTEP
  (`10.255.3.5`, `10.255.3.6`) -- the default route genuinely made it all
  the way from `fw1`, through both borderleaves, across EVPN, to a leaf with
  no direct connection to the firewall at all.

## Dataplane (`playbooks/verify_dataplane.yml`)

All four checks passed, both on the first build and on the independent
cold-rebuild described above:

1. `h1-red` -> `h2-red` ping (cross-rack, same VRF, pure EVPN-VXLAN, no
   firewall in the path): 4/4 received.
2. `h1-red` -> `h1-blue` ping (cross-VRF, via `fw1`): 4/4 received.
3. `h1-red` -> `h1-blue` TCP/8080: connection refused/dropped (`nc` returns
   non-zero) -- the negative case, proving `fw1`'s nftables ruleset is
   actually enforcing policy, not merely present in the path.
4. `h1-red` -> `h2-red` TCP/8080 (same-VRF control): connection succeeds --
   proves the busybox-extras `httpd` listener genuinely works, so test 3's
   failure is attributable to the firewall, not a dead server on the target.

## ANTA (`playbooks/validate.yml`, `tests/anta_catalog.yml`)

62/62 tests passed on the independent cold-rebuild run listed above (13 test
definitions x varying device counts per `filters.tags` scope). Getting there
required several real fixes to the catalog itself, not just the fabric --
see `docs/troubleshooting.md` for the full story on each:

- `VerifyLACPInterfacesStatus`'s `name`/`portchannel` fields were backwards.
- `VerifyVxlanVniBinding`'s L2 VNI entries need a VLAN id (int), not a VRF
  name (str) -- and the VNI number itself was wrong in an earlier draft
  (`10120` instead of the correct `20120`).
- `VerifyEVPNType2Route` had to be scoped to spines only, and a small
  ARP-warming ping added, once EVPN's ES-peer route-import suppression
  (`docs/troubleshooting.md`) and ordinary MAC-table aging were both
  understood as real, separate causes of the same symptom.
- A leaf-to-locally-attached-host `VerifyReachability` test was tried and
  then deliberately dropped, for the same ES-peer reason -- see
  `docs/decisions.md`.

## GitLab CI, run for real (2026-08-24)

MR !1 (the initial build) and its pipeline both went green: `lint` ->
`drift` -> `render-and-diff` on the MR, and (see below) `lint` -> `precheck`
-> `push` -> `postcheck` on `main` after merging. The config diff was
correctly posted as an MR note.

**Bootstrap gotcha, worth remembering:** this project started completely
empty, so its `default_branch` was whatever branch got pushed first
(`build/initial-scaffold`, not `main`) until fixed via the API
(`PUT /projects/:id` with `default_branch=main`). Before that fix, a plain
`git push` to the feature branch satisfied `.gitlab-ci.yml`'s
`$CI_COMMIT_BRANCH == $CI_DEFAULT_BRANCH` rule and ran the full
precheck/push/postcheck sequence against the live fabric straight off a
feature-branch push -- pipeline 58, which happened to succeed since it
carried the same tested content that was headed for `main` anyway, but that
was luck, not the intended gate. Check a fresh project's actual
`default_branch` before assuming an empty-repo push landed where expected.

**Automatic rollback (removed).** An earlier version of this pipeline had a
`rollback` stage (`playbooks/rollback.yml` + a `last-good-deploy` git tag)
that auto-reverted the fabric on a postcheck failure. It was built and
proven live with a real deliberate break (MR !2: a bad `ip_address_virtual`
broke postcheck, rollback restored the fabric, confirmed on-device), then
removed by request -- too much complexity for the value. No automatic
rollback now; a postcheck failure just fails the pipeline.

## Borderleaf config split + fw1 single-homing (2026-08-24)

Two changes landed together in this session, both requiring a full
`containerlab destroy`/`deploy` (the fw1 single-homing change removes a
physical link, not just device config -- containerlab's own topology has to
be rebuilt, `eos_config` alone cannot "unplug" a veth pair).

**`group_vars/BORDERLEAFS.yml` split (the route-map/ACL/AS-path objects):**
confirmed the group-based scoping actually works BEFORE ever rendering a
device config, via `ansible-inventory -i inventory/inventory.yml --host
borderleaf1` vs `--host leaf1a`: `borderleaf1` resolves
`custom_structured_configuration_route_maps` and `ipv4_acls`, `leaf1a` has
neither. After rendering, grepped both `.cfg` files to confirm the objects
appear only where expected.

- `RM-FW-IN`'s effect is real, not just present in config: `show ip bgp vrf
  VRF_RED` on `borderleaf1` shows the default route learned from fw1 at
  `LocPref 80`, vs `100` on the fabric's own EVPN routes.
- `RM-FW-OUT` + `ASPATH-LOCAL-ONLY` (`permit ^$`, matching only routes with
  an empty AS-path) were the riskiest addition in this session -- getting
  the semantics wrong could have silently blackholed the tenant subnet
  routes fw1 needs for inter-VRF routing to work at all. Pushed via
  `deploy_confirm.yml`'s self-reverting commit-confirm specifically so a
  wrong guess would undo itself, then checked `show ip route bgp` on `fw1`
  immediately after convergence: both tenant subnets (`10.10.110.0/24`,
  `10.20.120.0/24`) and both VTEP diagnostic loopbacks were still present.
  The empty-AS-path assumption (these routes are effectively originated
  fresh into the VRF's own IPv4-unicast BGP process when leaked from EVPN,
  not carrying forward their EVPN-side AS-path) held.
- `ACL-FW-TRANSIT-IN` was found to fail the push outright the first time it
  was wired to an interface -- see docs/troubleshooting.md's ordering entry.
  It stayed defined-but-unreferenced after that; not re-attempted here.

**fw1 single-homing:** after the redeploy + push, confirmed exactly one
link in the generated topology (`grep fw1
containerlab/topology.clab.yml` -- one node block, one `links:` entry, one
`eth1.<vlan>` pair in fw1's own `exec:`), and exactly one BGP session per
VRF on `fw1` itself (`show ip route bgp` inside the `fw1` container shows a
single via-path per tenant subnet, not the pre-change ECMP pair).

**Full re-verification after both changes, on the rebuilt fabric:** 59/59
ANTA tests (down from 62 -- three fewer devices' worth of firewall-adjacent
tests now that only `borderleaf1` carries the `fw-uplink` tag, not both
borderleaves; see `tests/anta_catalog.yml`'s header for the tag mechanism),
all 4 `verify_dataplane.yml` checks including the negative TCP-blocked
case.

## Not yet exercised

- The exact `show` command for inspecting EVPN DF election directly was not
  found (see `docs/troubleshooting.md`) -- DF election was inferred
  indirectly (port-channel member status + working dataplane traffic across
  both members of both ESI pairs), not observed directly.
- No test has yet exercised a link failure (shutting one ESI member port and
  confirming the pair's other member keeps traffic flowing) or the
  precheck stage's cold-lab-bringup path (it has only ever run against an
  already-deployed lab so far).
