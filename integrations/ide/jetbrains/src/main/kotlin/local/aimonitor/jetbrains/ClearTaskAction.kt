package local.aimonitor.jetbrains

import com.intellij.openapi.actionSystem.AnAction
import com.intellij.openapi.actionSystem.AnActionEvent
import com.intellij.openapi.ui.Messages

class ClearTaskAction : AnAction() {
    override fun actionPerformed(event: AnActionEvent) {
        val project = event.project ?: return
        try {
            AiMonitorClient.deleteCurrentTask(project)
        } catch (error: Exception) {
            Messages.showWarningDialog(project, error.message ?: "AI Monitor clear failed", "AI Monitor")
        }
    }
}
