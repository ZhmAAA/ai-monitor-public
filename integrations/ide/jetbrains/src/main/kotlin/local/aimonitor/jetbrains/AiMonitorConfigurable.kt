package local.aimonitor.jetbrains

import com.intellij.openapi.options.Configurable
import com.intellij.openapi.project.ProjectManager
import com.intellij.ui.components.JBCheckBox
import com.intellij.ui.components.JBTextField
import com.intellij.util.ui.FormBuilder
import javax.swing.JComponent
import javax.swing.JPanel

class AiMonitorConfigurable : Configurable {
    private val daemonUrl = JBTextField()
    private val apiToken = JBTextField()
    private val source = JBTextField()
    private val autoReport = JBCheckBox("Auto-report run configurations")
    private var panel: JPanel? = null

    override fun getDisplayName(): String = "AI Monitor"

    override fun createComponent(): JComponent {
        val settings = firstProjectSettings()
        daemonUrl.text = settings?.state?.daemonUrl ?: "http://127.0.0.1:4318"
        apiToken.text = settings?.state?.apiToken ?: ""
        source.text = settings?.state?.source ?: "jetbrains"
        autoReport.isSelected = settings?.state?.autoReportRunConfigurations ?: true

        panel = FormBuilder.createFormBuilder()
            .addLabeledComponent("Daemon URL", daemonUrl)
            .addLabeledComponent("API token", apiToken)
            .addLabeledComponent("Source", source)
            .addComponent(autoReport)
            .panel
        return panel!!
    }

    override fun isModified(): Boolean {
        val settings = firstProjectSettings()?.state ?: return false
        return settings.daemonUrl != daemonUrl.text ||
            settings.apiToken != apiToken.text ||
            settings.source != source.text ||
            settings.autoReportRunConfigurations != autoReport.isSelected
    }

    override fun apply() {
        val settings = firstProjectSettings()?.state ?: return
        settings.daemonUrl = daemonUrl.text.trim()
        settings.apiToken = apiToken.text.trim()
        settings.source = source.text.trim().ifEmpty { "jetbrains" }
        settings.autoReportRunConfigurations = autoReport.isSelected
    }

    private fun firstProjectSettings(): AiMonitorSettings? =
        ProjectManager.getInstance().openProjects.firstOrNull()?.let(AiMonitorSettings::getInstance)
}
