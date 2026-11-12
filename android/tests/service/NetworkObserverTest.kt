package com.follow.clash.service

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class NetworkObserverTest {

    @Test
    fun `validated cellular beats unvalidated wifi`() {
        val unvalidatedWifi = computeNetworkPriority(
            transportRank = 0,
            isVpn = false,
            isValidated = false,
            losingPenalty = 0,
        )
        val validatedCellular = computeNetworkPriority(
            transportRank = 4,
            isVpn = false,
            isValidated = true,
            losingPenalty = 0,
        )

        assertTrue(validatedCellular < unvalidatedWifi)
    }

    @Test
    fun `validated wifi beats validated cellular until losing`() {
        val validatedWifi = computeNetworkPriority(
            transportRank = 0,
            isVpn = false,
            isValidated = true,
            losingPenalty = 0,
        )
        val losingWifi = computeNetworkPriority(
            transportRank = 0,
            isVpn = false,
            isValidated = true,
            losingPenalty = 10,
        )
        val validatedCellular = computeNetworkPriority(
            transportRank = 4,
            isVpn = false,
            isValidated = true,
            losingPenalty = 0,
        )

        assertTrue(validatedWifi < validatedCellular)
        assertTrue(validatedCellular < losingWifi)
    }

    @Test
    fun `route tracker skips initial startup, offline gaps, and catches 464xlat ipv4 arrival`() {
        val tracker = RouteSwitchTracker()

        // Initial Wi-Fi startup does not reset network.
        assertFalse(
            tracker.onPreferredRoute(
                RouteFingerprint(netHandle = 100L, hasIpv4 = true, hasIpv6 = false),
            ),
        )
        // Duplicate callback is ignored.
        assertFalse(
            tracker.onPreferredRoute(
                RouteFingerprint(netHandle = 100L, hasIpv4 = true, hasIpv6 = false),
            ),
        )
        // Switch to IPv6-only LTE triggers reset.
        assertTrue(
            tracker.onPreferredRoute(
                RouteFingerprint(netHandle = 200L, hasIpv4 = false, hasIpv6 = true),
            ),
        )
        // Delayed 464xlat clat4 IPv4 arrival on the same netHandle triggers reset.
        assertTrue(
            tracker.onPreferredRoute(
                RouteFingerprint(netHandle = 200L, hasIpv4 = true, hasIpv6 = true),
            ),
        )
        // Offline gap does NOT trigger reset while disconnected, avoiding ClientBind spin.
        assertFalse(tracker.onPreferredRoute(null))
        assertTrue(tracker.hadDisconnect)
        // Reconnecting to the very same network after an offline gap triggers reset.
        assertTrue(
            tracker.onPreferredRoute(
                RouteFingerprint(netHandle = 200L, hasIpv4 = true, hasIpv6 = true),
            ),
        )
        assertFalse(tracker.hadDisconnect)
    }

    @Test
    fun `delayed slaac ipv6 flap on active ipv4 wifi does not reset unless vpn ipv6 enabled`() {
        val tracker = RouteSwitchTracker()

        // Initial Wi-Fi with IPv4 only.
        assertFalse(
            tracker.onPreferredRoute(
                RouteFingerprint(netHandle = 300L, hasIpv4 = true, hasIpv6 = false),
                vpnIpv6Enabled = false,
            ),
        )
        // Delayed SLAAC Router Advertisement adds IPv6 on the same Wi-Fi while VPN IPv6 is disabled.
        assertFalse(
            tracker.onPreferredRoute(
                RouteFingerprint(netHandle = 300L, hasIpv4 = true, hasIpv6 = true),
                vpnIpv6Enabled = false,
            ),
        )
        // Subsequent SLAAC expiry on the same Wi-Fi also stays silent when VPN IPv6 is disabled.
        assertFalse(
            tracker.onPreferredRoute(
                RouteFingerprint(netHandle = 300L, hasIpv4 = true, hasIpv6 = false),
                vpnIpv6Enabled = false,
            ),
        )
        // When VPN IPv6 IS enabled, IPv6 arrival on the same network does trigger reset.
        assertTrue(
            tracker.onPreferredRoute(
                RouteFingerprint(netHandle = 300L, hasIpv4 = true, hasIpv6 = true),
                vpnIpv6Enabled = true,
            ),
        )
    }
}
