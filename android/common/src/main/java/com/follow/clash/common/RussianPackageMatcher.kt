package com.follow.clash.common

import android.Manifest
import android.content.pm.PackageInfo
import android.content.pm.PackageManager
import android.os.Build

/**
 * Identifies Russian domestic Android packages that must bypass the VPN tunnel
 * by default so they never observe VPN exit node IPs:
 *
 * 1. Curated non-`ru.*` domestic packages (e.g. `com.idamob.tinkoff.android`,
 *    `com.vkontakte.android`, `com.avito.android`, `com.wildberries.ru`,
 *    `psb.market.app`, `logo.com.mbanking`, etc.).
 * 2. Any installed package under Russian top-level package roots (`ru.*`, `su.*`)
 *    that requests `INTERNET`.
 * 3. Any installed package with `INTERNET` whose installer source is RuStore
 *    (`ru.vk.store`), catching renamed banking/fintech APKs distributed via
 *    RuStore regardless of package prefix.
 *
 * Browsers (including `com.yandex.browser*` and `ru.mail.browser`) and global
 * apps that users rely on VPN to reach are explicitly skipped so blocked sites
 * continue working inside mobile browsers even when installed from RuStore.
 */
object RussianPackageMatcher {

    val RUSTORE_INSTALLERS: Set<String> = setOf(
        "ru.vk.store",
        "ru.rustore.sdk",
    )

    private val SKIPPED_PREFIXES: List<String> = listOf(
        // Browsers must remain inside the VPN tunnel so blocked websites open.
        "com.yandex.browser",
        "ru.mail.browser",
        "com.android.chrome",
        "com.chrome.beta",
        "com.chrome.dev",
        "com.chrome.canary",
        "org.chromium.chrome",
        "org.cromite.cromite",
        "org.mozilla.firefox",
        "org.mozilla.firefox_beta",
        "org.mozilla.fenix",
        "org.mozilla.focus",
        "com.brave.browser",
        "com.brave.browser_beta",
        "com.brave.browser_nightly",
        "com.opera.browser",
        "com.opera.browser.beta",
        "com.opera.mini.native",
        "com.opera.gx",
        "com.vivaldi.browser",
        "com.microsoft.emmx",
        "com.duckduckgo.mobile.android",
        "org.torproject.torbrowser",
        "com.sec.android.app.sbrowser",
        "com.mi.globalbrowser",
        // Core Android / Google platform & global apps that require VPN access
        // even if side-loaded or updated through alternative stores.
        "com.google",
        "com.android.vending",
        "org.telegram.messenger",
        "org.thunderdog.challegram",
        "tw.nekomimi.nekogram",
        "uz.unnarsx.cherrygram",
        "com.whatsapp",
        "com.discord",
        "com.instagram.android",
        "com.zhiliaoapp.musically",
        "com.ss.android.ugc.trill",
        "com.spotify.music",
        "com.openai.chatgpt",
        "com.anthropic.claude",
        "com.twitter.android",
        "com.reddit.frontpage",
        "com.netflix.mediaclient",
        "tv.twitch.android.app",
        "com.valvesoftware.android.steam.community",
    )

    private val RUSSIAN_ROOT_PREFIXES: List<String> = listOf(
        "ru.",
        "su.",
    )

    val CURATED_NON_RU_PACKAGES: Set<String> = setOf(
        "cb.ibank",
        "cb.ibank.v2",
        "com.allgoritm.youla",
        "com.apegroup.mcdonaldsrussia",
        "com.appkode.pobeda.aero",
        "com.avito.android",
        "com.bank.domrf.v2",
        "com.carshering",
        "com.cdek.tracking",
        "com.drweb",
        "com.ertelecom.domru",
        "com.ertelecom.domrutv",
        "com.gnivts.selfemployed",
        "com.idamob.tinkoff.android",
        "com.kms.free",
        "com.lamoda.lite",
        "com.logistic.sdek",
        "com.notissimus.allinstruments.android",
        "com.octopod.russianpost.client.android",
        "com.openbank",
        "com.punicapp.whoosh",
        "com.raiffeisen.raiffeisenonline",
        "com.rencredit.mobile",
        "com.s7.s7air",
        "com.tochka.bank",
        "com.uma.musicvk",
        "com.vk.admin",
        "com.vk.calls",
        "com.vk.clips",
        "com.vk.im",
        "com.vk.mail",
        "com.vkontakte.android",
        "com.wildberries.ru",
        "com.yandex.aliceapp",
        "com.yandex.bank",
        "com.yandex.iot",
        "com.yandex.lavka",
        "goldapple.ru.goldapple.customers",
        "gpm.tnt_premier",
        "limehd.ru.ctv",
        "logo.com.mbanking",
        "octopod.russianpost.client",
        "promsvyazbank.android.app",
        "psb.market.app",
        "tv.okko.androidtv",
        "tv.start.android",
        "youdrive.today",
    )

