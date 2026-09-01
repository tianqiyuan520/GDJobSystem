#!/usr/bin/env python
import os
import sys

from methods import print_error


libname = "GDJobSystem"
projectdir = "project"

localEnv = Environment(tools=["default"], PLATFORM="")

# The JobSystem kernel (third_party/EntJoy) relies on C++ exceptions
# (std::exception_ptr in HandleState); godot-cpp defaults to no exceptions.
localEnv["disable_exceptions"] = False

# Build profiles can be used to decrease compile times.
# You can either specify "disabled_classes", OR
# explicitly specify "enabled_classes" which disables all other classes.
# Modify the example file as needed and uncomment the line below or
# manually specify the build_profile parameter when running SCons.

# localEnv["build_profile"] = "build_profile.json"

customs = ["custom.py"]
customs = [os.path.abspath(path) for path in customs]

opts = Variables(customs, ARGUMENTS)
opts.Update(localEnv)

Help(opts.GenerateHelpText(localEnv))

env = localEnv.Clone()

if not (os.path.isdir("godot-cpp") and os.listdir("godot-cpp")):
    print_error("""godot-cpp is not available within this folder, as Git submodules haven't been initialized.
Run the following command to download godot-cpp:

    git submodule update --init --recursive""")
    sys.exit(1)

env = SConscript("godot-cpp/SConstruct", {"env": env, "customs": customs})

# The EntJoy JobSystem kernel (third_party/EntJoy/src/NativeDll) requires C++20 (std::atomic::wait/notify)
# and exports its internal debug hooks guarded by JOB_SYSTEM_EXPORT.
# Drop godot-cpp's default C++17 flag first to avoid MSVC D9025 redefinition warnings.
env["CXXFLAGS"] = [f for f in env.get("CXXFLAGS", []) if "std:c++17" not in f and "std=c++17" not in f]
if env.get("is_msvc", False):
    env.Append(CXXFLAGS=["/std:c++20"])
else:
    env.Append(CXXFLAGS=["-std=c++20"])
env.Append(CPPDEFINES=["JOB_SYSTEM_EXPORT", "GDJS_EXPORTS"])

# MinGW 没有 #pragma comment(lib) 机制，Scheduler::Initialize 的 timeBeginPeriod
# 需显式链接 winmm（MSVC 由 JobSystem_Scheduler.cpp 内的 pragma 处理）。
if env["platform"] == "windows" and not env.get("is_msvc", False):
    env.Append(LIBS=["winmm"])

env.Append(CPPPATH=["src/", "third_party/EntJoy/src/NativeDll/"])

# EntJoy kernel sources are consumed from the submodule (third_party/EntJoy,
# sparse-checkout of src/NativeDll) via an explicit list: the NativeDll
# directory also contains Exports.cpp / Native.cpp / tasksys.cpp /
# JobDebuggerGUI.cpp (C# P/Invoke + ImGui layers) which must NOT be compiled here.
kernel_sources = [
    "third_party/EntJoy/src/NativeDll/JobSystem.cpp",
    "third_party/EntJoy/src/NativeDll/JobSystem_State.cpp",
    "third_party/EntJoy/src/NativeDll/JobSystem_Tiles.cpp",
    "third_party/EntJoy/src/NativeDll/JobSystem_Scheduler.cpp",
    "third_party/EntJoy/src/NativeDll/ChaseLevScheduler.cpp",
    "third_party/EntJoy/src/NativeDll/JobProfiler.cpp",
]
sources = Glob("src/*.cpp") + kernel_sources

if env["target"] in ["editor", "template_debug"]:
    try:
        doc_data = env.GodotCPPDocData("src/gen/doc_data.gen.cpp", source=Glob("doc_classes/*.xml"))
        sources.append(doc_data)
    except AttributeError:
        print("Not including class reference as we're targeting a pre-4.3 baseline.")

# .dev doesn't inhibit compatibility, so we don't need to key it.
# .universal just means "compatible with all relevant arches" so we don't need to key it.
suffix = env['suffix'].replace(".dev", "").replace(".universal", "")

lib_filename = "{}{}{}{}".format(env.subst('$SHLIBPREFIX'), libname, suffix, env.subst('$SHLIBSUFFIX'))

library = env.SharedLibrary(
    "bin/{}/{}".format(env['platform'], lib_filename),
    source=sources,
)

copy = env.Install("project/addons/GDJobsystem/bin/{}/".format(env["platform"]), library)

default_args = [library, copy]
Default(*default_args)
