# Design decisions

ADR-style record of the choices made building this repo, and why. Read this
before changing any of them.

## ESI multihoming instead of MLAG

Every host and the border pair are dual-homed via EVPN ESI multihoming
(all-active), not MLAG. `l3leaf.defaults.mlag: false` is set explicitly --
AVD treats any 2-node l3leaf node_group as an MLAG pair by default and then
demands `mlag_interfaces` (a peer-link), so this has to be turned off, not
just left unset.

**Why:** the user explicitly asked for ESI multihoming over MLAG for this
build. The practical payoff shows up in the topology: there is no MLAG
peer-link anywhere in `inventory/site_registry.yml` or
`containerlab/topology.clab.yml` -- one less cabled link per pair, and no
peer-link BGP/ISL config to get wrong. AVD generates the ESI identifier and
LACP system-id from `ethernet_segment.short_esi: auto`; both ends of a pair
render identical values (confirmed live -- see `docs/verification.md`), which
is what lets a host's LACP bond present two independent switches as one
logical partner.

## Routed firewall handoff, not an ESI-LAG to fw1

`fw1` connects to `borderleaf1` over one plain routed link with a dot1q
subinterface per VRF (tags 3110/3120), not a bonded ESI-LAG.

**Why:** offered as a choice, and this one was picked over bonding fw1 as a
third ES member. A routed handoff gives ANTA and `verify_dataplane.yml` real,
independently-addressable BGP sessions and interfaces to check per VRF --
two sessions, each individually verifiable. An ESI-LAG would collapse that
into one bundle and hide the interesting failure modes (e.g. one VRF's
session flapping while the other stays up).

## fw1 is single-homed to one borderleaf, not dual-homed to both

An earlier version of this design connected `fw1` to *both* borderleaves --
two physical links, two subinterfaces per VRF, four BGP sessions total
(one per VRF per borderleaf), with `bgp bestpath as-path multipath-relax`
on fw1's own FRR config to ECMP across the two paths per tenant. This was
simplified to a single link/two sessions after review.

**Why:** `fw1` is one non-redundant Linux container -- it has no
active/standby pair of its own (see the "Known gaps" note in
`docs/LLD.md`). Dual-homing it to both borderleaves protects against
*borderleaf* failure, but does nothing for the actual single point of
failure in this path: lose `fw1` itself and inter-VRF routing is down
regardless of how many borderleaf links it has. The second link bought
BGP-session-pair complexity (a second neighbor per VRF, `multipath-relax`,
double the `route_map_in`/`route_map_out`/ACL wiring to keep consistent
across two devices) for redundancy that didn't actually exist. If `fw1` is
ever made genuinely redundant (an active/standby or active/active pair of
firewall devices), dual-homing becomes worth reintroducing --
`inventory/site_registry.yml`'s `firewall.uplinks` is deliberately still a
list (of length one today) and `containerlab/topology.clab.yml.j2`/
`network_services.yml` are both written generically over that list rather
than assuming exactly one entry, specifically so that change would be
additive rather than a rewrite.

## fw1 advertises the default route only

`containerlab/frr-firewall/frr.conf` has an explicit `ip prefix-list
DEFAULT_ONLY` + outbound route-map on every BGP neighbor, on top of
`default-originate`.

**Why:** fw1 learns both tenants' prefixes (it has to, in order to route
between them) but must not re-advertise them. If it did, a VRF_BLUE prefix
would arrive back at a borderleaf inside VRF_RED carrying AS-path
"65500 65103" -- the fabric's own ASN -- and get dropped as an AS-path loop.
Sending only 0.0.0.0/0 avoids this entirely and is sufficient: a host follows
its VRF's default to fw1, fw1 has a real route to the other subnet (learned
via BGP, not redistribute-connected -- see the ADR-adjacent note in
`inventory/group_vars/FABRIC/network_services.yml`), and the return traffic
follows the other VRF's own default back the same way. Both borderleaves
advertise the same prefixes with the same weight, so fw1 sees two equal-cost
paths per tenant subnet -- confirmed live via `vtysh -c "show ip route bgp"`
(see `docs/verification.md`), giving real dual-homed redundancy, not just a
theoretical second path.

## nftables permits ICMP only between the two tenant subnets

**Why:** a passing ping between VRF_RED and VRF_BLUE proves fw1 is in the
path, but says nothing about whether it is actually filtering anything.
Blocking TCP while permitting ICMP turns `playbooks/verify_dataplane.yml`
into a real positive-and-negative test: ping must pass, a TCP connection on
the exact same host pair must fail, and a same-VRF TCP control case (proving
the listener itself works) must pass. Three data points, not one, is what
makes the firewall's presence provable rather than assumed.

## site_registry.yml as the single source of truth, not NetBox

