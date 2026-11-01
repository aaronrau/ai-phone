cmake_minimum_required(VERSION 3.22)
project(receptionist_pocket LANGUAGES C CXX)
include(FetchContent)
find_program(POCKET_PATCH_EXECUTABLE patch REQUIRED)
# Pocket TTS runtime source (pinned commit and hash below) and the patch applied to it.
file(SHA256 ${CMAKE_CURRENT_LIST_DIR}/pocket-runtime.patch POCKET_PATCH_SHA)
set_property(DIRECTORY APPEND PROPERTY CMAKE_CONFIGURE_DEPENDS
  ${CMAKE_CURRENT_LIST_DIR}/pocket-runtime.patch)
FetchContent_Declare(pocket_source
  URL https://codeload.github.com/soniqo/speech-core/tar.gz/c2cdcf2f1b90f15acac640cf8cf5233ed1f388a9
  URL_HASH SHA256=c11a07313600da4c4d18750f55915c6ea4349d61f43f022038eca7d53dbb617f
  SOURCE_DIR ${CMAKE_CURRENT_BINARY_DIR}/pocket-source-${POCKET_PATCH_SHA}
  PATCH_COMMAND ${POCKET_PATCH_EXECUTABLE} -p1 -i ${CMAKE_CURRENT_LIST_DIR}/pocket-runtime.patch)
FetchContent_GetProperties(pocket_source)
if(NOT pocket_source_POPULATED)
  FetchContent_Populate(pocket_source)
endif()
set(ORT_INCLUDE ${CMAKE_CURRENT_BINARY_DIR}/ort-include)
file(MAKE_DIRECTORY ${ORT_INCLUDE})
foreach(HEADER onnxruntime_c_api.h onnxruntime_ep_c_api.h)
  if(HEADER STREQUAL "onnxruntime_c_api.h")
    set(HASH c4ed26d7bbc7b649c1c38622424d88dfb1a28e3d3594c5f1456cf458814e8381)
  else()
    set(HASH f65ac849718cabe3ff4902698dd2de643c3b3dbe0010242b2b0407548e7ee00c)
  endif()
  file(DOWNLOAD https://raw.githubusercontent.com/microsoft/onnxruntime/v1.27.0/include/onnxruntime/core/session/${HEADER}
    ${ORT_INCLUDE}/${HEADER} EXPECTED_HASH SHA256=${HASH} TLS_VERIFY ON)
endforeach()
add_library(onnxruntime SHARED IMPORTED)
set_target_properties(onnxruntime PROPERTIES IMPORTED_LOCATION ${ORT_LIB_DIR}/${ANDROID_ABI}/libonnxruntime.so)
add_library(receptionist_pocket SHARED pocket_jni.cpp pocket_core.cpp
  ${pocket_source_SOURCE_DIR}/src/models/pocket/onnx_pocket_tts.cpp
  ${pocket_source_SOURCE_DIR}/src/models/pocket/pocket_tts_tokenizer.cpp
  ${pocket_source_SOURCE_DIR}/src/tts_synthesis_options.cpp
  ${pocket_source_SOURCE_DIR}/src/audio/offline_spectral_de_esser.cpp
  ${pocket_source_SOURCE_DIR}/third_party/fftooura/ooura_fft_engine.cpp
  ${pocket_source_SOURCE_DIR}/third_party/fftooura/fft4g.cpp)
target_compile_features(receptionist_pocket PRIVATE cxx_std_17)
target_compile_options(receptionist_pocket PRIVATE -O3)
target_include_directories(receptionist_pocket PRIVATE ${ORT_INCLUDE} ${CMAKE_CURRENT_LIST_DIR}
  ${pocket_source_SOURCE_DIR}/include ${pocket_source_SOURCE_DIR}/third_party
  ${pocket_source_SOURCE_DIR}/third_party/fftooura)
target_link_libraries(receptionist_pocket PRIVATE onnxruntime log)
