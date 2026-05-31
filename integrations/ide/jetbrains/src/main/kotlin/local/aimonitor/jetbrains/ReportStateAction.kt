package local.aimonitor.jetbrains

import com.intellij.openapi.actionSystem.AnAction
import com.intellij.openapi.actionSystem.AnActionEvent
import com.intellij.openapi.ui.Messages

class ReportStateAction : AnAction() {
    override fun actionPerformed(event: AnActionEvent) {
        val project = event.project ?: return
        val presentation = event.presentation.text.orEmpty()
        val state = stateForAction(presentation)
        try {
            AiMonitorClient.postState(project, state.status, state.step, state.message, state.priority)
        } catch (error: Exception) {
            Messages.showWarningDialog(project, error.message ?: "AI Monitor delivery failed", "AI Monitor")
        }
    }

    private fun stateForAction(text: String): ReportState =
        when {
            text.contains("Waiting", ignoreCase = true) ->
                ReportState("waiting_for_input", "Waiting for input", "JetBrains agent is waiting for user input", "P0")
            text.contains("Pending", ignoreCase = true) ->
                ReportState("idle_but_not_done", "Pending changes", "JetBrains agent has pending changes or diff approval", "P0")
            text.contains("Completed", ignoreCase = true) ->
                ReportState("completed", "IDE task completed", "JetBrains agent or task completed", "P1")
            text.contains("Failed", ignoreCase = true) ->
                ReportState("failed", "IDE task failed", "JetBrains agent or task failed", "P0")
            else ->
                ReportState("running", "IDE task running", "JetBrains agent or task is running", "P2")
        }
}

data class ReportState(
    val status: String,
    val step: String,
    val message: String,
    val priority: String,
)
