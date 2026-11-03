# App Review notes

iADB has no login or server account. It connects to an Android 11 or newer device over the review device's local Wi-Fi network.

## Test setup

1. Put the iPhone or iPad and Android device on the same Wi-Fi network.
2. On Android, enable Developer options and Wireless debugging.
3. Open **Pair device with pairing code** on Android.
4. In iADB, tap **Connect a Device** on the welcome screen, then choose **Pair Device** or select the discovered device. Enter the address, pairing port, and six-digit code shown by Android.
5. After pairing, iADB connects automatically if the discovered Bonjour service remains available. Otherwise, enter the IP address and regular Wireless debugging port from Android's main Wireless debugging screen, then tap **Connect**. Allow Local Network access when iOS asks.

After connection, Device, Files, Apps, Console, and Screens become available. Console contains Shell and Logs. Screens can save a captured Android screenshot to Photos after the reviewer grants add-only Photos access.

The pairing port and regular Wireless debugging port differ. If Android closes its pairing dialog before step 4, open the dialog again and use the new code and port.

## Local network use

iADB finds Android devices over these channels, all of them confined to the local subnet:

- Bonjour (`_adb-tls-connect._tcp`, `_adb-tls-pairing._tcp`), declared in `NSBonjourServices`.
- SSDP: a UPnP `M-SEARCH` to `239.255.255.250:1900` plus a unicast copy to each address in the subnet, so discovery still works on access points that drop multicast. No multicast entitlement is used.
- A TCP connect probe of port 5555 on the subnet, used when the device runs `adb tcpip` and advertises nothing.
- The default gateway of the current Wi-Fi network, dialled once as soon as a scan starts. This is the device itself whenever it is the one hosting the hotspot.
- Endpoints the user connected to before.

Both the gateway and the ARP neighbour list come from the BSD routing table via `sysctl(CTL_NET, PF_ROUTE, ...)`. This is the same public interface the system `netstat` uses: it needs no entitlement, returns only addresses on the network the phone is already joined to, and nothing from it is transmitted or stored off the device. The gateway is read rather than assumed to be `.1` because a hotspot host may be configured with any address, and probing the wrong one costs a full connect timeout on every scan.

The SSDP step also fetches the device's UPnP description document over plain HTTP from the device itself, to show its model name. That request never leaves the local network, which is why `NSAllowsLocalNetworking` is set in `NSAppTransportSecurity`. No public host is ever contacted.

The app uses TLS, RSA authentication, SPAKE2 pairing, and AES-GCM as required by Android's wireless ADB protocol. The `ITSAppUsesNonExemptEncryption` flag is set to `true`; complete the export-compliance questions in App Store Connect for the selected distribution regions.
