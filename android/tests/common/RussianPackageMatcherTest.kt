package com.follow.clash.common

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class RussianPackageMatcherTest {

    private val selfPkg = "com.follow.clash"

    @Test
    fun `matches ru and su package roots on a strict dot boundary`() {
        assertTrue(RussianPackageMatcher.isRussianCandidate("ru.sberbankmobile", selfPkg))
        assertTrue(RussianPackageMatcher.isRussianCandidate("ru.chelindbank.mobile", selfPkg))
        assertTrue(RussianPackageMatcher.isRussianCandidate("su.some.regional.service", selfPkg))

        assertFalse(RussianPackageMatcher.isRussianCandidate("run.docker.app", selfPkg))
        assertFalse(RussianPackageMatcher.isRussianCandidate("super.app.global", selfPkg))
    }

    @Test
    fun `matches curated non-ru Russian apps`() {
        val curated = listOf(
            "com.idamob.tinkoff.android",
            "com.vkontakte.android",
            "com.avito.android",
            "com.wildberries.ru",
            "psb.market.app",
            "logo.com.mbanking",
            "cb.ibank",
            "com.gnivts.selfemployed",
            "com.yandex.bank",
            "goldapple.ru.goldapple.customers",
            "youdrive.today",
            "gpm.tnt_premier",
        )
        for (pkg in curated) {
            assertTrue(pkg, RussianPackageMatcher.isRussianCandidate(pkg, selfPkg))
        }
    }

    @Test
    fun `matches renamed apps installed from RuStore when they use the internet`() {
        assertTrue(
            RussianPackageMatcher.isRussianCandidate(
                packageName = "com.renamed.secretbank.client",
                appPackageName = selfPkg,
                hasInternetPermission = true,
                installerPackageNames = setOf("ru.vk.store"),
            ),
        )
        assertFalse(
            RussianPackageMatcher.isRussianCandidate(
                packageName = "com.offline.flashlight",
                appPackageName = selfPkg,
                hasInternetPermission = false,
                installerPackageNames = setOf("ru.vk.store"),
            ),
        )
    }

    @Test
    fun `never auto-excludes browsers or global VPN-dependent apps even from RuStore`() {
        val protectedBrowsersAndGlobal = listOf(
            "com.yandex.browser",
            "com.yandex.browser.beta",
            "com.yandex.browser.lite",
            "ru.mail.browser",
            "com.android.chrome",
            "org.mozilla.firefox",
            "com.brave.browser",
            "com.opera.browser",
            "com.vivaldi.browser",
            "org.telegram.messenger",
            "com.google.android.youtube",
            "com.instagram.android",
            "com.discord",
            "com.openai.chatgpt",
        )
        for (pkg in protectedBrowsersAndGlobal) {
            assertFalse(
                pkg,
                RussianPackageMatcher.isRussianCandidate(
                    packageName = pkg,
                    appPackageName = selfPkg,
                    hasInternetPermission = true,
                    installerPackageNames = setOf("ru.vk.store"),
                ),
            )
        }
    }

    @Test
    fun `never excludes the VPN app itself or android framework`() {
        assertFalse(RussianPackageMatcher.isRussianCandidate(selfPkg, selfPkg))
        assertFalse(RussianPackageMatcher.isRussianCandidate("ru.custom.vpnclient", "ru.custom.vpnclient"))
        assertFalse(RussianPackageMatcher.isRussianCandidate("android", selfPkg))
    }

    @Test
    fun `resolveEffectiveRejectSet respects user manual opt-outs and removes self`() {
        val result = RussianPackageMatcher.resolveEffectiveRejectSet(
            explicitRejectList = listOf("ru.sberbankmobile", selfPkg),
            autoDetectedRussian = listOf("ru.regional.bank", "ru.opted.out.game"),
            autoRejectExcludedList = listOf("ru.opted.out.game"),
            autoRejectRussian = true,
            appPackageName = selfPkg,
        )

        assertEquals(
            setOf("ru.sberbankmobile", "ru.regional.bank"),
            result,
        )
    }
}