    fun isSkipped(packageName: String): Boolean = SKIPPED_PREFIXES.any { prefix ->
        packageName == prefix || packageName.startsWith("$prefix.")
    }

    fun matchesRussianRootPrefix(packageName: String): Boolean =
        RUSSIAN_ROOT_PREFIXES.any(packageName::startsWith)

    fun isRussianCandidate(
        packageName: String,
        appPackageName: String,
        hasInternetPermission: Boolean = true,
        installerPackageNames: Set<String> = emptySet(),
    ): Boolean {
        if (packageName.isBlank() ||
            packageName == appPackageName ||
            packageName == ANDROID_PACKAGE_NAME
        ) {
            return false
        }
        if (isSkipped(packageName)) {
            return false
        }
        if (CURATED_NON_RU_PACKAGES.contains(packageName)) {
            return true
        }
        if (!hasInternetPermission) {
            return false
        }
        if (matchesRussianRootPrefix(packageName)) {
            return true
        }
        return installerPackageNames.any(RUSTORE_INSTALLERS::contains)
    }

    fun resolveEffectiveRejectSet(
        explicitRejectList: Collection<String>,
        autoDetectedRussian: Collection<String>,
        autoRejectExcludedList: Collection<String>?,
        autoRejectRussian: Boolean,
        appPackageName: String,
    ): Set<String> {
        val excluded = autoRejectExcludedList.orEmpty().toSet()
        val autoRejected = if (autoRejectRussian) {
            autoDetectedRussian.asSequence().filterNot(excluded::contains).toSet()
        } else {
            emptySet()
        }
        return (explicitRejectList.toSet() + autoRejected) - appPackageName
    }

    fun findInstalledRussianPackages(
        packageManager: PackageManager,
        appPackageName: String,
    ): Set<String> {
        val packages = runCatching { getInstalledPackagesWithPermissions(packageManager) }
            .getOrDefault(emptyList())
        if (packages.isEmpty()) {
            return emptySet()
        }
        val matched = LinkedHashSet<String>()
        for (info in packages) {
            val pkg = info.packageName
            if (pkg.isBlank() || pkg == appPackageName || pkg == ANDROID_PACKAGE_NAME || isSkipped(pkg)) {
                continue
            }
            if (CURATED_NON_RU_PACKAGES.contains(pkg)) {
                matched.add(pkg)
                continue
            }
            val hasInternet = info.requestedPermissions
                ?.contains(Manifest.permission.INTERNET) == true
            if (!hasInternet) {
                continue
            }
            if (matchesRussianRootPrefix(pkg)) {
                matched.add(pkg)
                continue
            }
            val installers = queryInstallerPackages(packageManager, pkg)
            if (installers.any(RUSTORE_INSTALLERS::contains)) {
                matched.add(pkg)
            }
        }
        return matched
    }

    private fun getInstalledPackagesWithPermissions(
        packageManager: PackageManager,
    ): List<PackageInfo> {
        val flags = PackageManager.GET_PERMISSIONS
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            packageManager.getInstalledPackages(
                PackageManager.PackageInfoFlags.of(flags.toLong()),
            )
        } else {
            @Suppress("DEPRECATION")
            packageManager.getInstalledPackages(flags)
        }
    }

    private fun queryInstallerPackages(
        packageManager: PackageManager,
        packageName: String,
    ): Set<String> = runCatching {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            val source = packageManager.getInstallSourceInfo(packageName)
            setOfNotNull(
                source.installingPackageName,
                source.initiatingPackageName,
                source.originatingPackageName,
            )
        } else {
            @Suppress("DEPRECATION")
            setOfNotNull(packageManager.getInstallerPackageName(packageName))
        }
    }.getOrDefault(emptySet())

    private const val ANDROID_PACKAGE_NAME = "android"
}
