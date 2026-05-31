package local.aimonitor.jetbrains

import com.intellij.execution.ExecutionListener
import com.intellij.execution.process.ProcessHandler
import com.intellij.execution.runners.ExecutionEnvironment

class AiMonitorExecutionListener : ExecutionListener {
    override fun processStarted(executorId: String, env: ExecutionEnvironment, handler: ProcessHandler) {
        val project = env.project
        if (!AiMonitorSettings.getInstance(project).state.autoReportRunConfigurations) return
        val runName = runConfigurationName(env)
        val testRun = isTestRun(runName, executorId)
        AiMonitorClient.postRunConfigurationState(
            project,
            "running",
            if (testRun) "Tests running" else "Run configuration running",
            "$runName started with executor $executorId",
            if (testRun) "P1" else "P2",
            runName,
            executorId,
        )
    }

    override fun processNotStarted(executorId: String, env: ExecutionEnvironment) {
        val project = env.project
        if (!AiMonitorSettings.getInstance(project).state.autoReportRunConfigurations) return
        val runName = runConfigurationName(env)
        AiMonitorClient.postRunConfigurationState(
            project,
            "failed",
            "Run configuration failed to start",
            "$runName did not start",
            "P0",
            runName,
            executorId,
        )
    }

    override fun processTerminated(
        executorId: String,
        env: ExecutionEnvironment,
        handler: ProcessHandler,
        exitCode: Int,
    ) {
        val project = env.project
        if (!AiMonitorSettings.getInstance(project).state.autoReportRunConfigurations) return
        val runName = runConfigurationName(env)
        val testRun = isTestRun(runName, executorId)
        val failed = exitCode != 0
        AiMonitorClient.postRunConfigurationState(
            project,
            if (failed) "failed" else "completed",
            when {
                failed && testRun -> "Tests failed"
                testRun -> "Tests completed"
                failed -> "Run configuration failed"
                else -> "Run configuration completed"
            },
            "$runName exited with $exitCode",
            if (failed) "P0" else "P1",
            runName,
            executorId,
            exitCode,
        )
    }

    private fun runConfigurationName(env: ExecutionEnvironment): String =
        env.runProfile?.name?.takeIf { it.isNotBlank() }
            ?: env.runnerAndConfigurationSettings?.name?.takeIf { it.isNotBlank() }
            ?: "JetBrains Run"

    private fun isTestRun(name: String, executorId: String): Boolean {
        val value = "$name $executorId".lowercase()
        return listOf("test", "spec", "junit", "pytest", "gradle test").any(value::contains)
    }
}