One YAML file (`inventory/site_registry.yml`) drives generated
`containerlab/topology.clab.yml` and `inventory/inventory.yml`, and is
validated (not generated) against the hand-authored AVD `group_vars`. No
NetBox integration.

**Why:** offered as a choice against NetBox-as-SoT (the pattern `home/avd`
eventually reached) and against fully hand-authored files (the pattern
`ceos-evpn-firewall-lab` used). The registry approach was picked as the
middle ground -- eliminates the specific failure mode of "mgmt IP defined in
three places, one of them wrong" without requiring a running NetBox instance
this lab doesn't otherwise need. `playbooks/render_lab.yml --check --diff` is
the CI drift gate; see that playbook's own header comment for why some files
are generated wholesale and others only validated.

## Commit-confirm (`deploy_confirm.yml`) is the default push path

Unlike the sibling `home/avd` and `home/arista-avd-dc-wan` repos (where
commit-confirm exists but plain `eos_config replace:config` is the everyday
path), **this repo's CI always pushes via `playbooks/deploy_confirm.yml`**.
`playbooks/deploy_lab.yml` (plain replace, no confirm) exists only for fast
manual iteration.

**Why:** `eos_config`'s `replace: config` mode opens, applies, and commits
its own session in one atomic module call -- there is no way to hold a commit
open for verification before it takes effect. A push that breaks the
management plane (moves the wrong VRF, changes the wrong ACL) has no
automatic undo; recovery is a full `containerlab destroy` + `deploy`.
`deploy_confirm.yml` instead opens a named config session, applies the
rendered config with `commit timer`, checks the device is still reachable,
and only then issues the confirming commit -- if the push cut its own
management access, the device reverts itself when the timer expires. Given
this repo's CI runs the push unattended (a merge to `main`, no human at a
console to notice a lockout), holding this safety net closed by default was
judged worth the extra ~10s per device it costs over the plain path. Verified
live on cEOS 4.36 in the sibling `arista-avd-dc-wan` repo before being reused
here unchanged.

## ANTA scoping around EVPN local-bias (see docs/troubleshooting.md)

`tests/anta_catalog.yml`'s `VerifyEVPNType2Route` is scoped to spines only,
and there is no leaf-to-locally-attached-host `VerifyReachability` test at
all -- both were live findings, not upfront design. See
`docs/troubleshooting.md` for the full story; recorded here because it drove
a real scoping decision: **real host reachability is proven by
`playbooks/verify_dataplane.yml` (traffic sourced from the hosts themselves),
not by switch-CPU-sourced ANTA pings to ES-multihomed anycast hosts**, which
can genuinely and correctly fail depending on which ES member the host's own
LACP hash happens to favor for a given flow.

## `group_vars/BORDERLEAFS.yml` as a separate group_vars file, not inline in `network_services.yml`

Route-maps, an AS-path access-list, and an ACL for the fw1 handoff live in
their own file, scoped to a real (but AVD-invisible) `BORDERLEAFS` Ansible
child group of `L3LEAFS` -- see `templates/inventory.yml.j2` for how that
group is generated and `group_vars/BORDERLEAFS.yml`'s own header for the
full case.

**Why:** two reasons, not just tidiness. First, scoping: `network_services.yml`
has a node-scoping mechanism for *peer-level fields* (`bgp_peers[].nodes`,
`l3_interfaces[].nodes`), but none for *definitions* -- a route-map or ACL
*object* placed in that file would render on every l3leaf-type node,
including the four plain leaves that have no fw1 peer to ever apply it to.
Second, boundary: every object in `BORDERLEAFS.yml` exists specifically
because `borderleaf1` is the one device in the fabric with a peer outside
AVD's own EVPN-VXLAN design (`fw1`) -- a leaf never needs a route-map or ACL
of its own, because eos_designs generates its entire underlay/overlay policy
itself. The split file is where genuinely edge-only config lives, not a
stylistic reorganization of what network_services.yml already had.

**Real limitation surfaced by building this out, not upfront design:**
`custom_structured_configuration_route_maps` (used for `RM-FW-IN`/
`RM-FW-OUT`, since route-maps have no eos_designs-native equivalent -- see
that file's header) has no per-device "only renders if referenced" behavior
the way eos_designs-native `ipv4_acls` does. Since both borderleaves are
still members of the `BORDERLEAFS` group (only the fw1 *uplink* moved to
being borderleaf1-only, not group membership), `RM-FW-IN`/`RM-FW-OUT` render
on `borderleaf2` too, unreferenced and inert. Confirmed harmless (an
unreferenced route-map does nothing), but worth knowing before assuming
"defined in BORDERLEAFS.yml" and "only exists on the device that actually
uses it" are the same guarantee -- they are not, for every object type.
