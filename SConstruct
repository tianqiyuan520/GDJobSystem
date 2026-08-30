#!/usr/bin/env python
import os
import sys

from methods import print_error


libname = "GDJobSystem"
projectdir = "project"

localEnv = Environment(tools=["default"], PLATFORM="")

# The JobSystem kernel (src/native) relies on C++ exceptions
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

# The EntJoy JobSystem kernel (src/native) requires C++20 (std::atomic::wait/notify)
# and exports its internal debug hooks guarded by JOB_SYSTEM_EXPORT.
# Drop godot-cpp's default C++17 flag first to avoid MSVC D9025 redefinition warnings.
env["CXXFLAGS"] = [f for f in env.get("CXXFLAGS", []) if "std:c++17" not in f and "std=c++17" not in f]
if env.get("is_msvc", False):
    env.Append(CXXFLAGS=["/std:c++20"])
else:
    env.Append(CXXFLAGS=["-std=c++20"])
env.Append(CPPDEFINES=["JOB_SYSTEM_EXPORT"])

env.Append(CPPPATH=["src/", "src/native/"])
sources = Glob("src/*.cpp") + Glob("src/native/*.cpp")

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
