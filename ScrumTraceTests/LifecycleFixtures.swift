@testable import ScrumTrace

/// Test setup only: put a fixture manifest straight into a saved state, the way a manifest on disk can be.
/// Production code changes the lifecycle through `SessionLifecycle`'s transitions.
extension SessionManifest {
    var fixtureStatus: PipelineStatus {
        get { pipelineStatus }
        set { lifecycle = SessionLifecycle(status: newValue, completedStages: completedStages) }
    }

    var fixtureStages: [PipelineStatus] {
        get { completedStages }
        set { lifecycle = SessionLifecycle(status: pipelineStatus, completedStages: newValue) }
    }
}
