# eos-avd-anta-dc

Arista AVD L3LS EVPN-VXLAN reference design on containerlab: 2 spines, 2 ESI
leaf pairs, 1 border pair, 4 dual-homed test hosts, and a Linux firewall doing
inter-VRF routing off the border pair. Deployed and validated through GitLab
CI, with ANTA as the health gate on both sides of every push.

**No MLAG anywhere.** Every host is attached with EVPN ESI multihoming
(all-active), not MLAG -- see [docs/decisions.md](docs/decisions.md) for why.

See [docs/LLD.md](docs/LLD.md) for the full topology, ASN/IP scheme, and
variable layering; [docs/decisions.md](docs/decisions.md) for the rationale
behind the design choices; [docs/troubleshooting.md](docs/troubleshooting.md)
and [docs/verification.md](docs/verification.md) for what was actually hit and
proven while building this.

## Layout

```
inventory/site_registry.yml     single source of truth: nodes, cabling, hosts, firewall
inventory/inventory.yml         GENERATED from the registry
inventory/group_vars/           AVD data model (fabric_variables.yml, network_services.yml)
inventory/intended/             committed render (configs + structured configs)
templates/                      Jinja2 templates the registry renders into
containerlab/topology.clab.yml  GENERATED from the registry
containerlab/frr-firewall/      the inter-VRF firewall: FRR + nftables in a Debian container
playbooks/render_lab.yml        generate + drift-gate the two generated files above
playbooks/build.yml             render AVD structured config + device config (no device access)
playbooks/deploy_confirm.yml    commit-confirm push (default push path -- see docs/decisions.md)
playbooks/deploy_lab.yml        one-shot push for manual iteration only, not used by CI
playbooks/validate.yml          run the ANTA catalog against the live fabric
playbooks/verify_dataplane.yml  docker-exec host-to-host proof, including the inter-VRF block
tests/anta_catalog.yml          the ANTA NRFU test catalog
```

## Running it

Everything below runs from the containerlab VM (`192.168.1.132`, user
`oser`), using the shared `~/avd-venv` (pyavd 6.3.0 + anta 1.9.0 already
installed there). This repo does not install its own copy of the AVD
toolchain -- see `requirements.txt`/`requirements.yml` for what venv it
expects.

```bash
source ~/avd-venv/bin/activate

# 1. Generate topology.clab.yml + inventory.yml from the registry
ansible-playbook playbooks/render_lab.yml

# 2. Build the firewall image (once; not published to any registry)
docker build -t frr-firewall:1 containerlab/frr-firewall/

# 3. Bring the lab up
sudo containerlab deploy -t containerlab/topology.clab.yml

# 4. Render the AVD intended config (writes inventory/intended/, no device access)
ansible-playbook -i inventory/inventory.yml playbooks/build.yml

# 5. Push it -- commit-confirm, holds the change open behind a timer
ansible-playbook -i inventory/inventory.yml playbooks/deploy_confirm.yml

# 6. Validate
ansible-playbook -i inventory/inventory.yml playbooks/validate.yml
ansible-playbook playbooks/verify_dataplane.yml
```

`playbooks/deploy_lab.yml` (plain `eos_config replace:config`, no
commit-confirm) is available for faster manual iteration once the management
plane is known-good, but is never what CI runs -- see `.gitlab-ci.yml`.

## CI

MR pipelines lint, check the registry for drift, and post the would-be config
diff as an MR note -- nothing touches a device. Pushing to `main` runs
precheck -> push -> postcheck against the live fabric. No automatic
rollback -- a postcheck failure just fails the pipeline; recovery is manual.
The only automatic safety net is `deploy_confirm.yml`'s own commit-confirm
timer (device-level, self-reverts if a push cuts its own management access).
See the top of `.gitlab-ci.yml` for the exact stage graph and
`docs/decisions.md` for why postcheck also runs
`playbooks/verify_dataplane.yml`, not just ANTA.

Required CI/CD variables on this project: `GITLAB_API_TOKEN` (masked, **not**
protected -- MR pipelines run on unprotected branches). `EOS_USERNAME` /
`EOS_PASSWORD` are optional and default to `admin`/`admin`.

---
Mirrored from a private GitLab instance where this is developed day-to-day.
