// Stub implementation for JobSystem::JobDebuggerGUI.
// The full Dear ImGui debug panel (JobDebuggerGUI.cpp + thirdParty/imgui) is not
// part of the GDJobSystem plugin build. These no-op stubs satisfy the call from
// JobSystem_Scheduler.cpp (Scheduler::Initialize -> JobDebuggerGUI::TryLaunch).
#include "JobDebuggerGUI.h"

namespace JobSystem
{
    void JobDebuggerGUI::TryLaunch()
    {
        // Debug GUI intentionally disabled in GDJobSystem build.
    }

    void JobDebuggerGUI::Launch()
    {
        // Debug GUI intentionally disabled in GDJobSystem build.
    }

    void JobDebuggerGUI::Shutdown()
    {
        // Debug GUI intentionally disabled in GDJobSystem build.
    }
}
