# The Flutter wrapper keeps its stable libmpv API headers. Runtime DLLs are locked
# independently and provide the same FFT analyzer on both Windows architectures.
find_package(Python3 COMPONENTS Interpreter REQUIRED)
get_filename_component(BOBTV_SOURCE_ROOT "${CMAKE_CURRENT_SOURCE_DIR}/../../.." ABSOLUTE)
if(FLUTTER_TARGET_PLATFORM STREQUAL "windows-arm64")
  set(BOBTV_AUDIO_ARCH "arm64")
else()
  set(BOBTV_AUDIO_ARCH "x64")
endif()
set(BOBTV_AUDIO_RUNTIME "${CMAKE_BINARY_DIR}/bobtv-audio-runtime")
execute_process(
  COMMAND "${Python3_EXECUTABLE}" "${BOBTV_SOURCE_ROOT}/tools/native/prepare_audio_runtime.py"
          windows --arch "${BOBTV_AUDIO_ARCH}" --output "${BOBTV_AUDIO_RUNTIME}"
  RESULT_VARIABLE BOBTV_AUDIO_RESULT OUTPUT_QUIET ERROR_VARIABLE BOBTV_AUDIO_ERROR)
if(NOT BOBTV_AUDIO_RESULT EQUAL 0)
  message(FATAL_ERROR "Verified FFT runtime preparation failed: ${BOBTV_AUDIO_ERROR}")
endif()
file(GLOB BOBTV_AUDIO_DLLS "${BOBTV_AUDIO_RUNTIME}/*.dll")
if(NOT EXISTS "${BOBTV_AUDIO_RUNTIME}/libmpv-2.dll")
  message(FATAL_ERROR "The native audio runtime does not contain libmpv")
endif()
# Prefer the locked runtime's newer common DLLs over duplicate ANGLE support DLLs.
set(BOBTV_AUDIO_BUNDLED ${BOBTV_AUDIO_DLLS})
foreach(ANGLE_FILE IN LISTS BOBTV_ANGLE_FILES)
  get_filename_component(ANGLE_NAME "${ANGLE_FILE}" NAME)
  if(NOT EXISTS "${BOBTV_AUDIO_RUNTIME}/${ANGLE_NAME}")
    list(APPEND BOBTV_AUDIO_BUNDLED "${ANGLE_FILE}")
  endif()
endforeach()
set(media_kit_libs_windows_video_bundled_libraries ${BOBTV_AUDIO_BUNDLED} PARENT_SCOPE)
install(DIRECTORY "${BOBTV_AUDIO_RUNTIME}/ThirdPartyNotices" DESTINATION "." COMPONENT Runtime)
set_property(DIRECTORY APPEND PROPERTY CMAKE_CONFIGURE_DEPENDS "${BOBTV_SOURCE_ROOT}/tools/native/runtime-lock.json")
