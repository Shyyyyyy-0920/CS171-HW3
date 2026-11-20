# Distributed under the OSI-approved BSD 3-Clause License.  See accompanying
# file LICENSE.rst or https://cmake.org/licensing for details.

cmake_minimum_required(VERSION ${CMAKE_VERSION}) # this file comes with cmake

# If CMAKE_DISABLE_SOURCE_CHANGES is set to true and the source directory is an
# existing directory in our source tree, calling file(MAKE_DIRECTORY) on it
# would cause a fatal error, even though it would be a no-op.
if(NOT EXISTS "E:/CS171/ShanghaiTech-CS171/HW/CS171-HW3/build-cuda/_deps/linalg-src")
  file(MAKE_DIRECTORY "E:/CS171/ShanghaiTech-CS171/HW/CS171-HW3/build-cuda/_deps/linalg-src")
endif()
file(MAKE_DIRECTORY
  "E:/CS171/ShanghaiTech-CS171/HW/CS171-HW3/build-cuda/_deps/linalg-build"
  "E:/CS171/ShanghaiTech-CS171/HW/CS171-HW3/build-cuda/_deps/linalg-subbuild/linalg-populate-prefix"
  "E:/CS171/ShanghaiTech-CS171/HW/CS171-HW3/build-cuda/_deps/linalg-subbuild/linalg-populate-prefix/tmp"
  "E:/CS171/ShanghaiTech-CS171/HW/CS171-HW3/build-cuda/_deps/linalg-subbuild/linalg-populate-prefix/src/linalg-populate-stamp"
  "E:/CS171/ShanghaiTech-CS171/HW/CS171-HW3/build-cuda/_deps/linalg-subbuild/linalg-populate-prefix/src"
  "E:/CS171/ShanghaiTech-CS171/HW/CS171-HW3/build-cuda/_deps/linalg-subbuild/linalg-populate-prefix/src/linalg-populate-stamp"
)

set(configSubDirs )
foreach(subDir IN LISTS configSubDirs)
    file(MAKE_DIRECTORY "E:/CS171/ShanghaiTech-CS171/HW/CS171-HW3/build-cuda/_deps/linalg-subbuild/linalg-populate-prefix/src/linalg-populate-stamp/${subDir}")
endforeach()
if(cfgdir)
  file(MAKE_DIRECTORY "E:/CS171/ShanghaiTech-CS171/HW/CS171-HW3/build-cuda/_deps/linalg-subbuild/linalg-populate-prefix/src/linalg-populate-stamp${cfgdir}") # cfgdir has leading slash
endif()
