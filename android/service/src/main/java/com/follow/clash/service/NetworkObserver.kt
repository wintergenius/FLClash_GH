package com.follow.clash.service

import android.net.ConnectivityManager
import android.net.LinkProperties
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkCapabilities.TRANSPORT_SATELLITE
import android.net.NetworkCapabilities.TRANSPORT_USB
import android.net.NetworkRequest
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import androidx.core.content.getSystemService
import com.follow.clash.common.GlobalState
import com.follow.clash.core.Core
import java.net.Inet4Address
import java.net.Inet6Address
import java.net.InetAddress
import java.util.concurrent.ConcurrentHashMap

internal data class RouteFingerprint(
    val netHandle: Long,
    val hasIpv4: Boolean,
    val hasIpv6: Boolean,
) {
    val hasUsableAddress: Boolean
        get() = hasIpv4 || hasIpv6
}

internal class RouteSwitchTracker {
    var lastFingerprint: RouteFingerprint? = null
        private set
    var hadDisconnect: Boolean = false
        private set

    fun onPreferredRoute(fingerprint: RouteFingerprint?): Boolean {
        if (fingerprint == null || !fingerprint.hasUsableAddress) {
            if (lastFingerprint != null) {
                hadDisconnect = true
            }
            return false
        }
        val shouldReset = lastFingerprint != null &&
            (fingerprint != lastFingerprint || hadDisconnect)
        lastFingerprint = fingerprint
        hadDisconnect = false
        return shouldReset
    }
}

internal fun computeNetworkPriority(
    transportRank: Int,
    isVpn: Boolean,
    isValidated: Boolean,
    losingPenalty: Int,
): Int {
    if (isVpn) return 900
    val validationPenalty = if (isValidated) 0 else 100
    return transportRank + validationPenalty + losingPenalty
}

private data class NetworkInfo(
    @Volatile var losingUntilMillis: Long = 0,
    @Volatile var capabilities: NetworkCapabilities? = null,
    @Volatile var dnsList: List<InetAddress> = emptyList(),
    @Volatile var hasIpv4: Boolean = false,
    @Volatile var hasIpv6: Boolean = false,
) {
    val priorityPenalty: Int
        get() = if (losingUntilMillis > System.currentTimeMillis()) 10 else 0
}

// Outlives every service run: the Core also tests delays and updates providers
// while stopped, and a `system` nameserver has no upstream until DNS arrives here.
object NetworkObserver {

    private val networkInfos = ConcurrentHashMap<Network, NetworkInfo>()
    private val connectivity by lazy {
        GlobalState.application.getSystemService<ConnectivityManager>()
    }
    private val handler by lazy {
        Handler(HandlerThread("NetworkObserve").apply { start() }.looper)
    }
    private var currentDnsList = listOf<String>()
    private val routeSwitchTracker = RouteSwitchTracker()
    private var started = false

