cmake_minimum_required(VERSION 3.24)
project(JawalHost LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_MSVC_RUNTIME_LIBRARY "MultiThreaded$<$<CONFIG:Debug>:Debug>")

add_executable(Jawal WIN32
    src/main.cpp
    src/PackageBridge.cpp
    src/VmController.cpp
)

target_include_directories(Jawal PRIVATE src)
target_compile_definitions(Jawal PRIVATE UNICODE _UNICODE NOMINMAX WIN32_LEAN_AND_MEAN)
target_link_libraries(Jawal PRIVATE dwmapi shell32 shlwapi ws2_32)

if(MSVC)
    target_compile_options(Jawal PRIVATE /W4 /permissive- /EHsc)
endif()
