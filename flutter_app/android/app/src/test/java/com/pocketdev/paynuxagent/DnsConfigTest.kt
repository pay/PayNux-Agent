package com.pocketdev.paynuxagent

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import java.nio.file.Files

class DnsConfigTest {
    private fun tempDir(): File = Files.createTempDirectory("paynux-dns").toFile()

    @Test
    fun writesBindAndFallbackWithIdenticalContent() {
        val base = tempDir()
        val config = File(base, "config")
        val etc = File(base, "rootfs/ubuntu/etc")
        val content = "nameserver 10.0.0.1\nnameserver 8.8.8.8\n"

        val bind = DnsConfig.ensure(config, etc, content)

        assertEquals(File(config, "resolv.conf"), bind)
        assertArrayEquals(content.toByteArray(), File(config, "resolv.conf").readBytes())
        assertArrayEquals(content.toByteArray(), File(etc, "resolv.conf").readBytes())
        assertEquals(0, config.listFiles { it.name.startsWith(".") }?.size ?: 0)
        base.deleteRecursively()
    }

    @Test
    fun replacesExistingFilesAtomically() {
        val base = tempDir()
        val config = File(base, "config")
        val etc = File(base, "rootfs/ubuntu/etc")
        config.mkdirs(); etc.mkdirs()
        File(config, "resolv.conf").writeText("nameserver 1.1.1.1\n")
        File(etc, "resolv.conf").writeText("nameserver 1.1.1.1\n")

        val content = "nameserver 10.0.0.1\n"
        DnsConfig.ensure(config, etc, content)

        assertEquals(content, File(config, "resolv.conf").readText())
        assertEquals(content, File(etc, "resolv.conf").readText())
        assertFalse(config.listFiles()!!.any { it.name.startsWith(".") })
        base.deleteRecursively()
    }

    @Test
    fun blankContentFailsWithoutTouchingFiles() {
        val base = tempDir()
        val config = File(base, "config")
        val etc = File(base, "rootfs/ubuntu/etc")
        val original = "nameserver 9.9.9.9\n"
        File(config, "resolv.conf").apply { parentFile.mkdirs(); writeText(original) }

        assertThrows(DnsConfig.Failure::class.java) {
            DnsConfig.ensure(config, etc, "   ")
        }
        assertEquals(original, File(config, "resolv.conf").readText())
        base.deleteRecursively()
    }

    @Test
    fun contentWithoutNameserverIsRejected() {
        val base = tempDir()
        val config = File(base, "config")
        val etc = File(base, "rootfs/ubuntu/etc")
        assertThrows(DnsConfig.Failure::class.java) {
            DnsConfig.ensure(config, etc, "garbage\n")
        }
        assertFalse(File(config, "resolv.conf").exists())
        base.deleteRecursively()
    }

    @Test
    fun fallbackIsVerifiedToo() {
        val base = tempDir()
        val config = File(base, "config")
        val etc = File(base, "rootfs/ubuntu/etc")
        etc.mkdirs()
        // A directory where resolv.conf should be forces rename to fail.
        File(etc, "resolv.conf").mkdirs()

        assertThrows(DnsConfig.Failure::class.java) {
            DnsConfig.ensure(config, etc, "nameserver 8.8.8.8\n")
        }
        // Bind file may have been written, but the call reported failure so
        // the PRoot launch must be aborted by the caller.
        assertTrue(File(config, "resolv.conf").exists() || File(config, "resolv.conf").parentFile.exists())
        base.deleteRecursively()
    }

    @Test
    fun systemDnsIsUsedWithoutPublicResolverAppended() {
        val content = DnsConfig.formatServers(listOf("10.0.0.1", "192.168.1.1"))
        assertEquals("nameserver 10.0.0.1\nnameserver 192.168.1.1\n", content)
        assertFalse(content.contains("8.8.8.8"))
    }

    @Test
    fun vpnDnsIsPreservedVerbatim() {
        val content = DnsConfig.formatServers(listOf("10.8.0.1"))
        assertEquals("nameserver 10.8.0.1\n", content)
        assertEquals(1, content.lines().count { it.isNotBlank() })
    }

    @Test
    fun explicitFallbackOnlyWhenSystemDnsIsEmpty() {
        assertEquals(DnsConfig.PUBLIC_DNS_FALLBACK, DnsConfig.formatServers(emptyList()))
        assertEquals(DnsConfig.PUBLIC_DNS_FALLBACK, DnsConfig.formatServers(listOf("  ")))
    }
}
