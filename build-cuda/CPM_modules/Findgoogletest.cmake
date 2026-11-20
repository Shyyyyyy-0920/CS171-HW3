include("E:/CS171/ShanghaiTech-CS171/HW/CS171-HW3/data/CPM.cmake")
CPMAddPackage("NAME;googletest;GITHUB_REPOSITORY;google/googletest;GIT_TAG;main;OPTIONS;INSTALL_GTEST OFF;gtest_force_shared_crt")
set(googletest_FOUND TRUE)