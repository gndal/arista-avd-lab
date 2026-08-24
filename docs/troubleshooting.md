# Troubleshooting / gotchas

Real bugs hit building this repo, in the order they were found, with the fix
and why it wasn't obvious. All confirmed live against the actual containerlab
fabric -- see `docs/verification.md` for the specific commands and output.

## Jinja2 `loop.parent` is not a real attribute

`templates/topology.clab.yml.j2`'s firewall `exec:` block nests a loop over
subinterfaces inside a loop over uplinks, and needed the outer loop's index
inside the inner loop. The first attempt used `loop.parent.index` --
Jinja2's `LoopContext` has no `parent` attribute at all (not `.parent`, not
`.parent.loop` either -- both were tried and both failed the same way:
`object of type 'LoopContext' has no attribute 'parent'`). Ansible's
`ansible.builtin.template` reports this as a task failure with the Jinja2
traceback, not a rendering warning -- easy to mistake for a data problem
rather than a template syntax one.

**Fix:** capture the outer index in a `{% set %}` variable before entering
the inner loop (`{% set eth_idx = loop.index %}`), then reference that
variable instead of trying to reach through `loop` at all. `{% set %}`
inside a `{% for %}` body is visible to nested loops within that same
iteration, which is the mechanism that actually works here.

## Alpine's `busybox` binary does not have an `httpd` applet -- `busybox-extras` does

The test hosts need a persistent TCP listener for
`playbooks/verify_dataplane.yml`'s TCP-blocked-vs-allowed check.
`busybox httpd -p 8080 -h /tmp` seemed like the obvious zero-dependency
choice on `alpine:3.20` -- it fails with `httpd: applet not found`. Alpine
splits `httpd` (and several other applets) into a **separate package**,
`busybox-extras`, which installs its own binary (`/bin/busybox-extras`) and
symlinks `/usr/sbin/httpd` to it. `busybox httpd` still fails even after
installing `busybox-extras` -- the applet lives in the other binary, not the
main one. The correct invocation is plain `httpd` (via the symlink), not
`busybox httpd`.

**Compounding gotcha:** the container's `exec:` sequence replaces its default
route with the tenant gateway (`ip route replace default via ... dev bond0`)
partway through, for hosts to correctly route application traffic through
`fw1`. Any `apk add` issued *after* that point has no path to the package
mirror at all and hangs/fails -- this is why `apk add --no-cache iproute2
busybox-extras` has to be the very first exec command, before the route
replace, not added as an afterthought later in the sequence. Confirmed live:
`apk update` from a container whose default route already points at the
tenant gateway returns `temporary error` against `dl-cdn.alpinelinux.org`,
even though the exact same command succeeded earlier in the same container's
life, before the route was replaced.

**Fix (live-only, no redeploy):** temporarily add two more-specific routes
(`0.0.0.0/1` and `128.0.0.0/1` via the mgmt gateway) that outrank the
existing `0.0.0.0/0` tenant default without removing it, install the
package, then delete the two temp routes. Used once to unblock the four
already-running containers during this session; not needed for a normal
redeploy since the template fix (below) makes it correct from boot.

**Fix (template, permanent):** `templates/topology.clab.yml.j2`'s host
`exec:` block installs `busybox-extras` alongside `iproute2` in the same
first command, and invokes plain `httpd`. Verified live with a full
`containerlab destroy` + `deploy` cycle (not just a manual per-container
patch) -- `httpd` is running on all four hosts immediately after boot with no
intervention.

## YAML does not merge duplicate top-level keys

An early draft of `tests/anta_catalog.yml` split one ANTA module's tests
across two separate `anta.tests.interfaces:` blocks for readability, with a
comment claiming "ANTA merges same-module keys." That is wrong -- plain YAML
parsing keeps only the **last** occurrence of a duplicate mapping key and
silently drops everything under the earlier one(s). Caught by parsing the
file with `yaml.safe_load` and counting entries per key before ever running
it against a device -- `anta.tests.interfaces` had 2 entries where 6 were
written, and `anta.tests.routing.bgp` had 1 where 3 were written.

