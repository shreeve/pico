# Wi-Fi and Networking Notes

Practical implementation notes, current status, and near-term roadmap for the
CYW43439 Wi-Fi and networking stack on Pico W / Pico 2 W.

## Current proven state (April 5, 2026)

The Pico W networking stack is proven on real hardware through DHCP:

- PIO SPI / gSPI transport at 31 MHz
- firmware upload + NVRAM token + HT clock boot
- SDPCM/CDC IOCTL control plane
- CLM upload and onboard LED control
- Wi-Fi scan discovering nearby SSIDs and hidden networks
- WPA2-PSK join with retry/cooldown handling
- raw Ethernet TX/RX through the CYW43 data channel
- DHCP client bound at `10.0.0.27` without lwIP
- ARP responder present in the tree
- DHCP lease-renewal logic present in the tree

Representative boot log:

```text
[cyw43] SPI OK
[cyw43] ALP clock OK
[cyw43] verify OK
[cyw43] HT clock OK — firmware running
[cyw43] F2 ready
[cyw43] MAC=28:cd:c1:10:3e:1b
[cyw43] CLM loaded
[cyw43] LED blink OK
[cyw43] WiFi UP
[scan] 8 networks found:
  -38 dBm  c6:50:9c:9e:fc:69  Shreeve
  ...
[join] associated!
[dhcp] offer 10.0.0.27 from 10.0.0.1
[dhcp] bound 10.0.0.27 gw 10.0.0.1 mask 255.255.255.0
[wifi] IP=10.0.0.27
```

## What is fully proven

- scan results are deduplicated by BSSID
- hidden networks render as `(Hidden)`
- `pollDevice()` drains all pending packets, not just one
- `bsscfg:` iovars require an extra interface index word
- WPA2 join may require a retry/cooldown after AP deauth
- data-channel TX requires BDC version 2 (`0x20`)
- the reorganized source tree still boots, joins `Shreeve:innovation`, and gets a DHCP lease

## What is present but still needs validation or hardening

- ARP responder should be revalidated explicitly from another machine on the LAN
- DHCP renewal semantics need more soak testing and stricter timeout handling
- TCP transport is still a stub in `src/net/tcp.zig`
- the JS-facing Wi-Fi/MQTT surface exists but is not yet a complete runtime API

## What is next

1. Validate ARP from another machine on the LAN
2. Harden DHCP renewal semantics and lease expiry behavior
3. Build minimal TCP/IP state on top of the working Ethernet path
4. Layer TLS and MQTT on top of the TCP path
5. Expose stable JS-facing network APIs
6. Improve provisioning / commissioning flow

## Scope boundary

This document is for:

- current networking milestone status
- what is proven on hardware
- what is next in the stack

Low-level CYW43 transport, firmware-upload, and bus/protocol bring-up details live in `CYW43.md`.
The host-side CLI/debug-tool vision lives in `PICO.md`.
