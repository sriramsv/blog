+++
date = '2026-07-12T00:00:00Z'
draft = false
title = 'Monitoring my home network from a free Oracle VPS, without exposing anything'
tags = ['gatus', 'tailscale', 'oracle-cloud', 'homelab', 'monitoring', 'self-hosted']
+++

I wanted a status page that tells me when something at home goes down. Home Assistant, internal
DNS, my Zigbee coordinator, all of it. And I wanted the checks to run from outside my network,
because if the thing checking "is it up" is sitting on the same LAN, it's not really telling you
anything. Problem is, I didn't want to port-forward anything into my home network to make that
work. No way.

So I ended up with a free Oracle Cloud VM running [Gatus](https://gatus.io/), and it reaches into
my home LAN entirely over [Tailscale](https://tailscale.com/). No public ports opened on the
router, no home services sitting behind a reverse proxy on the internet. Only thing exposed is
the Gatus dashboard, and even that's tailnet-only.

## Architecture

```
              ┌───────────────────────┐
              │   oracle1 (OCI VM)    │
              │  ┌─────────────────┐  │
              │  │ docktail        │  │   Tailscale service (tailnet-only)
              │  │  (labels-based  │──┼──▶ gatus.<tailnet>.ts.net   ◀── my phone/laptop
              │  │   TS proxy)     │  │
              │  │                 │  │   Tailscale service (tailnet-only)
              │  │  ┌───────────┐  │──┼──▶ ntfy.<tailnet>.ts.net    ◀── my phone/laptop
              │  │  │  gatus    │  │  │
              │  │  └─────┬─────┘  │  │
              │  └────────┼────────┘  │
              │       tailscaled      │   (installed on host, plain tailnet client)
              └───────────┼───────────┘
                          │  WireGuard, encrypted, tailnet-wide
                          ▼
              ┌───────────────────────┐
              │  Talos subnet router  │   Connector CR: advertises
              │  (pod in home k8s)    │   192.168.1.0/24, 192.168.20.0/26
              └───────────┼───────────┘
                          │
                          ▼
              Home LAN — 192.168.1.137 (Zigbee coordinator),
              192.168.1.53 (internal DNS), Home Assistant, etc.
```

There are two different Tailscale roles here, don't mix them up:

- **oracle1** is just a normal tailnet client. It doesn't advertise any routes, it's just another
  peer that happens to run Gatus and Docktail on it.
- The actual **subnet router** is separate, running as a Tailscale Operator `Connector` pod
  inside my home Talos Kubernetes cluster. It advertises the home LAN CIDRs into the tailnet.
  This is the only reason oracle1 can hit `192.168.1.137` directly. Tailscale routes that traffic
  over the encrypted mesh like oracle1 is sitting right there on my home LAN, without touching
  the router config at all.

## Setting up the VPS

Oracle's free tier gives you a `VM.Standard.E2.1.Micro`, nothing fancy, 1/8 OCPU and 1GB RAM, but
it's more than enough to run Gatus polling a couple dozen endpoints. Provisioned with OpenTofu:

```hcl
provider "oci" {
  tenancy_ocid     = var.tenancy_ocid
  user_ocid        = var.user_ocid
  fingerprint      = var.fingerprint
  private_key_path = var.private_key_path
  region           = var.region
}
```

The security list only opens SSH, HTTP and HTTPS to the internet. No rule for Tailscale's UDP
port anywhere. Don't need one — Tailscale either relays through DERP or punches through NAT via
STUN, so the tailnet mesh doesn't need an inbound hole on the firewall.

## Getting traffic to Gatus, no reverse proxy needed

Instead of running Traefik or nginx in front of Gatus, the compose stack uses
[Docktail](https://github.com/marvinvr/docktail). It reads Docker labels off each container and
registers it as its own Tailscale service, reachable only inside the tailnet — nothing here
touches Funnel, nothing gets a public HTTPS endpoint:

```yaml
docktail:
  image: ghcr.io/marvinvr/docktail:latest
  volumes:
    - /var/run/docker.sock:/var/run/docker.sock:ro
    - /var/run/tailscale:/var/run/tailscale
  environment:
    - TAILSCALE_OAUTH_CLIENT_ID={{ ts_oauth_client_id }}
    - TAILSCALE_OAUTH_CLIENT_SECRET={{ ts_oauth_client_secret }}
    - DEFAULT_SERVICE_TAGS=tag:docktail-service

gatus:
  labels:
    - "docktail.service.enable=true"
    - "docktail.service.name=gatus"
    - "docktail.service.port=8080"
    - "docktail.service.service-port=443"
```

Gatus is only reachable inside the tailnet at `gatus.<tailnet>.ts.net` through MagicDNS. `ntfy`,
which handles alert delivery, gets the same treatment — its own tailnet service at
`ntfy.<tailnet>.ts.net`. Both stay tailnet-private, nothing is punched out to the public internet.

## Gatus config

Endpoints are grouped by area — `iot`, `media`, `tools`, `infra`, `DNS`. Two of them only work
because the subnet router exists:

```yaml
- name: coordinator
  group: iot
  url: "http://192.168.1.137"
  conditions: ["[CONNECTED] == true"]

- name: tailscale-apple-tv
  group: infra
  url: "icmp://apple-tv.antelope-puffin.ts.net"
  interval: 30s
  conditions: ["[CONNECTED] == true"]
  alerts:
    - description: "Tailscale subnet router (Apple TV) is down! Home network unreachable."
```

First one's a plain LAN IP. Gatus, running on a VM in San Jose, is pinging a Zigbee coordinator
sitting on my home network directly. No Tailscale client on the coordinator itself, nothing. Just
works because the subnet router made the whole CIDR routable.

Second one's got a naming issue I still haven't cleaned up. The alert text says "Apple TV"
because that's what used to run the subnet router, ages back. It's now a dedicated Connector pod
in my Talos cluster, but I never updated the alert description. Still works fine, just misleading
if I ever have to debug this at 2am and forget what it actually means now.

Alerts go out through ntfy:

```yaml
alerting:
  ntfy:
    topic: "gatus"
    url: "https://ntfy.antelope-puffin.ts.net"
    priority: 3
    token: "{{ ntfy_monitoring_token }}"
```

## The subnet router itself

This is the part that actually makes everything work, and it lives at home, not on the VPS. A
Tailscale Operator `Connector` resource running as a pod in my Talos Kubernetes cluster (still
named `k3s-subnet-router` from before I moved off k3s, haven't renamed it either):

```yaml
apiVersion: tailscale.com/v1alpha1
kind: Connector
metadata:
  name: k3s-subnet-router
spec:
  hostname: k3s-subnet-router
  exitNode: true
  subnetRouter:
    advertiseRoutes:
      - "192.168.1.0/24"
      - "192.168.20.0/26"
```

That's it. One pod advertises two home CIDRs into the tailnet, and any tailnet peer that accepts
routes — oracle1 included — can reach anything in those ranges like it's sitting locally. No need
to install Tailscale on the coordinator, the DNS box, or anything else at home. One router
handles the whole subnet.

This has been solid: zero public exposure of anything at home, zero recurring cost, and a status
page that actually tells me whether my home network is reachable from the outside world, not just
whether my home Wi-Fi thinks everything's fine.
