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

`fw1` connects to each borderleaf over a plain routed link with a dot1q
subinterface per VRF (tags 3110/3120), not a bonded ESI-LAG.

**Why:** offered as a choice, and this one was picked over bonding fw1 as a
third ES member. A routed handoff gives ANTA and `verify_dataplane.yml` real,
independently-addressable BGP sessions and interfaces to check per VRF per
borderleaf -- four sessions, each individually verifiable. An ESI-LAG would
collapse that into one bundle and hide the interesting failure modes (e.g.
one VRF's session flapping while the other stays up).

## fw1 is dual-homed to both borderleaves

`fw1` connects to both borderleaves -- two physical links, two
subinterfaces per VRF, four BGP sessions total (one per VRF per
borderleaf), with `bgp bestpath as-path multipath-relax` on fw1's own FRR
config to ECMP across the two paths per tenant.

**History, since it explains some of the surrounding design:** this was
briefly simplified to single-homed (one link, two sessions) on the
reasoning that `fw1` is one non-redundant Linux container with no
active/standby pair of its own, so a second borderleaf link protects
against *borderleaf* failure but does nothing for the actual single point
of failure in the path (`fw1` itself). That reasoning still holds as a
general point, but the topology was reverted back to dual-homed by
request. The reversal was a clean, small diff -- `inventory/site_
registry.yml`'s `firewall.uplinks` was deliberately kept as a list (of
length one during the single-homed period, written generically over
throughout `containerlab/topology.clab.yml.j2` and `network_services.yml`
rather than assuming exactly one entry) specifically so this exact change
would be additive, and it was.

**Real gotcha hit doing the reversal, worth remembering:** the push failed
five times in a row with every device unreachable post-apply, which looked
like CPU contention (all 8 devices doing a large `rollback clean-config`
replay at once) but was not -- see `docs/troubleshooting.md`'s "stale
render after a group_vars fix" entry for the actual cause and how it was
diagnosed.

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
because the borderleaves are the devices in the fabric with a peer outside
AVD's own EVPN-VXLAN design (`fw1`) -- a leaf never needs a route-map or ACL
of its own, because eos_designs generates its entire underlay/overlay policy
itself. The split file is where genuinely edge-only config lives, not a
stylistic reorganization of what network_services.yml already had.

**Real limitation surfaced while fw1 was briefly single-homed (see the fw1
dual-homed decision above), not upfront design, and now moot again since
both borderleaves have an fw1 peer:** `custom_structured_configuration_
route_maps` (used for `RM-FW-IN`/`RM-FW-OUT`, since route-maps have no
eos_designs-native equivalent -- see that file's header) has no per-device
"only renders if referenced" behavior the way eos_designs-native `ipv4_acls`
does. While only one borderleaf had the fw1 uplink, `RM-FW-IN`/`RM-FW-OUT`
still rendered on the other one too, unreferenced and inert (confirmed
harmless -- an unreferenced route-map does nothing) -- but it's worth
remembering that "defined in BORDERLEAFS.yml" and "only exists on the
device that actually uses it" are NOT the same guarantee, for every
object type.

## Local tooling: repo-local `.venv` via `uv`, not a devcontainer

Replaces `avd-venv`/`.lintvenv` with `uv venv .venv` + `uv pip sync
requirements.lock.txt` -- a lockfile (`requirements.lock.txt`, compiled by
`uv pip compile requirements.txt requirements-dev.txt`) resolving exact
versions on top of the existing floor-only `requirements.txt`. Galaxy
collections (`requirements.yml`) are still a separate `ansible-galaxy
collection install` step -- uv has no equivalent for those.

**Why not a devcontainer:** briefly built and live-tested (image built,
tools worked, `--network=host` gave it reachability to the lab's mgmt
network) but replaced almost immediately -- it added a Docker build/rebuild
cycle and a VS Code Remote-SSH dependency for a problem that a lockfile
already solves on its own: `requirements.txt` was already floor-only and
manually re-resolved by hand; `uv` gives the same reproducibility (exact
pins, one command to sync) without the container layer. `.devcontainer/`'s
one real bug -- `build.context` defaulting to the `.devcontainer/` folder
itself instead of the repo root, breaking the `COPY requirements.txt` step
under the actual Dev Containers CLI even though a manual `docker build`
test masked it -- is itself a small example of the kind of indirection a
container build adds that a plain venv doesn't have.

**Why repo-local, not the shared `~/avd-venv`:** portability -- a
VM-wide shared venv doesn't travel to a different Arista system with its
own inventory. `requirements.lock.txt` is committed, so `uv pip sync` on
any host reproduces the same exact environment. CI is intentionally left
on its own separately-maintained `~/avd-venv`/`.lintvenv` -- out of scope
here, same as it was for the devcontainer attempt.

Live-verified before adopting: `uv venv` (pulls its own pinned CPython
3.12, independent of system Python), `uv pip compile`, `uv pip sync`, a
real `ansible --version`/`yamllint`/`ansible-lint` run, eAPI reachability
(`405` on `/command-api`), and a full `yamllint`/`ansible-lint` pass
against the actual repo checkout -- all from inside the new `.venv`.
