# FABRIC

## Table of Contents

- [Fabric Switches and Management IP](#fabric-switches-and-management-ip)
  - [Fabric Switches with inband Management IP](#fabric-switches-with-inband-management-ip)
- [Fabric Topology](#fabric-topology)
- [Fabric IP Allocation](#fabric-ip-allocation)
  - [Fabric Point-To-Point Links](#fabric-point-to-point-links)
  - [Point-To-Point Links Node Allocation](#point-to-point-links-node-allocation)
  - [Loopback Interfaces (BGP EVPN Peering)](#loopback-interfaces-bgp-evpn-peering)
  - [Loopback0 Interfaces Node Allocation](#loopback0-interfaces-node-allocation)
  - [VTEP Loopback VXLAN Tunnel Source Interfaces (VTEPs Only)](#vtep-loopback-vxlan-tunnel-source-interfaces-vteps-only)
  - [VTEP Loopback Node allocation](#vtep-loopback-node-allocation)

## Fabric Switches and Management IP

| POD | Type | Node | Management IP | Platform | Provisioned in CloudVision | Serial Number |
| --- | ---- | ---- | ------------- | -------- | -------------------------- | ------------- |
| FABRIC | l3leaf | borderleaf1 | 172.40.40.31/24 | cEOSLab | Provisioned | - |
| FABRIC | l3leaf | borderleaf2 | 172.40.40.32/24 | cEOSLab | Provisioned | - |
| FABRIC | l3leaf | leaf1a | 172.40.40.21/24 | cEOSLab | Provisioned | - |
| FABRIC | l3leaf | leaf1b | 172.40.40.22/24 | cEOSLab | Provisioned | - |
| FABRIC | l3leaf | leaf2a | 172.40.40.23/24 | cEOSLab | Provisioned | - |
| FABRIC | l3leaf | leaf2b | 172.40.40.24/24 | cEOSLab | Provisioned | - |
| FABRIC | spine | spine1 | 172.40.40.11/24 | cEOSLab | Provisioned | - |
| FABRIC | spine | spine2 | 172.40.40.12/24 | cEOSLab | Provisioned | - |

> Provision status is based on Ansible inventory declaration and do not represent real status from CloudVision.

### Fabric Switches with inband Management IP

| POD | Type | Node | Management IP | Inband Interface |
| --- | ---- | ---- | ------------- | ---------------- |

## Fabric Topology

| Type | Node | Node Interface | Peer Type | Peer Node | Peer Interface |
| ---- | ---- | -------------- | --------- | --------- | -------------- |
| l3leaf | borderleaf1 | Ethernet1 | spine | spine1 | Ethernet5 |
| l3leaf | borderleaf1 | Ethernet2 | spine | spine2 | Ethernet5 |
| l3leaf | borderleaf2 | Ethernet1 | spine | spine1 | Ethernet6 |
| l3leaf | borderleaf2 | Ethernet2 | spine | spine2 | Ethernet6 |
| l3leaf | leaf1a | Ethernet1 | spine | spine1 | Ethernet1 |
| l3leaf | leaf1a | Ethernet2 | spine | spine2 | Ethernet1 |
| l3leaf | leaf1b | Ethernet1 | spine | spine1 | Ethernet2 |
| l3leaf | leaf1b | Ethernet2 | spine | spine2 | Ethernet2 |
| l3leaf | leaf2a | Ethernet1 | spine | spine1 | Ethernet3 |
| l3leaf | leaf2a | Ethernet2 | spine | spine2 | Ethernet3 |
| l3leaf | leaf2b | Ethernet1 | spine | spine1 | Ethernet4 |
| l3leaf | leaf2b | Ethernet2 | spine | spine2 | Ethernet4 |

## Fabric IP Allocation

### Fabric Point-To-Point Links

| Uplink IPv4 Pool | Available Addresses | Assigned addresses | Assigned Address % |
| ---------------- | ------------------- | ------------------ | ------------------ |
| 10.254.0.0/24 | 256 | 24 | 9.38 % |

### Point-To-Point Links Node Allocation

| Node | Node Interface | Node IP Address | Peer Node | Peer Interface | Peer IP Address |
| ---- | -------------- | --------------- | --------- | -------------- | --------------- |
| borderleaf1 | Ethernet1 | 10.254.0.17/31 | spine1 | Ethernet5 | 10.254.0.16/31 |
| borderleaf1 | Ethernet2 | 10.254.0.19/31 | spine2 | Ethernet5 | 10.254.0.18/31 |
| borderleaf2 | Ethernet1 | 10.254.0.21/31 | spine1 | Ethernet6 | 10.254.0.20/31 |
| borderleaf2 | Ethernet2 | 10.254.0.23/31 | spine2 | Ethernet6 | 10.254.0.22/31 |
| leaf1a | Ethernet1 | 10.254.0.1/31 | spine1 | Ethernet1 | 10.254.0.0/31 |
| leaf1a | Ethernet2 | 10.254.0.3/31 | spine2 | Ethernet1 | 10.254.0.2/31 |
| leaf1b | Ethernet1 | 10.254.0.5/31 | spine1 | Ethernet2 | 10.254.0.4/31 |
| leaf1b | Ethernet2 | 10.254.0.7/31 | spine2 | Ethernet2 | 10.254.0.6/31 |
| leaf2a | Ethernet1 | 10.254.0.9/31 | spine1 | Ethernet3 | 10.254.0.8/31 |
| leaf2a | Ethernet2 | 10.254.0.11/31 | spine2 | Ethernet3 | 10.254.0.10/31 |
| leaf2b | Ethernet1 | 10.254.0.13/31 | spine1 | Ethernet4 | 10.254.0.12/31 |
| leaf2b | Ethernet2 | 10.254.0.15/31 | spine2 | Ethernet4 | 10.254.0.14/31 |

### Loopback Interfaces (BGP EVPN Peering)

| Loopback Pool | Available Addresses | Assigned addresses | Assigned Address % |
| ------------- | ------------------- | ------------------ | ------------------ |
| 10.255.0.0/24 | 256 | 2 | 0.79 % |
| 10.255.2.0/24 | 256 | 6 | 2.35 % |

### Loopback0 Interfaces Node Allocation

| POD | Node | Loopback0 |
| --- | ---- | --------- |
| FABRIC | borderleaf1 | 10.255.2.5/32 |
| FABRIC | borderleaf2 | 10.255.2.6/32 |
| FABRIC | leaf1a | 10.255.2.1/32 |
| FABRIC | leaf1b | 10.255.2.2/32 |
| FABRIC | leaf2a | 10.255.2.3/32 |
| FABRIC | leaf2b | 10.255.2.4/32 |
| FABRIC | spine1 | 10.255.0.1/32 |
| FABRIC | spine2 | 10.255.0.2/32 |

### VTEP Loopback VXLAN Tunnel Source Interfaces (VTEPs Only)

| VTEP Loopback Pool | Available Addresses | Assigned addresses | Assigned Address % |
| ------------------ | ------------------- | ------------------ | ------------------ |
| 10.255.3.0/24 | 256 | 6 | 2.35 % |

### VTEP Loopback Node allocation

| POD | Node | Loopback1 |
| --- | ---- | --------- |
| FABRIC | borderleaf1 | 10.255.3.5/32 |
| FABRIC | borderleaf2 | 10.255.3.6/32 |
| FABRIC | leaf1a | 10.255.3.1/32 |
| FABRIC | leaf1b | 10.255.3.2/32 |
| FABRIC | leaf2a | 10.255.3.3/32 |
| FABRIC | leaf2b | 10.255.3.4/32 |