    private val request = NetworkRequest.Builder().apply {
        addCapability(NetworkCapabilities.NET_CAPABILITY_NOT_VPN)
        addCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            addCapability(NetworkCapabilities.NET_CAPABILITY_FOREGROUND)
        }
        addCapability(NetworkCapabilities.NET_CAPABILITY_NOT_RESTRICTED)
    }.build()

    private val callback = object : ConnectivityManager.NetworkCallback() {
        override fun onAvailable(network: Network) {
            val info = NetworkInfo(
                capabilities = connectivity?.getNetworkCapabilities(network),
            )
            connectivity?.getLinkProperties(network)?.let { info.applyLinkProperties(it) }
            networkInfos[network] = info
            scheduleUpdateNetwork()
        }

        override fun onCapabilitiesChanged(
            network: Network,
            networkCapabilities: NetworkCapabilities,
        ) {
            val info = networkInfos.computeIfAbsent(network) { NetworkInfo() }
            info.capabilities = networkCapabilities
            scheduleUpdateNetwork()
        }

        override fun onLosing(network: Network, maxMsToLive: Int) {
            val info = networkInfos[network] ?: return
            info.losingUntilMillis = System.currentTimeMillis() + maxMsToLive
            scheduleUpdateNetwork()
            if (maxMsToLive > 0) {
                handler.postDelayed({
                    if (networkInfos.containsKey(network)) {
                        updateNetwork()
                    }
                }, maxMsToLive.toLong() + 50)
            }
        }

        override fun onLost(network: Network) {
            networkInfos.remove(network)
            scheduleUpdateNetwork()
        }

        override fun onLinkPropertiesChanged(network: Network, linkProperties: LinkProperties) {
            val info = networkInfos.computeIfAbsent(network) {
                NetworkInfo(capabilities = connectivity?.getNetworkCapabilities(network))
            }
            info.applyLinkProperties(linkProperties)
            scheduleUpdateNetwork()
        }
    }

    private fun NetworkInfo.applyLinkProperties(linkProperties: LinkProperties) {
        dnsList = linkProperties.dnsServers
        var v4 = false
        var v6 = false
        for (linkAddress in linkProperties.linkAddresses) {
            val addr = linkAddress.address
            if (addr.isLinkLocalAddress || addr.isLoopbackAddress) continue
            when (addr) {
                is Inet4Address -> v4 = true
                is Inet6Address -> v6 = true
            }
        }
        hasIpv4 = v4
        hasIpv6 = v6
    }

    private val updateNetworkTask = Runnable(::updateNetwork)

    // Coalesces the burst of onAvailable + onCapabilitiesChanged +
    // onLinkPropertiesChanged (+ 464xlat clat4 bring-up) into a single switch.
    private fun scheduleUpdateNetwork() {
        handler.removeCallbacks(updateNetworkTask)
        handler.postDelayed(updateNetworkTask, NETWORK_UPDATE_DELAY_MILLIS)
    }

    @Synchronized
    fun start() {
        if (started) return
        runCatching { requireNotNull(connectivity).registerNetworkCallback(request, callback) }
            .onSuccess { started = true }
            .onFailure { error -> GlobalState.log("Unable to observe networks: $error") }
    }

    private fun networkPriority(entry: Map.Entry<Network, NetworkInfo>): Int {
        val capabilities = entry.value.capabilities
            ?: connectivity?.getNetworkCapabilities(entry.key)
            ?: return 1000
        val isVpn = capabilities.hasTransport(NetworkCapabilities.TRANSPORT_VPN)
        val isValidated = capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED)
        val transportRank = when {
            capabilities.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) -> 0
            capabilities.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET) -> 1
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.S &&
                capabilities.hasTransport(TRANSPORT_USB) -> 2

            capabilities.hasTransport(NetworkCapabilities.TRANSPORT_BLUETOOTH) -> 3
            capabilities.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) -> 4
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.VANILLA_ICE_CREAM &&
                capabilities.hasTransport(TRANSPORT_SATELLITE) -> 5

            else -> 20
        }
        return computeNetworkPriority(
            transportRank = transportRank,
            isVpn = isVpn,
            isValidated = isValidated,
            losingPenalty = entry.value.priorityPenalty,
        )
    }

    @Synchronized
    private fun updateNetwork() {
        val preferred = networkInfos.entries.minByOrNull(::networkPriority)
        val dnsList = preferred
            ?.value
            ?.dnsList
            .orEmpty()
            .map { address -> address.asSocketAddressText(DNS_PORT) }
            .distinct()
        // Never overwrite Core system DNS with an empty string when all networks
        // transiently disappear.
        if (dnsList.isNotEmpty() && dnsList != currentDnsList) {
            currentDnsList = dnsList
            Core.updateDNS(dnsList.joinToString(","))
        }
        val fingerprint = preferred?.let { (network, info) ->
            RouteFingerprint(
                netHandle = network.networkHandle,
                hasIpv4 = info.hasIpv4,
                hasIpv6 = info.hasIpv6,
            )
        }
        if (routeSwitchTracker.onPreferredRoute(fingerprint)) {
            Core.resetNetwork()
        }
    }
}

private const val DNS_PORT = 53
private const val NETWORK_UPDATE_DELAY_MILLIS = 350L

private fun InetAddress.asSocketAddressText(port: Int): String = when (this) {
    is Inet6Address -> "[$hostAddress]:$port"
    is Inet4Address -> "$hostAddress:$port"
    else -> error("Unsupported address type: ${javaClass.name}")
}
