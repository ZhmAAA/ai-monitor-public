package local.aimonitor.jetbrains

import com.intellij.openapi.project.Project
import com.intellij.openapi.vfs.VirtualFileManager
import java.net.HttpURLConnection
import java.net.URI
import java.nio.charset.StandardCharsets
import java.security.MessageDigest
import java.time.Instant

object AiMonitorClient {
    fun postState(
        project: Project,
        status: String,
        step: String,
        message: String,
        priority: String,
        taskIdSuffix: String = "agent",
        metadata: Map<String, String> = emptyMap(),
    ) {
        val settings = AiMonitorSettings.getInstance(project).state
        val workspace = project.basePath.orEmpty()
        val taskId = stableTaskId(settings.source, workspace, taskIdSuffix)
        val now = Instant.now().toString()
        val metadataJson = metadata.entries.joinToString(",\n") { (key, value) ->
            "                \"${json(key)}\": \"${json(value)}\""
        }
        val metadataSeparator = if (metadataJson.isBlank()) "" else ","
        val body = """
            {
              "event_id": "evt_ide_${System.currentTimeMillis()}",
              "task_id": "$taskId",
              "source": "${json(settings.source)}",
              "app": "JetBrains",
              "workspace": "${json(workspace)}",
              "session_name": "${json(project.name)}",
              "window_title": "JetBrains - ${json(project.name)}",
              "title": "${json(project.name)}",
              "status": "$status",
              "step": "${json(step)}",
              "message": "${json(message)}",
              "confidence": 0.9,
              "priority": "$priority",
              "notify_desktop": true,
              "notify_external": true,
              "created_at": "$now",
              "updated_at": "$now",
              "actions": [
                {
                  "label": "Open workspace",
                  "type": "open_file",
                  "target": "${json(workspace)}",
                  "file_path": "${json(workspace)}",
                  "metadata": {}
                }
              ],
              "metadata": {
                "ide": "jetbrains",
                "project_name": "${json(project.name)}",
                "project_url": "${json(VirtualFileManager.constructUrl("file", workspace))}"$metadataSeparator
$metadataJson
              }
            }
        """.trimIndent()
        request(settings.daemonUrl, "/events", "POST", settings.apiToken, body)
    }

    fun postRunConfigurationState(
        project: Project,
        status: String,
        step: String,
        message: String,
        priority: String,
        runConfigurationName: String,
        executorId: String,
        exitCode: Int? = null,
    ) {
        val suffix = if (isTestRun(runConfigurationName, executorId)) {
            "tests-${safeSuffix(runConfigurationName)}"
        } else {
            "run-${safeSuffix(runConfigurationName)}"
        }
        postState(
            project,
            status,
            step,
            message,
            priority,
            suffix,
            buildMap {
                put("jetbrains_run_configuration", runConfigurationName)
                put("jetbrains_executor_id", executorId)
                if (exitCode != null) put("jetbrains_exit_code", exitCode.toString())
                put("jetbrains_auto_report", "true")
            },
        )
    }

    fun deleteCurrentTask(project: Project) {
        val settings = AiMonitorSettings.getInstance(project).state
        val taskId = stableTaskId(settings.source, project.basePath.orEmpty(), "agent")
        request(settings.daemonUrl, "/tasks/$taskId", "DELETE", settings.apiToken, null)
    }

    private fun request(baseUrl: String, path: String, method: String, token: String, body: String?) {
        val url = localDaemonUri(baseUrl, path).toURL()
        val connection = url.openConnection() as HttpURLConnection
        connection.requestMethod = method
        connection.connectTimeout = 1500
        connection.readTimeout = 2500
        if (token.isNotBlank()) {
            connection.setRequestProperty("x-ai-monitor-token", token)
        }
        if (body != null) {
            val bytes = body.toByteArray(StandardCharsets.UTF_8)
            connection.doOutput = true
            connection.setRequestProperty("content-type", "application/json")
            connection.setRequestProperty("content-length", bytes.size.toString())
            connection.outputStream.use { it.write(bytes) }
        }
        if (connection.responseCode !in 200..299) {
            throw IllegalStateException("AI Monitor returned HTTP ${connection.responseCode}")
        }
    }

    private fun localDaemonUri(baseUrl: String, path: String): URI {
        val uri = URI(baseUrl.trim().trimEnd('/') + path)
        val scheme = uri.scheme?.lowercase()
        if (scheme != "http" || !isLoopbackHost(uri.host)) {
            throw IllegalArgumentException("AI Monitor daemon URL must be local HTTP loopback")
        }
        return uri
    }

    private fun isLoopbackHost(host: String?): Boolean {
        val normalized = host?.lowercase() ?: return false
        if (normalized == "localhost" || normalized == "::1" || normalized == "[::1]") {
            return true
        }
        val parts = normalized.split(".")
        if (parts.size != 4 || parts.first() != "127") {
            return false
        }
        return parts.all { part ->
            val value = part.toIntOrNull()
            value != null && value in 0..255
        }
    }

    private fun stableTaskId(source: String, workspace: String, suffix: String): String {
        val digest = MessageDigest.getInstance("SHA-1")
            .digest("$source\u0000$workspace\u0000$suffix".toByteArray(StandardCharsets.UTF_8))
            .take(8)
            .joinToString("") { "%02x".format(it) }
        return "ide_${source}_$digest"
    }

    private fun json(value: String): String =
        value.replace("\\", "\\\\").replace("\"", "\\\"").replace("\n", "\\n")

    private fun isTestRun(name: String, executorId: String): Boolean {
        val value = "$name $executorId".lowercase()
        return listOf("test", "spec", "junit", "pytest", "gradle test").any(value::contains)
    }

    private fun safeSuffix(value: String): String =
        value.lowercase()
            .replace(Regex("[^a-z0-9]+"), "-")
            .trim('-')
            .ifEmpty { "configuration" }
            .take(48)
}
