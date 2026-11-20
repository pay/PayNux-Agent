package com.pocketdev.paynuxagent

import java.io.File

/**
 * Single authoritative writer for the PRoot DNS bind source and its rootfs
 * fallback. Both files are written atomically from the SAME content, so DNS
 * inside PRoot is consistent whether the bind succeeds or not.
 *
 * No Android API is used here: callers supply the DNS content obtained from
 * Android's ConnectivityManager. This keeps the writer unit-testable.
 */
object DnsConfig {
    class Failure(message: String) : Exception(message)

    /**
     * Explicit fallback policy, used ONLY when the Android active network
     * exposes no DNS servers. Public resolvers are never appended to a
     * non-empty system list, so VPN-provided DNS is not bypassed silently.
     */
    const val PUBLIC_DNS_FALLBACK = "nameserver 8.8.8.8\nnameserver 8.8.4.4\n"

    /** Format all given DNS servers (order preserved, duplicates removed). */
    fun formatServers(servers: List<String>): String {
        val cleaned = servers.map { it.trim() }.filter { it.isNotEmpty() }.distinct()
        if (cleaned.isEmpty()) return PUBLIC_DNS_FALLBACK
        return cleaned.joinToString("\n") { "nameserver $it" } + "\n"
    }

    /** @param configDir host directory holding config/resolv.conf (bind source)
     *  @param rootfsEtcDir guest rootfs /etc directory (fallback destination)
     */
    fun ensure(configDir: File, rootfsEtcDir: File, content: String): File {
        if (content.isBlank()) throw Failure("DNS content is empty")
        if (content.lines().none { it.trim().startsWith("nameserver ") }) {
            throw Failure("DNS content has no nameserver entry")
        }

        val bindFile = atomicWrite(File(configDir, "resolv.conf"), content)
        // Failure here must abort the PRoot launch, never be swallowed.
        val fallback = atomicWrite(File(rootfsEtcDir, "resolv.conf"), content)
        verify(bindFile)
        verify(fallback)
        return bindFile
    }

    private fun atomicWrite(target: File, content: String): File {
        val dir = target.parentFile
            ?: throw Failure("No parent directory for ${target.absolutePath}")
        if (!dir.exists() && !dir.mkdirs()) {
            throw Failure("Cannot create DNS directory: ${dir.absolutePath}")
        }

        val tmp = try {
            File.createTempFile(".${target.name}-", ".tmp", dir)
        } catch (e: Exception) {
            throw Failure("Cannot create temp DNS file in ${dir.absolutePath}: ${e.message}")
        }

        try {
            tmp.writeText(content)
            if (!tmp.renameTo(target)) {
                // Some Android filesystems refuse rename over an existing file.
                // Never delete a directory or other non-regular target.
                if (target.exists() && !target.isFile) {
                    throw Failure("DNS target is not a regular file: ${target.absolutePath}")
                }
                if (target.exists() && !target.delete()) {
                    throw Failure("Cannot replace DNS file: ${target.absolutePath}")
                }
                if (!tmp.renameTo(target)) {
                    throw Failure("Atomic rename failed for ${target.absolutePath}")
                }
            }
        } finally {
            if (tmp.exists()) tmp.delete()
        }
        return target
    }

    private fun verify(file: File) {
        if (!file.exists() || !file.isFile || file.length() == 0L || !file.canRead()) {
            throw Failure(
                "DNS file unavailable: ${file.absolutePath}; " +
                    "exists=${file.exists()}, length=${if (file.exists()) file.length() else -1}",
            )
        }
    }
}
