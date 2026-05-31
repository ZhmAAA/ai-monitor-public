package local.aimonitor.jetbrains

import com.intellij.openapi.components.PersistentStateComponent
import com.intellij.openapi.components.Service
import com.intellij.openapi.components.State
import com.intellij.openapi.components.Storage
import com.intellij.openapi.project.Project

@State(name = "AiMonitorSettings", storages = [Storage("ai-monitor.xml")])
@Service(Service.Level.PROJECT)
class AiMonitorSettings : PersistentStateComponent<AiMonitorSettings.State> {
    data class State(
        var daemonUrl: String = "http://127.0.0.1:4318",
        var apiToken: String = "",
        var source: String = "jetbrains",
        var autoReportRunConfigurations: Boolean = true,
    )

    private var state = State()

    override fun getState(): State = state

    override fun loadState(state: State) {
        this.state = state
    }

    companion object {
        fun getInstance(project: Project): AiMonitorSettings =
            project.getService(AiMonitorSettings::class.java)
    }
}