**Fix:** one key per ANTA module, all of that module's test entries appended
to the same list. The catalog's own header comment now says so explicitly,
specifically to stop this from being reintroduced.

## `VerifyLACPInterfacesStatus`'s `name` is the member interface, not the port-channel

First attempt set `name: Port-Channel3, portchannel: Port-Channel3` --
looked reasonable, failed with `Not configured` on every leaf. ANTA's
`InterfaceState` input model uses `name` for the **physical member
interface** being checked and `portchannel` for the bundle it must belong
to; passing the port-channel's own name as `name` asks ANTA to verify that
`Port-Channel3` is itself a member of a port-channel called `Port-Channel3`,
which is never true.

**Fix:** `name: Ethernet3, portchannel: Port-Channel3` (and Ethernet4 /
Port-Channel4). Confirmed by reading `anta.input_models.interfaces.
InterfaceState`'s docstring directly on the containerlab VM's venv rather
than guessing a second time.

## `VerifyVxlanVniBinding`'s value type selects VLAN-binding vs VRF-binding, not just "which VNI"

`bindings: {10110: VRF_RED, 20120: VRF_BLUE, 10: VRF_RED, 20: VRF_BLUE}`
failed with "Binding not found" for the two L2 VNIs even though
`show vxlan vlan 120` on the device plainly showed `vni 20120` configured.
Reading `anta.tests.vxlan.VerifyVxlanVniBinding`'s source directly: the
dict **value's Python type** decides which EOS field ANTA checks -- an
`int` value is compared against `vniBindings.<vni>.vlan` (an L2 VNI's VLAN
binding), a `str` value against `vniBindingsToVrf.<vni>.vrfName` (an L3
VNI's VRF binding). Giving a VRF name for an L2 VNI does not fail loudly as
"wrong kind of check" -- it fails as "binding not found," because ANTA looked
in `vniBindingsToVrf` for a VNI that only exists in `vniBindings`.

**Fix:** `10110: 110, 20120: 120` (VLAN IDs, ints) for the L2 VNIs;
`10: VRF_RED, 20: VRF_BLUE` (VRF names, strings) for the L3 VNIs unchanged.
Also worth remembering while reading this: AVD's L2 VNI numbering here is
`mac_vrf_vni_base + vlan_id` (10000+110=10110, 20000+120=20120) -- an
earlier draft had `10120` (wrong tenant's base, right VLAN id) before this
was checked against the actual rendered config.

## EVPN "local bias" genuinely does not sync Type-2 routes between a host's own two ES-peers

The most interesting finding of this build, and initially looked like a
broken fabric rather than correct behavior.

**Symptom:** `leaf1a` (h1-blue's own directly-attached ES-peer switch) could
not ping h1-blue from its own SVI -- 100% loss, `show ip arp vrf VRF_BLUE`
showed no entry for it at all. `leaf1b` (the *other* ES-peer, also directly
attached to the exact same host) pinged it fine, 0% loss, with a normal
local ARP entry. Symmetric problem the other direction too: `leaf1b` could
not see h1-red's EVPN Type-2 route (`show bgp evpn route-type mac-ip
10.10.110.101` returned nothing), while `leaf1a` (h1-red's other ES-peer)
had it as a locally-originated route.

**Root cause, confirmed by checking BGP tables directly rather than
guessing:** `leaf1b` genuinely originates and holds a local Type-2 route for
h1-blue (`show bgp evpn route-type mac-ip 10.20.120.101` on leaf1b: one
route, RD `10.255.2.2:20120`). The identical query on `leaf1a` returns
**nothing** -- not filtered, not stale, simply never received. EVPN's
"local bias" procedure is usually understood as a data-plane rule (don't
re-flood BUM traffic received from an ES-attached CE back to that CE's other
ES-peer, since the peer already has its own local copy). What was not
obvious going in: on this cEOS build, the same principle extends to
**control-plane Type-2 route import** -- an ES-peer does not import a
Type-2 route for a host on its *own* shared Ethernet Segment from the other
peer, on the assumption both peers will independently learn that host
locally. That assumption holds under symmetric traffic distribution; it
does **not** hold when the host's own LACP transmit-hash consistently
favors one specific link for a given flow (which Linux bonding's `layer2`
hash mode will do -- it is deterministic per source/destination MAC pair,
not per-packet round robin).

**This is not a fault.** Real host-to-host dataplane traffic was completely
unaffected -- `playbooks/verify_dataplane.yml`'s four tests (including
cross-rack, cross-VRF-via-firewall, and the negative TCP-blocked case) all
passed throughout, both before and after this was understood, because
end-to-end forwarding never depended on a specific switch's own control
plane resolving ARP for a host it happens not to be the "chosen" ES-peer
for on that particular flow.

**Consequence for this repo's ANTA catalog:** a `VerifyReachability` test
that pings a locally-ES-attached host from a leaf's own SVI is fundamentally
unreliable for exactly this reason -- it can correctly fail depending on
which ES member the host's hashing favors, which is not something this repo
controls or should try to. `tests/anta_catalog.yml` does not attempt that
test at all; real host reachability is covered by
`playbooks/verify_dataplane.yml` instead, which sources traffic from the
hosts themselves. `VerifyEVPNType2Route` is scoped to spines only (see
`docs/decisions.md`) -- the spines have no ES relationship to anything and
import every Type-2 route normally, so they are the one place in the fabric
this specific check is unambiguous.

**A second, unrelated cause of the same symptom worth knowing about:** even
on a spine, `VerifyEVPNType2Route` can fail simply because the underlying
MAC-address-table entry aged out from lack of recent traffic -- EOS
withdraws the Type-2 route when the local dynamic MAC entry it was built
from times out. `playbooks/validate.yml` sends one small ping from `leaf1a`
(h1-red's *originating* leaf, chosen specifically because it is not the
ES-peer affected by the bug above) immediately before the ANTA run, purely
to keep that one entry fresh. This is about MAC aging, unrelated to local
bias -- don't confuse the two if this test starts failing again; check
`show ip arp vrf VRF_RED` for "not learned" (aged out) versus checking
whether the querying device is genuinely an ES-peer of the host in question
(local bias).

## `eos_config replace:config` applies config as an order-sensitive command sequence -- an interface can't reference an ACL rendered later in the same file

Hit adding a mock `ipv4_acl_in` to a borderleaf's fw1-facing subinterface
(`tests/anta_catalog.yml`'s sibling change, `group_vars/BORDERLEAFS.yml`).
The push failed on both borderleaves: `CLI command 46 of 181 '   ip
access-group ACL-FW-TRANSIT-IN in' failed: invalid command`. commit-confirm
caught it cleanly -- both devices self-reverted on their 5-minute timer,
confirmed by re-checking `show running-config interfaces Ethernet3.3110`
afterward and finding the ACL reference genuinely gone, not just believed
gone from a job log.

**Root cause, confirmed by reading the installed `arista.eos` collection's
source, not guessed:** `eos_cli_config_gen` always renders `interface`
blocks before `ip access-list` blocks (checked directly -- true across the
whole file, not an artifact of this specific YAML). `eos_config`'s
`replace: config` mode (`arista.eos.eos.py`'s httpapi plugin, and the
module's own docstring) applies the *entire* candidate as one ordered
sequence of CLI commands inside `configure session ... ; rollback
clean-config ; <every candidate line in file order> ; commit`.
`rollback clean-config` rebuilds the session's view of config from nothing
using *only* that sequence -- so an interface's `ip access-group X in`
always gets evaluated before `X`'s own definition, regardless of whether `X`
already exists in the device's real running-config from an earlier push.
Re-pushing repeatedly, or trying to "pre-create the object first," does not
help: it is not a device-state problem, it is a per-push ordering problem
inherent to how this specific push mechanism works, and nothing in the
source YAML controls eos_cli_config_gen's internal section order.

**Not every forward reference has this problem** -- `bgp_peers[].
route_map_in` (a route-map referenced from a BGP neighbor statement) pushed
and worked correctly in the same file, with the route-map's own definition
rendering earlier than its reference anyway by coincidence of section order,
and this repo already had a working, pre-existing precedent for it
(`RM-CONN-2-BGP`, AVD's own `redistribute connected route-map`). EOS
appears to validate an interface's ACL reference more strictly/immediately
than a BGP neighbor's route-map reference. Confirmed live afterward: the
route-map's effect is real, not just present in config -- the default route
learned from fw1 shows `LocPref 80` (the route-map's `set local-preference
80`) versus `100` on the fabric's own EVPN-native routes, in `show ip bgp
vrf VRF_RED`.

**Consequence:** don't apply a *newly introduced* `ipv4_acl_in`/
`ipv4_acl_out` to an interface in the same push that defines the ACL, via
this repo's push mechanism, without first confirming the specific ordering
is safe. `group_vars/BORDERLEAFS.yml`'s `ipv4_acls: ACL-FW-TRANSIT-IN` entry
is kept defined (documented, ready to reference) but deliberately not
referenced from any `l3_interfaces` entry -- see that file's own header for
the full account. A real fix, if this is ever needed for real, would mean
either an `eos_cli_config_gen` template override to change section
rendering order, or applying the ACL via a separate incremental (non-`replace:
config`) push after the interface already exists -- not attempted here.

## Pushing a stale render after a group_vars fix looks exactly like CPU contention

Hit reintroducing fw1's second borderleaf uplink (see docs/decisions.md's
"fw1 is dual-homed" entry). Renaming `group_vars/all.yml` to a same-named
sibling of the existing `group_vars/FABRIC/` directory
(`group_vars/FABRIC.yml`) silently broke variable resolution -- Ansible does
not merge a `<group>.yml` file and a `<group>/` directory for the same
group, it drops one of them, in this case the file. Confirmed via
`ansible-inventory --host spine1`: `ansible_password` resolved to nothing.

Fixed by moving the content into the existing directory
(`group_vars/FABRIC/connection.yml`) instead of a same-named sibling file.
Confirmed the fix worked for Ansible's own connection variables -- but
`playbooks/build.yml` (the render) had already been run once *before* that
fix, using the broken variable resolution. The render it produced was
missing `management api http-commands` and `aaa_settings` entirely, since
those come from the same file, but it was never re-run after the fix.

Every push after that used the stale render, and **every single one failed
identically**: `deploy_confirm.yml`'s post-apply reachability check timed
out for all 8 devices, the commit was never confirmed, and the device
self-reverted on its 5-minute timer -- exactly deploy_confirm.yml's intended
behavior for "a push that cuts its own management access," working
correctly the whole time. It was misdiagnosed as CPU contention for five
consecutive attempts (host load average was genuinely elevated at the time,
which fit that theory well enough to be actively misleading) -- switching
from parallel to serialized (`--forks 1`) pushes and waiting progressively
longer between attempts both failed to help, because neither addressed the
real cause. The actual signal that broke the misdiagnosis: SSH access to
the devices kept working throughout, which a genuine CPU-contention/
convergence-delay theory does not explain, but "eAPI was never enabled by
the push" does immediately.

**How it was actually found:** grepping the rendered `.cfg` file directly
for `management api http-commands` -- zero matches. Re-running
`playbooks/build.yml` after the group_vars fix (not just trusting that the
fix was in place) produced a render that included it, and the very next
push confirmed cleanly on the first try.

**Lesson:** after any group_vars structural change, re-run `playbooks/
build.yml` and grep the regenerated `.cfg` for the specific settings that
change touched, before assuming a fix that resolved one symptom (Ansible's
own connection vars, checkable via `ansible-inventory`) also fixed the
render (a completely separate consumer of the same variables, only
checkable by regenerating and reading the actual output).

## `show bgp evpn ethernet-segment` is not a valid command on this cEOS build

Tried while investigating the above, as a way to directly inspect DF
election. `show bgp evpn ethernet-segment`, `show evpn ethernet-segment`,
and `show ethernet-segment` were all tried via eAPI and via an interactive
`docker exec ... Cli` session -- all rejected as invalid input on cEOS 4.36.
Not resolved; `show port-channel` (confirms both ESI port-channels have
their expected member bundled) and the BGP EVPN route-type queries above
were sufficient for this build's verification needs, so the exact working
DF-election show command was not tracked down. Worth revisiting if a future
change needs to inspect DF election specifically.
